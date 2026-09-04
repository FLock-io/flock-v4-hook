// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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

/// @notice End-to-end rehearsal of the GOOGL/FLOCK pilot against a Robinhood Chain mainnet fork:
///         deploy hook → register → initialise → seed single-sided FLOCK → quote → swap → verify fee & accounting.
/// @dev Run with: forge test --match-contract FlockGooglPoolFork --fork-url robinhood -vv
contract FlockGooglPoolFork is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    bytes32 constant SWAP_SIG = keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");

    // Pilot parameters: ~8,756 FLOCK per GOOGL → tick 90,780; tickSpacing 60.
    int24 constant INIT_TICK = 90_780;
    int24 constant TICK_SPACING = 60;
    uint256 constant SEED_FLOCK = 2_600_000e18; // ≈ $100k at $0.0386

    IERC20 flock = IERC20(RobinhoodV4.FLOCK);
    IERC20 googl = IERC20(RobinhoodV4.GOOGL);
    address owner = RobinhoodV4.FLOCK_SAFE;
    address trader = makeAddr("trader");

    FlockStockPairHook hook;
    PoolKey key;
    PoolId poolId;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    uint256 pmFlockBefore;

    FlockStockPairHook.FeeConfig cfg = FlockStockPairHook.FeeConfig({baseFee: 10_000, minFee: 5_000, maxFee: 50_000, launchFee: 30_000, closedMarketFee: 15_000, launchSeconds: 1800, minCountedStock: 1e15});

    modifier onlyFork() {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        _;
    }

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        deployArtifactsAndLabel();

        // Hook at a flag-encoded address (mainnet deployment mines a CREATE2 salt for the same bits).
        address hookAddr = address(FLAGS ^ (0x5151 << 144));
        deployCodeTo(
            "FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, RobinhoodV4.FLOCK, owner), hookAddr
        );
        hook = FlockStockPairHook(hookAddr);
        vm.label(hookAddr, "FlockStockPairHook");

        // GOOGL (0x2e08…) < FLOCK (0x5ab3…) → currency0 = GOOGL, currency1 = FLOCK.
        key = PoolKey(
            Currency.wrap(RobinhoodV4.GOOGL),
            Currency.wrap(RobinhoodV4.FLOCK),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING,
            IHooks(hook)
        );
        poolId = key.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(INIT_TICK);
        vm.startPrank(owner);
        hook.registerPool(key, cfg);
        hook.initializePool(key, sqrtPrice);
        vm.stopPrank();

        // Single-sided FLOCK (currency1) seed: range strictly BELOW spot so the position holds only FLOCK and
        // sells it as traders pay GOOGL (zeroForOne) and push the price down into the range.
        tickUpper = _floorTick(INIT_TICK, TICK_SPACING); // <= current tick
        tickLower = tickUpper - 60 * TICK_SPACING; // ~30% wide band (60 * 60 ticks ≈ 36% price range)

        pmFlockBefore = flock.balanceOf(address(poolManager));
        deal(RobinhoodV4.FLOCK, address(this), SEED_FLOCK);
        flock.approve(address(permit2), type(uint256).max);
        permit2.approve(RobinhoodV4.FLOCK, address(positionManager), type(uint160).max, type(uint48).max);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 0, SEED_FLOCK
        );
        (tokenId,) = positionManager.mint(
            key, tickLower, tickUpper, liquidity, 0, SEED_FLOCK, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        vm.prank(owner);
        hook.setPaused(poolId, false); // starts the launch clock
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 t = (tick / spacing) * spacing;
        if (tick < 0 && t != tick) t -= spacing;
        return t;
    }

    function test_seedIsSingleSidedFlock() public onlyFork {
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertTrue(st.initialized);
        assertFalse(st.flockIsCurrency0, "FLOCK must be currency1 in GOOGL/FLOCK");
        // The seed sits entirely in the PoolManager and needed no GOOGL.
        assertGe(flock.balanceOf(address(poolManager)) - pmFlockBefore, SEED_FLOCK - 1e18, "seed not in pool");
        assertLt(flock.balanceOf(address(this)), 1e18);
        assertEq(googl.balanceOf(address(this)), 0);
        (,,, uint24 lpFeeBefore) = poolManager.getSlot0(poolId);
        assertEq(lpFeeBefore, 10_000, "base fee stored as default LP fee until the first swap syncs it");
        // The range ends exactly at spot, so nothing is active until the first GOOGL→FLOCK buy pushes the price
        // into the band; after a tiny buy the position is live.
        assertEq(poolManager.getLiquidity(poolId), 0, "range must start strictly below spot");
        deal(RobinhoodV4.GOOGL, trader, 1e16);
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        assertGt(poolManager.getLiquidity(poolId), 0, "liquidity should be active after the first buy");
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, 30_000, "stored fee synced to the charged launch fee after the first swap");
    }

    function test_quoteMatchesSwap_andFeeApplied() public onlyFork {
        uint128 amountIn = 1e18; // 1 GOOGL ≈ $338
        deal(RobinhoodV4.GOOGL, trader, 10e18);
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Canonical V4Quoter (the same contract the Uniswap app / routing API use) must quote a hooked pool exactly.
        IV4Quoter quoter = IV4Quoter(RobinhoodV4.QUOTER);
        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: true, exactAmount: amountIn, hookData: Constants.ZERO_BYTES
            })
        );
        assertGt(quotedOut, 0, "quoter returned zero");

        vm.recordLogs();
        vm.startPrank(trader, trader);
        BalanceDelta d = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();

        uint256 flockOut = uint256(int256(d.amount1()));
        assertEq(flockOut, quotedOut, "quote must equal executed output");
        assertEq(flock.balanceOf(trader), flockOut);

        // Fee-free CPMM on a 1 GOOGL trade at ~8,756 FLOCK/GOOGL with $100k depth ≈ 8,756 − impact; with 3% fee
        // the trader should receive between 94% and 97.5% of the spot amount.
        uint256 spotOut = 8_756e18; // FLOCK for 1 GOOGL at the init tick (approx)
        assertLt(flockOut, spotOut * 975 / 1000, "fee not applied");
        assertGt(flockOut, spotOut * 940 / 1000, "impact too large for a $338 trade in a $100k pool");

        // Event & accounting
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == SWAP_SIG) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), trader);
                (,,, int256 flockDelta, uint24 fee,) =
                    abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
                assertEq(fee, 30_000);
                assertEq(uint256(flockDelta), flockOut);
            }
        }
        assertTrue(found, "StockPairSwap not emitted");
        assertEq(hook.netFlock(poolId, trader), int256(flockOut));
        assertEq(hook.poolState(poolId).uniqueTraders, 1);
        assertEq(hook.poolState(poolId).swapCount, 1);
    }

    function test_googlAccumulatesInPoolFromBuyers() public onlyFork {
        uint256 before = googl.balanceOf(address(poolManager));
        deal(RobinhoodV4.GOOGL, trader, 5e18);
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        assertEq(googl.balanceOf(address(poolManager)) - before, 5e18, "pool must hold exactly the GOOGL paid in");
        // and the LP position now owns that GOOGL as fees + principal
        assertGt(hook.poolState(poolId).stockVolume, 0);
    }

    function test_sellingFlockBackIntoPoolWorksAfterBuys() public onlyFork {
        deal(RobinhoodV4.GOOGL, trader, 20e18);
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        flock.approve(address(swapRouter), type(uint256).max);
        BalanceDelta buy = swapRouter.swapExactTokensForTokens({
            amountIn: 20e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        uint256 got = uint256(int256(buy.amount1()));
        // Sell half back for GOOGL (oneForZero); the GOOGL paid in earlier is the only GOOGL in this pool.
        BalanceDelta sell = swapRouter.swapExactTokensForTokens({
            amountIn: got / 2,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        assertGt(int256(sell.amount0()), 0, "should receive GOOGL back");
        assertLt(uint256(int256(sell.amount0())), 10e18, "cannot get back more GOOGL than half the buy (fees, impact)");
        assertEq(hook.poolState(poolId).swapCount, 2);
        assertGt(hook.netFlock(poolId, trader), 0);
    }

    function test_ownerCanPauseOnFork() public onlyFork {
        vm.prank(owner);
        hook.setPaused(poolId, true);
        deal(RobinhoodV4.GOOGL, trader, 1e18);
        vm.startPrank(trader, trader);
        googl.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        // LP exit still works while paused
        positionManager.decreaseLiquidity(tokenId, 1e15, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES);
    }
}
