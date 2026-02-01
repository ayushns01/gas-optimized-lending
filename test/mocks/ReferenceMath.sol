// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ReferenceMath
 * @author Gas-Optimized Lending Protocol
 * @notice Pure Solidity reference implementation for differential fuzzing.
 * @dev This library uses CHECKED arithmetic and serves as the "source of truth"
 *      to verify the correctness of OptimizedMath.sol.
 *
 *      This is NOT gas-optimized. It exists solely for testing.
 */
library ReferenceMath {
    /// @dev 1e18 - The standard fixed-point unit.
    uint256 internal constant WAD = 1e18;

    /**
     * @notice Reference implementation of floor(a * b / c).
     * @dev Uses checked arithmetic. Will revert on overflow.
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        require(c > 0, "ReferenceMath: division by zero");
        return (a * b) / c;
    }

    /**
     * @notice Reference implementation of ceil(a * b / c).
     * @dev Rounds up by adding (c - 1) before division.
     */
    function mulDivUp(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        require(c > 0, "ReferenceMath: division by zero");
        uint256 product = a * b;
        // ceil(product / c) = (product + c - 1) / c
        // But beware of overflow when adding c - 1
        if (product == 0) return 0;
        return ((product - 1) / c) + 1;
    }

    /**
     * @notice Reference implementation of linear interest calculation.
     * @dev Formula: nextIndex = lastIndex + (lastIndex * rate * timeDelta) / WAD
     */
    function calculateLinearInterest(
        uint256 lastIndex,
        uint256 rate,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        uint256 rateTimeDelta = rate * timeDelta;
        uint256 interestDelta = mulDiv(lastIndex, rateTimeDelta, WAD);
        return lastIndex + interestDelta;
    }

    /**
     * @notice Reference implementation of scaled -> actual debt conversion.
     * @dev Rounds UP.
     */
    function getActualDebt(
        uint256 scaledDebt,
        uint256 marketIndex
    ) internal pure returns (uint256) {
        return mulDivUp(scaledDebt, marketIndex, WAD);
    }

    /**
     * @notice Reference implementation of actual -> scaled debt conversion.
     * @dev Rounds UP.
     */
    function getScaledDebt(
        uint256 actualDebt,
        uint256 marketIndex
    ) internal pure returns (uint256) {
        return mulDivUp(actualDebt, WAD, marketIndex);
    }
}
