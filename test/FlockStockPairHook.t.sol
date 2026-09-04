// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

contract FlockStockPairHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    bytes32 constant SWAP_SIG = keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");

    // Calendar anchors (UTC): 2026-09-02 Wed, 2026-09-03 Thu, 2026-09-05 Sat, 2026-09-06 Sun, 2026-09-07 Mon.
    uint256 constant WED_2026_09_02 = 1788350400;
    uint256 constant THU_2026_09_03 = 1788436800;
    uint256 constant SAT_2026_09_05 = 1788609600;
    uint256 constant SUN_2026_09_06 = 1788696000;
    uint256 constant MON_2026_09_07 = 1788782400;
    uint256 constant INIT_BLOCK = 1_000_000;

    MockERC20 flock;
    MockERC20 stock;
    Currency currency0;
    Currency currency1;
    bool flockIs0;

    FlockStockPairHook hook;
    address owner = makeAddr("flockSafe");
    address trader = makeAddr("trader");
    address other = makeAddr("otherTrader");

    PoolKey key;
    PoolId poolId;
    uint256 tokenId;

    FlockStockPairHook.FeeConfig cfg = FlockStockPairHook.FeeConfig({
        baseFee: 10_000, // 1.00%
        minFee: 5_000, // 0.50%
        maxFee: 50_000, // 5.00%
        launchFee: 30_000, // 3.00% at launch
        closedMarketFee: 15_000, // 1.50%
        launchSeconds: 1800,
        minCountedStock: 1e15 // 0.001 stock token
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
        (currency0, currency1) = flockIs0
            ? (Currency.wrap(address(flock)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(flock)));

        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo(
            "FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, address(flock), owner), hookAddr
        );
        hook = FlockStockPairHook(hookAddr);

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();

        vm.startPrank(owner);
        hook.registerPool(key, cfg);
        hook.initializePool(key, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();

        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);
        uint128 liquidity = 1_000_000e18;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        (tokenId,) = positionManager.mint(
            key, tickLower, tickUpper, liquidity, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        vm.prank(owner);
        hook.setPaused(poolId, false); // starts the launch-fee clock

        _fund(trader);
        _fund(other);
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who) internal {
        flock.mint(who, 10_000_000e18);
        stock.mint(who, 10_000_000e18);
        vm.startPrank(who, who);
        flock.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address who, bool buyFlock, uint256 amountIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who); // msg.sender == tx.origin == who
        d = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: buyFlock ? !flockIs0 : flockIs0,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    function _buyFlock(address who, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(who, true, amountIn);
    }

    function _sellFlock(address who, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(who, false, amountIn);
    }

    function _flockDelta(BalanceDelta d) internal view returns (int256) {
        return flockIs0 ? int256(d.amount0()) : int256(d.amount1());
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    function _absTick(int24 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint24(-x)) : uint256(uint24(x));
    }

    /// @dev Returns (found, fee, trader) of the last StockPairSwap emitted by the hook in the recorded logs.
    function _lastSwapEvent() internal returns (bool found, uint24 fee, address evTrader) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length == 4 && logs[i].topics[0] == SWAP_SIG) {
                found = true;
                evTrader = address(uint160(uint256(logs[i].topics[2])));
                (,,,, fee,) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
            }
        }
    }

    // ------------------------------------------------------------------ registration & initialisation

    function test_registrationState() public {
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertTrue(st.registered);
        assertTrue(st.initialized);
        assertFalse(st.paused);
        assertEq(st.flockIsCurrency0, flockIs0);
        assertEq(st.initTs, uint40(WED_2026_09_02));
        assertEq(st.launchTs, uint40(WED_2026_09_02));
        assertEq(hook.feeConfig(poolId).baseFee, 10_000);
        // The stored LP fee starts at the base fee and is re-synced to the charged fee after every swap.
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, 10_000);
        _buyFlock(trader, 1e18);
        (,,, lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, 30_000, "stored fee synced to the launch fee after a swap");
        assertEq(hook.owner(), owner);
        assertEq(hook.flock(), address(flock));
    }

    function test_hookAddressCarriesOnlyDeclaredFlags() public view {
        uint160 mask = uint160((1 << 14) - 1);
        assertEq(uint160(address(hook)) & mask, FLAGS);
        assertEq(uint160(address(hook)) & uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), 0);
        assertEq(uint160(address(hook)) & uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), 0);
    }

    function test_initializeRevertsWhenNotRegistered() public {
        PoolKey memory unregistered = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.expectRevert(); // beforeInitialize -> InitializerNotHook (wrapped by the PoolManager)
        poolManager.initialize(unregistered, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.PoolNotRegistered.selector);
        hook.initializePool(unregistered, Constants.SQRT_PRICE_1_1);
    }

    function test_onlyHookCanInitializeRegisteredPool() public {
        PoolKey memory key2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.prank(owner);
        hook.registerPool(key2, cfg);
        // A third party (or the owner directly) cannot initialise through the PoolManager...
        vm.expectRevert();
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectRevert();
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
        // ...and a non-owner cannot use the hook's initialiser.
        vm.expectRevert();
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1);
        // The owner can, exactly once; the new pool starts paused with no launch clock.
        vm.prank(owner);
        int24 tick = hook.initializePool(key2, Constants.SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertTrue(hook.poolState(key2.toId()).initialized);
        assertTrue(hook.poolState(key2.toId()).paused);
        assertEq(hook.poolState(key2.toId()).launchTs, 0);
        assertEq(hook.previewFee(key2.toId()), 30_000, "full launch fee while not yet launched");
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.PoolAlreadyInitialized.selector);
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1);
    }

    function test_registerRevertsForNonDynamicFee() public {
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.NotDynamicFee.selector);
        hook.registerPool(staticKey, cfg);
    }

    function test_registerRevertsWithoutFlock() public {
        MockERC20 a = deployToken();
        MockERC20 b = deployToken();
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        PoolKey memory noFlock = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.NotFlockPair.selector);
        hook.registerPool(noFlock, cfg);
    }

    function test_registerRevertsForWrongHook() public {
        PoolKey memory wrongHook = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(0)));
        vm.prank(owner);
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(wrongHook, cfg);
    }

    function test_registerTwiceReverts() public {
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.PoolAlreadyRegistered.selector);
        hook.registerPool(key, cfg);
    }

    function test_onlyOwnerAdmin() public {
        vm.expectRevert();
        hook.setPaused(poolId, true);
        vm.expectRevert();
        hook.setFeeConfig(poolId, cfg);
        vm.expectRevert();
        hook.registerPool(key, cfg);
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.RenounceDisabled.selector);
        hook.renounceOwnership();
    }

    function test_registerRejectsBadTickSpacingAndOrdering() public {
        PoolKey memory badSpacing = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 0, IHooks(hook));
        vm.prank(owner);
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(badSpacing, cfg);
        PoolKey memory unordered = PoolKey(currency1, currency0, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vm.prank(owner);
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(unordered, cfg);
    }

    function test_noOpSwapThroughEmptyLiquidityReverts() public {
        // A second registered pool with no liquidity: any swap only walks the price and exchanges nothing.
        PoolKey memory key2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.startPrank(owner);
        hook.registerPool(key2, cfg);
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1);
        hook.setPaused(key2.toId(), false);
        vm.stopPrank();
        (, int24 tickBefore,,) = poolManager.getSlot0(key2.toId());
        vm.startPrank(trader, trader);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key2,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        (, int24 tickAfter,,) = poolManager.getSlot0(key2.toId());
        assertEq(tickAfter, tickBefore, "price must not move without a real trade");
        assertEq(hook.poolState(key2.toId()).swapCount, 0);
    }

    function test_dustSwapsDoNotCountAsTraders() public {
        // Below minCountedStock (0.001 stock): netFlock and volume update, counters do not.
        _buyFlock(trader, 1e12);
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 0);
        assertEq(st.uniqueTraders, 0);
        assertEq(hook.firstTradeAt(poolId, trader), 0);
        assertGt(hook.netFlock(poolId, trader), 0);
        _buyFlock(trader, 1e18);
        st = hook.poolState(poolId);
        assertEq(st.swapCount, 1);
        assertEq(st.uniqueTraders, 1);
    }

    function test_launchClockStartsAtUnpauseNotInit() public {
        PoolKey memory key2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.startPrank(owner);
        hook.registerPool(key2, cfg);
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();
        vm.warp(WED_2026_09_02 + 6 hours); // long after init, still paused → full launch fee
        assertEq(hook.previewFee(key2.toId()), 30_000);
        vm.prank(owner);
        hook.setPaused(key2.toId(), false);
        assertEq(hook.poolState(key2.toId()).launchTs, uint40(WED_2026_09_02 + 6 hours));
        vm.warp(WED_2026_09_02 + 6 hours + 900);
        assertEq(hook.previewFee(key2.toId()), 20_000);
        vm.warp(WED_2026_09_02 + 6 hours + 1800);
        assertEq(hook.previewFee(key2.toId()), 10_000);
    }

    function test_ownershipIsTwoStep() public {
        address newOwner = makeAddr("newSafe");
        vm.prank(owner);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), owner, "owner must not change before acceptance");
        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner);
    }

    function test_feeConfigValidation() public {
        FlockStockPairHook.FeeConfig memory bad = cfg;
        bad.maxFee = 200_000; // > 10% hard cap
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.InvalidFeeConfig.selector);
        hook.setFeeConfig(poolId, bad);

        bad = cfg;
        bad.minFee = 20_000; // min > base
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.InvalidFeeConfig.selector);
        hook.setFeeConfig(poolId, bad);

        bad = cfg;
        bad.launchFee = 60_000; // above maxFee
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.InvalidFeeConfig.selector);
        hook.setFeeConfig(poolId, bad);
    }

    // ------------------------------------------------------------------ fee schedule

    function test_launchFeeDecaysToBase() public {
        assertEq(hook.previewFee(poolId), 30_000, "fee at init should be launchFee");
        vm.warp(WED_2026_09_02 + 900);
        assertEq(hook.previewFee(poolId), 20_000, "fee half way should be the mid-point");
        vm.warp(WED_2026_09_02 + 1800);
        assertEq(hook.previewFee(poolId), 10_000, "fee after the launch window should be baseFee");
        vm.warp(THU_2026_09_03 + 6 hours); // Thursday 18:00 UTC, market open
        assertEq(hook.previewFee(poolId), 10_000);
    }

    function test_closedMarketFee() public {
        vm.warp(SAT_2026_09_05); // 3 days after init: launch window long over
        assertEq(hook.previewFee(poolId), 15_000);
        vm.warp(SUN_2026_09_06);
        assertEq(hook.previewFee(poolId), 15_000);
        vm.warp(MON_2026_09_07 + 2 hours + 30 minutes); // Monday 14:30 UTC: open in both DST regimes
        assertEq(hook.previewFee(poolId), 10_000);
        vm.warp(MON_2026_09_07 + 1 hours); // Monday 13:00 UTC: still inside the closed window
        assertEq(hook.previewFee(poolId), 15_000);
        vm.warp(SAT_2026_09_05 - 12 hours - 5 hours); // Friday 19:00 UTC: market open
        assertEq(hook.previewFee(poolId), 10_000);
        vm.warp(SAT_2026_09_05 - 12 hours - 3 hours); // Friday 21:00 UTC: closed
        assertEq(hook.previewFee(poolId), 15_000);
    }

    function test_closedMarketDoesNotLowerAHigherLaunchFee() public {
        // Stretch the launch window to 10 days so Saturday (3 days in) is still decaying: 3% - 2% * 3/10 = 2.4%.
        FlockStockPairHook.FeeConfig memory c = cfg;
        c.launchSeconds = 10 days;
        vm.prank(owner);
        hook.setFeeConfig(poolId, c);
        vm.warp(SAT_2026_09_05);
        assertEq(hook.previewFee(poolId), 24_000);
    }

    function test_feeIgnoresPoolTick_noGriefingViaEmptyRanges() public {
        // With single-sided liquidity the tick can be teleported for free through empty ranges; the fee must not care.
        vm.warp(WED_2026_09_02 + 2000);
        uint24 before = hook.previewFee(poolId);
        _buyFlock(trader, 3_000_000e18); // huge move
        assertEq(hook.previewFee(poolId), before);
        _sellFlock(other, 3_000_000e18);
        assertEq(hook.previewFee(poolId), before);
    }

    function test_isMarketClosedCalendar() public view {
        assertFalse(hook.isMarketClosed(WED_2026_09_02));
        assertFalse(hook.isMarketClosed(THU_2026_09_03));
        assertTrue(hook.isMarketClosed(SAT_2026_09_05));
        assertTrue(hook.isMarketClosed(SUN_2026_09_06));
        uint256 friMidnight = SAT_2026_09_05 - 12 hours;
        assertFalse(hook.isMarketClosed(friMidnight - 4 hours - 1)); // Fri 19:59:59 UTC open
        assertTrue(hook.isMarketClosed(friMidnight - 4 hours)); // Fri 20:00:00 UTC closed
        uint256 monMidnight = MON_2026_09_07 - 12 hours;
        assertTrue(hook.isMarketClosed(monMidnight + 14 hours + 29 minutes + 59)); // Mon 14:29:59 closed
        assertFalse(hook.isMarketClosed(monMidnight + 14 hours + 30 minutes)); // Mon 14:30:00 open
        assertFalse(hook.isMarketClosed(MON_2026_09_07 + 6 hours)); // Mon 18:00 open
    }

    function test_feeIsChargedOnSwap() public {
        // At init the fee is 3%: a tiny 1,000 stock buy in a huge 1:1 pool returns ≈ 970 FLOCK.
        BalanceDelta d = _buyFlock(trader, 1_000e18);
        int256 got = _flockDelta(d);
        assertGt(got, 0);
        assertApproxEqRel(uint256(got), 970e18, 0.002e18);

        // After the launch window the same trade returns ≈ 990 (minus the ~0.1% price impact of the first trade
        // and of this trade itself, hence the 0.5% tolerance).
        vm.warp(WED_2026_09_02 + 2000);
        BalanceDelta d2 = _buyFlock(other, 1_000e18);
        assertApproxEqRel(uint256(_flockDelta(d2)), 990e18, 0.005e18);
        assertLt(uint256(_flockDelta(d2)), 990e18);
        assertGt(uint256(_flockDelta(d2)), 985e18);
    }

    function test_minFeeFloorApplies() public {
        FlockStockPairHook.FeeConfig memory c = cfg;
        c.baseFee = 5_000;
        c.minFee = 5_000;
        c.launchSeconds = 0;
        vm.prank(owner);
        hook.setFeeConfig(poolId, c);
        assertEq(hook.previewFee(poolId), 5_000);
    }

    // ------------------------------------------------------------------ accounting

    function test_accountingNetFlockAndUniqueTraders() public {
        BalanceDelta b1 = _buyFlock(trader, 1_000e18);
        BalanceDelta b2 = _buyFlock(trader, 500e18);
        BalanceDelta s1 = _sellFlock(trader, 300e18);
        int256 expected = _flockDelta(b1) + _flockDelta(b2) + _flockDelta(s1);
        assertEq(hook.netFlock(poolId, trader), expected);
        assertEq(hook.firstTradeAt(poolId, trader), uint40(block.timestamp));

        _buyFlock(other, 10e18);
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 4);
        assertEq(st.uniqueTraders, 2);
        assertGt(st.flockVolume, 0);
        assertGt(st.stockVolume, 0);
        assertEq(st.lastSwapTs, uint40(block.timestamp));
        assertEq(st.lastTick, _tick());
    }

    function test_swapEmitsStockPairSwapWithFeeAndTrader() public {
        vm.recordLogs();
        _buyFlock(trader, 1_000e18);
        (bool found, uint24 fee, address evTrader) = _lastSwapEvent();
        assertTrue(found, "StockPairSwap not emitted");
        assertEq(fee, 30_000, "fee in event should be the launch fee at the init block");
        assertEq(evTrader, trader, "trader should be tx.origin");
    }

    // ------------------------------------------------------------------ pause

    function test_pauseBlocksSwapsNotLiquidityRemoval() public {
        vm.prank(owner);
        hook.setPaused(poolId, true);
        assertTrue(hook.poolState(poolId).paused);

        vm.startPrank(trader, trader);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: !flockIs0,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();

        // LPs can still exit while paused (no remove-liquidity callback).
        positionManager.decreaseLiquidity(tokenId, 1e18, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES);

        vm.prank(owner);
        hook.setPaused(poolId, false);
        _buyFlock(trader, 1e18);
    }

    // ------------------------------------------------------------------ shipping defaults (01_RegisterPool)

    function test_shippingDefaultsRegisterAndBehave() public {
        FlockStockPairHook.FeeConfig memory ship = FlockStockPairHook.FeeConfig({
            baseFee: 3_000, minFee: 2_500, maxFee: 10_000, launchFee: 10_000, closedMarketFee: 6_000,
            launchSeconds: 1800, minCountedStock: 3e16
        });
        PoolKey memory key2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60 * 2, IHooks(hook));
        vm.startPrank(owner);
        hook.registerPool(key2, ship);
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();
        PoolId id2 = key2.toId();
        (,,, uint24 stored) = poolManager.getSlot0(id2);
        assertEq(stored, 3_000, "stored fee = base fee at init");
        assertEq(hook.previewFee(id2), 10_000, "full launch fee while paused");
        vm.prank(owner);
        hook.setPaused(id2, false);
        assertEq(hook.previewFee(id2), 10_000);
        vm.warp(block.timestamp + 900);
        assertEq(hook.previewFee(id2), 6_500);
        vm.warp(block.timestamp + 900);
        assertEq(hook.previewFee(id2), 3_000);
        vm.warp(SAT_2026_09_05);
        assertEq(hook.previewFee(id2), 6_000, "closed-market fee on Saturday");
        vm.warp(MON_2026_09_07 + 3 hours);
        assertEq(hook.previewFee(id2), 3_000, "back to base on Monday afternoon");
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_feeAlwaysWithinBounds(uint64 blocksAhead, uint32 secondsAhead, uint96 amount) public {
        amount = uint96(bound(amount, 1e15, 3_000_000e18));
        vm.roll(INIT_BLOCK + bound(blocksAhead, 0, 100_000));
        vm.warp(WED_2026_09_02 + bound(secondsAhead, 0, 30 days));
        uint24 fee = hook.previewFee(poolId);
        assertGe(fee, cfg.minFee);
        assertLe(fee, cfg.maxFee);
        vm.recordLogs();
        _buyFlock(trader, amount);
        (bool found, uint24 charged,) = _lastSwapEvent();
        assertTrue(found);
        assertEq(charged, fee, "charged fee must equal the previewed fee for the same state");
    }
}
