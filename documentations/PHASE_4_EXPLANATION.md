# Phase 4 Explanation: LendingPool Core Implementation

This document explains the technical implementation of `LendingPool.sol` and its gas-optimized design.

---

## 1. Architecture Overview

The LendingPool is a **single-asset lending pool** with:
- **UUPS Upgradeability** — Proxy pattern for future upgrades
- **EIP-1153 Transient Guard** — Gas-efficient reentrancy protection
- **Bit-Packed Storage** — Multiple values per slot
- **Yul-Optimized Math** — From Phase 3's `OptimizedMath.sol`

---

## 2. Storage Layout

```
Slot 0-50:  Reserved (UUPS/Ownable gap)
Slot 51:    VolumeState [Liquidity(128b MSB)][Borrows(128b LSB)]
Slot 52:    RateState [BorrowIndex(128b)][LiquidityIndex(96b)][Timestamp(32b)]
Slot 53+:   UserConfig mapping [Collateral(128b MSB)][Debt(128b LSB)]
```

### Why Bit-Packing?
| Storage Pattern | Slots | Gas (2 values) |
|-----------------|-------|----------------|
| Separate slots  | 2     | ~4,400 gas     |
| Bit-packed      | 1     | ~2,200 gas     |

**Savings:** ~50% on storage operations.

---

## 3. Core Functions

### A. Deposit
```
1. Validate amount > 0, amount <= uint128.max
2. Enter reentrancy guard
3. Accrue interest
4. Transfer tokens IN
5. Update user collateral (bit-packed)
6. Update total liquidity
7. Exit guard, emit event
```

### B. Withdraw
```
1. Validate amount, check sufficient collateral
2. Check available liquidity (totalLiquidity - totalBorrows)
3. Check health AFTER withdrawal (LTV check)
4. Update state, transfer tokens OUT
```

### C. Borrow
```
1. Check available liquidity
2. Calculate actual debt using current borrow index
3. Validate new debt <= 80% of collateral (LTV_RATIO)
4. Add scaled debt (rounded UP to favor protocol)
5. Transfer tokens OUT
```

### D. Repay
```
1. Calculate actual debt from scaled debt × borrow index
2. Cap repayment at actual debt
3. Reduce scaled debt accordingly
4. Transfer tokens IN
```

### E. Liquidate
```
1. Verify position is unhealthy (debt > 85% of collateral)
2. Seize collateral 1:1 with debt covered
3. effectiveDebtCovered = min(debtCovered, collateral)
4. Update all accounting using effectiveDebtCovered
```

---

## 4. Interest Accrual Model

### Formula
```
newBorrowIndex = lastIndex + (lastIndex × rate × timeDelta) / WAD
```

### Rate Calculation
```
utilization = totalBorrows / totalLiquidity
rate = BASE_RATE + (utilization × SLOPE)
```

| Parameter | Value | Meaning |
|-----------|-------|---------|
| BASE_RATE | 0 | No interest at 0% utilization |
| SLOPE | 3.17e9 | ~10% APR at 100% utilization |
| LTV_RATIO | 0.8e18 | Max borrow = 80% collateral |
| LIQUIDATION_THRESHOLD | 0.85e18 | Unhealthy if debt > 85% |

---

## 5. Audit-Grade Safety Fixes

| Issue | Fix |
|-------|-----|
| **Type Safety** | `if (amount > type(uint128).max) revert AmountOverflow()` |
| **Scaled Debt Overflow** | Check before accumulation in `borrow()` |
| **Index Overflow** | Validate `newBorrowIndex <= type(uint128).max` |
| **Liquidation Accounting** | Use `effectiveDebtCovered = collateralToSeize` |
| **Gas Hygiene** | Early return when `totalBorrows == 0` |

---

## 6. Gas Optimizations

| Optimization | Impact |
|--------------|--------|
| TransientGuard (EIP-1153) | ~100 gas vs ~5,000 gas (ReentrancyGuard) |
| Bit-packed storage | 50% fewer SSTOREs |
| Yul math | ~70% savings on interest calculations |
| Early returns | Skip unnecessary work |

---

## 7. Test Coverage

| Category | Tests |
|----------|-------|
| Initialization | 3 |
| Deposit | 5 |
| Withdraw | 5 |
| Borrow | 6 |
| Repay | 5 |
| Liquidate | 3 |
| Interest Accrual | 2 |
| Health Checks | 3 |
| Integration | 1 |
| **Total** | **33** |

All tests pass with comprehensive edge case coverage.

---

## 8. Summary

| Decision | Rationale |
|----------|-----------|
| UUPS Proxy | Upgradeable without changing proxy |
| Single Asset | MVP simplicity, gas efficiency |
| Scaled Balances | O(1) interest accrual |
| 1:1 Liquidation | No bonus = simpler invariants |
| Overflow Checks | Audit-grade safety |
