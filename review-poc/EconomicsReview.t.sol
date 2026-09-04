// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FlockStockPairHook} from "../../src/FlockStockPairHook.sol";

/// @dev Minimal direct PoolManager swapper (what any attacker can write); avoids router-side min-out checks.
contract RawSwapper is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    struct Data {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta d) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory r = pm.unlock(
            abi.encode(
                Data(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}), msg.sender)
            )
        );
        d = abi.decode(r, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        Data memory dt = abi.decode(raw, (Data));
        BalanceDelta d = pm.swap(dt.key, dt.params, "");
        _settle(dt.key.currency0, d.amount0(), dt.payer);
        _settle(dt.key.currency1, d.amount1(), dt.payer);
        return abi.encode(d);
    }

    function _settle(Currency c, int128 amt, address payer) internal {
        if (amt < 0) {
            pm.sync(c);
            MockERC20(Currency.unwrap(c)).transferFrom(payer, address(pm), uint256(uint128(-amt)));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, payer, uint256(uint128(amt)));
        }
    }
}

/// @title Economics / game-theory review PoCs for FlockStockPairHook (GOOGL/FLOCK launch parameters).
/// @dev Replicates script/02_InitializeAndSeed.s.sol: tick 90,780 (8,756 FLOCK/GOOGL), tickSpacing 60,
///      2.6M FLOCK single-sided in [87,180, 90,780], FLOCK = currency1 (deterministic addresses).
///      Fee config = the one in test/FlockStockPairHook.t.sol and the README (3%→1% launch, 2.5% surge on).
abstract contract EconomicsReviewBase is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    int24 constant INIT_TICK = 90_780;
    int24 constant TICK_SPACING = 60;
    uint256 constant SEED_FLOCK = 2_600_000e18;
    uint256 constant GOOGL_USD = 338; // $ per GOOGL, so $1k = 2.9586 GOOGL
    uint256 constant WED_2026_09_02 = 1788350400;
    uint32 constant LAUNCH_SECONDS = 1800;

    MockERC20 googl; // deterministic low address -> currency0
    MockERC20 flock; // deterministic high address -> currency1
    FlockStockPairHook hook;
    RawSwapper raw;
    PoolKey key;
    PoolId poolId;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtP0;

    address owner = makeAddr("flockSafe");
    address whale = makeAddr("whale");
    address retail = makeAddr("retail");
    address griefer = makeAddr("griefer");

    FlockStockPairHook.FeeConfig cfg = FlockStockPairHook.FeeConfig({
        baseFee: 10_000,
        minFee: 5_000,
        maxFee: 50_000,
        launchFee: 30_000,
        weekendFee: 15_000,
        surgeFee: 25_000,
        surgeTickThreshold: 500,
        surgeWindow: 300,
        launchSeconds: LAUNCH_SECONDS
    });

    function setUp() public virtual {
        deployArtifactsAndLabel();
        vm.warp(WED_2026_09_02);

        // Deterministic ordering: stock < FLOCK, as GOOGL (0x2e08...) < FLOCK (0x5ab3...) on Robinhood.
        googl = MockERC20(address(uint160(0x2e08) << 144 | 1));
        flock = MockERC20(address(uint160(0x5ab3) << 144 | 1));
        deployCodeTo(
            "lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("GOOGL", "GOOGL", uint8(18)),
            address(googl)
        );
        deployCodeTo(
            "lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("FLOCK", "FLOCK", uint8(18)),
            address(flock)
        );
        vm.label(address(googl), "GOOGL");
        vm.label(address(flock), "FLOCK");

        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo("FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, address(flock), owner), hookAddr);
        hook = FlockStockPairHook(hookAddr);
        raw = new RawSwapper(poolManager);

        key = PoolKey(Currency.wrap(address(googl)), Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
        poolId = key.toId();
        vm.prank(owner);
        hook.registerPool(key, cfg);

        sqrtP0 = TickMath.getSqrtPriceAtTick(INIT_TICK);
        vm.prank(owner);
        hook.initializePool(key, sqrtP0);

        _seed();
        _fund(whale);
        _fund(retail);
        _fund(griefer);
    }

    /// @dev Exact replica of 02_InitializeAndSeed (FLOCK = currency1 branch).
    function _seed() internal {
        tickUpper = (INIT_TICK / TICK_SPACING) * TICK_SPACING; // 90,780
        tickLower = tickUpper - 60 * TICK_SPACING; // 87,180
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP0, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 0, SEED_FLOCK
        );
        flock.mint(address(this), SEED_FLOCK + SEED_FLOCK / 1000);
        flock.approve(address(permit2), type(uint256).max);
        permit2.approve(address(flock), address(positionManager), type(uint160).max, type(uint48).max);
        googl.approve(address(permit2), type(uint256).max);
        permit2.approve(address(googl), address(positionManager), type(uint160).max, type(uint48).max);
        uint256 flockBefore = flock.balanceOf(address(this));
        (tokenId,) = positionManager.mint(
            key, tickLower, tickUpper, liquidity, 1, SEED_FLOCK + SEED_FLOCK / 1000, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        uint256 pulled = flockBefore - flock.balanceOf(address(this));
        assertLe(pulled, SEED_FLOCK + 1, "LiquidityAmounts rounding should cost at most 1 wei extra");
        assertGe(pulled, SEED_FLOCK - 1e12, "should pull essentially the whole seed");
        assertEq(googl.balanceOf(address(poolManager)), 0, "no GOOGL at T0");
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who) internal {
        googl.mint(who, 1_000_000e18);
        flock.mint(who, 100_000_000e18);
        vm.startPrank(who, who);
        googl.approve(address(swapRouter), type(uint256).max);
        flock.approve(address(swapRouter), type(uint256).max);
        googl.approve(address(raw), type(uint256).max);
        flock.approve(address(raw), type(uint256).max);
        vm.stopPrank();
    }

    function _buy(address who, uint256 googlIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who);
        d = swapRouter.swapExactTokensForTokens({
            amountIn: googlIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    function _sell(address who, uint256 flockIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who);
        d = swapRouter.swapExactTokensForTokens({
            amountIn: flockIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    /// @dev FLOCK a buyer would get at the initial spot price with zero fee/impact.
    function _spotOut(uint256 googlIn) internal view returns (uint256) {
        uint256 priceX192 = uint256(sqrtP0) * uint256(sqrtP0);
        return FullMath.mulDiv(googlIn, priceX192, 1 << 192);
    }

    function _usd(uint256 usd) internal pure returns (uint256) {
        return usd * 1e18 / GOOGL_USD;
    }

    function _pastLaunch() internal {
        vm.warp(block.timestamp + LAUNCH_SECONDS); // base fee 1%
    }
}

contract EconomicsReviewTest is EconomicsReviewBase {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ 1. single-sided seed behaviour & price impact

    function test_seedMath_T0_noActiveLiquidity_firstBuyCrossesIntoBand() public {
        assertEq(poolManager.getLiquidity(poolId), 0, "T0: nothing active");
        assertEq(_tick(), INIT_TICK);
        _pastLaunch();
        uint256 g0 = gasleft();
        BalanceDelta d = _buy(retail, 1e16);
        console2.log("gas: normal buy (router)          ", g0 - gasleft());
        assertGt(poolManager.getLiquidity(poolId), 0, "first buy activates the band");
        assertGt(int256(d.amount1()), 0);
        console2.log("tick after 0.01 GOOGL buy:", int256(_tick()));
    }

    function test_priceImpact_1k_5k_20k_and_surgeTriggerSize() public {
        _pastLaunch();
        uint256[3] memory usd = [uint256(1_000), 5_000, 20_000];
        for (uint256 i = 0; i < usd.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 googlIn = _usd(usd[i]);
            BalanceDelta d = _buy(retail, googlIn);
            uint256 out = uint256(int256(d.amount1()));
            uint256 spot = _spotOut(googlIn);
            uint256 spotAfterFee = spot * 99 / 100;
            console2.log("---- buy USD:", usd[i]);
            console2.log("  FLOCK out                        ", out / 1e18);
            console2.log("  FLOCK at spot, no fee            ", spot / 1e18);
            console2.log("  total cost vs spot (bps)         ", (spot - out) * 10_000 / spot);
            console2.log("  pure impact after 1% fee (bps)   ", (spotAfterFee - out) * 10_000 / spotAfterFee);
            console2.log("  tick move                        ", int256(INIT_TICK) - int256(_tick()));
            vm.revertToState(snap);
        }

        // Size that arms the surge fee for everyone else for the next 300 s: |tick move| >= 500.
        uint256 lo = 1e18;
        uint256 hi = 200e18;
        for (uint256 it = 0; it < 40; it++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            _buy(whale, mid);
            bool armed = INIT_TICK - _tick() >= 500;
            vm.revertToState(snap);
            if (armed) hi = mid;
            else lo = mid;
        }
        console2.log("GOOGL needed to move 500 ticks (surge trigger), wei:", hi);
        console2.log("  ~USD:", hi * GOOGL_USD / 1e18);
        console2.log("  as % of $100k seed:", hi * GOOGL_USD / 1e18 * 100 / 100_000);
        assertLt(hi * GOOGL_USD / 1e18, 20_000, "surge is armed by well under $20k of buying");
    }

    function test_fullDepletion_belowBand_thenBuysRevert_sellsRecover() public {
        _pastLaunch();
        uint256 pmFlock = flock.balanceOf(address(poolManager));
        BalanceDelta d = _buy(whale, 1_000e18); // far more than the band can absorb
        uint256 consumed = uint256(-int256(d.amount0()));
        uint256 got = uint256(int256(d.amount1()));
        console2.log("depletion: GOOGL consumed       ", consumed / 1e18);
        console2.log("depletion: ~USD paid            ", consumed / 1e18 * GOOGL_USD);
        console2.log("depletion: FLOCK received       ", got / 1e18);
        console2.log("depletion: FLOCK left in PM     ", (pmFlock - got) / 1e18);
        console2.log("depletion: tick after           ", int256(_tick()));
        assertLt(consumed, 400e18, "band exhausts at ~359 GOOGL");
        assertEq(_tick(), TickMath.MIN_TICK, "price teleports to MIN_TICK through the empty region at zero cost");
        assertEq(poolManager.getLiquidity(poolId), 0);

        // Further buys revert (PriceLimitAlreadyExceeded): the pool holds only GOOGL.
        vm.startPrank(retail, retail);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18, amountOutMin: 0, zeroForOne: true, poolKey: key, hookData: Constants.ZERO_BYTES,
            receiver: retail, deadline: block.timestamp + 1
        });
        vm.stopPrank();

        // Sells work: price climbs for free from MIN_TICK until the band's lower edge, then fills.
        BalanceDelta s = _sell(retail, 100_000e18);
        assertGt(int256(s.amount0()), 0, "seller receives GOOGL");
        console2.log("depletion: sell 100k FLOCK -> GOOGL", uint256(int256(s.amount0())) / 1e18);
        console2.log("depletion: tick after sell      ", int256(_tick()));
        assertEq(hook.previewFee(poolId), 25_000, "recovery trade leaves surge armed for 300s");
    }

    // ------------------------------------------------------------------ 2. zero-cost tick teleport / surge griefing

    function test_grief_T0_dustSellTeleportsTickToMaxAndArmsSurge() public {
        // Launch is 3% > surge (2.5%) for the first 450 s; at t+900 s the launch fee is 2% and surge binds.
        vm.warp(block.timestamp + 900);
        assertEq(hook.previewFee(poolId), 20_000);

        uint256 gBefore = flock.balanceOf(griefer);
        vm.prank(griefer, griefer);
        BalanceDelta d = raw.swap(key, false, -1); // sell 1 wei FLOCK into an empty upside
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        assertEq(flock.balanceOf(griefer), gBefore, "griefer paid nothing");
        int24 t = _tick();
        console2.log("tick after 1-wei sell at T0:", int256(t));
        assertEq(t, TickMath.MAX_TICK - 1, "tick teleports to the top with zero liquidity");

        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 1, "zero-value swap counted");
        assertEq(st.uniqueTraders, 1, "zero-value swap counts a unique trader");
        assertEq(st.windowStartTick, INIT_TICK);

        // Everyone buying FLOCK now pays the surge fee instead of the 2% launch fee.
        assertEq(hook.previewFee(poolId), 25_000, "surge armed for free");
        uint256 gasBefore = gasleft();
        BalanceDelta b = _buy(retail, _usd(1_000));
        console2.log("gas: $1k buy travelling from MAX_TICK:", gasBefore - gasleft());
        console2.log("retail got FLOCK for $1k at 2.5% instead of 2%:", uint256(int256(b.amount1())) / 1e18);
        vm.warp(block.timestamp + 301);
        assertLt(hook.previewFee(poolId), 25_000, "window lapsed: back to the (further decayed) launch fee");
    }

    function test_grief_sellerRescuingDepletedPoolPaysSurge() public {
        _pastLaunch();
        _buy(whale, 1_000e18); // exhausts the band, tick at MIN_TICK
        vm.warp(block.timestamp + 301);
        vm.prank(griefer, griefer);
        vm.expectRevert(); // zeroForOne at the MIN price limit reverts (PriceLimitAlreadyExceeded)
        raw.swap(key, true, -1);
        // A seller re-anchors the window at MIN_TICK (pre-swap) and everyone after pays surge.
        _sell(retail, 10_000e18);
        assertEq(hook.previewFee(poolId), 25_000);
    }

    function test_dustSwapCountsAsUniqueTrader_sybilCost() public {
        _pastLaunch();
        _buy(whale, 1e18); // activate band
        uint64 before = hook.poolState(poolId).uniqueTraders;
        for (uint160 i = 1; i <= 5; i++) {
            address sybil = address(uint160(0xBEEF00) + i);
            googl.mint(sybil, 1);
            vm.startPrank(sybil, sybil);
            googl.approve(address(raw), 1);
            uint256 g0 = gasleft();
            BalanceDelta d = raw.swap(key, true, -1); // 1 wei GOOGL, all taken as fee, 0 FLOCK out
            uint256 gas = g0 - gasleft();
            vm.stopPrank();
            assertEq(d.amount1(), 0);
            if (i == 1) console2.log("gas per 1-wei sybil swap:", gas);
        }
        assertEq(hook.poolState(poolId).uniqueTraders, before + 5, "5 fake traders for 5 wei + gas");
    }

    // ------------------------------------------------------------------ 3. surge fee incidence

    function test_surge_firstMoverPaysBase_bystanderPaysSurge_whaleRoundTripAvoidsSurge() public {
        _pastLaunch();
        _buy(retail, 1e18); // activate band, anchor window
        vm.warp(block.timestamp + 301);

        // Whale: a $20k buy as a single swap. Fee is computed BEFORE the move: base 1%.
        assertEq(hook.previewFee(poolId), 10_000);
        BalanceDelta w1 = _buy(whale, _usd(20_000));
        console2.log("whale $20k buy moved ticks:", int256(INIT_TICK) - int256(_tick()));

        // Bystander 10s later, either direction, pays 2.5%.
        vm.warp(block.timestamp + 10);
        assertEq(hook.previewFee(poolId), 25_000, "bystander pays surge");

        // Whale waits out the window and reverses: the new window anchors at the current tick, so no surge.
        vm.warp(block.timestamp + 300);
        assertEq(hook.previewFee(poolId), 10_000, "whale's reversal pays base");
        BalanceDelta w2 = _sell(whale, uint256(int256(w1.amount1())));
        console2.log("whale round trip GOOGL in  (1e-3):", uint256(-int256(w1.amount0())) / 1e15);
        console2.log("whale round trip GOOGL out (1e-3):", uint256(int256(w2.amount0())) / 1e15);
        assertEq(hook.previewFee(poolId), 25_000, "second surge window for bystanders");
    }

    /// @dev The surge window is a fixed 300 s epoch anchored by the first swap after a lapse. A mover who trades
    ///      at second 299 of an epoch gets a fresh epoch (anchored at the moved tick) 2 s later, so the reversal
    ///      pays base. Only bystanders in the gap and in the following epoch pay surge.
    function test_surge_windowTimingBypass_twoSecondRoundTrip() public {
        _pastLaunch();
        _buy(retail, 1e18); // anchors epoch at t0
        uint256 t0 = block.timestamp;
        assertEq(hook.poolState(poolId).windowStartTs, uint40(t0));

        vm.warp(t0 + 299);
        assertEq(hook.previewFee(poolId), 10_000, "whale leg 1 at base");
        BalanceDelta w1 = _buy(whale, _usd(20_000)); // moves ~650 ticks
        int24 moved = _tick();

        vm.warp(t0 + 300);
        assertEq(hook.previewFee(poolId), 25_000, "bystander at t0+300 pays surge");

        vm.warp(t0 + 301); // epoch lapsed; next swap re-anchors at the *moved* tick
        assertEq(hook.previewFee(poolId), 10_000, "whale leg 2 at base, 2 s after a 650-tick move");
        _sell(whale, uint256(int256(w1.amount1())));
        assertEq(hook.poolState(poolId).windowStartTick, moved);
        vm.warp(t0 + 302);
        assertEq(hook.previewFee(poolId), 25_000, "bystanders taxed for the next 300 s");
    }

    // ------------------------------------------------------------------ 4. weekend definition vs US market hours

    function test_weekend_missesFridayCloseMondayPreOpenAndHolidays() public {
        _pastLaunch();
        vm.warp(1788609600 - 12 hours - 3 hours); // Fri 2026-09-04 21:00 UTC: NYSE closed since 20:00 UTC
        assertFalse(hook.isWeekend(block.timestamp));
        assertEq(hook.previewFee(poolId), 10_000, "Fri 21:00 UTC: base fee although market is closed");
        vm.warp(1788782400 + 1 hours); // Mon 2026-09-07 13:00 UTC: 30 min before the open
        assertFalse(hook.isWeekend(block.timestamp));
        assertEq(hook.previewFee(poolId), 10_000, "Mon 13:00 UTC: base fee although market is closed");
        vm.warp(1788782400 + 6 hours); // Mon 2026-09-07 is Labor Day
        assertEq(hook.previewFee(poolId), 10_000, "Labor Day: base fee");
    }

    // ------------------------------------------------------------------ 5. accounting gaming

    function test_washTrade_netFlockNetsButVolumeDoubles_andOutOfPoolExitInvisible() public {
        _pastLaunch();
        BalanceDelta b = _buy(whale, _usd(5_000));
        uint256 got = uint256(int256(b.amount1()));
        _sell(whale, got);
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        console2.log("gross FLOCK volume counted after one round trip:", st.flockVolume / 1e18);
        assertEq(hook.netFlock(poolId, whale), 0);
        assertGe(st.flockVolume, 2 * got - 1);

        BalanceDelta b2 = _buy(whale, _usd(5_000));
        vm.prank(whale);
        flock.transfer(address(0xdead), uint256(int256(b2.amount1())));
        assertEq(hook.netFlock(poolId, whale), int256(b2.amount1()), "netFlock credit survives off-pool exit");
    }

    // ------------------------------------------------------------------ 6. stored lpFee never refreshed

    function test_storedLpFeeStaysAtLaunchForever() public {
        vm.warp(block.timestamp + 10_000);
        _buy(retail, 1e18);
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, 30_000, "explorers/StateView still show 3% long after launch");
        assertEq(hook.previewFee(poolId), 10_000);
    }
}

/// @dev Init and seed are now two transactions (owner-only `initializePool`, then PositionManager mint).
contract EconomicsReviewLaunchGapTest is EconomicsReviewBase {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    function setUp() public override {
        deployArtifactsAndLabel();
        vm.warp(WED_2026_09_02);
        googl = MockERC20(address(uint160(0x2e08) << 144 | 1));
        flock = MockERC20(address(uint160(0x5ab3) << 144 | 1));
        deployCodeTo("lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("GOOGL", "GOOGL", uint8(18)), address(googl));
        deployCodeTo("lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("FLOCK", "FLOCK", uint8(18)), address(flock));
        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo("FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, address(flock), owner), hookAddr);
        hook = FlockStockPairHook(hookAddr);
        raw = new RawSwapper(poolManager);
        key = PoolKey(Currency.wrap(address(googl)), Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
        poolId = key.toId();
        vm.prank(owner);
        hook.registerPool(key, cfg);
        sqrtP0 = TickMath.getSqrtPriceAtTick(INIT_TICK);
        _fund(retail);
        _fund(griefer);
    }

    /// @dev The launch-fee clock starts in `initializePool`; trading only starts when the seed lands. Any delay
    ///      between the Safe's init tx and the seeding wallet's seed tx eats the anti-snipe window, and the empty pool
    ///      can be tick-teleported for free in between.
    function test_launchClockStartsAtInit_notAtSeed_andEmptyPoolCanBeTeleported() public {
        // The old 02 path (PositionManager.initializePool) no longer works: PositionManager != hook, the hook's
        // beforeInitialize reverts and PositionManager swallows it (try/catch), leaving the pool uninitialised.
        positionManager.initializePool(key, sqrtP0);
        assertFalse(hook.poolState(poolId).initialized, "PositionManager path silently fails now");
        (uint160 sqrtLive,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtLive, 0, "pool not initialised via PositionManager");

        vm.prank(owner);
        hook.initializePool(key, sqrtP0);
        uint256 t0 = block.timestamp;
        assertEq(hook.previewFee(poolId), 30_000);

        // Anyone can move the empty pool's tick for free before the seed arrives.
        vm.prank(griefer, griefer);
        raw.swap(key, false, -1);
        assertEq(_tick(), TickMath.MAX_TICK - 1);

        // Safe signers take 30 minutes to execute the seed: the launch fee is gone when trading actually starts.
        vm.warp(t0 + LAUNCH_SECONDS);
        _seed();
        assertEq(hook.previewFee(poolId), 10_000, "no anti-snipe premium left when trading actually starts");
        BalanceDelta d = _buy(retail, 1e18); // first real trade travels down from MAX_TICK; pays base
        assertGt(int256(d.amount1()), 0);
        // ...and because the pre-swap tick was MAX_TICK-1, the new surge window is anchored there: every trade in
        // the next 300 s pays the surge fee although nobody moved the market.
        assertEq(hook.poolState(poolId).windowStartTick, TickMath.MAX_TICK - 1);
        assertEq(hook.previewFee(poolId), 25_000, "launch traders pay surge because of a free 1-wei swap");
    }
}
