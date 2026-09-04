// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";

/// @notice Sanity checks that the Robinhood Chain fork wiring (addresses, Permit2, PoolManager state reads) works.
/// @dev Run with: forge test --match-contract RobinhoodForkSanity --fork-url robinhood
contract RobinhoodForkSanity is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        deployArtifactsAndLabel();
    }

    function test_forkWiring() public view {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return; // skip when not forked
        assertEq(address(poolManager), RobinhoodV4.POOL_MANAGER);
        assertEq(address(positionManager), RobinhoodV4.POSITION_MANAGER);
        assertGt(RobinhoodV4.POOL_MANAGER.code.length, 0, "PoolManager has no code");
        assertGt(RobinhoodV4.POSITION_MANAGER.code.length, 0, "PositionManager has no code");
        assertGt(RobinhoodV4.PERMIT2.code.length, 0, "Permit2 has no code");
        assertGt(address(swapRouter).code.length, 0, "local swap router not deployed on fork");

        // FLOCK and GOOGL are live 18-decimal tokens
        assertEq(IERC20(RobinhoodV4.FLOCK).decimals(), 18);
        assertEq(IERC20(RobinhoodV4.GOOGL).decimals(), 18);
        assertGt(IERC20(RobinhoodV4.FLOCK).totalSupply(), 1_000_000e18);
        assertGt(IERC20(RobinhoodV4.GOOGL).totalSupply(), 1_000e18);
    }

    function test_existingFlockUsdgPoolState() public view {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        // FLOCK/USDG 0.25% hookless pool created 2026-08-10 (currency0 = FLOCK < USDG)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(RobinhoodV4.FLOCK),
            currency1: Currency.wrap(RobinhoodV4.USDG),
            fee: 2500,
            tickSpacing: 25,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();
        assertEq(PoolId.unwrap(id), 0x77f0e97f94b742b7c2046efb6675eb9583a31b36316c8b7b070d0d04f11aa7b2, "pool id mismatch");
        (uint160 sqrtPriceX96,, , uint24 lpFee) = poolManager.getSlot0(id);
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(lpFee, 2500);
        assertGt(poolManager.getLiquidity(id), 0, "no active liquidity");
    }
}
