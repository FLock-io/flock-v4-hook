// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {RobinhoodV4} from "../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";

/// @notice Adds a two-sided "core" position that straddles the current price: an exact amount of the stock token
///         (STOCK_AMOUNT_E18) plus the FLOCK the range requires. Gives the pool active liquidity at T0 so both
///         directions quote immediately (the single-sided seed from 02 only serves FLOCK buyers).
///  Env: HOOK_ADDRESS, STOCK_TOKEN, TICK_SPACING (60), STOCK_AMOUNT_E18 (required), HALF_WIDTH_SPACINGS (10 → ±600
///       ticks ≈ ±6%), MAX_FLOCK (500_000, whole tokens; guard against a fat-fingered range), LP_RECIPIENT (Safe),
///       ALLOW_UNPAUSED (false; by default the pool must still be paused so the price cannot move under us).
///  forge script script/05_AddCoreLiquidity.s.sol --rpc-url robinhood --account <keystore> --broadcast
contract AddCoreLiquidityScript is LiquidityHelpers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Core {
        PoolKey key;
        PoolId id;
        int24 tick;
        uint160 sqrtPrice;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 stockAmount;
        uint256 flockAmount;
        uint256 amount0Max;
        uint256 amount1Max;
        address lpRecipient;
        bool flockIs1;
    }

    function run() external {
        require(address(hookContract) != address(0), "Core: set HOOK_ADDRESS");
        FlockStockPairHook hook = FlockStockPairHook(address(hookContract));

        Core memory c;
        uint256 tickSpacingRaw = vm.envOr("TICK_SPACING", uint256(60));
        require(tickSpacingRaw >= 1 && tickSpacingRaw <= 32767, "Core: TICK_SPACING out of range");
        int24 spacing = int24(int256(tickSpacingRaw));
        c.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: hookContract
        });
        c.id = c.key.toId();

        FlockStockPairHook.PoolState memory st = hook.poolState(c.id);
        require(st.initialized, "Core: pool not initialized (run 02 first)");
        require(
            st.paused || vm.envOr("ALLOW_UNPAUSED", false),
            "Core: pool is live; set ALLOW_UNPAUSED=true to add liquidity at a moving price"
        );
        (c.sqrtPrice, c.tick,,) = poolManager.getSlot0(c.id);
        require(c.sqrtPrice != 0, "Core: pool state unreadable");
        c.flockIs1 = flockIsCurrency1();

        _range(c, spacing);
        _amounts(c);

        c.lpRecipient = vm.envOr("LP_RECIPIENT", RobinhoodV4.FLOCK_SAFE);
        require(c.lpRecipient != address(0), "Core: zero LP recipient");
        require(stockToken.balanceOf(deployerAddress) >= c.stockAmount, "Core: payer lacks stock token");
        require(flock.balanceOf(deployerAddress) >= c.flockAmount, "Core: payer lacks FLOCK");

        _log(c);
        _execute(c);
        console2.log("core minted. active liquidity now:", poolManager.getLiquidity(c.id));
    }

    function _range(Core memory c, int24 spacing) internal view {
        uint256 halfRaw = vm.envOr("HALF_WIDTH_SPACINGS", uint256(10));
        require(halfRaw >= 1 && halfRaw <= 10_000, "Core: HALF_WIDTH_SPACINGS out of range");
        int24 half = int24(int256(halfRaw)) * spacing;
        int24 center = truncateTickSpacing(c.tick, spacing);
        c.tickLower = center - half;
        c.tickUpper = center + half;
        require(c.tickLower < c.tick && c.tick < c.tickUpper, "Core: range must straddle spot");
        require(
            c.tickLower >= TickMath.minUsableTick(spacing) && c.tickUpper <= TickMath.maxUsableTick(spacing),
            "Core: band out of range"
        );
    }

    /// @dev The stock leg is exact; liquidity follows from it and the FLOCK leg follows from liquidity.
    function _amounts(Core memory c) internal view {
        c.stockAmount = vm.envUint("STOCK_AMOUNT_E18");
        require(c.stockAmount > 0 && c.stockAmount <= 1_000_000e18, "Core: STOCK_AMOUNT_E18 out of range");
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(c.tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(c.tickUpper);
        if (c.flockIs1) {
            // stock = currency0: its amount is set by the upper half of the range
            c.liquidity = LiquidityAmounts.getLiquidityForAmount0(c.sqrtPrice, sqrtB, c.stockAmount);
        } else {
            c.liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtA, c.sqrtPrice, c.stockAmount);
        }
        require(c.liquidity > 0, "Core: zero liquidity");
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(c.sqrtPrice, sqrtA, sqrtB, c.liquidity);
        c.flockAmount = c.flockIs1 ? a1 : a0;
        uint256 maxFlock = vm.envOr("MAX_FLOCK", uint256(500_000)) * 1e18;
        require(c.flockAmount <= maxFlock, "Core: FLOCK leg exceeds MAX_FLOCK (narrow the range or lower the stock amount)");
        // Exact stock leg (+1 wei rounding), 1% slack on the FLOCK leg; only what the range needs is pulled.
        uint256 flockMax = c.flockAmount + c.flockAmount / 100 + 1;
        c.amount0Max = c.flockIs1 ? c.stockAmount + 1 : flockMax;
        c.amount1Max = c.flockIs1 ? flockMax : c.stockAmount + 1;
    }

    function _log(Core memory c) internal view {
        console2.log("stock token      :", address(stockToken), IERC20(address(stockToken)).symbol());
        console2.log("pool id          :", vm.toString(PoolId.unwrap(c.id)));
        console2.log("spot tick        :", int256(c.tick));
        console2.log("core tickLower   :", int256(c.tickLower));
        console2.log("core tickUpper   :", int256(c.tickUpper));
        console2.log("stock leg (wei)  :", c.stockAmount);
        console2.log("FLOCK leg (whole):", c.flockAmount / 1e18);
        console2.log("liquidity units  :", c.liquidity);
        console2.log("LP NFT recipient :", c.lpRecipient);
        console2.log("payer            :", deployerAddress);
    }

    function _execute(Core memory c) internal {
        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            c.key, c.tickLower, c.tickUpper, c.liquidity, c.amount0Max, c.amount1Max, c.lpRecipient, new bytes(0)
        );
        vm.startBroadcast();
        tokenApprovals(c.amount0Max, c.amount1Max);
        positionManager.modifyLiquidities(abi.encode(actions, mintParams), block.timestamp + 3600);
        revokeApprovals();
        vm.stopBroadcast();
    }
}
