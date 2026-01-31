# Threat Model & Security Mitigations

This document enumerates known attack vectors relevant to the current system design
and specifies the **explicit architectural decisions** used to mitigate them.

This document is **authoritative**.  
If implementation behavior conflicts with this file, the implementation is incorrect.

---

## 1. Market & Economic Attacks

### A. Share Inflation (ERC-4626-Style Attacks)

**Status:** **NOT APPLICABLE**

**Analysis**
* **Vector:** First depositor “donating” assets to inflate an exchange rate (`assets / shares`).
* **Defense:** The protocol uses **index-based accounting** (principal adjusted by a global interest index),
  not share-based accounting (vaults).
* **Conclusion:** There is no exchange-rate denominator to manipulate. User balances track underlying amounts
  directly, adjusted by the interest index.

---

### B. Interest Rate Manipulation (“Flash Utilization”)

**Vector**  
An attacker temporarily borrows a large amount to push utilization to 100% immediately
before another user interaction, forcing disproportionate interest accrual on the victim.

**Mitigation**
* Interest is accrued **before** any state-changing action.
* Utilization and rate calculations are based on protocol state **prior** to the current transaction’s effect.
* No user action can retroactively affect interest applied to others within the same block.

---

## 2. Technical / EVM-Level Attacks

### A. Read-Only Reentrancy

**Vector**  
During an external call (e.g., token transfer), a view function (e.g., solvency or health checks)
is invoked while the protocol is in an intermediate (“dirty”) state, returning inconsistent data.

**Mitigation**
* **Transient Guard (EIP-1153):** `nonReentrant` modifier applied to all state-mutating functions.
* **Scoped View Guarding:**
  * Only **critical view functions** that expose solvency, health, or pricing data
    MUST check the `TLOAD` lock state and revert if the protocol is locked.
  * Pure informational or non-critical views remain unguarded to preserve composability.

---

### B. Precision Loss & Rounding Exploits

**Vector**  
An attacker exploits integer truncation (rounding down) to withdraw marginally more value
over repeated interactions (“dust draining”).

**Mitigation — “Favor the Protocol”**
* **Debt Calculation:** Rounds **UP** (user owes slightly more).
* **Collateral Withdrawal:** Rounds **DOWN** (user receives slightly less).
* **Implementation:** Custom assembly `mulDivUp` for debt; standard `mulDiv` (floor) for assets.

---

### C. Storage Collision (Upgradeable Proxy)

**Vector**  
Upgrading to an implementation with an incompatible storage layout corrupts existing state
(e.g., overwriting `totalLiquidity` with a new variable).

**Mitigation**
* **Layout Pinning:** Storage layout is defined strictly in `DataTypes.sol`.
* **Authority:** If implementation code conflicts with `DataTypes.sol`, the implementation is incorrect.
* **Storage Gaps:** Mandatory `uint256[50] __gap` reservation in all upgradeable contracts.
* **Validation:** `forge inspect storage` checks required before any upgrade deployment.

---

## 3. Operational Risks

### A. Admin Key Compromise

**Vector**  
An attacker gains control of the admin / owner key.

**Mitigation**
* **Scope Limiting:** Admin authority is strictly limited.
  * No function allows seizure of user collateral.
  * No arbitrary token rescue for supported assets.
* **Renounceability:** Ownership can be renounced.

---

### B. Protocol Liveness

**Vector**  
Admin pauses the protocol indefinitely, freezing user funds.

**Mitigation**
* **Partial Pausing:** Pausing restricts **risk-increasing actions only** (`deposit`, `borrow`).
* **Exit Assurance:** Risk-reducing actions (`repay`, `liquidate`) remain available even when paused,
  ensuring users can always close positions.

---

## 4. Explicit Non-Threats (Out of Scope)

The following vectors are **intentionally not addressed**:
* Oracle manipulation (hardcoded/mock price used for gas benchmarking).
* Governance capture (no DAO).
* MEV extraction (sandwich attacks are irrelevant to single-asset lending).