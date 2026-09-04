// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {RobinhoodV4} from "../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";

/// @notice Read-only status report for operational monitoring.
///  forge script script/04_ReadState.s.sol --rpc-url robinhood
contract ReadStateScript is BaseScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external view {
        require(address(hookContract) != address(0), "ReadState: set HOOK_ADDRESS");
        FlockStockPairHook hook = FlockStockPairHook(address(hookContract));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        console2.log("== hook ==");
        console2.log("address      :", address(hook));
        console2.log("owner        :", hook.owner());
        console2.log("pendingOwner :", hook.pendingOwner());
        console2.log("flock        :", hook.flock());
        uint160 bits = uint160(address(hook)) & uint160((1 << 14) - 1);
        console2.log("permission bits (expect 8384 = beforeInit|beforeSwap|afterSwap):", uint256(bits));
        console2.log("address starts with 0x91 (allowlist review trigger):", uint8(uint160(address(hook)) >> 152) == 0x91);
        console2.log("uses return-delta flags:", (bits & uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)) != 0);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });
        PoolId id = key.toId();
        FlockStockPairHook.PoolState memory st = hook.poolState(id);
        FlockStockPairHook.FeeConfig memory cfg = hook.feeConfig(id);

        console2.log("== pool ==");
        console2.log("stock token  :", address(stockToken), IERC20(address(stockToken)).symbol());
        console2.log("pool id      :", vm.toString(PoolId.unwrap(id)));
        console2.log("registered   :", st.registered);
        console2.log("initialized  :", st.initialized);
        console2.log("paused       :", st.paused);
        if (!st.initialized) return;

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(id);
        console2.log("sqrtPriceX96 :", sqrtPriceX96);
        console2.log("tick         :", int256(tick));
        console2.log("stored lpFee :", uint256(lpFee));
        console2.log("preview fee  :", uint256(hook.previewFee(id)));
        console2.log("active liq   :", uint256(poolManager.getLiquidity(id)));
        console2.log("swaps / unique traders:", uint256(st.swapCount), uint256(st.uniqueTraders));
        console2.log("gross FLOCK volume    :", st.flockVolume / 1e18);
        console2.log("gross stock volume    :", st.stockVolume / 1e18);
        console2.log("initTs / launchTs / last swap ts:", uint256(st.initTs), uint256(st.launchTs), uint256(st.lastSwapTs));
        console2.log("fee cfg base/min/max:", uint256(cfg.baseFee), uint256(cfg.minFee), uint256(cfg.maxFee));
        console2.log("   launch/closedMarket/launchSeconds:", uint256(cfg.launchFee), uint256(cfg.closedMarketFee), uint256(cfg.launchSeconds));
        console2.log("   minCountedStock (wei):", uint256(cfg.minCountedStock));
        console2.log("market closed now:", hook.isMarketClosed(block.timestamp));

        console2.log("== token balances ==");
        IERC20 stock = IERC20(address(stockToken));
        uint256 supply = stock.totalSupply();
        uint256 inPm = stock.balanceOf(address(poolManager));
        console2.log("stock totalSupply (whole tokens):", supply / 1e18);
        console2.log("stock held by v4 PoolManager (all pools):", inPm / 1e18);
        console2.log("FLOCK held by v4 PoolManager (all pools):", flock.balanceOf(address(poolManager)) / 1e18);
    }
}
