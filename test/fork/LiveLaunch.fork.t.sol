// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../../src/FlockStockPairHook.sol";

/// @notice Fork test against the deployed hook (0x33e9…): add a two-sided core position and a FLOCK band as scripts
///         05/02 would, unpause as the owner, then quote and swap both directions through the canonical quoter.
/// @dev forge test --match-contract LiveLaunchFork --fork-url robinhood -vv
contract LiveLaunchFork is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK = 0x33e924fb8663871bAb61D6844e79CDea159C60c0;
    address constant OWNER = 0x091e6E476D026edB209477aFee27AF92EC00F10c;
    int24 constant TICK_SPACING = 60;
    uint256 constant CORE_GOOGL = 20e18;
    uint256 constant EXTRA_FLOCK_TOTAL = 1_000_000e18;
    bytes32 constant SWAP_SIG = keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");

    IERC20 flock = IERC20(RobinhoodV4.FLOCK);
    IERC20 googl = IERC20(RobinhoodV4.GOOGL);
    FlockStockPairHook hook = FlockStockPairHook(HOOK);
    PoolKey key;
    PoolId poolId;
    address trader = makeAddr("trader");
    uint256 coreFlock;

    modifier onlyFork() {
        if (block.chainid != RobinhoodV4.CHAIN_ID || HOOK.code.length == 0) return;
        _;
    }

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID || HOOK.code.length == 0) return;
        deployArtifactsAndLabel();
        key = PoolKey(
            Currency.wrap(RobinhoodV4.GOOGL),
            Currency.wrap(RobinhoodV4.FLOCK),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING,
            IHooks(HOOK)
        );
        poolId = key.toId();
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 t = (tick / spacing) * spacing;
        if (tick < 0 && t != tick) t -= spacing;
        return t;
    }

    function _mintCoreAndExtra() internal {
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        require(st.initialized && st.paused, "live pool expected initialized+paused");
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(poolId);

        deal(RobinhoodV4.GOOGL, address(this), CORE_GOOGL);
        deal(RobinhoodV4.FLOCK, address(this), EXTRA_FLOCK_TOTAL);
        googl.approve(address(permit2), type(uint256).max);
        flock.approve(address(permit2), type(uint256).max);
        permit2.approve(RobinhoodV4.GOOGL, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(RobinhoodV4.FLOCK, address(positionManager), type(uint160).max, type(uint48).max);

        // Core: ±10 spacings (600 ticks) around the truncated spot, stock leg exact (same math as script 05).
        int24 center = _floorTick(tick, TICK_SPACING);
        int24 lower = center - 10 * TICK_SPACING;
        int24 upper = center + 10 * TICK_SPACING;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtPrice, sqrtB, CORE_GOOGL);
        (, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPrice, sqrtA, sqrtB, liq);
        coreFlock = a1;
        positionManager.mint(
            key, lower, upper, liq, CORE_GOOGL + 1, a1 + a1 / 100 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        assertGt(poolManager.getLiquidity(poolId), 0, "core must be active at spot");

        // Extra FLOCK: same band shape as the seed (60 spacings strictly below spot), remaining FLOCK.
        uint256 extra = flock.balanceOf(address(this));
        int24 bUpper = _floorTick(tick, TICK_SPACING);
        int24 bLower = bUpper - 60 * TICK_SPACING;
        uint128 liqB = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(bLower), TickMath.getSqrtPriceAtTick(bUpper), 0, extra
        );
        positionManager.mint(key, bLower, bUpper, liqB, 0, extra + 1, address(this), block.timestamp, Constants.ZERO_BYTES);
    }

    function test_liveStateIsSeededAndPaused() public onlyFork {
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertTrue(st.registered && st.initialized && st.paused);
        assertEq(hook.owner(), OWNER);
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        assertEq(tick, 90_692);
        assertEq(poolManager.getLiquidity(poolId), 0, "seed band sits strictly below spot");
        assertEq(uint256(hook.previewFee(poolId)), 10_000, "launch fee while paused");
    }

    function test_coreThenOpenThenTradeBothWays() public onlyFork {
        _mintCoreAndExtra();
        // FLOCK leg of the core ≈ 20 GOOGL worth (≈ 8,680 FLOCK/GOOGL → ~174k), never more than 200k.
        assertGt(coreFlock, 150_000e18);
        assertLt(coreFlock, 200_000e18);

        vm.prank(OWNER);
        hook.setPaused(poolId, false);
        assertEq(uint256(hook.previewFee(poolId)), 10_000);

        IV4Quoter quoter = IV4Quoter(RobinhoodV4.QUOTER);
        deal(RobinhoodV4.GOOGL, trader, 1e18);

        // Quote BUY (0.1 GOOGL → FLOCK) up front; the quoter's reverted simulation still shows up in recordLogs.
        (uint256 qBuy,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: true, exactAmount: 1e17, hookData: ""})
        );
        vm.recordLogs();
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d1 = swapRouter.swapExactTokensForTokens({
            amountIn: 1e17, amountOutMin: 0, zeroForOne: true, poolKey: key, hookData: "", receiver: trader, deadline: block.timestamp + 1
        });
        vm.stopPrank();
        uint256 flockOut = uint256(int256(d1.amount1()));
        assertEq(flockOut, qBuy, "buy: quote != execution");
        // ~868 FLOCK per 0.1 GOOGL before fee; 1% launch fee and tiny impact → 850–862
        assertGt(flockOut, 845e18);
        assertLt(flockOut, 866e18);

        // SELL: half of it back → GOOGL (needs the core's GOOGL side). Quote outside the recorded window.
        uint128 sellIn = uint128(flockOut / 2);
        Vm.Log[] memory buyLogs = vm.getRecordedLogs();
        (uint256 qSell,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: false, exactAmount: sellIn, hookData: ""})
        );
        vm.recordLogs();
        vm.startPrank(trader, trader);
        flock.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d2 = swapRouter.swapExactTokensForTokens({
            amountIn: sellIn, amountOutMin: 0, zeroForOne: false, poolKey: key, hookData: "", receiver: trader, deadline: block.timestamp + 1
        });
        vm.stopPrank();
        uint256 googlOut = uint256(int256(d2.amount0()));
        assertEq(googlOut, qSell, "sell: quote != execution");
        assertGt(googlOut, 0.048e18); // ~0.05 GOOGL minus 1% fee and impact
        assertLt(googlOut, 0.0495e18);

        // Hook accounting: both swaps counted (0.1 and ~0.05 GOOGL exceed minCountedStock 0.03), fee 1%.
        Vm.Log[] memory sellLogs = vm.getRecordedLogs();
        uint256 seen = _countSwapEvents(buyLogs) + _countSwapEvents(sellLogs);
        assertEq(seen, 2);
        assertEq(hook.poolState(poolId).swapCount, 2);
        assertEq(hook.poolState(poolId).uniqueTraders, 1);
        (,,, uint24 storedFee) = poolManager.getSlot0(poolId);
        assertEq(storedFee, 10_000, "stored fee synced to launch fee");
    }

    function _countSwapEvents(Vm.Log[] memory logs) internal pure returns (uint256 seen) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == HOOK && logs[i].topics[0] == SWAP_SIG) {
                seen++;
                (,,,, uint24 fee,) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
                require(fee == 10_000, "fee must be the 1% launch fee");
            }
        }
    }

    function test_launchFeeDecaysAfterOpen() public onlyFork {
        _mintCoreAndExtra();
        vm.prank(OWNER);
        hook.setPaused(poolId, false);
        vm.warp(block.timestamp + 900);
        assertEq(uint256(hook.previewFee(poolId)), 6_500);
        vm.warp(block.timestamp + 900);
        assertEq(uint256(hook.previewFee(poolId)), 3_000);
    }
}
