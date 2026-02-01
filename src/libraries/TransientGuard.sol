// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title TransientGuard
 * @author Gas-Optimized Lending Protocol
 * @notice Implements specific Reentrancy Guard logic using EIP-1153 (Transient Storage).
 * @dev Replaces standard SSTORE-based guards (~22,100 gas) with TSTORE-based guards (~100 gas).
 *
 *      OPCODE EXPLAINER:
 *      ─────────────────
 *      TSTORE (0x5d): Stores word in transient storage (resets at transaction end).
 *      TLOAD  (0x5c): Loads word from transient storage.
 *
 *      Why is this safe?
 *      Locked state persists only during the transaction. If a re-entrant call occurs,
 *      it sees the "LOCKED" state. At the end of the transaction, it auto-clears.
 *
 *      COMPATIBILITY WARNING:
 *      Requires Cancun hardfork. Will revert on older chains.
 */
library TransientGuard {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Keccak256("GAS_OPTIMIZED_LENDING_GUARD_SLOT")
    ///      Using a unique slot to avoid collisions with other transient storage users.
    bytes32 internal constant GUARD_SLOT =
        0x2e19d7cb992ce58556b6b77c9803bf3ec1bd668b577002061e888636baefc674;

    /// @dev Value representing "LOCKED" state.
    ///      Using 2 (uint256) instead of boolean to match standard reentrancy guard patterns,
    ///      though strictly 1 would suffice. 2 is often used to avoid 0/1 confusion.
    uint256 internal constant REENTRANCY_LOCKED = 2;

    /// @dev Value representing "UNLOCKED" state (default is 0, but explicit expected state).
    ///      Transient storage defaults to 0.
    uint256 internal constant REENTRANCY_UNLOCKED = 0;

    // ═══════════════════════════════════════════════════════════════════════════
    // LOGIC
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Enters a non-reentrant section.
     * @dev Checks if GUARD_SLOT is 0. If not, reverts. Sets GUARD_SLOT to LOCKED.
     */
    function enter() internal {
        assembly {
            // Check if locked
            if tload(GUARD_SLOT) {
                // Revert with ReentrancyGuardReentrant() selector (standard OZ selector)
                // 0x3300f829
                // mstore stores 32 bytes right-aligned, so we need to shift left by 224 bits (28 bytes)
                // so that the selector occupies the first 4 bytes at 0x00.
                mstore(
                    0x00,
                    0x3300f82900000000000000000000000000000000000000000000000000000000
                )
                revert(0x00, 0x04)
            }

            // Lock
            tstore(GUARD_SLOT, REENTRANCY_LOCKED)
        }
    }

    /**
     * @notice Exits a non-reentrant section.
     * @dev Clears the GUARD_SLOT back to 0.
     *      Note: TSTORE costs 100 gas.
     */
    function exit() internal {
        assembly {
            tstore(GUARD_SLOT, REENTRANCY_UNLOCKED)
        }
    }

    /**
     * @notice View-only check to see if the protocol is currently locked.
     * @dev Useful for `view` functions that should not be accessed during execution
     *      (read-only reentrancy protection).
     * @return locked True if the guard is currently active.
     */
    function isLocked() internal view returns (bool locked) {
        assembly {
            locked := tload(GUARD_SLOT)
        }
    }
}
