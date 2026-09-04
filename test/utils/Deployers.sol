// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";

/**
 * Base Deployer Contract for Hook Testing and Scripts.
 *
 * 1. On anvil (31337) deploys local Permit2, PoolManager, PositionManager and a V4 swap router.
 * 2. On Robinhood Chain (4663) uses the canonical Uniswap v4 deployments from `RobinhoodV4`
 *    (hookmate's AddressConstants does not know chain 4663). The swap router is either a
 *    configured address (`_configuredSwapRouter()`) or, when allowed (tests / forks), a locally
 *    deployed hookmate V4Router so fork tests can swap without the Universal Router encoding.
 * 3. On every other chain falls back to hookmate's AddressConstants.
 */
abstract contract Deployers {
    IPermit2 permit2;
    IPoolManager poolManager;
    IPositionManager positionManager;
    IUniswapV4Router04 swapRouter;

    function deployToken() internal returns (MockERC20 token) {
        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(address(this), 10_000_000 ether);

        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function deployCurrencyPair() internal virtual returns (Currency currency0, Currency currency1) {
        MockERC20 token0 = deployToken();
        MockERC20 token1 = deployToken();

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function deployPermit2() internal {
        address permit2Address = AddressConstants.getPermit2Address();

        if (permit2Address.code.length > 0) {
            // Permit2 is already deployed (true on Robinhood Chain mainnet and forks).
        } else {
            _etch(permit2Address, Permit2Deployer.deploy().code);
        }

        permit2 = IPermit2(permit2Address);
    }

    function deployPoolManager() internal virtual {
        if (block.chainid == 31337) {
            poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(0x4444)));
        } else if (block.chainid == RobinhoodV4.CHAIN_ID) {
            poolManager = IPoolManager(RobinhoodV4.POOL_MANAGER);
        } else {
            poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        }
    }

    function deployPositionManager() internal virtual {
        if (block.chainid == 31337) {
            positionManager = IPositionManager(
                V4PositionManagerDeployer.deploy(
                    address(poolManager), address(permit2), 300_000, address(0), address(0)
                )
            );
        } else if (block.chainid == RobinhoodV4.CHAIN_ID) {
            positionManager = IPositionManager(RobinhoodV4.POSITION_MANAGER);
        } else {
            positionManager = IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid));
        }
    }

    function deployRouter() internal virtual {
        if (block.chainid == 31337) {
            swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));
        } else if (block.chainid == RobinhoodV4.CHAIN_ID) {
            address configured = _configuredSwapRouter();
            if (configured != address(0)) {
                swapRouter = IUniswapV4Router04(payable(configured));
            } else if (_allowLocalRouterDeploy()) {
                swapRouter =
                    IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));
            }
            // else: no swap router (deployment / liquidity scripts do not need one)
        } else {
            swapRouter = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));
        }
    }

    /// @dev Swap router to use on Robinhood Chain when one is already deployed (scripts read it from env).
    function _configuredSwapRouter() internal view virtual returns (address) {
        return address(0);
    }

    /// @dev Whether a local hookmate router may be deployed on Robinhood Chain (true for tests/forks only).
    function _allowLocalRouterDeploy() internal view virtual returns (bool) {
        return false;
    }

    function _etch(address, bytes memory) internal virtual {
        revert("Not implemented");
    }

    function deployArtifacts() internal {
        // Order matters.
        deployPermit2();
        deployPoolManager();
        deployPositionManager();
        deployRouter();
    }
}
