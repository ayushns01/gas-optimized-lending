// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {OptimizedMath} from "../src/libraries/OptimizedMath.sol";
import {ReferenceMath} from "./mocks/ReferenceMath.sol";

/**
 * @title OptimizedMathTest
 * @notice Differential fuzzing tests to verify OptimizedMath matches ReferenceMath.
 * @dev Per TESTING.md: "Correctness is established by proving equivalence to a
 *      reference Solidity implementation within defined bounds."
 */
contract OptimizedMathTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS (Bounds per ASSUMPTIONS.md)
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 constant WAD = 1e18;

    // Index bounds: starts at 1e18, max at 1e38 (allows 1e20 growth factor)
    uint256 constant MIN_INDEX = WAD;
    uint256 constant MAX_INDEX = 1e38;

    // Rate bounds: 0 to 500% APR expressed as rate per second
    // 500% APR = 5 * WAD / SECONDS_PER_YEAR ≈ 1.585e11 per second
    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    uint256 constant MAX_RATE = (5 * WAD) / SECONDS_PER_YEAR; // ~158 billion

    // Time bounds: 1 second to 100 years
    uint256 constant MIN_TIME_DELTA = 1;
    uint256 constant MAX_TIME_DELTA = 100 * SECONDS_PER_YEAR;

    // Value bounds for debt conversions
    uint256 constant MAX_VALUE = type(uint128).max;

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS: mulDiv
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_mulDiv_Parity(
        uint256 a,
        uint256 b,
        uint256 c
    ) public pure {
        // Bound inputs to avoid overflow in reference (a * b must fit in uint256)
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        c = bound(c, 1, type(uint256).max); // Avoid division by zero

        uint256 optimized = OptimizedMath.mulDiv(a, b, c);
        uint256 expected = ReferenceMath.mulDiv(a, b, c);

        assertEq(optimized, expected, "mulDiv divergence");
    }

    function testFuzz_mulDivUp_Parity(
        uint256 a,
        uint256 b,
        uint256 c
    ) public pure {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        c = bound(c, 1, type(uint256).max);

        uint256 optimized = OptimizedMath.mulDivUp(a, b, c);
        uint256 expected = ReferenceMath.mulDivUp(a, b, c);

        assertEq(optimized, expected, "mulDivUp divergence");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS: calculateLinearInterest
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_calculateLinearInterest_Parity(
        uint256 lastIndex,
        uint256 rate,
        uint256 timeDelta
    ) public pure {
        // Bound inputs per ASSUMPTIONS.md
        lastIndex = bound(lastIndex, MIN_INDEX, MAX_INDEX);
        rate = bound(rate, 0, MAX_RATE);
        timeDelta = bound(timeDelta, 0, MAX_TIME_DELTA);

        uint256 optimized = OptimizedMath.calculateLinearInterest(
            lastIndex,
            rate,
            timeDelta
        );
        uint256 expected = ReferenceMath.calculateLinearInterest(
            lastIndex,
            rate,
            timeDelta
        );

        assertEq(optimized, expected, "calculateLinearInterest divergence");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS: Debt Conversions
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_getActualDebt_Parity(
        uint256 scaledDebt,
        uint256 marketIndex
    ) public pure {
        scaledDebt = bound(scaledDebt, 0, MAX_VALUE);
        marketIndex = bound(marketIndex, MIN_INDEX, MAX_INDEX);

        uint256 optimized = OptimizedMath.getActualDebt(
            scaledDebt,
            marketIndex
        );
        uint256 expected = ReferenceMath.getActualDebt(scaledDebt, marketIndex);

        assertEq(optimized, expected, "getActualDebt divergence");
    }

    function testFuzz_getScaledDebt_Parity(
        uint256 actualDebt,
        uint256 marketIndex
    ) public pure {
        actualDebt = bound(actualDebt, 0, MAX_VALUE);
        marketIndex = bound(marketIndex, MIN_INDEX, MAX_INDEX);

        uint256 optimized = OptimizedMath.getScaledDebt(
            actualDebt,
            marketIndex
        );
        uint256 expected = ReferenceMath.getScaledDebt(actualDebt, marketIndex);

        assertEq(optimized, expected, "getScaledDebt divergence");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UNIT TESTS: Edge Cases
    // ═══════════════════════════════════════════════════════════════════════════

    // Note: vm.expectRevert requires the revert to happen in a sub-call.
    // Since library functions are inlined, we use external wrapper functions.

    function callMulDiv(
        uint256 a,
        uint256 b,
        uint256 c
    ) external pure returns (uint256) {
        return OptimizedMath.mulDiv(a, b, c);
    }

    function callMulDivUp(
        uint256 a,
        uint256 b,
        uint256 c
    ) external pure returns (uint256) {
        return OptimizedMath.mulDivUp(a, b, c);
    }

    function test_mulDiv_ZeroDenominator_Reverts() public {
        vm.expectRevert();
        this.callMulDiv(1, 1, 0);
    }

    function test_mulDivUp_ZeroDenominator_Reverts() public {
        vm.expectRevert();
        this.callMulDivUp(1, 1, 0);
    }

    function test_calculateLinearInterest_ZeroTimeDelta() public pure {
        uint256 result = OptimizedMath.calculateLinearInterest(WAD, 1e15, 0);
        assertEq(
            result,
            WAD,
            "Zero timeDelta should return lastIndex unchanged"
        );
    }

    function test_calculateLinearInterest_ZeroRate() public pure {
        uint256 result = OptimizedMath.calculateLinearInterest(WAD, 0, 1000);
        assertEq(result, WAD, "Zero rate should return lastIndex unchanged");
    }

    function test_getActualDebt_AtGenesisIndex() public pure {
        // At genesis, index = WAD, so actual = scaled
        uint256 scaled = 100 * WAD;
        uint256 actual = OptimizedMath.getActualDebt(scaled, WAD);
        assertEq(
            actual,
            scaled,
            "At genesis index, actual should equal scaled"
        );
    }

    function test_getScaledDebt_RoundsUp() public pure {
        // If actual = 3, index = 2e18, scaled = ceil(3 * 1e18 / 2e18) = ceil(1.5) = 2
        uint256 scaled = OptimizedMath.getScaledDebt(3, 2 * WAD);
        assertEq(scaled, 2, "Should round up");
    }

    function test_getActualDebt_RoundsUp() public pure {
        // If scaled = 3, index = 2e18, actual = ceil(3 * 2e18 / 1e18) = ceil(6) = 6
        // But let's try a case with remainder:
        // scaled = 1, index = 1.5e18, actual = ceil(1 * 1.5e18 / 1e18) = ceil(1.5) = 2
        uint256 actual = OptimizedMath.getActualDebt(1, 15e17);
        assertEq(actual, 2, "Should round up");
    }
}
