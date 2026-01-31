# System Architecture

This document outlines the high-level design, component interactions, and the critical storage layout strategy used to achieve gas optimization.

This document is **authoritative**.  
If implementation details conflict with this file, the implementation is **incorrect**.

---

## 1. Component Overview

The system is designed as a **Monolithic UUPS Proxy** to minimize external calls (which cost gas). Logic is modularized via Libraries rather than separate contracts to prevent `DELEGATECALL` overhead where possible.

### Monolithic Definition
"Monolithic" refers to **contract deployment**, not code structure.  
While the bytecode resides in a single implementation contract to save `DELEGATECALL` gas, internal separation of concerns (**storage, math, safety**) must be preserved via internal libraries to maintain auditability and test isolation.

### Core Contracts

* **`LendingPool.sol` (Entry Point):**
  * Inherits: `UUPSUpgradeable`, `OwnableUpgradeable`, `TransientGuard`
  * Responsibility: User interface, state management, and high-level flow control (Check-Effects-Interactions)
  * Optimization: Acts as the **sole storage holder**

---

### Libraries (Internal Linking)

* **`OptimizedMath.sol`:**
  * Responsibility: Pure Yul implementations of compounding interest and index calculations
  * Rationale: Inlined into the bytecode to allow compiler optimization across boundaries

* **`DataTypes.sol`:**
  * Responsibility: Defines bit-packed structs and helper functions for encoding/decoding storage data

#### Library Rules (Binding)

1. Libraries **MUST** be `pure` or `view` only  
2. Libraries **MUST NOT** access storage directly  
3. Libraries **MUST NOT** perform external calls  
4. All state mutation occurs **only** in `LendingPool.sol`

---

## 2. Interaction Flow (The "Hot Path")

The most gas-critical flow is the **Repay** action, as it involves state reads, interest calculation, and state writes.

### Repay Sequence

1. **Guard**
   * `nonReentrant` checks `TLOAD(slot)`
   * Approximate cost: ~100 gas

2. **State Fetch**
   * `SLOAD` user configuration from `mapping(address => UserConfig)`
   * Optimization: Reads `collateral` and `debt` in a single cold access (2100 gas)

3. **Math**
   * Call to `OptimizedMath.calculateInterest`
   * Optimization: Unchecked Yul execution on validated inputs

4. **State Update**
   * Updates occur in memory only

5. **External Token Transfer**
   * External call to underlying asset contract

   **External Call Constraints**
   * Only standard ERC-20 tokens with consistent return behavior are supported
   * Fee-on-transfer, rebasing, or callback-enabled tokens are explicitly **out of scope**
   * External calls must occur **after** all state updates (CEI enforced)

6. **State Write**
   * `SSTORE` updated packed struct back to storage
   * Optimization: Writes collateral and debt in a single operation

---

### Non-Optimization Zones

The following areas are intentionally **not** optimized for gas.  
Readability and correctness take priority.

* Initialization logic (`initialize`)
* Upgrade authorization (`_authorizeUpgrade`)
* Admin-only configuration paths
* Error handling paths (reverts)

---

## 3. Storage Layout (The "Tetris" Strategy)

Gas savings are primarily achieved through aggressive utilization of EVM 32-byte storage slots.

### Storage Allocation Rules (Binding)

* Slot ranges are explicitly reserved and **MUST NOT** be reused
* User-specific storage begins **after** global state slots
* New storage variables must be appended only
* Storage packing changes require a new **ADR**
* **Partial-slot writes are forbidden**  
  (Packed fields must be read-modify-written as a full 256-bit value)

---

### Slot 0–50: Upgradeability & Inheritance

* **Slot 0**
  * Packed `Ownable` owner address
  * `Initializable` flags

* **Slot 1–50**
  * `__gap` reserved for UUPS compatibility

---

### Slot 51: Protocol Global State

Global accounting data is packed into a single slot.

```text
[ Unused (0 bits) ][ Total Borrows (128 bits) ][ Total Liquidity (128 bits) ]
|                  |                           |                             |
<-- MSB                                                                  LSB