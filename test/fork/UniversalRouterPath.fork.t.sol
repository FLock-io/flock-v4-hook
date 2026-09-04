// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";
import {FlockStockPairHook} from "../../src/FlockStockPairHook.sol";

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

/// @notice Proves the hooked pool is tradeable through the canonical Universal Router (the path app.uniswap.org uses).
contract UniversalRouterPathFork is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    FlockStockPairHook hook;
    PoolKey key;
    address trader = makeAddr("urTrader");

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        deployArtifactsAndLabel();
        address hookAddr = address(FLAGS ^ (0x6161 << 144));
        deployCodeTo(
            "FlockStockPairHook.sol:FlockStockPairHook",
            abi.encode(poolManager, RobinhoodV4.FLOCK, RobinhoodV4.FLOCK_SAFE),
            hookAddr
        );
        hook = FlockStockPairHook(hookAddr);
        key = PoolKey(
            Currency.wrap(RobinhoodV4.GOOGL), Currency.wrap(RobinhoodV4.FLOCK), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook)
        );
        vm.prank(RobinhoodV4.FLOCK_SAFE);
        hook.registerPool(
            key,
            FlockStockPairHook.FeeConfig({baseFee: 10_000, minFee: 5_000, maxFee: 50_000, launchFee: 30_000, closedMarketFee: 15_000, launchSeconds: 1800, minCountedStock: 1e15})
        );
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(90_780);
        vm.prank(RobinhoodV4.FLOCK_SAFE);
        hook.initializePool(key, sqrtPrice);
        int24 tickUpper = 90_780;
        int24 tickLower = tickUpper - 3_600;
        deal(RobinhoodV4.FLOCK, address(this), 2_600_000e18);
        IERC20(RobinhoodV4.FLOCK).approve(address(permit2), type(uint256).max);
        permit2.approve(RobinhoodV4.FLOCK, address(positionManager), type(uint160).max, type(uint48).max);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 0, 2_600_000e18
        );
        positionManager.mint(key, tickLower, tickUpper, liq, 0, 2_600_000e18, address(this), block.timestamp, Constants.ZERO_BYTES);
        vm.prank(RobinhoodV4.FLOCK_SAFE);
        hook.setPaused(key.toId(), false);
    }

    function test_universalRouterSwapMatchesQuote() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID) return;
        uint128 amountIn = 1e18;
        deal(RobinhoodV4.GOOGL, trader, amountIn);

        (uint256 quoted,) = IV4Quoter(RobinhoodV4.QUOTER).quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: true, exactAmount: amountIn, hookData: ""})
        );

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            URExactInputSingleParams({poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: uint128(quoted * 995 / 1000), sqrtPriceLimitX96: 0, hookData: ""})
        );
        params[1] = abi.encode(key.currency0, uint256(amountIn));
        params[2] = abi.encode(key.currency1, uint256(quoted * 995 / 1000));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.startPrank(trader, trader);
        IERC20(RobinhoodV4.GOOGL).approve(address(permit2), amountIn);
        permit2.approve(RobinhoodV4.GOOGL, RobinhoodV4.UNIVERSAL_ROUTER, uint160(amountIn), uint48(block.timestamp + 1 hours));
        try IUniversalRouter(RobinhoodV4.UNIVERSAL_ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 600) {
            console2.log("UR execute ok");
        } catch (bytes memory err) {
            console2.log("UR execute reverted, data length:", err.length);
            console2.logBytes(err);
            revert("UR path failed");
        }
        vm.stopPrank();

        uint256 got = IERC20(RobinhoodV4.FLOCK).balanceOf(trader);
        assertEq(got, quoted, "Universal Router output must equal V4Quoter quote");
        assertEq(hook.poolState(key.toId()).swapCount, 1);
        assertEq(hook.netFlock(key.toId(), trader), int256(got));
    }
}
