// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TransientGuard} from "../src/libraries/TransientGuard.sol";

contract Harness {
    function guardedCall() external {
        TransientGuard.enter();
        // Simulate work
        TransientGuard.exit();
    }

    function reentrancyAttack() external {
        TransientGuard.enter();
        // Try to re-enter
        this.guardedCall();
        TransientGuard.exit();
    }
}

contract TransientGuardTest is Test {
    Harness harness;

    error ReentrancyGuardReentrant();

    function setUp() public {
        harness = new Harness();
    }

    function test_NormalExecution() public {
        // Should not revert
        harness.guardedCall();
    }

    function test_RevertOnReentrancy() public {
        // Expect standard OZ error selector 0x3300f829
        vm.expectRevert(bytes4(0x3300f829));
        harness.reentrancyAttack();
    }

    function test_GasCost() public {
        // Measure gas for enter + exit (excluding external call overhead)

        uint256 startGas = gasleft();
        // We use a separate harness call to measure internal cost would be ideal,
        // but measuring the wrapper is sufficient to see the massive difference vs SSTORE.
        harness.guardedCall();
        uint256 gasUsed = startGas - gasleft();

        // 21k (base transaction) + ~100 (guard) + overhead
        // Standard SSTORE guard would be ~22k + 5k = ~27k overhead in warm/cold mix
        // Or ~2.9k if warm.
        // TSTORE is 100 gas x 2 = 200 gas + overhead.

        // Just log it for observation as per GAS.md rules
        console.log("Gas used for guarded call:", gasUsed);
    }
}
