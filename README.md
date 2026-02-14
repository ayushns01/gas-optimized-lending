# ⚡ Gas-Optimized Lending Protocol (EVM 2026)

> **Status:** MVP Implementation (Educational Artifact)  
> **EVM Target:** Cancun (EIP-1153 targeted)  
> **License:** MIT

## 📖 Overview
This project is a ground-up implementation of a Lending Market Engine designed to explore the limits of **EVM gas efficiency** and **architectural modularity**.

Unlike standard forks (Aave/Compound) that prioritize broad feature sets, this project isolates the lending core to experiment with **Inline Assembly (Yul)**, **Transient Storage (EIP-1153)**, and **Bit-Packed Storage Layouts**.

Gas costs are measured against a baseline Solidity implementation using Foundry gas snapshots (see `GAS.md`). Initial benchmarks show meaningful reductions in hot execution paths compared to standard libraries.

## 🎯 Motivation
This project was built to deeply understand how Solidity code executes on the EVM. The goal was to move beyond high-level syntax and explore the trade-offs between **gas efficiency**, **security**, and **code maintainability** in protocol design.

It serves as a technical artifact to demonstrate low-level EVM comprehension, specifically regarding opcode pricing, storage slots, and memory management.

## 🚫 Non-Goals
To ensure engineering depth over breadth, this project is intentionally **not**:
- A production-ready DeFi protocol.
- Deployed to mainnet (Local/Fork testing only).
- Integrated with live price oracles or governance systems.
- Optimized for UX or composability.

The focus is strictly on **EVM-level efficiency**, **correctness**, and **test rigor**.

## 🏗 Key Technical Differentiators
1.  **Transient Reentrancy Guards:** Utilizing `TLOAD`/`TSTORE` (EIP-1153) designed for post-Cancun EVM semantics. This aims to reduce the overhead of reentrancy checks compared to traditional storage-based locks.
2.  **Yul-Native Math:** Critical interest rate compounding logic is rewritten in **Inline Assembly (Yul)** to bypass checked arithmetic overhead, relying instead on rigorous input validation and pre-conditions.
3.  **Storage Packing Strategy:** `UserConfig` structs are bit-packed into single slots to minimize `SLOAD` operations (Cold access: 2100 gas), validated via `forge inspect storage`.
4.  **Differential Fuzzing:** Yul math correctness is validated via fuzz testing against a reference Solidity implementation within defined operational bounds.

## 🧪 Testing (68 Tests)
*   **Unit Tests (33):** Boundary conditions and failure paths for all state-mutating functions.
*   **Differential Fuzzing (15):** Yul math parity tested against reference Solidity implementation.
*   **Invariant Testing (6):** Stateful fuzzing (256 runs × 500 calls) validates 5 protocol invariants — token solvency, principal safety, liquidity safety, index monotonicity, and view consistency.
*   **Gas Benchmarks (14):** Paired Optimized vs Reference benchmarks for all core actions.

## 🛠 Tech Stack
*   **Framework:** Foundry (Forge, Cast, Anvil)
*   **Language:** Solidity 0.8.28+, Yul

## 📂 Project Structure
```text
├── src/
│   ├── interfaces/           # ILendingPool interface
│   ├── libraries/            # DataTypes, OptimizedMath (Yul), TransientGuard (EIP-1153)
│   └── LendingPool.sol       # UUPS-upgradeable core contract
├── test/
│   ├── benchmarks/           # Gas benchmark tests (Optimized vs Reference)
│   ├── invariants/           # Stateful invariant testing (Handler + Assertions)
│   └── mocks/                # MockERC20, ReferencePool, ReferenceMath
├── documentations/
│   ├── GAS.md                # Benchmark results & methodology
│   ├── THREATS.md            # Security analysis & mitigations
│   └── PHASES/               # Phase 1-6 explanation docs
└── foundry.toml              # Cancun, via-IR, 20000 optimizer runs
```
