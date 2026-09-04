// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Env-var parsing footguns in the scripts (no fork needed).
//   forge test --match-contract OpsReviewEnv -vv

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract OpsReviewEnv is Test {
    /// 02_InitializeAndSeed line 70: `int24(vm.envInt("INIT_TICK"))` truncates silently.
    function test_initTickTruncation() public {
        // Values >= 2^23 wrap. 16_867_996 = 2^24 + 90_780 wraps to exactly the pilot tick: the script would
        // happily initialise at 90_780 while the operator typed something else (no error, no warning).
        vm.setEnv("INIT_TICK", "16867996");
        int256 raw = vm.envInt("INIT_TICK");
        int24 t = int24(raw);
        console2.log("raw INIT_TICK:", raw);
        console2.log("-> int24:", int256(t));
        assertEq(t, 90_780, "silent wrap to a plausible tick");
        // A plain x10 typo (9_078_000) wraps to -7_699_216 which TickMath rejects: fails closed only by luck.
        vm.setEnv("INIT_TICK", "9078000");
        int24 t2 = int24(vm.envInt("INIT_TICK"));
        console2.log("9078000 -> int24:", int256(t2));
        vm.expectRevert();
        this.sqrtAt(t2);
    }

    function sqrtAt(int24 t) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }

    /// 01_RegisterPool lines 77-85: `uint24(vm.envOr("BASE_FEE", ...))` truncates silently to a value that passes validation.
    function test_feeTruncation() public {
        vm.setEnv("BASE_FEE", "16787216"); // 2^24 + 10_000
        uint24 fee = uint24(vm.envOr("BASE_FEE", uint256(10_000)));
        console2.log("BASE_FEE env 16787216 -> uint24:", uint256(fee));
        assertEq(fee, 10_000, "wraps to a plausible value");
    }

    /// TICK_SPACING: huge values wrap to the default.
    function test_tickSpacingTruncation() public {
        vm.setEnv("TICK_SPACING", "16777276"); // 2^24 + 60
        int24 ts = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        console2.log("TICK_SPACING env 16777276 -> int24:", int256(ts));
        assertEq(ts, 60);
    }
}
