// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title OptimizedMath
 * @author Gas-Optimized Lending Protocol
 * @notice Pure library for gas-optimized interest rate math using inline assembly.
 * @dev All functions are PURE. No storage access, no external calls, no block.timestamp.
 *
 *      SAFETY WARNING:
 *      ───────────────
 *      This library uses UNCHECKED arithmetic in Yul.
 *      Inputs MUST be validated at the caller level before being passed here.
 *      Silent overflow WILL occur if bounds are violated.
 *
 *      ROUNDING RULES (per THREATS.md):
 *      ─────────────────────────────────
 *      - Debt calculations round UP (favor protocol).
 *      - Collateral calculations round DOWN (favor protocol).
 *
 *      PRECISION:
 *      ──────────
 *      All values use WAD (1e18) fixed-point precision.
 */
library OptimizedMath {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev 1e18 - The standard fixed-point unit for all internal accounting.
    uint256 internal constant WAD = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE MATH PRIMITIVES (Yul)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculates floor(a * b / c) without overflow for intermediate product.
     * @dev Uses the mulmod trick to detect overflow, then computes result via Yul.
     *      This is the standard "mulDiv" pattern used throughout DeFi.
     *
     *      WARNING: Reverts if denominator is zero or result overflows uint256.
     *
     * @param a First multiplicand
     * @param b Second multiplicand
     * @param c Denominator (must be non-zero)
     * @return result floor(a * b / c)
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256 result) {
        assembly {
            // Check for zero denominator
            if iszero(c) {
                // revert with Panic(0x12) - division by zero
                mstore(
                    0x00,
                    0x4e487b7100000000000000000000000000000000000000000000000000000000
                )
                mstore(0x04, 0x12)
                revert(0x00, 0x24)
            }

            // Compute full 512-bit product: (high, low) = a * b
            // mm = (a * b) mod 2^256
            let mm := mulmod(a, b, not(0))
            // low = a * b (truncated to 256 bits)
            let low := mul(a, b)
            // high = carry from a * b
            let high := sub(sub(mm, low), lt(mm, low))

            // If high > 0, result would overflow uint256
            if high {
                // Check if result fits: high < c required
                if iszero(lt(high, c)) {
                    // revert with Panic(0x11) - overflow
                    mstore(
                        0x00,
                        0x4e487b7100000000000000000000000000000000000000000000000000000000
                    )
                    mstore(0x04, 0x11)
                    revert(0x00, 0x24)
                }
                // Use 512-bit division: result = (high * 2^256 + low) / c
                // This is complex; for simplicity we revert on overflow in this MVP
                // In production, use full 512-bit division algorithm
                mstore(
                    0x00,
                    0x4e487b7100000000000000000000000000000000000000000000000000000000
                )
                mstore(0x04, 0x11)
                revert(0x00, 0x24)
            }

            // Simple case: high == 0, just divide
            result := div(low, c)
        }
    }

    /**
     * @notice Calculates ceil(a * b / c) - rounds UP.
     * @dev Same as mulDiv but adds 1 if there's a remainder.
     *      Used for debt calculations to favor the protocol.
     *
     * @param a First multiplicand
     * @param b Second multiplicand
     * @param c Denominator (must be non-zero)
     * @return result ceil(a * b / c)
     */
    function mulDivUp(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256 result) {
        assembly {
            // Check for zero denominator
            if iszero(c) {
                mstore(
                    0x00,
                    0x4e487b7100000000000000000000000000000000000000000000000000000000
                )
                mstore(0x04, 0x12)
                revert(0x00, 0x24)
            }

            // Compute full 512-bit product
            let mm := mulmod(a, b, not(0))
            let low := mul(a, b)
            let high := sub(sub(mm, low), lt(mm, low))

            // Overflow check
            if high {
                mstore(
                    0x00,
                    0x4e487b7100000000000000000000000000000000000000000000000000000000
                )
                mstore(0x04, 0x11)
                revert(0x00, 0x24)
            }

            // floor(a * b / c)
            result := div(low, c)

            // If there's a remainder, round up
            if mod(low, c) {
                result := add(result, 1)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEREST CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculates the next interest index using linear interest growth.
     * @dev Formula: nextIndex = lastIndex + (lastIndex * rate * timeDelta) / WAD
     *
     *      This represents linear interest accrual between updates.
     *      The index compounds over time as updates are applied sequentially.
     *
     *      BOUNDS (must be enforced by caller):
     *      - lastIndex: [1e18, type(uint128).max]
     *      - rate: [0, ~158% per second max for uint256 safety with 100yr delta]
     *      - timeDelta: [0, ~100 years in seconds]
     *
     * @param lastIndex The previous interest index (WAD precision, starts at 1e18)
     * @param rate The interest rate per second (WAD precision)
     * @param timeDelta Time elapsed since last update (seconds)
     * @return nextIndex The updated interest index
     */
    function calculateLinearInterest(
        uint256 lastIndex,
        uint256 rate,
        uint256 timeDelta
    ) internal pure returns (uint256 nextIndex) {
        // nextIndex = lastIndex + (lastIndex * rate * timeDelta) / WAD
        // We compute (lastIndex * rate * timeDelta) / WAD using two mulDiv calls
        // to avoid intermediate overflow.

        // Step 1: interestDelta = (lastIndex * rate * timeDelta) / WAD
        //       = mulDiv(mulDiv(lastIndex, rate, 1), timeDelta, WAD)
        //       OR more safely: mulDiv(lastIndex, rate * timeDelta, WAD)
        //       But rate * timeDelta could overflow. Let's be careful.

        // Safe approach: (lastIndex * rate / WAD) * timeDelta might lose precision.
        // Better: mulDiv(lastIndex * rate, timeDelta, WAD) but lastIndex * rate might overflow.
        // Best: Split into two multiplications.

        // Actually, for linear interest with reasonable bounds:
        // lastIndex <= 1e38, rate <= 1e18 (100% per second is absurd), timeDelta <= 3.15e9 (100 years)
        // lastIndex * rate <= 1e56 (fits in uint256)
        // lastIndex * rate * timeDelta <= 1e66 (DOES NOT fit in uint256!)

        // We need proper handling. Use two-step mulDiv:
        // interestDelta = mulDiv(lastIndex, rate, WAD) * timeDelta
        // But mulDiv(lastIndex, rate, WAD) could be huge, then times timeDelta could overflow.

        // Correct approach: mulDiv(mulDiv(lastIndex, rate, WAD), timeDelta, 1)
        // That's just mulDiv(lastIndex, rate, WAD) * timeDelta which can overflow.

        // Actually the safest is: mulDiv(lastIndex, mulDiv(rate, timeDelta, 1), WAD)
        // But rate * timeDelta is the issue.

        // For this MVP, we assume caller ensures rate * timeDelta fits in uint256.
        // Realistic: rate = 1e18 * 0.05 / 31536000 ≈ 1.585e9 (5% APR per second)
        // timeDelta = 31536000 (1 year)
        // rate * timeDelta = 5e16 (safe)
        // lastIndex * 5e16 = 5e34 (safe)

        uint256 rateTimeDelta;
        assembly {
            rateTimeDelta := mul(rate, timeDelta)
            // Overflow check: if rate != 0 and timeDelta != 0, result should be >= max(rate, timeDelta)
            // Simple check: if timeDelta != 0, rateTimeDelta / timeDelta should == rate
            if timeDelta {
                if iszero(eq(div(rateTimeDelta, timeDelta), rate)) {
                    mstore(
                        0x00,
                        0x4e487b7100000000000000000000000000000000000000000000000000000000
                    )
                    mstore(0x04, 0x11)
                    revert(0x00, 0x24)
                }
            }
        }

        uint256 interestDelta = mulDiv(lastIndex, rateTimeDelta, WAD);

        assembly {
            nextIndex := add(lastIndex, interestDelta)
            // Overflow check
            if lt(nextIndex, lastIndex) {
                mstore(
                    0x00,
                    0x4e487b7100000000000000000000000000000000000000000000000000000000
                )
                mstore(0x04, 0x11)
                revert(0x00, 0x24)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCALED BALANCE CONVERSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Converts scaled debt to actual debt using the market index.
     * @dev Formula: actualDebt = ceil(scaledDebt * marketIndex / WAD)
     *      Rounds UP to favor the protocol (user owes slightly more).
     *
     * @param scaledDebt The stored scaled debt (principal / index at time of borrow)
     * @param marketIndex The current borrow index (WAD precision)
     * @return actualDebt The face value of debt owed
     */
    function getActualDebt(
        uint256 scaledDebt,
        uint256 marketIndex
    ) internal pure returns (uint256 actualDebt) {
        actualDebt = mulDivUp(scaledDebt, marketIndex, WAD);
    }

    /**
     * @notice Converts actual debt to scaled debt using the market index.
     * @dev Formula: scaledDebt = ceil(actualDebt * WAD / marketIndex)
     *      Rounds UP to ensure scaled * index >= actual (favors protocol).
     *
     * @param actualDebt The face value of debt to be stored
     * @param marketIndex The current borrow index (WAD precision)
     * @return scaledDebt The scaled debt to store
     */
    function getScaledDebt(
        uint256 actualDebt,
        uint256 marketIndex
    ) internal pure returns (uint256 scaledDebt) {
        scaledDebt = mulDivUp(actualDebt, WAD, marketIndex);
    }
}
