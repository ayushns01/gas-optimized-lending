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
4.  **Formal Verification:** Critical math paths are checked using **Halmos** (Symbolic Execution) to mathematically prove overflow safety within operational bounds.

## 🧪 Testing Standards
*   **Unit Tests:** Focus on boundary conditions and failure paths for all state-mutating functions.
*   **Fuzzing:** Differential testing comparing the optimized Assembly implementation against a Reference Solidity implementation.
*   **Invariant:** `forge test --invariant` ensures protocol solvency holds under randomized transaction sequences.

## 🛠 Tech Stack
*   **Framework:** Foundry (Forge, Cast, Anvil)
*   **Language:** Solidity 0.8.28+, Yul
*   **Analysis:** Halmos (Symbolic Execution)

## 📂 Project Structure
```text
├── src/
│   ├── libraries/        # Yul-optimized math & storage packing
│   ├── safety/           # EIP-1153 Transient Guards
│   └── LendingPool.sol   # UUPS Entry point
├── test/                 # Differential Fuzzing & Invariants
├── GAS.md                # Benchmark Reports & Comparison
└── THREATS.md            # Security Analysis & Mitigations
