# Project Scope & Boundaries

This document defines the **Minimum Viable Product (MVP)** boundaries.
The goal is to produce a **technical artifact** demonstrating EVM-level gas optimization and correctness.

This document is **authoritative**.  
Features not listed in **In Scope** are implicitly **Out of Scope**.  
This scope supersedes feature suggestions from AI unless explicitly updated.

---

## 1. ✅ In Scope (The Core)

The following features constitute the **Gas-Optimized Lending Engine**.

### A. Core Mechanics

* **Deposit**
  * User transfers ERC-20 tokens to the protocol.
  * Protocol updates internal state using **index-based accounting** (no shares).

* **Withdraw**
  * User withdraws underlying assets based on index-based accounting.
  * No share minting or redemption logic exists.
  * Liquidity availability is checked prior to transfer.

* **Borrow**
  * User requests debt.
  * Protocol checks collateralization using a fixed price assumption.
  * ERC-20 assets are transferred to the borrower.

* **Repay**
  * User transfers ERC-20 tokens to reduce outstanding debt.
  * Protocol accrues interest, updates indices, and applies repayment.

* **Liquidate**
  * Third-party repays an under-collateralized position.
  * Collateral is seized immediately (no auction mechanism).

  **Liquidation Constraints**
  * No auction system
  * No liquidation bonus
  * Partial liquidation is the default behavior
  * All parameters must be explicitly defined (no inferred economics)

* **Flash Loan (ERC-3156)**
  * Temporary borrowing of available liquidity for a single transaction.
  * Fee implementation (or fee-free architecture) to be defined.
  * Must conform strictly to ERC-3156 standard.

* **Permit (ERC-2612)**
  * Allows gasless token approvals combined with actions (`depositWithPermit`, `repayWithPermit`).
  * Depends on the underlying asset supporting EIP-2612.

---

### B. Math & Economics

* **Asset Support**
  * Single-asset pool only (e.g., USDC loops).
  * Collateral and debt are the **same asset**.
  * Rationale: isolates gas benchmarks from cross-asset normalization logic.

* **Interest Model**
  * Linear kinked interest rate model.

### C. Advanced Primitives (Phase 7 & 8)

* **Verification**
  * Fuzzing (Foundry)
  * Invariant Testing (O(1) ghost variables)
  * Formal Verification (Halmos) for Yul Math blocks validation.