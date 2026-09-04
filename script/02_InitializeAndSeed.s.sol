// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {RobinhoodV4} from "../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";

/// @notice Initialises the registered FLOCK/<stock> pool at INIT_TICK through the hook (owner-gated) and seeds a
///         SINGLE-SIDED FLOCK position via the PositionManager. The range ends exactly at spot and extends
///         RANGE_SPACINGS tick-spacings below it, so at T0 the position holds only FLOCK and no stock token.
///
///  Sequence: initializePool (owner; pool starts PAUSED) → mint seed → setPaused(false) (owner; starts the launch
///  fee clock). Set UNPAUSE=false to stop after the seed and unpause later with a separate setPaused(false).
///  Seed-only mode adds another FLOCK band to an existing pool (paused, or ALLOW_LIVE=true + ALLOW_EXISTING_LIQUIDITY=true
///  when the pool is already open and has active liquidity).
///  clock). While paused nothing can trade or walk the empty price, so the init→seed gap is safe.
///    - broadcaster == hook owner (ops EOA pilot): all three steps in one script run (3 transactions, use --slow);
///    - hook owner is the Safe: run 1 writes safe-batches/initializePool-<SYMBOL>-4663.json; after the Safe executed
///      it, run 2 mints the seed and writes safe-batches/unpause-<SYMBOL>-4663.json for the Safe to execute.
///  The INIT_TICK sanity check against the live FLOCK/USDG pool is mandatory unless SKIP_TICK_CHECK=true.
///
///  Env:
///    HOOK_ADDRESS (required)   STOCK_TOKEN (default GOOGL)   TICK_SPACING (default 60)
///    INIT_TICK      – pool tick for price = FLOCK per stock token (currency1/currency0 when FLOCK is currency1).
///                     tick = log_1.0001(FLOCK per stock token); e.g. 8,756 FLOCK/GOOGL → 90780.
///    SEED_FLOCK     – FLOCK to seed, in whole tokens (default 2600000)
///    RANGE_SPACINGS – width of the band in tick spacings (default 60 → 3,600 ticks ≈ 30% price range)
///    LP_RECIPIENT   – owner of the LP NFT (default: FLock Safe). The broadcaster pays the FLOCK.
///    MAX_TICK_DEVIATION – abort if INIT_TICK deviates from the on-chain FLOCK/USDG-implied price check by more
///                     than this many ticks (default 2000 ≈ 22%). Set 0 to skip the check (stock token price is
///                     not read on-chain; this only guards against fat-finger ticks).
///
///  Dry run:   forge script script/02_InitializeAndSeed.s.sol --rpc-url robinhood
///  Broadcast: forge script script/02_InitializeAndSeed.s.sol --rpc-url robinhood --account <keystore> --broadcast
contract InitializeAndSeedScript is LiquidityHelpers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Seed {
        PoolKey key;
        PoolId id;
        int24 tickSpacing;
        int24 initTick;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPrice;
        uint128 liquidity;
        uint256 seedFlock;
        uint256 amount0Max;
        uint256 amount1Max;
        address lpRecipient;
        bool flockIs1;
    }

    function run() external {
        require(address(hookContract) != address(0), "Seed: set HOOK_ADDRESS");
        FlockStockPairHook hook = FlockStockPairHook(address(hookContract));

        Seed memory p;
        uint256 tickSpacingRaw = vm.envOr("TICK_SPACING", uint256(60));
        require(tickSpacingRaw >= 1 && tickSpacingRaw <= 32767, "Seed: TICK_SPACING out of range");
        p.tickSpacing = int24(int256(tickSpacingRaw));
        int256 initTickRaw = vm.envInt("INIT_TICK");
        require(initTickRaw >= TickMath.MIN_TICK && initTickRaw <= TickMath.MAX_TICK, "Seed: INIT_TICK out of range");
        p.initTick = int24(initTickRaw);
        uint256 seedWhole = vm.envOr("SEED_FLOCK", uint256(2_600_000));
        require(seedWhole >= 1 && seedWhole <= 100_000_000, "Seed: SEED_FLOCK out of range");
        p.seedFlock = seedWhole * 1e18;
        uint256 rangeRaw = vm.envOr("RANGE_SPACINGS", uint256(60));
        require(rangeRaw >= 1 && rangeRaw <= 10_000, "Seed: RANGE_SPACINGS out of range");
        int24 rangeSpacings = int24(int256(rangeRaw));
        p.lpRecipient = vm.envOr("LP_RECIPIENT", RobinhoodV4.FLOCK_SAFE);
        require(p.lpRecipient != address(0), "Seed: zero LP recipient");

        p.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: p.tickSpacing,
            hooks: hookContract
        });
        p.id = p.key.toId();

        FlockStockPairHook.PoolState memory st = hook.poolState(p.id);
        require(st.registered, "Seed: pool not registered in hook (run 01_RegisterPool)");
        bool alreadyInitialized = st.initialized;
        if (alreadyInitialized) {
            // Seed-only mode: use the live price so the band is anchored where the pool actually is.
            (uint160 liveSqrt, int24 liveTick,,) = poolManager.getSlot0(p.id);
            require(liveSqrt != 0, "Seed: pool state unreadable");
            require(poolManager.getLiquidity(p.id) == 0 || vm.envOr("ALLOW_EXISTING_LIQUIDITY", false), "Seed: pool already has liquidity");
            int256 dev = int256(liveTick) - initTickRaw;
            if (dev < 0) dev = -dev;
            require(uint256(dev) <= vm.envOr("MAX_TICK_DEVIATION", uint256(2000)), "Seed: live tick far from INIT_TICK");
            // An open pool may only take extra single-sided FLOCK when it already has active liquidity (a real
            // price) and the operator says so explicitly; an open EMPTY pool can have been walked to any tick.
            require(
                st.paused || (vm.envOr("ALLOW_LIVE", false) && poolManager.getLiquidity(p.id) > 0),
                "Seed: pool is initialized but NOT paused - do not seed an unpaused empty pool (ALLOW_LIVE=true only with live liquidity)"
            );
            p.initTick = liveTick;
            console2.log("pool already initialized (paused); seeding at live tick", int256(liveTick));
        }

        p.sqrtPrice = TickMath.getSqrtPriceAtTick(p.initTick);
        p.flockIs1 = flockIsCurrency1();

        // Single-sided FLOCK band. FLOCK = currency1 → band strictly BELOW spot (price falls as GOOGL buys FLOCK).
        // FLOCK = currency0 → band strictly ABOVE spot.
        if (p.flockIs1) {
            p.tickUpper = truncateTickSpacing(p.initTick, p.tickSpacing);
            p.tickLower = p.tickUpper - rangeSpacings * p.tickSpacing;
        } else {
            p.tickLower = truncateTickSpacing(p.initTick, p.tickSpacing);
            if (p.tickLower < p.initTick) p.tickLower += p.tickSpacing; // strictly above spot
            p.tickUpper = p.tickLower + rangeSpacings * p.tickSpacing;
        }
        require(
            p.tickLower >= TickMath.minUsableTick(p.tickSpacing) && p.tickUpper <= TickMath.maxUsableTick(p.tickSpacing),
            "Seed: band out of range"
        );

        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p.sqrtPrice,
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            p.flockIs1 ? 0 : p.seedFlock,
            p.flockIs1 ? p.seedFlock : 0
        );
        require(p.liquidity > 0, "Seed: zero liquidity");

        // Nothing at all on the empty side (no approval is made for it), exact seed + 1 wei on the FLOCK side.
        p.amount0Max = p.flockIs1 ? 0 : p.seedFlock + 1;
        p.amount1Max = p.flockIs1 ? p.seedFlock + 1 : 0;

        _sanityCheckTick(p.initTick, p.flockIs1); // also in seed-only mode: a paused pool cannot have moved, but check anyway
        _log(p);

        if (!alreadyInitialized) {
            if (hook.owner() != deployerAddress) {
                bytes memory data = abi.encodeCall(FlockStockPairHook.initializePool, (p.key, p.sqrtPrice));
                string memory file = string.concat(
                    "safe-batches/initializePool-", IERC20(address(stockToken)).symbol(), "-", vm.toString(block.chainid), ".json"
                );
                vm.writeJson(_safeTxBuilderJson(address(hook), data, "FlockStockPairHook.initializePool"), file);
                console2.log("hook owner is the Safe; wrote Safe Transaction Builder batch:", file);
                console2.log("execute it, then re-run this script to add the seed liquidity.");
                return;
            }
            vm.startBroadcast();
            hook.initializePool(p.key, p.sqrtPrice);
            vm.stopBroadcast();
        }

        // The pool is paused until the seed is in, so its tick cannot legitimately differ from INIT_TICK here.
        (, int24 liveTickNow,,) = poolManager.getSlot0(p.id);
        require(liveTickNow == p.initTick, "Seed: pool tick differs from INIT_TICK - investigate before seeding");
        require(flock.balanceOf(deployerAddress) >= p.seedFlock, "Seed: payer lacks FLOCK (bridge first)");

        _execute(p);

        (uint160 sqrtAfter, int24 tickAfter,, uint24 lpFee) = poolManager.getSlot0(p.id);
        if (!alreadyInitialized) require(sqrtAfter == p.sqrtPrice, "Seed: unexpected pool price after init");
        console2.log("seeded. tick     :", int256(tickAfter));
        console2.log("stored lpFee     :", uint256(lpFee));

        _finish(hook, p);
    }

    /// @dev Unpause = launch (owner action; the launch-fee clock starts now), or hand the Safe the batch to do it.
    function _finish(FlockStockPairHook hook, Seed memory p) internal {
        if (!hook.poolState(p.id).paused) {
            console2.log("pool is already open; liquidity added to the live pool");
            return;
        }
        if (hook.owner() == deployerAddress) {
            if (!vm.envOr("UNPAUSE", true)) {
                console2.log("seed is in; pool stays PAUSED (UNPAUSE=false). Unpause with the owner key:");
                console2.log("  cast send", address(hook), "'setPaused(bytes32,bool)'", vm.toString(PoolId.unwrap(p.id)));
                console2.log("  ... false --rpc-url robinhood --account <owner-keystore>");
                return;
            }
            vm.startBroadcast();
            hook.setPaused(p.id, false);
            vm.stopBroadcast();
            console2.log("pool unpaused; launch fee decaying");
        } else {
            bytes memory data = abi.encodeCall(FlockStockPairHook.setPaused, (p.id, false));
            string memory file = string.concat(
                "safe-batches/unpause-", IERC20(address(stockToken)).symbol(), "-", vm.toString(block.chainid), ".json"
            );
            vm.writeJson(_safeTxBuilderJson(address(hook), data, "FlockStockPairHook.setPaused(false)"), file);
            console2.log("seed is in; pool stays PAUSED until the Safe executes:", file);
        }
    }

    function _log(Seed memory p) internal view {
        console2.log("stock token      :", address(stockToken), IERC20(address(stockToken)).symbol());
        console2.log("pool id          :", vm.toString(PoolId.unwrap(p.id)));
        console2.log("init tick        :", int256(p.initTick));
        console2.log("sqrtPriceX96     :", p.sqrtPrice);
        console2.log("band tickLower   :", int256(p.tickLower));
        console2.log("band tickUpper   :", int256(p.tickUpper));
        console2.log("seed FLOCK       :", p.seedFlock / 1e18);
        console2.log("liquidity units  :", p.liquidity);
        console2.log("LP NFT recipient :", p.lpRecipient);
        console2.log("payer            :", deployerAddress);
        console2.log("payer FLOCK bal  :", flock.balanceOf(deployerAddress) / 1e18);
    }

    function _execute(Seed memory p) internal {
        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            p.key, p.tickLower, p.tickUpper, p.liquidity, p.amount0Max, p.amount1Max, p.lpRecipient, new bytes(0)
        );
        vm.startBroadcast();
        tokenApprovals(p.amount0Max, p.amount1Max);
        positionManager.modifyLiquidities(abi.encode(actions, mintParams), block.timestamp + 3600);
        revokeApprovals();
        vm.stopBroadcast();
    }

    /// @dev Guards against a fat-fingered INIT_TICK using the live FLOCK/USDG pool and a STOCK_USD_E6 env price:
    ///      implied FLOCK per stock = stockUsd / flockUsd. Skipped when MAX_TICK_DEVIATION == 0 or STOCK_USD_E6 unset.
    ///      USDG has 6 decimals, so the raw pool tick is shifted by log_1.0001(1e12) to get a USD-per-FLOCK tick.
    function _sanityCheckTick(int24 initTick, bool flockIs1) internal view {
        uint256 maxDev = vm.envOr("MAX_TICK_DEVIATION", uint256(2000));
        uint256 stockUsdE6 = vm.envOr("STOCK_USD_E6", uint256(0)); // stock price in USD * 1e6
        if (maxDev == 0 || stockUsdE6 == 0) {
            require(vm.envOr("SKIP_TICK_CHECK", false), "Seed: set STOCK_USD_E6 (and MAX_TICK_DEVIATION) or SKIP_TICK_CHECK=true");
            console2.log("WARNING: tick sanity check skipped by SKIP_TICK_CHECK");
            return;
        }
        // FLOCK (0x5ab3…) < USDG (0x5fc5…) → currency0 = FLOCK (18 dec), currency1 = USDG (6 dec); hookless 0.25% / 25.
        PoolKey memory usdgKey = PoolKey({
            currency0: Currency.wrap(RobinhoodV4.FLOCK),
            currency1: Currency.wrap(RobinhoodV4.USDG),
            fee: 2500,
            tickSpacing: 25,
            hooks: IHooks(address(0))
        });
        (, int24 usdgTickRaw,,) = poolManager.getSlot0(usdgKey.toId());
        uint8 usdgDec = IERC20(RobinhoodV4.USDG).decimals();
        uint8 stockDec = IERC20(address(stockToken)).decimals();
        require(stockDec == 18, "Seed: stock token must have 18 decimals for this check");
        // USD per FLOCK tick = raw tick + log_1.0001(10^(18 - usdgDec))
        int256 flockUsdTick = int256(usdgTickRaw) + _ticksOf(10 ** (18 - usdgDec), 1);
        int256 stockUsdTick = _ticksOf(stockUsdE6, 1e6);
        // FLOCK per stock (currency1/currency0 with stock = currency0) = stockUsd / flockUsd
        int256 implied = stockUsdTick - flockUsdTick;
        if (!flockIs1) implied = -implied; // FLOCK = currency0 → price is stock per FLOCK
        int256 dev = int256(initTick) - implied;
        if (dev < 0) dev = -dev;
        console2.log("FLOCK/USDG raw tick :", int256(usdgTickRaw));
        console2.log("implied FLOCK usd tick:", flockUsdTick);
        console2.log("implied pool tick   :", implied);
        console2.log("deviation (ticks)   :", dev);
        require(uint256(dev) <= maxDev, "Seed: INIT_TICK deviates too much from implied price");
    }

    /// @dev Minimal Safe Transaction Builder file with a single CALL (operation 0, value 0).
    function _safeTxBuilderJson(address to, bytes memory data, string memory name) internal returns (string memory) {
        string memory tx_ = "tx";
        vm.serializeAddress(tx_, "to", to);
        vm.serializeString(tx_, "value", "0");
        vm.serializeString(tx_, "data", vm.toString(data));
        string memory txJson = vm.serializeString(tx_, "operation", "0");
        string memory meta = "meta";
        vm.serializeString(meta, "name", name);
        vm.serializeString(meta, "txBuilderVersion", "1.16.5");
        string memory metaJson = vm.serializeString(meta, "description", "FLOCK stock-pair hook launch step");
        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", block.timestamp * 1000);
        vm.serializeString(root, "meta", metaJson);
        string[] memory txs = new string[](1);
        txs[0] = txJson;
        return vm.serializeString(root, "transactions", txs);
    }

    /// @dev tick = log_1.0001(num/den), via sqrtPriceX96 = sqrt(num/den) * 2^96 and TickMath (exact to +-1 tick).
    function _ticksOf(uint256 num, uint256 den) internal pure returns (int256) {
        uint256 sqrtPriceX96 = _sqrt((num << 192) / den);
        return int256(TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
