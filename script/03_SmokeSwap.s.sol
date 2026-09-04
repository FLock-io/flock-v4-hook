// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {RobinhoodV4} from "../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../src/FlockStockPairHook.sol";

/// @dev Robinhood's Universal Router is compiled against a v4-periphery where ExactInputSingleParams still carries
///      `sqrtPriceLimitX96` (verified from live UR calldata, 12 words); the current periphery in lib/ dropped it.
struct URExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Post-launch smoke test through the SAME path the Uniswap app uses: quote with the canonical V4Quoter,
///         then swap a small amount of the stock token for FLOCK through the Universal Router (Permit2 approvals),
///         and print what the hook recorded. Also proves the hook is routable without any custom router.
///  Env: HOOK_ADDRESS, STOCK_TOKEN, TICK_SPACING, AMOUNT_IN_E18 (input-token wei, default 0.01), DIRECTION
///       ("buy" = pay the stock token for FLOCK, default; "sell" = pay FLOCK for the stock token).
///  forge script script/03_SmokeSwap.s.sol --rpc-url robinhood --account <keystore> --broadcast
contract SmokeSwapScript is BaseScript {
    using PoolIdLibrary for PoolKey;

    uint8 constant V4_SWAP = 0x10; // Universal Router command

    struct Swap {
        PoolKey key;
        PoolId id;
        bool zeroForOne;
        Currency cIn;
        Currency cOut;
        uint128 amountIn;
        uint128 minOut;
        uint256 quoted;
    }

    function run() external {
        require(address(hookContract) != address(0), "Smoke: set HOOK_ADDRESS");
        FlockStockPairHook hook = FlockStockPairHook(address(hookContract));

        Swap memory w;
        w.amountIn = uint128(vm.envOr("AMOUNT_IN_E18", uint256(1e16)));
        w.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(60)))),
            hooks: hookContract
        });
        w.id = w.key.toId();
        bool flockIs1 = flockIsCurrency1();
        bool sell = keccak256(bytes(vm.envOr("DIRECTION", string("buy")))) == keccak256("sell");
        w.zeroForOne = sell ? !flockIs1 : flockIs1; // buy: pay the stock token, receive FLOCK
        w.cIn = w.zeroForOne ? w.key.currency0 : w.key.currency1;
        w.cOut = w.zeroForOne ? w.key.currency1 : w.key.currency0;
        console2.log(sell ? "direction: SELL FLOCK for the stock token" : "direction: BUY FLOCK with the stock token");

        console2.log("fee preview before swap:", uint256(hook.previewFee(w.id)));
        (w.quoted,) = IV4Quoter(RobinhoodV4.QUOTER).quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: w.key, zeroForOne: w.zeroForOne, exactAmount: w.amountIn, hookData: ""
            })
        );
        console2.log("quoted out (wei):", w.quoted);
        w.minOut = uint128(w.quoted * 995 / 1000);

        IERC20 outToken = IERC20(Currency.unwrap(w.cOut));
        uint256 outBefore = outToken.balanceOf(deployerAddress);
        _execute(w);
        uint256 got = outToken.balanceOf(deployerAddress) - outBefore;
        console2.log("executed out (wei):", got);
        require(got == w.quoted, "Smoke: quote != execution");

        FlockStockPairHook.PoolState memory st = hook.poolState(w.id);
        console2.log("hook swapCount / uniqueTraders:", uint256(st.swapCount), uint256(st.uniqueTraders));
        console2.log("netFlock(deployer) (wei):", hook.netFlock(w.id, deployerAddress));
        console2.log("fee preview after swap:", uint256(hook.previewFee(w.id)));
    }

    /// @dev Universal Router V4_SWAP payload: SWAP_EXACT_IN_SINGLE -> SETTLE_ALL -> TAKE_ALL, funded via Permit2.
    function _execute(Swap memory w) internal {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            URExactInputSingleParams({poolKey: w.key, zeroForOne: w.zeroForOne, amountIn: w.amountIn, amountOutMinimum: w.minOut, sqrtPriceLimitX96: 0, hookData: ""})
        );
        params[1] = abi.encode(w.cIn, uint256(w.amountIn));
        params[2] = abi.encode(w.cOut, uint256(w.minOut));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.startBroadcast();
        IERC20(Currency.unwrap(w.cIn)).approve(address(permit2), w.amountIn);
        permit2.approve(
            Currency.unwrap(w.cIn), RobinhoodV4.UNIVERSAL_ROUTER, uint160(w.amountIn), uint48(block.timestamp + 1 hours)
        );
        IUniversalRouter(RobinhoodV4.UNIVERSAL_ROUTER).execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 600);
        // Leave no standing allowances behind.
        permit2.approve(Currency.unwrap(w.cIn), RobinhoodV4.UNIVERSAL_ROUTER, 0, 0);
        IERC20(Currency.unwrap(w.cIn)).approve(address(permit2), 0);
        vm.stopBroadcast();
    }
}
