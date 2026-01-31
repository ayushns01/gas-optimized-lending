# System Assumptions & Constraints

This document defines the **explicit assumptions and environmental constraints**
under which the protocol is designed to operate correctly and safely.

This document is **authoritative**.  
If implementation behavior violates these assumptions, the implementation is incorrect.

---

## 1. EVM Execution Environment

* **Hardfork Dependency**
  * The protocol targets the **Cancun** hardfork or later.
  * **Requirement:** `TSTORE` (0x5d) and `TLOAD` (0x5c) opcodes MUST be available.

* **Implication**
  * The protocol MUST NOT be deployed on:
    * Pre-Cancun L1 forks
    * L2s or sidechains that have not adopted EIP-1153
    * Private EVM forks lacking transient storage support

* **Chain ID**
  * Chain-agnostic.
  * Logic MUST NOT depend on `block.chainid`.

---

## 2. Token Standards & Asset Constraints (ERC-20)

### Decimals Normalization

* All internal accounting operates in **18-decimal fixed-point units (WAD)**.
* Assets with non-18 decimals (e.g., USDC with 6 decimals):
  * MUST be scaled on ingress
  * MUST be descaled on egress
* Scaling logic is part of the **interface layer**, not core math.

---

### ERC-20 Return Behavior

* Tokens MAY return:
  * `true`
  * `false`
  * no value at all (e.g., USDT)

**Constraint**
* Transfer success MUST be explicitly validated.
* No assumptions may be made about return values.

**Implementation Rule**
* Transfers MUST use minimal, explicit success-checking logic  
  (custom assembly or equivalent), **not full OpenZeppelin SafeERC20 abstractions**.

---

### Unsupported Token Extensions (Hard Rejections)

The following token behaviors are **explicitly unsupported**:

* Fee-on-transfer tokens
* Rebasing or elastic-supply tokens
* Callback-enabled tokens

#### ERC-777

* ERC-777 tokens are **not supported**.
* The protocol MUST NOT accept tokens that can trigger recipient hooks.
* Reentrancy protection assumes ERC-20-only semantics.

---

## 3. Economic & Temporal Assumptions

### Price Feeds

* Price feeds are treated as **external inputs**.
* Oracle correctness is **out of scope** for this project.
* The protocol assumes:
  * Prices are denominated in 18-decimal fixed-point units
  * Inputs are sane and non-malicious

**Constraint**
* No oracle validation, smoothing, or manipulation resistance is implemented.

---

### Time

* `block.timestamp` is assumed to be:
  * Monotonic
  * Manipulable within ±15 seconds by validators

**Justification**
* This variance is negligible for interest accrual measured over minutes or longer.

---

### Solvency Parameters

* Liquidation thresholds and risk parameters are assumed to be:
  * Correctly set
  * Maintained by a benevolent admin

**Constraint**
* Protocol logic assumes parameters are valid.
* Parameter misconfiguration is out of scope.

---

## 4. Arithmetic Bounds & Validation

### Storage Bounds

* User balances are stored as `uint128`.
* Maximum representable value:
  * `2¹²⁸ − 1 ≈ 3.4 × 10³⁸`

**Assumption**
* No user balance will ever approach this bound.
* This exceeds realistic economic limits by multiple orders of magnitude.

---

### Interest Rate Bounds

* Interest rate math assumes:
  * Rates per second remain within predefined, sane bounds
  * Example upper bound: ≤ 500% APR

**Constraint**
* Inputs exceeding allowed bounds MUST:
  * Be rejected at the API boundary
  * Never reach Yul math execution

**Rule**
* Yul math operates only on validated inputs.
* Silent clamping is forbidden.

---

## 5. Explicit Non-Assumptions

The protocol does **not** assume safety against:

* Oracle manipulation
* MEV extraction
* Governance attacks
* Cross-protocol composability exploits
* Validator censorship or liveness failures

These risks are **intentionally excluded** to maintain focus on
EVM-level correctness and gas efficiency.