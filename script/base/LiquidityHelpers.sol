// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {BaseScript} from "./BaseScript.sol";

contract LiquidityHelpers is BaseScript {
    using CurrencyLibrary for Currency;

    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, recipient);
        params[3] = abi.encode(poolKey.currency1, recipient);

        return (actions, params);
    }

    /// @dev Approve exactly what the PositionManager needs, through Permit2, for both pool currencies.
    ///      Amounts are capped to the configured maxima instead of type(uint).max so a leaked approval
    ///      cannot drain the seeding wallet.
    function tokenApprovals(uint256 amount0Max, uint256 amount1Max) public {
        _approveCurrency(currency0, amount0Max);
        _approveCurrency(currency1, amount1Max);
    }

    function _approveCurrency(Currency currency, uint256 amountMax) internal {
        if (currency.isAddressZero() || amountMax == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        token.approve(address(permit2), amountMax);
        permit2.approve(
            Currency.unwrap(currency), address(positionManager), uint160(amountMax), uint48(block.timestamp + 1 days)
        );
    }

    /// @dev Zero the Permit2 and ERC20 allowances left behind by `tokenApprovals`.
    function revokeApprovals() public {
        _revokeCurrency(currency0);
        _revokeCurrency(currency1);
    }

    function _revokeCurrency(Currency currency) internal {
        if (currency.isAddressZero()) return;
        address token = Currency.unwrap(currency);
        (uint160 amount,,) = permit2.allowance(deployerAddress, token, address(positionManager));
        if (amount != 0) permit2.approve(token, address(positionManager), 0, 0);
        if (IERC20(token).allowance(deployerAddress, address(permit2)) != 0) IERC20(token).approve(address(permit2), 0);
    }

    function truncateTickSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        /// forge-lint: disable-next-line(divide-before-multiply)
        int24 truncated = (tick / tickSpacing) * tickSpacing;
        // Solidity truncates toward zero; for negative ticks round down so the tick stays below `tick`.
        if (tick < 0 && truncated != tick) truncated -= tickSpacing;
        return truncated;
    }
}
