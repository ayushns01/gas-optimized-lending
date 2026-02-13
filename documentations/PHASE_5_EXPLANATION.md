# Phase 5 Explanation: Stateful Invariant Testing

This document explains the design and implementation of the invariant testing suite for the LendingPool protocol.

---

## 1. What is Invariant Testing?

Unlike unit tests (fixed inputs → expected outputs), **invariant testing** executes randomized sequences of protocol actions and asserts that critical properties hold after every sequence.

| Dimension | Unit Test | Invariant Test |
|-----------|-----------|----------------|
| Input | Fixed | Randomized (fuzzed) |
| Sequence | Single call | Hundreds of calls |
| Assertion | Per-call output | Global property |
| Coverage | Known paths | Unknown paths |

---

## 2. Architecture

```
LendingPoolInvariants.t.sol     ← Invariant assertions (what must hold)
        │
        ├── setUp()             ← Deploys pool, creates actors, wires handler
        │
        └── invariant_*()       ← O(1) checks run after each action sequence
                │
                ▼
LendingPoolHandler.sol          ← Action dispatch + ghost accounting
        │
        ├── deposit()           ← Bounded amounts, deal tokens, try/catch
        ├── withdraw()          ← Check collateral, track actual delta
        ├── borrow()            ← LTV-aware bounds, track token outflow
        ├── repay()             ← Debt-capped, track token inflow
        ├── liquidate()         ← Pool balance + collateral snapshots
        └── warp()              ← Advance time (triggers interest)
```

---

## 3. Ghost Accounting (Shadow State)

### Why Ghost Variables?

Summing over all users (`Σ userCollateral`) is **O(N)** — too slow for fuzzing at scale. Instead, the Handler tracks aggregate values incrementally using **ghost variables**.

### Rules
1. **Actual deltas only** — track what actually executed, not what was requested
2. **Try/catch** — ghost state only updates after successful calls
3. **Token flow model** — track real ERC-20 transfers, not accounting values

### Ghost Variables
| Variable | Tracks | Updated By |
|----------|--------|------------|
| `ghost_totalDeposits` | Tokens → pool via deposit | `deposit()` |
| `ghost_totalWithdrawals` | Tokens ← pool via withdraw | `withdraw()` |
| `ghost_totalBorrows` | Tokens ← pool via borrow | `borrow()` |
| `ghost_totalRepays` | Tokens → pool via repay | `repay()` |
| `ghost_totalLiquidations` | Tokens → pool (debt payment) | `liquidate()` |
| `ghost_totalLiquidationSeizures` | Tokens ← pool (collateral) | `liquidate()` |
| `ghost_lastBorrowIndex` | Last known borrow index | `invariant_indexMonotonicity()` |

---

## 4. Invariants (5 Total, All O(1))

### INV-1: Token Solvency (Strict Equality)
```
asset.balanceOf(pool) == ghost_totalDeposits + ghost_totalRepays
                         + ghost_totalLiquidations
                         - ghost_totalWithdrawals - ghost_totalBorrows
                         - ghost_totalLiquidationSeizures
```
**Why:** Interest is purely accounting — no tokens flow. This strict equality proves no tokens are created or destroyed.

### INV-2: Principal Safety
```
ghost_totalDeposits + ghost_totalRepays + ghost_totalLiquidations
    >= ghost_totalWithdrawals
```
**Why:** Users cannot withdraw more than what was deposited + repaid. Proves no-free-money.

### INV-3: Liquidity Safety
```
pool.getTotalLiquidity() >= pool.getTotalBorrows()
```
**Why:** The protocol must never lend more than it holds. Direct protocol state check.

### INV-4: Borrow Index Monotonicity
```
pool.getBorrowIndex() >= ghost_lastBorrowIndex
// then: ghost_lastBorrowIndex = current
```
**Why:** Interest only accrues forward. Index decrease = catastrophic accounting bug. Ghost updates after assertion to validate step-by-step monotonicity.

### INV-5: Available Liquidity Consistency
```
pool.getAvailableLiquidity() == pool.getTotalLiquidity() - pool.getTotalBorrows()
```
**Why:** View function must match internal state. Catches storage packing bugs across different code paths.

---

## 5. Interest Handling

Interest is **intentionally excluded** from ghost variables because:
- Interest accrual creates no token flow (pure accounting)
- Repay deltas include interest (ghost_totalRepays captures it)
- Interest correctness is validated indirectly via:
  - **INV-3** (liquidity never goes negative)
  - **INV-4** (index only increases)

---

## 6. Liquidation Ghost Accounting

Liquidation involves **two** token transfers:
1. **Liquidator → Pool:** `effectiveDebtCovered` (inflow)
2. **Pool → Liquidator:** `collateralToSeize` (outflow)

We derive both from snapshots:
```
collateralSeized = targetCollateralBefore - targetCollateralAfter
poolDelta = poolBalAfter - poolBalBefore
debtPaid = poolDelta + collateralSeized
```

Per SCOPE.md, liquidation is 1:1 (no bonus), so `effectiveDebtCovered == collateralToSeize` when collateral covers debt.

---

## 7. Results

| Metric | Value |
|--------|-------|
| Invariants | 5 (all O(1)) |
| Actors | 5 bounded addresses |
| Runs | 256 |
| Calls per run | 500 |
| Total calls | 128,000 |
| Failures | **0** |
| Actions exercised | ~21,000 each |

### Full Test Suite
| Suite | Tests |
|-------|-------|
| Unit/Integration (Phase 4) | 33 |
| Fuzz (Phase 4) | 15 |
| Invariant (Phase 5) | 6 |
| **Total** | **54** |

---

## 8. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Ghost accounting over O(N) sums | Scalable to millions of fuzz runs |
| Token flow tracking (not accounting deltas) | Interest-safe, no false positives |
| `targetSelector` for handler | Prevents fuzzer from calling ghost update functions |
| `msg.sender` guard on `updateGhostBorrowIndex` | Defense-in-depth against ghost state corruption |
| `try/catch` on all actions | Ghost state stays consistent on reverts |
| 5 actors (bounded set) | Enough coverage without excessive state space |
