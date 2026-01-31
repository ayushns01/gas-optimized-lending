# Execution Tasks (Authoritative Order)

This document defines the **only permitted implementation order**.
Tasks MUST be completed sequentially.  
Skipping, reordering, or merging steps is forbidden.

This document is **authoritative**.

---

## Phase 0 — Environment Setup

- [ ] **Initialize Project**
  * `forge init`
  * Configure `foundry.toml`
    * `evm_version = cancun`
    * `via_ir = true`
    * Optimizer enabled

**Gate**
* No Solidity files may be written before setup is complete.

---

## Phase 1 — Storage & Primitives (No Logic)

- [ ] **Library:** `DataTypes.sol`
  * Define packed storage layouts
  * Implement bitmask helpers
  * No math
  * No external calls
  * No state mutation outside encoding/decoding

**Gate**
* Storage layout must match `SystemArchitecture.md` exactly.
* Proceed only after manual review.

---

## Phase 2 — Safety Primitives

- [ ] **Library:** `TransientGuard.sol`
  * Implement EIP-1153 reentrancy guard in assembly
  * No protocol logic
  * No storage reads/writes other than transient storage

**Gate**
* Must conform to ADR-001 and ThreatModel.md.
* No interaction with `DataTypes`.

---

## Phase 3 — Math Layer (Isolated)

- [ ] **Library:** `OptimizedMath.sol`
  * Yul-based interest math only
  * No storage access
  * No protocol assumptions

- [ ] **Tests:** Differential fuzz tests
  * Reference Solidity math vs Optimized Yul math
  * Input bounds enforced per `ASSUMPTIONS.md`

**Gate**
* Differential fuzzing must pass before proceeding.
* No protocol code may import `OptimizedMath` before this gate.

---

## Phase 4 — Core Protocol Logic

- [ ] **Core:** `LendingPool.sol`
  * Implement shared internal helpers first:
    * Interest accrual
    * Index updates
    * Solvency checks
  * Then implement:
    * Deposit
    * Withdraw
    * Borrow
    * Repay
    * Liquidate
  * Enforce CEI ordering
  * No gas optimizations outside hot paths

**Gate**
* Must conform to:
  * SystemArchitecture.md
  * SCOPE.md
  * THREATS.md
* No gas benchmarking yet.

---

## Phase 5 — System Validation

- [ ] **Tests:** Stateful invariant testing
  * Solvency invariants
  * Accounting invariants

**Gate**
* All invariants must hold.
* No optimization allowed to “fix” failing tests.

---

## Phase 6 — Measurement & Reporting

- [ ] **Audit:** Gas benchmarking
  * `forge snapshot`
  * Populate `GAS.md`

**Rule**
* Gas results are **observational only**.
* Regressions must be justified or reverted.

---

## Explicit Non-Rules

This task list does **not**:
* Authorize feature additions
* Permit skipping gates
* Replace architectural documents
* Allow refactors during measurement

Any deviation requires an updated ADR.