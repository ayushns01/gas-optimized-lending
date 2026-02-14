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

## 3. Benchmark Results

Measured via `forge test --match-contract GasBenchmark --gas-report`.
Function-level gas per external call (not total test gas).

### Raw Function Gas (from `--gas-report`)

| Action | Reference | Optimized | Δ Gas | Δ (%) |
|--------|-----------|-----------|-------|-------|
| Deposit (warm) | 102,138 | 86,111 | -16,027 | **-15.7%** |
| Withdraw | 70,536 | 49,451 | -21,085 | **-29.9%** |
| Borrow | 54,449 | 50,524 | -3,925 | **-7.2%** |
| Repay | 61,453 | 40,110 | -21,343 | **-34.7%** |
| Liquidate | 61,290 | 44,970 | -16,320 | **-26.6%** |
| View Debt | 2,788 | 2,845 | +57 | +2.0% |

### Caveats

* **Proxy overhead:** The Optimized pool runs behind an ERC1967Proxy
  (delegatecall ≈ 2,600 gas). The Reference pool is called directly.
  This means the Optimized numbers include proxy tax; the true
  implementation-level savings are **higher** than shown.
* **View Debt:** +2% overhead is from bit-unpacking on a pure read path.
  View calls are off-chain and gas-free in production.
* Reference contracts: `test/mocks/ReferencePool.sol`.
* Benchmark tests: `test/benchmarks/GasBenchmark.t.sol`.

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