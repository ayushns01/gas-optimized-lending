# Phase 2 Explanation: Transient Reentrancy Guards (EIP-1153)

This document explains the technical implementation of `TransientGuard.sol` and why it is a critical gas optimization.

---

## 1. The Cost of Safety

Reentrancy guards are mandatory for security, but expensive in standard EVM implementations.

### Standard Approach (OpenZeppelin)
A standard `ReentrancyGuard` uses **Storage** (`SSTORE`):

1.  **Enter:** `SSTORE(slot, LOCKED)` (from UNLOCKED)
    *   Cost: **~22,100 gas** (cold write) or **~2,900 gas** (warm write)
2.  **Exit:** `SSTORE(slot, UNLOCKED)`
    *   Cost: **~2,900 gas** (warm write -- technically a reset, but still costs)

**Total Overhead:** **~5,000 - 25,000 gas** per transaction just to say "I am busy".

---

## 2. The Optimized Approach (EIP-1153)

Effective from the **Cancun Hardfork**, the EVM supports **Transient Storage**.
- **Transient Storage** behaves like Storage (key-value mapping), but **wipes clean** at the end of every transaction.
- It is cheaper because validators don't need to write it to disk.

### TransientGuard Implementation
We utilize two implementations:
- `TSTORE (0x5d)`: Save to transient storage.
- `TLOAD (0x5c)`: Load from transient storage.

**Cost Profile:**
1.  **Enter:** `TSTORE(slot, LOCKED)`
    *   Cost: **100 gas**
2.  **Exit:** `TSTORE(slot, UNLOCKED)`
    *   Cost: **100 gas**

**Total Overhead:** **~200 gas**.
**Savings:** **>95% reduction** in guard overhead.

---

## 3. Implementation Details

### A. The Slot
We use a specific slot hash to avoid collisions:
```solidity
bytes32 constant GUARD_SLOT = keccak256("GAS_OPTIMIZED_LENDING_GUARD_SLOT");
```

### B. Inline Assembly Logic
We use Yul to access the opcodes directly (Solidity 0.8.28 supports `tstore`/`tload` in assembly).

```solidity
// Enter
if tload(GUARD_SLOT) { revert(...) }
tstore(GUARD_SLOT, 2) // Lock

// Exit
tstore(GUARD_SLOT, 0) // Unlock
```

### C. The Revert Selector Bug (Fixed)
During implementation, we encountered a subtle memory alignment issue with `mstore`.

**The Bug:**
```solidity
// Writes 0x3300f829 to the END of the 32-byte word (right-aligned)
mstore(0x00, 0x3300f829)
// result at 0x00: 0000...00003300f829

// Returns the FIRST 4 bytes (left-aligned)
revert(0x00, 0x04)
// returns: 00000000 (Empty error)
```

**The Fix:**
We aligned the selector to the LEFT of the 32-byte word by shifting or padding.
```solidity
// Writes to the START of the 32-byte word
mstore(0x00, 0x3300f82900000000000000000000000000000000000000000000000000000000)
// result at 0x00: 3300f8290000...

revert(0x00, 0x04)
// returns: 3300f829 (Correct "ReentrancyGuardReentrant()" selector)
```

---

## 4. Verification

We verified the implementation with `TransientGuard.t.sol`:
1.  **Gas Check:** Confirmed `enter` + `exit` consumes trivial gas (~100-200 range in raw opcode cost).
2.  **Reentrancy:** Confirmed it reverts when a re-entrant call is made.
3.  **Correct Revert:** Confirmed the custom error is returned correctly.

This component is now ready for use in the Core Protocol.
