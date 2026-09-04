// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {Deployers} from "test/utils/Deployers.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";

/// @notice Shared configuration between scripts.
/// @dev Pair configuration comes from the environment so the same scripts serve every FLOCK/<stock> pool:
///      - STOCK_TOKEN   : the Robinhood Stock Token to pair with FLOCK (default GOOGL)
///      - HOOK_ADDRESS  : the deployed hook (address(0) until 00_DeployHook has run)
///      - V4_SWAP_ROUTER: optional hookmate router already deployed on Robinhood (for smoke swaps)
///      FLOCK itself is fixed to the canonical address and is never overridable.
contract BaseScript is Script, Deployers {
    address immutable deployerAddress;

    IERC20 internal immutable flock;
    IERC20 internal immutable stockToken;
    IHooks internal immutable hookContract;

    Currency immutable currency0;
    Currency immutable currency1;

    constructor() {
        require(block.chainid == RobinhoodV4.CHAIN_ID, "BaseScript: run against Robinhood Chain (or an anvil fork of it)");
        require(RobinhoodV4.POOL_MANAGER.code.length > 0, "BaseScript: PoolManager has no code on this RPC");
        deployArtifacts();

        deployerAddress = getDeployer();

        flock = IERC20(RobinhoodV4.FLOCK);
        stockToken = IERC20(vm.envOr("STOCK_TOKEN", RobinhoodV4.GOOGL));
        hookContract = IHooks(vm.envOr("HOOK_ADDRESS", address(0)));

        require(address(stockToken) != address(flock), "BaseScript: stock token must differ from FLOCK");
        (currency0, currency1) = getCurrencies();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");

        vm.label(address(flock), "FLOCK");
        vm.label(address(stockToken), "StockToken");
        vm.label(address(hookContract), "HookContract");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
        } else {
            revert("Unsupported etch on this network");
        }
    }

    function _configuredSwapRouter() internal view override returns (address) {
        return vm.envOr("V4_SWAP_ROUTER", address(0));
    }

    /// @dev Currencies sorted the way the PoolManager expects (currency0 < currency1).
    function getCurrencies() internal view returns (Currency, Currency) {
        if (address(stockToken) < address(flock)) {
            return (Currency.wrap(address(stockToken)), Currency.wrap(address(flock)));
        } else {
            return (Currency.wrap(address(flock)), Currency.wrap(address(stockToken)));
        }
    }

    /// @dev True when FLOCK is currency1 (e.g. GOOGL/FLOCK, TSLA/FLOCK); false when FLOCK is currency0 (FLOCK/NVDA).
    function flockIsCurrency1() internal view returns (bool) {
        return address(stockToken) < address(flock);
    }

    function getDeployer() internal returns (address) {
        address[] memory wallets = vm.getWallets();

        if (wallets.length > 0) {
            return wallets[0];
        } else {
            return msg.sender;
        }
    }
}
