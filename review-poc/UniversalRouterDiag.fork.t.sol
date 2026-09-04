// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Review diagnostic: does the canonical Universal Router on Robinhood execute a V4_SWAP at all on this fork?
// Runs the SAME payload shape as script/03_SmokeSwap.s.sol against the live, hookless FLOCK/USDG pool.
// forge test --match-path test/review/UniversalRouterDiag.fork.t.sol --fork-url robinhood -vvv

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

contract UniversalRouterDiagFork is BaseTest {
    address trader = makeAddr("diagTrader");

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        deployArtifactsAndLabel();
    }

    function test_diag_emptyCommandsSucceeds() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        vm.prank(trader, trader);
        IUniversalRouter(RobinhoodV4.UNIVERSAL_ROUTER).execute("", new bytes[](0), block.timestamp + 600);
    }

    function test_diag_v4SwapOnHooklessFlockUsdgPool() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(RobinhoodV4.FLOCK),
            currency1: Currency.wrap(RobinhoodV4.USDG),
            fee: 2500,
            tickSpacing: 25,
            hooks: IHooks(address(0))
        });
        uint128 amountIn = 1e18;
        deal(RobinhoodV4.FLOCK, trader, amountIn);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ""
            })
        );
        params[1] = abi.encode(key.currency0, uint256(amountIn));
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.startPrank(trader, trader);
        IERC20(RobinhoodV4.FLOCK).approve(address(permit2), amountIn);
        permit2.approve(RobinhoodV4.FLOCK, RobinhoodV4.UNIVERSAL_ROUTER, uint160(amountIn), uint48(block.timestamp + 1 hours));
        (bool ok, bytes memory err) = RobinhoodV4.UNIVERSAL_ROUTER.call(
            abi.encodeWithSignature("execute(bytes,bytes[],uint256)", abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 600)
        );
        vm.stopPrank();
        console2.log("hookless pool UR v4 swap ok:", ok);
        if (!ok) console2.logBytes(err);
        console2.log("USDG received:", IERC20(RobinhoodV4.USDG).balanceOf(trader));
        assertTrue(ok, "UR V4_SWAP fails even on the live hookless pool");
    }
}
