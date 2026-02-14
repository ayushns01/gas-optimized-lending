# Validation & Testing Strategy

This document defines the **minimum testing rig** required to validate
**gas optimizations without sacrificing correctness or security**.

**Crucial Rule**

You cannot measure gas without running code.  
You cannot safely run low-level EVM code without validation.  

**Therefore: Tests = The Gas Benchmark.**

This document is **authoritative**.  
If implementation or tests violate this strategy, the implementation is incorrect.

---

## 1. Testing Layers

### A. Unit Testing (Logic Verification)

**Scope**
* `src/LendingPool.sol`
* Low-level helpers and guards

**Goal**
* Exhaustive coverage of all **meaningful execution paths and failure modes**
* Coverage metrics are **observational**, not prescriptive

**Focus Areas**
* `UserConfig` bit-packing:
  * Correct storage and retrieval
  * Reverts or rejects values exceeding defined bounds
* `TransientGuard`:
  * Lock engages and releases correctly
  * Reentrancy attempts revert
* Rounding rules:
  * Debt calculations round **up**
  * Collateral withdrawals round **down**
  * Favor-the-protocol behavior is enforced

---

### B. Differential Fuzzing (Primary Correctness Validator)

**Why This Is Mandatory**

The project uses **unchecked Yul (Assembly)** for math.
Unchecked math has no inherent safety guarantees.

Correctness is established by proving equivalence to a
reference Solidity implementation **within defined bounds**.

---

**Reference Implementation**
* `test/mocks/ReferenceMath.sol`
* Uses standard Solidity arithmetic (`+`, `*`, `/`)
* Represents the semantic baseline, not a performance target

**Target Implementation**
* `src/libraries/OptimizedMath.sol`
* Uses Yul (`mulDiv`, `add`, `sub`) on validated inputs only

---

**Fuzzing Strategy**

Fuzzed inputs MUST respect constraints defined in `ASSUMPTIONS.md`.

```solidity
function testFuzz_MathParity(
    uint256 principal,
    uint256 rate,
    uint256 timeElapsed
) public {
    vm.assume(principal <= type(uint128).max);
    vm.assume(rate <= MAX_RATE);
    vm.assume(timeElapsed > 0 && timeElapsed <= MAX_TIME);

    uint256 reference = ReferenceMath.calc(principal, rate, timeElapsed);
    uint256 optimized = OptimizedMath.calc(principal, rate, timeElapsed);

    assertEq(reference, optimized, "Yul math divergence");
}
```

---

### C. Stateful Invariant Testing (Protocol Validation)

**Why This Is Mandatory**

Unit tests verify individual paths. Invariant tests verify **global properties**
hold across randomized sequences of protocol actions.

**Handler** (`test/invariants/LendingPoolHandler.sol`)
* Dispatches randomized `deposit`, `withdraw`, `borrow`, `repay`, `liquidate`, `warp`
* Tracks actual token flows via ghost variables (O(1), not O(N) sums)
* Uses `try/catch` to update ghost state only on successful calls

**Invariants** (`test/invariants/LendingPoolInvariants.t.sol`)
* **INV-1:** Token Solvency — `pool.balance == net token flow` (strict equality)
* **INV-2:** Principal Safety — `inflows >= withdrawals`
* **INV-3:** Liquidity Safety — `totalLiquidity >= totalBorrows`
* **INV-4:** Borrow Index Monotonicity — index never decreases
* **INV-5:** Available Liquidity Consistency — view matches internal state

**Configuration:** 256 runs × 500 calls = 128,000 total calls, 0 failures.

---

### D. Gas Benchmarking (Measurement)

**Scope**
* Side-by-side comparison of Optimized (`LendingPool.sol`) vs Reference (`ReferencePool.sol`)
* Reference uses OZ ReentrancyGuard, unpacked storage, checked Solidity math
* Identical business logic, events, and error conditions

**Tests** (`test/benchmarks/GasBenchmark.t.sol`)
* 14 paired benchmarks covering cold/warm deposits, withdraw, borrow, repay, liquidate, and view
* Measured via `forge test --gas-report`
* Results populated in `documentations/GAS.md`