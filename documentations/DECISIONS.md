# Architectural Decision Records (ADR)

This document records the architectural decisions, the context, and the consequences of those decisions for the Gas-Optimized Lending Protocol.

---

## ADR-001: Adoption of EIP-1153 (Transient Storage) for Reentrancy Guards

### 1. Context
Standard reentrancy guards (e.g., OpenZeppelin `ReentrancyGuard.sol`) rely on persistent storage (`SSTORE`/`SLOAD`) to manage the `_status` lock.
*   **Cost:** Setting a non-zero slot costs ~22,100 gas (cold) or ~2,900 gas (warm).
*   **Lifecycle:** The lock state is only relevant during the transaction execution and does not need to persist between blocks.

### 2. Decision
We will implement a custom `TransientGuard` using the `TSTORE` (0x5d) and `TLOAD` (0x5c) opcodes.

### 3. Consequences
*   **Positive:** Reduces reentrancy check cost to ~100 gas (warm/cold are similar for transient), achieving a >95% reduction in gas overhead for this specific mechanism.
*   **Negative:** The protocol requires an EVM environment compatible with the Cancun hardfork or later. It cannot be deployed on legacy L2s that have not adopted EIP-1153.
*   **Mitigation:** We will clearly document the EVM target version in `foundry.toml`.

---

## ADR-002: Implementation of Interest Rate Math in Inline Assembly (Yul)

### 1. Context
The `calculateInterest` function is the "hottest" path in the protocol, executing on every Deposit, Withdraw, Borrow, and Repay action. Solidity 0.8.x enforces checked arithmetic (panic on overflow), which adds opcode overhead.

### 2. Decision
We will implement the core linear interest compounding logic in pure Yul, utilizing `unchecked` behavior and specific opcode optimizations (e.g., `mulDiv` patterns).

### 3. Consequences
*   **Positive:** Removes redundant overflow checks for logic that is mathematically bounded by input constraints. Estimated 15-20% gas saving on the calculation block.
*   **Negative:** Increases the risk of silent overflows. Reduces code readability.
*   **Mitigation:** 
    1.  Strict input validation at the Solidity ingress points (e.g., `require(rate < MAX_RATE)`).
    2.  Mandatory **Differential Fuzzing** against a reference Solidity implementation to verify correctness across the entire input space.
    3.  **Halmos** symbolic execution to prove impossibility of overflow within realistic time horizons (e.g., < 100 years).

---

## ADR-003: Aggressive Storage Bit-Packing for User Configuration

### 1. Context
EVM storage slots are 32 bytes (256 bits). Reading a slot (`SLOAD`) is the most expensive operation in a read-only or state-modifying transaction (2100 gas cold). Standard implementations often use `uint256` for all values, spreading data across multiple slots.

### 2. Decision
We will pack `collateralAmount` and `borrowAmount` into a single 32-byte slot.
*   **Layout:** `[uint128 collateral][uint128 debt]`
*   **Constraint:** Max value is $2^{128}-1$ (~$3.4 \times 10^{38}$).

### 3. Consequences
*   **Positive:** Updating both collateral and debt (e.g., during Repay or Liquidate) requires only 1 `SLOAD` and 1 `SSTORE`, effectively halving the storage gas cost for these operations.
*   **Negative:** Reduces the maximum supported amount.
*   **Justification:** $3.4 \times 10^{38}$ is orders of magnitude larger than the total supply of any existing ERC-20 token (including those with high decimals like 18 or 24). The overflow risk is practically non-existent.

---

## ADR-004: UUPS Proxy Pattern over Transparent Proxy

### 1. Context
Upgradeable contracts require a proxy pattern.
*   **Transparent Proxy:** Upgrade logic is in the Proxy. Requires reading the admin slot on every call to determine if the caller is admin.
*   **UUPS:** Upgrade logic is in the Implementation.

### 2. Decision
We will utilize the UUPS (Universal Upgradeable Proxy Standard) pattern.

### 3. Consequences
*   **Positive:** Removes the overhead of the admin check on every transaction, lowering gas costs for end-users.
*   **Negative:** Higher risk of "bricking" the contract if the implementation is upgraded to a version that lacks the `_authorizeUpgrade` function.
*   **Mitigation:** Tests must strictly enforce that all new implementation candidates inherit and implement the upgrade authorization logic.