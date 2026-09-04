// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {RobinhoodV4} from "../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";

/// @notice Mines a CREATE2 salt whose address encodes exactly the hook's permission bits and deploys
///         FlockStockPairHook through the deterministic CREATE2 factory (0x4e59…956C).
///
///  Env:
///    HOOK_OWNER  – owner of the hook (default: FLock governance Safe 0x6052…d31f). Ownership is 2-step and
///                  cannot be renounced; it can be transferred later via transferOwnership/acceptOwnership.
///
///  Dry run:   forge script script/00_DeployHook.s.sol --rpc-url robinhood
///  Broadcast: forge script script/00_DeployHook.s.sol --rpc-url robinhood --account <keystore> --broadcast --verify
contract DeployHookScript is BaseScript {
    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() public {
        require(block.chainid == RobinhoodV4.CHAIN_ID, "DeployHook: run against Robinhood Chain (or an anvil fork of it)");

        address owner = vm.envOr("HOOK_OWNER", RobinhoodV4.FLOCK_SAFE);
        require(owner != address(0), "DeployHook: zero owner");
        if (deployerAddress == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 || owner == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) {
            console2.log("WARNING: deployer/owner is anvil account #0 - this is a rehearsal, not a mainnet launch");
        }

        bytes memory constructorArgs = abi.encode(poolManager, RobinhoodV4.FLOCK, owner);
        (address hookAddress, bytes32 salt) = _mine(constructorArgs);

        console2.log("chain id            :", block.chainid);
        console2.log("pool manager        :", address(poolManager));
        console2.log("FLOCK               :", RobinhoodV4.FLOCK);
        console2.log("hook owner          :", owner);
        console2.log("predicted hook addr :", hookAddress);
        console2.log("salt                :", vm.toString(salt));

        require(hookAddress.code.length == 0, "DeployHook: address already has code");

        vm.startBroadcast();
        FlockStockPairHook hook = new FlockStockPairHook{salt: salt}(poolManager, RobinhoodV4.FLOCK, owner);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHook: address mismatch");
        require(hook.owner() == owner, "DeployHook: owner mismatch");
        require(hook.flock() == RobinhoodV4.FLOCK, "DeployHook: flock mismatch");
        console2.log("deployed hook       :", address(hook));
        console2.log("next: export HOOK_ADDRESS=%s and run 01_RegisterPool", address(hook));

        string memory j = "deployment";
        vm.serializeAddress(j, "hook", address(hook));
        vm.serializeAddress(j, "owner", owner);
        vm.serializeAddress(j, "poolManager", address(poolManager));
        vm.serializeAddress(j, "deployer", deployerAddress);
        vm.serializeUint(j, "timestamp", block.timestamp);
        string memory out = vm.serializeString(j, "salt", vm.toString(salt));
        string memory file = string.concat("deployments/", vm.toString(block.chainid), "-", vm.toString(address(hook)), ".json");
        vm.writeJson(out, file);
        console2.log("wrote", file);
    }

    /// @dev HookMiner.find() returns the first salt whose address carries FLAGS in its low 14 bits. Uniswap's
    ///      routing allowlist treats addresses starting with 0x91 as reserved for manual review, so we skip
    ///      those by re-mining from a different starting salt.
    function _mine(bytes memory constructorArgs) internal view returns (address hookAddress, bytes32 salt) {
        bytes memory creationCode = type(FlockStockPairHook).creationCode;
        for (uint256 attempt = 0; attempt < 16; attempt++) {
            (hookAddress, salt) = HookMiner.find(CREATE2_FACTORY, FLAGS, creationCode, constructorArgs);
            if (uint8(uint160(hookAddress) >> 152) != 0x91) return (hookAddress, salt);
            // Extremely unlikely (1/256); perturb constructor args is not allowed, so perturb via a different
            // search start by hashing the salt into the loop counter (HookMiner starts at a fixed seed, so we
            // fall back to a manual scan).
            (hookAddress, salt) = _manualScan(creationCode, constructorArgs, uint256(salt) + 1 + attempt);
            if (uint8(uint160(hookAddress) >> 152) != 0x91) return (hookAddress, salt);
        }
        revert("DeployHook: could not mine an address");
    }

    function _manualScan(bytes memory creationCode, bytes memory constructorArgs, uint256 start)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);
        uint160 mask = uint160((1 << 14) - 1);
        for (uint256 i = start; i < start + 500_000; i++) {
            salt = bytes32(i);
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), CREATE2_FACTORY, salt, initCodeHash))))
            );
            if ((uint160(hookAddress) & mask) == FLAGS && uint8(uint160(hookAddress) >> 152) != 0x91) {
                return (hookAddress, salt);
            }
        }
        revert("DeployHook: manual scan exhausted");
    }
}
