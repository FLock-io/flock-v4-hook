// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {RobinhoodV4} from "../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";

/// @notice Registers the FLOCK/<stock> pool key and its fee schedule in the hook.
///
///  If the broadcaster is the hook owner the call is sent directly. Otherwise (owner = Safe) the script writes a
///  Safe Transaction Builder JSON to safe-batches/ and prints the calldata, so the Safe signers can execute it.
///
///  Env (all fees in hundredths of a bip; 10_000 = 1%):
///    HOOK_ADDRESS (required)   STOCK_TOKEN (default GOOGL)   TICK_SPACING (default 60)
///    BASE_FEE 3000 (0.30%)  MIN_FEE 2500  MAX_FEE 10000 (1%)  LAUNCH_FEE 10000  LAUNCH_SECONDS 1800
///    CLOSED_MARKET_FEE 6000 (0.60%, Fri 20:00 UTC → Mon 14:30 UTC)
///    MIN_COUNTED_STOCK_E18 30000000000000000 (0.03 stock token ≈ $10 for GOOGL; smaller swaps are not counted as traders)
///
///  Dry run:   forge script script/01_RegisterPool.s.sol --rpc-url robinhood
///  Broadcast: forge script script/01_RegisterPool.s.sol --rpc-url robinhood --account <keystore> --broadcast
contract RegisterPoolScript is BaseScript {
    using PoolIdLibrary for PoolKey;

    function run() public {
        require(address(hookContract) != address(0), "RegisterPool: set HOOK_ADDRESS");
        FlockStockPairHook hook = FlockStockPairHook(address(hookContract));
        require(hook.flock() == RobinhoodV4.FLOCK, "RegisterPool: hook is not the FLOCK hook");

        uint256 tickSpacingRaw = vm.envOr("TICK_SPACING", uint256(60));
        require(tickSpacingRaw >= 1 && tickSpacingRaw <= 32767, "RegisterPool: TICK_SPACING out of range");
        int24 tickSpacing = int24(int256(tickSpacingRaw));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });
        FlockStockPairHook.FeeConfig memory cfg = _feeConfigFromEnv();

        console2.log("stock token   :", address(stockToken), IERC20(address(stockToken)).symbol());
        console2.log("currency0     :", Currency.unwrap(currency0));
        console2.log("currency1     :", Currency.unwrap(currency1));
        console2.log("FLOCK is currency1:", flockIsCurrency1());
        console2.log("tickSpacing   :", uint256(int256(tickSpacing)));
        console2.log("pool id       :", vm.toString(PoolId.unwrap(key.toId())));
        console2.log("baseFee/min/max      :", uint256(cfg.baseFee), uint256(cfg.minFee), uint256(cfg.maxFee));
        console2.log("launchFee/seconds    :", uint256(cfg.launchFee), uint256(cfg.launchSeconds));
        console2.log("closedMarketFee      :", uint256(cfg.closedMarketFee));
        console2.log("minCountedStock (wei):", uint256(cfg.minCountedStock));

        bytes memory data = abi.encodeCall(FlockStockPairHook.registerPool, (key, cfg));
        address owner = hook.owner();

        if (owner == deployerAddress) {
            vm.startBroadcast();
            hook.registerPool(key, cfg);
            vm.stopBroadcast();
            console2.log("registered directly by owner", owner);
        } else {
            string memory file = string.concat(
                "safe-batches/registerPool-", IERC20(address(stockToken)).symbol(), "-", vm.toString(block.chainid), ".json"
            );
            vm.writeJson(_safeTxBuilderJson(address(hook), data), file);
            console2.log("hook owner is", owner);
            console2.log("wrote Safe Transaction Builder batch:", file);
            console2.log("registerPool calldata:");
            console2.logBytes(data);
        }
    }

    function _feeConfigFromEnv() internal view returns (FlockStockPairHook.FeeConfig memory cfg) {
        cfg.baseFee = _fee("BASE_FEE", 3_000);
        cfg.minFee = _fee("MIN_FEE", 2_500);
        cfg.maxFee = _fee("MAX_FEE", 10_000);
        cfg.launchFee = _fee("LAUNCH_FEE", 10_000);
        cfg.closedMarketFee = _fee("CLOSED_MARKET_FEE", 6_000);
        uint256 launchSeconds = vm.envOr("LAUNCH_SECONDS", uint256(1800));
        require(launchSeconds <= 30 days, "RegisterPool: LAUNCH_SECONDS too large");
        cfg.launchSeconds = uint32(launchSeconds);
        uint256 minCounted = vm.envOr("MIN_COUNTED_STOCK_E18", uint256(3e16));
        require(minCounted <= type(uint128).max, "RegisterPool: MIN_COUNTED_STOCK_E18 too large");
        cfg.minCountedStock = uint128(minCounted);
    }

    /// @dev Reads a fee env var and refuses values that would silently truncate or exceed the hook's hard cap.
    function _fee(string memory name, uint256 dflt) internal view returns (uint24) {
        uint256 v = vm.envOr(name, dflt);
        require(v <= 100_000, string.concat("RegisterPool: ", name, " above 10% hard cap")); // == FlockStockPairHook.HARD_MAX_FEE
        return uint24(v);
    }

    /// @dev Minimal Safe Transaction Builder file with a single CALL (operation 0, value 0).
    function _safeTxBuilderJson(address to, bytes memory data) internal returns (string memory) {
        string memory tx_ = "tx";
        vm.serializeAddress(tx_, "to", to);
        vm.serializeString(tx_, "value", "0");
        vm.serializeString(tx_, "data", vm.toString(data));
        string memory txJson = vm.serializeString(tx_, "operation", "0");

        string memory meta = "meta";
        vm.serializeString(meta, "name", "FlockStockPairHook.registerPool");
        vm.serializeString(meta, "txBuilderVersion", "1.16.5");
        string memory metaJson = vm.serializeString(meta, "description", "Register FLOCK/<stock> pool key and fee schedule");

        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", block.timestamp * 1000);
        vm.serializeString(root, "meta", metaJson);
        string[] memory txs = new string[](1);
        txs[0] = txJson;
        return vm.serializeString(root, "transactions", txs);
    }
}
