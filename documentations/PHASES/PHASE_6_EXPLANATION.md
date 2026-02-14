# Phase 6 Explanation: Gas Benchmarking

This document explains the gas benchmarking methodology and results for the lending protocol.

---

## 1. Methodology

### A. What We Compare

| Aspect | Optimized (LendingPool) | Reference (ReferencePool) |
|--------|------------------------|--------------------------|
| Reentrancy | `TransientGuard` (EIP-1153) | OZ `ReentrancyGuard` (SSTORE) |
| User state | Bit-packed `uint256` → 1 slot | Separate `collateral` + `scaledDebt` → 2 slots |
| Volume state | Bit-packed `uint256` → 1 slot | Separate `totalLiquidity` + `totalBorrows` → 2 slots |
| Rate state | Bit-packed `uint256` → 1 slot | Separate `borrowIndex` + `lastTimestamp` → 2 slots |
| Math | `OptimizedMath` (Yul) | `ReferenceMath` (checked Solidity) |

### B. Rules
- Identical business logic, events, and error conditions
- Identical calldata and state conditions
- Measured via `forge test --gas-report` (via-IR, 20000 optimizer runs)
- Reference is not proxied (proxy overhead is constant, not an optimization)

---

## 2. Results

| Action | Reference | Optimized | Savings |
|--------|-----------|-----------|---------|
| Deposit (warm) | 102,138 | 86,111 | **-15.7%** |
| Withdraw | 70,536 | 49,451 | **-29.9%** |
| Borrow | 54,449 | 50,524 | **-7.2%** |
| Repay | 61,453 | 40,110 | **-34.7%** |
| Liquidate | 61,290 | 44,970 | **-26.6%** |
| View Debt | 2,788 | 2,845 | +2.0% |

**Average savings across state-changing operations: ~22.8%**

### Caveats
- **Proxy overhead:** The Optimized pool runs behind an ERC1967Proxy (delegatecall ≈ 2,600 gas)
  while the Reference pool is called directly. This **handicaps** the optimized numbers — the true
  implementation-level savings are higher than shown above.
- **View Debt:** +2% overhead is bit-unpacking on a pure read path. View calls are off-chain and gas-free.
- Gas values are per-function-call from `forge test --gas-report`, not per-test totals.


---

## 3. Optimization Breakdown

### A. TransientGuard (EIP-1153)
The biggest contributor to savings in repay and liquidate:
- **Reference:** `SSTORE(1)` + `SLOAD` + `SSTORE(0)` = ~5,000 gas per call
- **Optimized:** `TSTORE(1)` + `TLOAD` + `TSTORE(0)` = ~100 gas per call
- **Impact:** ~4,900 gas saved on every state-changing function

### B. Bit-Packed Storage
Dominant in withdraw and repay where both user state and volume state are read + written:
- **Reference:** 4 SLOADs + 4 SSTOREs (user collateral, user debt, liquidity, borrows)
- **Optimized:** 2 SLOADs + 2 SSTOREs (packed user config, packed volume state)
- **Impact:** ~4,400 gas saved per function touching both slots

### C. Yul Math (OptimizedMath)
Measurable but smaller contribution:
- Eliminates Solidity's checked arithmetic overhead on validated paths
- **Impact:** ~200-500 gas per math-intensive operation

### D. View Debt (+2%)
The optimized version is slightly more expensive due to bit-unpacking overhead (`shr`, `and` operations) on a pure read path. This is expected and acceptable — view functions are off-chain and gas-free.

---

## 4. Files

| File | Purpose |
|------|---------|
| `test/mocks/ReferencePool.sol` | Unoptimized baseline pool |
| `test/mocks/ReferenceMath.sol` | Checked Solidity math (existed in Phase 3) |
| `test/benchmarks/GasBenchmark.t.sol` | Paired benchmark tests (14 tests) |
| `documentations/GAS.md` | Populated with measured results |

---

## 5. Reproducing

```bash
# Run benchmarks
forge test --match-contract GasBenchmark --gas-report

# Generate snapshot
forge snapshot --match-contract GasBenchmark

# Full test suite (68 tests)
forge test
```
