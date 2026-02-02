# Phase 1 Explanation: The "Tetris" Strategy for Gas Optimization

This document explains the **architectural decisions** behind `DataTypes.sol`.
Every line of code in this file exists to solve one specific problem: **EVM Storage Costs**.

---

## 1. The Cost of Storage (The "Why")

In the EVM, storage is the most expensive resource.

| Operation | Scenario | Gas Cost |
|-----------|----------|----------|
| **SLOAD** | Cold Access (First time reading a slot) | **2,100 gas** |
| **SLOAD** | Warm Access (Reading it again) | 100 gas |
| **SSTORE** | Dirty (0 → Non-Zero) | **22,100 gas** |
| **SSTORE** | Reset (Non-Zero → Non-Zero) | **5,000 gas** |

**The Goal:** Touch as few storage slots as possible.

### The Naive vs. Optimized Approach

**Naive Way (Standard Solidity):**
```solidity
struct UserConfig {
    uint256 collateral; // Slot A
    uint256 debt;       // Slot B
}
```
*   **Reading user state:** 2 `SLOAD`s = **4,200 gas**.
*   **Writing user state:** 2 `SSTORE`s = **10,000 gas** (if updating both).

**Optimized Way (Bit-Packing):**
```solidity
// Single Slot: [Debt (128 bits)][Collateral (128 bits)]
```
*   **Reading:** 1 `SLOAD` = **2,100 gas** (**50% savings**).
*   **Writing:** 1 `SSTORE` = **5,000 gas** (**50% savings**).

---

## 2. Layout Decisions

We utilize **3 packed slots** to cover the entire core protocol state.

### A. UserConfig (Slot 53+)

**Layout:** `[ Debt (128b MSB) ][ Collateral (128b LSB) ]`

*   **Why 128 bits?**
    *   Max Value: $2^{128} - 1 \approx 3.4 \times 10^{38}$.
    *   Even with 18 decimals, this supports amounts far exceeding global GDP.
    *   **Safety:** Overflow is economically impossible for any real asset.
*   **Why Debt in MSB?**
    *   Debt calculation often involves rounding *up*.
    *   Having it in the upper bits isolates it cleanly from collateral during masking operations.

### B. VolumeState (Slot 51)

**Layout:** `[ Total Liquidity (128b MSB) ][ Total Borrows (128b LSB) ]`

*   **Override Fix:** We swapped the order to match your verified architecture.
*   **Gas Impact:**
    *   `deposit`: Reads `UserConfig` (user) + `VolumeState` (global). Total 2 slots.
    *   `borrow`: Reads `UserConfig` + `VolumeState` + `RateState`. Total 3 slots.
    *   Without packing, these operations would touch 4-6 slots, doubling gas costs.

### C. RateState (Slot 52)

**Layout:** `[ Borrow Index (128b) ][ Liquidity Index (96b) ][ Timestamp (32b) ]`

This is the most aggressive pack.

1.  **Timestamp (32 bits):**
    *   Max seconds: $2^{32} - 1 = 4,294,967,295$ (Year 2106).
    *   **Decision:** 32 bits is enough for the next 80 years. 40+ bits is wasteful.

2.  **Liquidity Index (96 bits):**
    *   Indices start at 1.0 (`1e27` or `1e18` depending on scaling).
    *   Max value: $2^{96} \approx 7.9 \times 10^{28}$.
    *   If base is `1e18`, this allows growth up to $7.9 \times 10^{10}$ (79 billion).
    *   **Trade-off:** If the index grows 80-billion-fold, the protocol breaks. Given standard interest rates (e.g., 5-10% APY), this takes centuries.

3.  **Borrow Index (128 bits):**
    *   Given full 128 bits because debt tracking errors are more dangerous than liquidity tracking errors.

---

## 3. The "Tetris" Implementation

To achieve this without Solidity variable overhead, we use **bitwise math**.

**Packing (Encode):**
```solidity
packed = (A << offset) | B
```
*   Shift `A` to the left (make room).
*   `OR` it with `B` (fill the gap).

**Unpacking (Decode):**
```solidity
A = (packed >> offset) & mask
B = packed & mask
```
*   Shift `A` back to the right.
*   Apply a `mask` (e.g., 128 ones: `0xFF...FF`) to wipe out "neighboring" data.

### Cost of Bitwise Ops
*   `SHL`, `SHR`, `AND`, `OR`: **3 gas each**.
*   Compared to **2,100 gas** for an `SLOAD`, checking/masking bits is practically free.
*   We trade ~20 gas of "CPU work" to save 2,100 gas of "Disk I/O".

---

## 4. Conclusion

Phase 1 isn't just "defining types." It is **defining the physical constraints** of the system.

By adhering to these layouts:
1.  We guarantee minimal cold storage access.
2.  We enable "single-slot updates" (reading, updating memory, writing back once).
3.  We accept specific, known limits (Year 2106, 128-bit balances) in exchange for massive efficiency.
