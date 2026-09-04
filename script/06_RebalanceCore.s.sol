// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

/// @notice Builds (never broadcasts) the Safe batch that moves part of an existing two-sided position into a
///         stock-token-only band further above spot, so arbitrage can keep tracking the pool price after larger
///         moves instead of FLOCK sells reverting at the old upper edge.
///           tx0  stockToken.approve(Permit2, dust)            – covers a possible 1-wei rounding deficit
///           tx1  Permit2.approve(stockToken → PositionManager, dust, deadline)
///           tx2  PositionManager.modifyLiquidities(
///                  DECREASE_LIQUIDITY(position, DECREASE_BPS)         → credit in both currencies
///                  MINT_POSITION_FROM_DELTAS(far band, amount1Max = 0) → uses ALL the stock-token credit
///                  CLOSE_CURRENCY(stock token) CLOSE_CURRENCY(FLOCK)   → leftovers to the Safe)
///         The far band takes whatever stock token the decrease returns at execution time, so ordinary price drift
///         between building and signing does not break the batch; if the price has entered the far band the mint
///         would need FLOCK (amount1Max = 0) and the whole batch reverts. The NFT owner (the Safe) executes it
///         atomically through the Transaction Builder; the FLOCK leg ends up in the Safe.
///  Env: HOOK_ADDRESS, STOCK_TOKEN, CORE_TOKEN_ID (required), DECREASE_BPS (3000), FAR_LOWER_TICK (default: the
///       position's upper tick), FAR_SPACINGS (40 → 2,400 ticks), DEADLINE_DAYS (7), DUST_ALLOWANCE_E18 (1e15).
///  forge script script/06_RebalanceCore.s.sol --rpc-url robinhood      (dry run only; writes safe-batches/…json)
contract RebalanceCoreScript is LiquidityHelpers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    struct Tx {
        address to;
        bytes data;
        string name;
    }

    struct Plan {
        uint256 tokenId;
        address owner;
        PoolKey key;
        PoolId id;
        int24 tick;
        uint160 sqrtPrice;
        int24 coreLower;
        int24 coreUpper;
        uint128 coreLiquidity;
        uint128 decrease;
        uint256 expect0; // stock token the decrease returns at the current price
        uint256 expect1; // FLOCK the decrease returns at the current price
        int24 farLower;
        int24 farUpper;
        uint128 expectFarLiquidity; // far-band liquidity if executed at the current price
        uint256 amount0Max;
        uint256 dust;
        uint256 deadline;
    }

    function run() external {
        (Plan memory p, Tx[] memory txs) = build();
        _log(p);
        string memory file = string.concat(
            "safe-batches/rebalance-core-", IERC20(address(stockToken)).symbol(), "-", vm.toString(block.chainid), ".json"
        );
        vm.writeJson(_batchJson(txs, "Move part of the core position into a stock-only band above spot"), file);
        console2.log("wrote Safe Transaction Builder batch:", file);
        for (uint256 i = 0; i < txs.length; i++) {
            console2.log(string.concat("tx", vm.toString(i), " ", txs[i].name));
            console2.log("  to  :", txs[i].to);
            console2.log("  data:", vm.toString(txs[i].data));
        }
    }

    /// @dev Pure planning: reads chain state, returns the plan and the calls the NFT owner must send.
    function build() public view returns (Plan memory p, Tx[] memory txs) {
        require(address(hookContract) != address(0), "Rebalance: set HOOK_ADDRESS");
        require(flockIsCurrency1(), "Rebalance: this script assumes stock token = currency0");
        p.tokenId = vm.envUint("CORE_TOKEN_ID");
        p.owner = IERC721Owner(address(positionManager)).ownerOf(p.tokenId);
        PositionInfo info;
        (p.key, info) = positionManager.getPoolAndPositionInfo(p.tokenId);
        require(address(p.key.hooks) == address(hookContract), "Rebalance: position is not in a hooked pool");
        require(Currency.unwrap(p.key.currency0) == address(stockToken), "Rebalance: position pair != STOCK_TOKEN/FLOCK");
        p.id = p.key.toId();
        p.coreLower = info.tickLower();
        p.coreUpper = info.tickUpper();
        p.coreLiquidity = positionManager.getPositionLiquidity(p.tokenId);
        require(p.coreLiquidity > 0, "Rebalance: position has no liquidity");
        (p.sqrtPrice, p.tick,,) = poolManager.getSlot0(p.id);

        uint256 bps = vm.envOr("DECREASE_BPS", uint256(3000));
        require(bps >= 100 && bps <= 10_000, "Rebalance: DECREASE_BPS out of range");
        p.decrease = uint128(uint256(p.coreLiquidity) * bps / 10_000);
        (p.expect0, p.expect1) = LiquidityAmounts.getAmountsForLiquidity(
            p.sqrtPrice, TickMath.getSqrtPriceAtTick(p.coreLower), TickMath.getSqrtPriceAtTick(p.coreUpper), p.decrease
        );
        require(p.expect0 > 0, "Rebalance: the decrease returns no stock token at the current price");

        int24 spacing = p.key.tickSpacing;
        p.farLower = int24(vm.envOr("FAR_LOWER_TICK", int256(p.coreUpper)));
        uint256 farSpacings = vm.envOr("FAR_SPACINGS", uint256(40));
        require(farSpacings >= 1 && farSpacings <= 10_000, "Rebalance: FAR_SPACINGS out of range");
        p.farUpper = p.farLower + int24(int256(farSpacings)) * spacing;
        require(p.farLower % spacing == 0, "Rebalance: FAR_LOWER_TICK not aligned to tick spacing");
        require(p.farLower >= p.tick + 5 * spacing, "Rebalance: far band must start well above spot");
        require(p.farUpper <= TickMath.maxUsableTick(spacing), "Rebalance: far band out of range");
        p.expectFarLiquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(p.farLower), TickMath.getSqrtPriceAtTick(p.farUpper), p.expect0
        );
        require(p.expectFarLiquidity > 0, "Rebalance: zero far liquidity");

        // Cap on what the mint may consume: twice today's expectation covers a strong FLOCK rally before execution.
        p.amount0Max = p.expect0 * 2 + 1;
        p.dust = vm.envOr("DUST_ALLOWANCE_E18", uint256(1e15));
        require(p.dust >= 1 && p.dust <= 1e18, "Rebalance: DUST_ALLOWANCE_E18 out of range");
        uint256 days_ = vm.envOr("DEADLINE_DAYS", uint256(7));
        require(days_ >= 1 && days_ <= 60, "Rebalance: DEADLINE_DAYS out of range");
        p.deadline = block.timestamp + days_ * 1 days;

        txs = new Tx[](3);
        txs[0] = Tx(address(stockToken), abi.encodeCall(IERC20.approve, (address(permit2), p.dust)), "stockToken.approve(Permit2, dust)");
        txs[1] = Tx(
            address(permit2),
            abi.encodeCall(IAllowanceTransfer.approve, (address(stockToken), address(positionManager), uint160(p.dust), uint48(p.deadline))),
            "Permit2.approve(stockToken -> PositionManager, dust)"
        );
        txs[2] = Tx(address(positionManager), _rebalanceCalldata(p), "PositionManager.modifyLiquidities: DECREASE_LIQUIDITY + MINT_POSITION_FROM_DELTAS + CLOSE_CURRENCY x2");
    }

    function _rebalanceCalldata(Plan memory p) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(p.tokenId, uint256(p.decrease), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(p.key, p.farLower, p.farUpper, uint128(p.amount0Max), uint128(0), p.owner, bytes(""));
        params[2] = abi.encode(p.key.currency0);
        params[3] = abi.encode(p.key.currency1);
        return abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), p.deadline));
    }

    function _log(Plan memory p) internal view {
        console2.log("position / owner    :", p.tokenId, p.owner);
        console2.log("core tickLower      :", int256(p.coreLower));
        console2.log("core tickUpper      :", int256(p.coreUpper));
        console2.log("spot tick           :", int256(p.tick));
        console2.log("core liquidity      :", p.coreLiquidity);
        console2.log("decrease liquidity  :", p.decrease);
        console2.log("expected stock out  :", p.expect0);
        console2.log("expected FLOCK out  :", p.expect1);
        console2.log("far tickLower       :", int256(p.farLower));
        console2.log("far tickUpper       :", int256(p.farUpper));
        console2.log("far liquidity @now  :", p.expectFarLiquidity);
        console2.log("amount0Max          :", p.amount0Max);
        console2.log("deadline (unix)     :", p.deadline);
    }

    function _batchJson(Tx[] memory txs, string memory description) internal returns (string memory) {
        string[] memory items = new string[](txs.length);
        for (uint256 i = 0; i < txs.length; i++) {
            string memory k = string.concat("tx", vm.toString(i));
            vm.serializeAddress(k, "to", txs[i].to);
            vm.serializeString(k, "value", "0");
            items[i] = vm.serializeString(k, "data", vm.toString(txs[i].data));
        }
        string memory meta = "meta";
        vm.serializeString(meta, "name", "FlockStockPairHook pool: rebalance core position");
        vm.serializeString(meta, "txBuilderVersion", "1.16.5");
        string memory metaJson = vm.serializeString(meta, "description", description);
        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", block.timestamp * 1000);
        vm.serializeString(root, "meta", metaJson);
        return vm.serializeString(root, "transactions", items);
    }
}

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}
