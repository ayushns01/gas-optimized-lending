# Gas Optimization Report

This document defines the **methodology, scope, and measurement rules**
used to evaluate gas efficiency improvements in the Optimized Protocol
relative to a Standard Reference implementation.

This document is **authoritative**.  
Gas optimization claims MUST be supported by reproducible measurements
defined herein.
The Optimized Implementation is the source of truth.
The Reference Implementation exists solely for benchmarking.
---

## Measurement Configuration

* **Tooling:** `forge snapshot`
* **Compiler Settings:**
  * `via_ir = true`
  * `optimizer_runs = 20000`
* **EVM Version:** Cancun-compatible
* **Execution Context:** Single-transaction measurements unless otherwise stated

---

## 1. Benchmark Scope

Gas measurements compare:

* **Optimized Implementation**
  * Uses transient storage (EIP-1153)
  * Packed storage layouts
  * Yul-based math for validated hot paths

* **Reference Implementation**
  * Uses OpenZeppelin `ReentrancyGuard`
  * Uses standard Solidity arithmetic
  * Uses unpacked storage
  * Matches Optimized logic **function-for-function**

**Constraint**
* The Reference implementation MUST preserve identical business logic.
* Artificial slowdowns or feature mismatches are forbidden.

---

## 2. Benchmark Rules (Binding)

All measurements MUST follow these rules:

1. Cold and warm access costs MUST be explicitly noted.
2. Each benchmark MUST specify:
   * First-call cost
   * Subsequent-call cost (if relevant)
3. Identical calldata sizes MUST be used.
4. Benchmarks MUST be executed under identical state conditions.
5. Measurements MUST be reproducible via `forge snapshot`.

---

## 3. Benchmark Table (To Be Populated)

| Action | Reference (Gas) | Optimized (Gas) | Δ Gas | Δ (%) |
|------|----------------|-----------------|-------|-------|
| Deposit | TBD | TBD | TBD | TBD |
| Borrow | TBD | TBD | TBD | TBD |
| Repay | TBD | TBD | TBD | TBD |
| Liquidate | TBD | TBD | TBD | TBD |
| View Debt | TBD | TBD | TBD | TBD |

**Note**
* Reference contracts are located in `test/mocks/ReferencePool.sol`.
* Numbers are provisional until populated by snapshot output.

---

## 4. Optimization Categories (Expected Sources)

### A. Reentrancy Guard

* **Reference**
  * `SSTORE` + `SLOAD` based lock
* **Optimized**
  * `TSTORE` + `TLOAD` transient lock

**Expectation**
* Reentrancy protection overhead becomes negligible relative to total execution cost.

---

### B. Storage Packing (`UserConfig`)

* **Reference**
  * Separate storage slots for collateral and debt
* **Optimized**
  * Single packed 256-bit slot

**Expectation**
* Reduced `SLOAD` / `SSTORE` count dominates bitwise overhead.

---

### C. Interest Rate Math (`OptimizedMath.sol`)

* **Reference**
  * Checked Solidity arithmetic
* **Optimized**
  * Yul-based `mulDiv` with validated inputs

**Expectation**
* Reduced opcode count on verified hot paths.
* Correctness takes priority over micro-optimizations.

---

## 5. Explicit Non-Goals

This report does **not**:
* Claim absolute gas optimality
* Compare against production protocols (Aave, Compound)
* Optimize cold or admin-only paths
* Sacrifice correctness for marginal gas savings

All claims must remain **local, measured, and reproducible**.