// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Verifier PoCs against the current revision of FlockStockPairHook (paused launch,
// NoOpSwap guard, launchTs on first unpause, stored-fee sync, key validation, RenounceDisabled, minCountedStock).
// Local PoolManager + mock tokens arranged so FLOCK is currency1 (like GOOGL/FLOCK). Nothing touches a live network.
//   forge test --match-path test/review/VerifierPoC.t.sol -vv

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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FlockStockPairHook} from "../../src/FlockStockPairHook.sol";

/// @dev Direct PoolManager swapper: settles whatever the swap owes (nothing when the delta is 0/0).
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

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        returns (BalanceDelta d)
    {
        bytes memory r = pm.unlock(
            abi.encode(
                Data(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}), msg.sender)
            )
        );
        d = abi.decode(r, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
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

contract VerifierPoCTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    bytes32 constant SWAP_SIG = keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");
    bytes4 constant WRAPPED_ERROR = bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"));

    int24 constant INIT_TICK = 90_780;
    int24 constant SP = 60;
    uint256 constant SEED = 2_600_000e18;
    uint256 constant WED_2026_09_02 = 1788350400; // 12:00 UTC
    uint256 constant SAT_2026_09_05 = 1788609600; // 12:00 UTC
    uint256 constant MON_2026_09_07 = 1788782400; // 12:00 UTC (Labor Day)

    MockERC20 stock; // currency0 (lower address)
    MockERC20 flock; // currency1 (higher address)
    FlockStockPairHook hook;
    RawSwapper raw;
    PoolKey key;
    PoolId poolId;
    uint160 sqrtP0;

    address owner = makeAddr("flockSafe");
    address attacker = makeAddr("attacker");
    address trader = makeAddr("trader");

    // Script 01 defaults (current revision).
    FlockStockPairHook.FeeConfig cfg = FlockStockPairHook.FeeConfig({
        baseFee: 3_000,
        minFee: 2_500,
        maxFee: 10_000,
        launchFee: 10_000,
        closedMarketFee: 6_000,
        launchSeconds: 1800,
        minCountedStock: 3e16
    });

    function setUp() public {
        deployArtifactsAndLabel();
        vm.warp(WED_2026_09_02);
        vm.roll(1_000_000);

        MockERC20 a = deployToken();
        MockERC20 b = deployToken();
        (stock, flock) = address(a) < address(b) ? (a, b) : (b, a); // FLOCK = currency1, like GOOGL/FLOCK
        vm.label(address(stock), "GOOGL");
        vm.label(address(flock), "FLOCK");

        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo("FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, address(flock), owner), hookAddr);
        hook = FlockStockPairHook(hookAddr);
        raw = new RawSwapper(poolManager);

        key = PoolKey(Currency.wrap(address(stock)), Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SP, IHooks(hook));
        poolId = key.toId();
        sqrtP0 = TickMath.getSqrtPriceAtTick(INIT_TICK);

        vm.prank(owner);
        hook.registerPool(key, cfg);

        _fund(trader);
        _fund(attacker);
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who) internal {
        flock.mint(who, 10_000_000e18);
        stock.mint(who, 10_000_000e18);
        vm.startPrank(who, who);
        flock.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        flock.approve(address(raw), type(uint256).max);
        stock.approve(address(raw), type(uint256).max);
        vm.stopPrank();
    }

    function _init() internal {
        vm.prank(owner);
        hook.initializePool(key, sqrtP0);
    }

    /// @dev Script 02 seed: FLOCK-only band [INIT_TICK - 3600, INIT_TICK].
    function _seed() internal returns (uint256 tokenId) {
        int24 tickUpper = INIT_TICK; // already a multiple of 60
        int24 tickLower = tickUpper - 60 * SP;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP0, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 0, SEED
        );
        (tokenId,) = positionManager.mint(
            key, tickLower, tickUpper, liquidity, 0, SEED + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    function _unpause() internal {
        vm.prank(owner);
        hook.setPaused(poolId, false);
    }

    function _launch() internal {
        _init();
        _seed();
        _unpause();
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    function _lpFee() internal view returns (uint24 f) {
        (,,, f) = poolManager.getSlot0(poolId);
    }

    function _buy(address who, uint256 stockIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who);
        d = swapRouter.swapExactTokensForTokens({
            amountIn: stockIn,
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

    /// @dev Attempts a raw swap and returns (reverted, revert data).
    function _tryRaw(address who, bool zeroForOne, int256 amount, uint160 limit) internal returns (bool ok, bytes memory data) {
        vm.prank(who, who);
        try raw.swap(key, zeroForOne, amount, limit) returns (BalanceDelta) {
            ok = true;
        } catch (bytes memory r) {
            ok = false;
            data = r;
        }
    }

    function _contains(bytes memory hay, bytes4 needle) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i = 0; i + 4 <= hay.length; i++) {
            if (bytes4(uint32(uint8(hay[i])) << 24 | uint32(uint8(hay[i + 1])) << 16 | uint32(uint8(hay[i + 2])) << 8 | uint32(uint8(hay[i + 3]))) == needle) {
                return true;
            }
        }
        return false;
    }

    function _swapEvents() internal returns (uint24[] memory fees, int24[] memory ticks) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length == 4 && logs[i].topics[0] == SWAP_SIG) n++;
        }
        fees = new uint24[](n);
        ticks = new int24[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length == 4 && logs[i].topics[0] == SWAP_SIG) {
                (,,,, fees[j], ticks[j]) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
                j++;
            }
        }
    }

    // ------------------------------------------------------------------ H-1 / OPS-01 / OPS-02 : init -> seed gap

    function test_H1_initStartsPaused_emptyPoolCannotBeWalked_seedWorksWhilePaused() public {
        _init();
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertTrue(st.initialized);
        assertTrue(st.paused, "pool must start paused");
        assertEq(st.launchTs, 0, "launch clock must not have started");
        assertEq(hook.previewFee(poolId), cfg.launchFee, "full launch fee is quoted while paused");
        assertEq(_lpFee(), cfg.baseFee, "stored lpFee = baseFee at init");

        // Attacker tries the free zero-delta price walk in both directions while paused.
        (bool ok, bytes memory data) = _tryRaw(attacker, false, -1e18, TickMath.MAX_SQRT_PRICE - 1);
        assertFalse(ok, "swap through paused empty pool must revert");
        assertTrue(_contains(data, FlockStockPairHook.PoolPaused.selector), "revert reason should be PoolPaused");
        (ok, data) = _tryRaw(attacker, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertFalse(ok);
        assertEq(_tick(), INIT_TICK, "tick unchanged while paused");

        // Liquidity ops are not gated by the pause: the seed lands while the pool is paused.
        uint256 flockBefore = flock.balanceOf(address(this));
        _seed();
        assertEq(flockBefore - flock.balanceOf(address(this)), SEED, "exactly the seed was pulled (amount1Max = SEED + 1 wei)");
        assertEq(stock.balanceOf(address(poolManager)), 0, "no stock token needed for the single-sided band");
        assertEq(poolManager.getLiquidity(poolId), 0, "band ends at spot: no active liquidity at T0");
        assertEq(_tick(), INIT_TICK);

        // Still paused: real buyers cannot trade until the owner unpauses.
        vm.startPrank(trader, trader);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1e18, 0, true, key, Constants.ZERO_BYTES, trader, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_H1_unpausedEmptyPoolPriceIsImmovable_NoOpSwap() public {
        // Worst case for the runbook: owner unpauses BEFORE seeding. The hook must still refuse zero-delta walks.
        _init();
        _unpause();
        assertEq(poolManager.getLiquidity(poolId), 0);
        uint256 a0 = stock.balanceOf(attacker);
        uint256 a1 = flock.balanceOf(attacker);

        (bool ok, bytes memory data) = _tryRaw(attacker, false, -1e18, TickMath.MAX_SQRT_PRICE - 1);
        assertFalse(ok, "zero-delta walk up must revert");
        assertTrue(_contains(data, FlockStockPairHook.NoOpSwap.selector), "reason should be NoOpSwap");
        (ok, data) = _tryRaw(attacker, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertFalse(ok, "zero-delta walk down must revert");
        assertTrue(_contains(data, FlockStockPairHook.NoOpSwap.selector));
        // exact-output variant
        (ok, data) = _tryRaw(attacker, false, 1e18, TickMath.MAX_SQRT_PRICE - 1);
        assertFalse(ok, "zero-delta exact-out walk must revert");
        assertTrue(_contains(data, FlockStockPairHook.NoOpSwap.selector));

        assertEq(_tick(), INIT_TICK, "price of an empty pool cannot be moved any more");
        assertEq(stock.balanceOf(attacker), a0);
        assertEq(flock.balanceOf(attacker), a1);
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 0);
        assertEq(st.uniqueTraders, 0);
    }

    // ------------------------------------------------------------------ M-1 / ECO-01 / OPS-10 : post-launch empty side

    function test_M1_sellIntoEmptySideAfterLaunchRevertsInsteadOfTeleporting() public {
        _launch();
        // T0: no liquidity above spot. A 1-wei FLOCK sell previously teleported the tick to MAX_TICK-1 for free.
        (bool ok, bytes memory data) = _tryRaw(attacker, false, -1, TickMath.MAX_SQRT_PRICE - 1);
        assertFalse(ok, "sell into empty side must revert");
        assertTrue(_contains(data, FlockStockPairHook.NoOpSwap.selector));
        assertEq(_tick(), INIT_TICK);
        // Same through the router (what a UI would do): reverts, nothing recorded.
        vm.startPrank(attacker, attacker);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1, 0, false, key, Constants.ZERO_BYTES, attacker, block.timestamp + 1);
        vm.stopPrank();
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 0);
        assertEq(st.uniqueTraders, 0);
        assertEq(hook.firstTradeAt(poolId, attacker), 0);
    }

    // ------------------------------------------------------------------ NoOpSwap regression: legit flows still work

    function test_NoOpGuard_doesNotBreakLegitimateSwaps() public {
        _launch();
        // Real buy crosses into the band.
        BalanceDelta d = _buy(trader, 1e18);
        assertGt(int256(d.amount1()), 0, "buyer receives FLOCK");
        assertLt(_tick(), INIT_TICK);
        assertGt(poolManager.getLiquidity(poolId), 0);

        // Dust exact-in (1 wei stock): fee consumes it all, delta = (-1, 0) -> NOT a no-op, must pass.
        (bool ok,) = _tryRaw(trader, true, -1, TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(ok, "1-wei exact-in must not be rejected as a no-op");

        // Exact-output buy of 1 FLOCK.
        (ok,) = _tryRaw(trader, true, int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(ok, "exact-out swap works");

        // Sell FLOCK back into the (now two-sided) band.
        BalanceDelta s = _sell(trader, 1_000e18);
        assertGt(int256(s.amount0()), 0, "seller receives stock token");

        // Quoter-style: a swap that exhausts the whole band and continues into the empty region still exchanges
        // something, so it is not a no-op (buys of the whole seed remain possible).
        BalanceDelta big = _buy(trader, 400e18);
        assertGt(int256(big.amount1()), 0);
        assertEq(poolManager.getLiquidity(poolId), 0, "band fully consumed");
        // ...but once empty below, a further buy is a no-op and reverts (instead of moving tick to MIN_TICK).
        (ok,) = _tryRaw(trader, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertFalse(ok, "buy through an exhausted band is a no-op and must revert");
    }

    // ------------------------------------------------------------------ ECO-03 : launch clock

    function test_ECO03_launchClockStartsAtFirstUnpause_notAtInit() public {
        _init();
        vm.warp(WED_2026_09_02 + 3 hours); // long Safe delay between init and seed
        assertEq(hook.previewFee(poolId), 10_000, "launch fee must not decay while paused");
        _seed();
        uint256 t0 = block.timestamp;
        _unpause();
        assertEq(hook.poolState(poolId).launchTs, uint40(t0), "launchTs anchored at the first unpause");
        assertEq(hook.previewFee(poolId), 10_000);
        vm.warp(t0 + 900);
        assertEq(hook.previewFee(poolId), 6_500, "half way: 1% - 0.7% * 0.5");
        vm.warp(t0 + 1800);
        assertEq(hook.previewFee(poolId), 3_000);
        // Incident pause / unpause later must not restart the launch fee.
        vm.prank(owner);
        hook.setPaused(poolId, true);
        vm.warp(t0 + 1 days);
        vm.prank(owner);
        hook.setPaused(poolId, false);
        assertEq(hook.poolState(poolId).launchTs, uint40(t0), "launchTs is set once");
        assertEq(hook.previewFee(poolId), 3_000);
    }

    function test_ECO03_unpauseBeforeInitDoesNotStartClock_initRepauses() public {
        PoolKey memory k2 = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        PoolId id2 = k2.toId();
        vm.startPrank(owner);
        hook.registerPool(k2, cfg);
        hook.setPaused(id2, false); // premature unpause on a registered, uninitialised pool
        assertEq(hook.poolState(id2).launchTs, 0);
        hook.initializePool(k2, sqrtP0);
        assertTrue(hook.poolState(id2).paused, "initializePool always leaves the pool paused");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ L-1 / ECO-07 : stored lpFee sync

    function test_L1_storedLpFeeTracksChargedFee() public {
        _launch();
        assertEq(_lpFee(), 3_000, "baseFee stored at init");
        vm.recordLogs();
        _buy(trader, 1e18);
        (uint24[] memory fees,) = _swapEvents();
        assertEq(fees.length, 1);
        assertEq(fees[0], 10_000, "launch fee charged");
        assertEq(_lpFee(), 10_000, "stored fee synced to the charged fee");
        vm.warp(block.timestamp + 1800);
        vm.recordLogs();
        _buy(trader, 1e18);
        (fees,) = _swapEvents();
        assertEq(fees[0], 3_000);
        assertEq(_lpFee(), 3_000, "stored fee synced back to base after the launch window");
        assertEq(hook.previewFee(poolId), 3_000);
    }

    // ------------------------------------------------------------------ L-2 : registerPool key validation

    function test_L2_registerPoolRejectsBadKeys() public {
        vm.startPrank(owner);
        PoolKey memory reversed = PoolKey(key.currency1, key.currency0, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(reversed, cfg);
        PoolKey memory same = PoolKey(key.currency1, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(same, cfg);
        PoolKey memory zeroSpacing = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 0, IHooks(hook));
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(zeroSpacing, cfg);
        PoolKey memory hugeSpacing = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 32768, IHooks(hook));
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(hugeSpacing, cfg);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ I-1 : renounce selector

    function test_I1_renounceRevertsWithRenounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.RenounceDisabled.selector);
        hook.renounceOwnership();
    }

    // ------------------------------------------------------------------ ECO-06 : minCountedStock gating

    function test_ECO06_dustSwapsDoNotCountAsTraders() public {
        _launch();
        _buy(trader, 1e18); // activate the band
        FlockStockPairHook.PoolState memory before = hook.poolState(poolId);
        // 0.01 stock token < minCountedStock (0.03): netFlock/volume updated, counters untouched.
        BalanceDelta d = _buy(attacker, 1e16);
        assertGt(int256(d.amount1()), 0);
        FlockStockPairHook.PoolState memory after_ = hook.poolState(poolId);
        assertEq(after_.swapCount, before.swapCount, "dust swap not counted");
        assertEq(after_.uniqueTraders, before.uniqueTraders, "dust trader not counted");
        assertEq(hook.firstTradeAt(poolId, attacker), 0);
        assertEq(hook.netFlock(poolId, attacker), int256(d.amount1()), "netFlock still tracked");
        assertGt(after_.stockVolume, before.stockVolume);
        // >= threshold counts.
        _buy(attacker, 3e16);
        after_ = hook.poolState(poolId);
        assertEq(after_.swapCount, before.swapCount + 1);
        assertEq(after_.uniqueTraders, before.uniqueTraders + 1);
        assertEq(hook.firstTradeAt(poolId, attacker), uint40(block.timestamp));
    }

    // ------------------------------------------------------------------ ECO-04 : closed-market window

    function test_ECO04_closedMarketCoversFridayCloseAndMondayPreOpen_notHolidays() public view {
        uint256 satMidnight = SAT_2026_09_05 - 12 hours;
        assertFalse(hook.isMarketClosed(satMidnight - 4 hours - 1), "Fri 19:59:59 UTC open");
        assertTrue(hook.isMarketClosed(satMidnight - 4 hours), "Fri 20:00 UTC closed");
        assertTrue(hook.isMarketClosed(satMidnight - 3 hours), "Fri 21:00 UTC closed");
        assertTrue(hook.isMarketClosed(SAT_2026_09_05));
        uint256 monMidnight = MON_2026_09_07 - 12 hours;
        assertTrue(hook.isMarketClosed(monMidnight + 13 hours), "Mon 13:00 UTC closed");
        assertFalse(hook.isMarketClosed(monMidnight + 14 hours + 30 minutes), "Mon 14:30 UTC open");
        assertFalse(hook.isMarketClosed(monMidnight + 18 hours), "Labor Day 18:00 UTC treated as open (holidays not modelled)");
    }

    // ------------------------------------------------------------------ I-4 : gates, multi-hop transient state

    function test_I4_thirdPartyInitialisersRejected() public {
        PoolKey memory k2 = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.prank(owner);
        hook.registerPool(k2, cfg);
        vm.prank(attacker);
        vm.expectRevert();
        poolManager.initialize(k2, sqrtP0);
        // PositionManager.initializePool swallows the revert: pool stays uninitialised.
        vm.prank(attacker);
        positionManager.initializePool(k2, sqrtP0);
        (uint160 sq,,,) = poolManager.getSlot0(k2.toId());
        assertEq(sq, 0, "pool must stay uninitialised");
        assertFalse(hook.poolState(k2.toId()).initialized);
        // Static-fee look-alike with the hook: beforeInitialize reverts too.
        PoolKey memory staticKey = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(hook));
        vm.expectRevert();
        poolManager.initialize(staticKey, sqrtP0);
    }

    function test_I4_hookEntryPointsRejectNonPoolManager() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert();
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert();
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert();
        hook.beforeInitialize(address(this), key, sqrtP0);
    }

    function test_I4_multiHopThroughTwoRegisteredPools_perSwapFee() public {
        _launch();
        _buy(trader, 1e18); // activate GOOGL/FLOCK

        // Second registered pool FLOCK/OTHER with a different, constant fee (2%).
        MockERC20 other = deployToken();
        (Currency c0, Currency c1) = address(other) < address(flock)
            ? (Currency.wrap(address(other)), Currency.wrap(address(flock)))
            : (Currency.wrap(address(flock)), Currency.wrap(address(other)));
        PoolKey memory kB = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        FlockStockPairHook.FeeConfig memory cfgB = cfg;
        cfgB.baseFee = 20_000;
        cfgB.launchFee = 20_000;
        cfgB.maxFee = 20_000;
        cfgB.launchSeconds = 0;
        vm.startPrank(owner);
        hook.registerPool(kB, cfgB);
        hook.initializePool(kB, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();
        (uint256 b0, uint256 b1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60)),
            100_000e18
        );
        positionManager.mint(
            kB, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100_000e18, b0 + 1, b1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        vm.prank(owner);
        hook.setPaused(kB.toId(), false);

        // GOOGL -> FLOCK (pool A, launch fee 1%) -> OTHER (pool B, 2%) in ONE unlock.
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook), "");
        path[1] = PathKey(Currency.wrap(address(other)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook), "");
        vm.recordLogs();
        vm.startPrank(trader, trader);
        swapRouter.swapExactTokensForTokens(1e18, 0, Currency.wrap(address(stock)), path, trader, block.timestamp + 1);
        vm.stopPrank();
        (uint24[] memory fees,) = _swapEvents();
        assertEq(fees.length, 2, "two StockPairSwap events");
        assertEq(fees[0], 10_000, "pool A charged its own (launch) fee");
        assertEq(fees[1], 20_000, "pool B charged its own fee: transient _pendingFee is per swap");
        assertGt(other.balanceOf(trader), 0);
    }

    // ------------------------------------------------------------------ ECO-05 : single-sided seed quantification (info)

    function test_ECO05_priceImpactAndDepletion_info() public {
        _launch();
        uint256 snap = vm.snapshotState();
        uint256[3] memory ins = [uint256(296e16), 148e17, 592e17]; // ~$1k / $5k / $20k of GOOGL at $338
        for (uint256 i = 0; i < 3; i++) {
            BalanceDelta d = _buy(trader, ins[i]);
            console2.log("GOOGL in (wei):", ins[i]);
            console2.log("  FLOCK out (wei):", uint256(int256(d.amount1())));
            console2.log("  tick after:", int256(_tick()));
            vm.revertToState(snap);
        }
        // Full depletion: 400 GOOGL is more than the band absorbs.
        BalanceDelta big = _buy(trader, 400e18);
        console2.log("400 GOOGL buy -> FLOCK out (wei):", uint256(int256(big.amount1())));
        console2.log("  GOOGL actually spent (wei):", uint256(-int256(big.amount0())));
        console2.log("  tick after:", int256(_tick()));
        assertEq(poolManager.getLiquidity(poolId), 0);
        assertLt(flock.balanceOf(address(poolManager)), 1e18, "band emptied");
    }
}
