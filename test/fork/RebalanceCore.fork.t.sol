// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";
import {RebalanceCoreScript} from "../../script/06_RebalanceCore.s.sol";

/// @notice Executes the exact Safe batch that script 06 emits, from the Safe, against a fork of the live pool:
///         with and without price drift before execution, then proves a FLOCK sell that crosses the old upper edge
///         still fills.
/// @dev forge test --match-contract RebalanceCoreFork --fork-url robinhood -vv
contract RebalanceCoreFork is BaseTest {
    using StateLibrary for IPoolManager;

    address constant HOOK = 0x33e924fb8663871bAb61D6844e79CDea159C60c0;
    address constant SAFE = RobinhoodV4.FLOCK_SAFE;
    uint256 constant CORE_TOKEN_ID = 1701445;

    IERC20 flock = IERC20(RobinhoodV4.FLOCK);
    IERC20 googl = IERC20(RobinhoodV4.GOOGL);
    address trader = makeAddr("trader");

    modifier onlyFork() {
        if (block.chainid != RobinhoodV4.CHAIN_ID || HOOK.code.length == 0) return;
        _;
    }

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID || HOOK.code.length == 0) return;
        deployArtifactsAndLabel();
        vm.setEnv("HOOK_ADDRESS", vm.toString(HOOK));
        vm.setEnv("CORE_TOKEN_ID", vm.toString(CORE_TOKEN_ID));
    }

    function _plan() internal returns (RebalanceCoreScript.Plan memory p, RebalanceCoreScript.Tx[] memory txs) {
        RebalanceCoreScript s = new RebalanceCoreScript();
        (p, txs) = s.build();
        assertEq(p.owner, SAFE, "core NFT must be owned by the Safe");
    }

    function _execute(RebalanceCoreScript.Tx[] memory txs) internal {
        for (uint256 i = 0; i < txs.length; i++) {
            vm.prank(SAFE);
            (bool ok, bytes memory ret) = txs[i].to.call(txs[i].data);
            require(ok, string.concat("batch tx failed: ", txs[i].name, " ", vm.toString(ret)));
        }
    }

    /// @dev Stock-token amount held by a position that sits entirely above spot.
    function _stockInFarBand(RebalanceCoreScript.Plan memory p, uint128 liq) internal pure returns (uint256) {
        return LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtPriceAtTick(p.farLower), TickMath.getSqrtPriceAtTick(p.farUpper), liq
        );
    }

    function test_batchExecutesFromSafe_andFarBandIsStockOnly() public onlyFork {
        (RebalanceCoreScript.Plan memory p, RebalanceCoreScript.Tx[] memory txs) = _plan();
        uint256 safeGooglBefore = googl.balanceOf(SAFE);
        uint256 safeFlockBefore = flock.balanceOf(SAFE);
        uint128 coreBefore = positionManager.getPositionLiquidity(CORE_TOKEN_ID);
        uint256 farId = positionManager.nextTokenId();

        _execute(txs);

        assertEq(positionManager.getPositionLiquidity(CORE_TOKEN_ID), coreBefore - p.decrease, "core reduced by the plan");
        // All the stock token the decrease returned went into the far band (up to 1 wei of rounding), FLOCK to the Safe.
        uint128 farLiq = positionManager.getPositionLiquidity(farId);
        assertEq(IERC721Owner(address(positionManager)).ownerOf(farId), SAFE);
        assertGt(farLiq, 0);
        // The decrease also collects the position's accrued fees, which the mint consumes too (a few % at most).
        uint256 farStock = _stockInFarBand(p, farLiq);
        assertGe(farStock + 1, p.expect0, "far band holds at least the returned stock token principal");
        assertLt(farStock, p.expect0 * 105 / 100, "far band holds principal + accrued fees only");
        assertLt(googl.balanceOf(SAFE) - safeGooglBefore, 1e12, "no stock token left idle in the Safe");
        uint256 flockGot = flock.balanceOf(SAFE) - safeFlockBefore;
        assertGe(flockGot + 1e12, p.expect1, "FLOCK principal returned to the Safe");
        assertLt(flockGot, p.expect1 * 105 / 100, "FLOCK principal + accrued fees only");
        assertGt(p.farLower, p.tick, "far band strictly above spot");
        (uint160 left,,) = permit2.allowance(SAFE, RobinhoodV4.GOOGL, address(positionManager));
        assertLe(left, uint160(p.dust), "only the dust allowance can remain");
    }

    function test_batchSurvivesFlockWeakeningBeforeExecution() public onlyFork {
        (RebalanceCoreScript.Plan memory p, RebalanceCoreScript.Tx[] memory txs) = _plan();
        // FLOCK weakens ~3% vs GOOGL before the Safe signs: a trader sells FLOCK into the pool.
        uint128 sellIn = 250_000e18;
        deal(RobinhoodV4.FLOCK, trader, sellIn);
        vm.startPrank(trader, trader);
        flock.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: sellIn, amountOutMin: 0, zeroForOne: false, poolKey: p.key, hookData: "", receiver: trader, deadline: block.timestamp + 1
        });
        vm.stopPrank();
        (, int24 tickNow,,) = poolManager.getSlot0(p.id);
        assertGt(tickNow, p.tick + 150, "price should have drifted up meaningfully");
        assertLt(tickNow, p.farLower, "but not into the far band");

        uint256 farId = positionManager.nextTokenId();
        _execute(txs); // same calldata built before the drift
        uint128 farLiq = positionManager.getPositionLiquidity(farId);
        assertGt(farLiq, 0, "batch still mints the far band");
        assertLt(_stockInFarBand(p, farLiq), p.expect0, "less stock token came out of the decrease after the drift");
    }

    function test_flockSellBeyondOldEdgeStillFills() public onlyFork {
        (RebalanceCoreScript.Plan memory p, RebalanceCoreScript.Tx[] memory txs) = _plan();
        _execute(txs);
        uint128 sellIn = 400_000e18;
        deal(RobinhoodV4.FLOCK, trader, sellIn);
        (uint256 quoted,) = IV4Quoter(RobinhoodV4.QUOTER).quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: p.key, zeroForOne: false, exactAmount: sellIn, hookData: ""})
        );
        vm.startPrank(trader, trader);
        flock.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swapRouter.swapExactTokensForTokens({
            amountIn: sellIn, amountOutMin: 0, zeroForOne: false, poolKey: p.key, hookData: "", receiver: trader, deadline: block.timestamp + 1
        });
        vm.stopPrank();
        uint256 googlOut = uint256(int256(d.amount0()));
        assertEq(googlOut, quoted, "quote != execution");
        (, int24 tickAfter,,) = poolManager.getSlot0(p.id);
        assertGt(tickAfter, p.coreUpper, "sell must have crossed the old upper edge");
        assertLt(tickAfter, p.farUpper, "and stayed inside the far band");
        assertGt(googlOut, 30e18, "a 400k FLOCK sell must fill for more than 30 GOOGL");
    }

    function test_buysStillWorkAfterRebalance() public onlyFork {
        (RebalanceCoreScript.Plan memory p, RebalanceCoreScript.Tx[] memory txs) = _plan();
        _execute(txs);
        deal(RobinhoodV4.GOOGL, trader, 1e18);
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swapRouter.swapExactTokensForTokens({
            amountIn: 1e18, amountOutMin: 0, zeroForOne: true, poolKey: p.key, hookData: "", receiver: trader, deadline: block.timestamp + 1
        });
        vm.stopPrank();
        assertGt(uint256(int256(d.amount1())), 8_000e18, "1 GOOGL should still buy more than 8,000 FLOCK");
    }
}

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}
