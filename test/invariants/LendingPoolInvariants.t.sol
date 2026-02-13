// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {LendingPoolHandler} from "./LendingPoolHandler.sol";

/**
 * @title LendingPoolInvariants
 * @notice Stateful invariant tests for the LendingPool protocol.
 * @dev All invariants are O(1) using ghost accounting from the Handler.
 *
 *      INV-1: Token Solvency      — pool balance == net token flow (strict)
 *      INV-2: Principal Safety     — inflows >= withdrawals (no free money)
 *      INV-3: Liquidity Safety     — totalLiquidity >= totalBorrows
 *      INV-4: Borrow Index Mono    — index never decreases + ghost update
 *      INV-5: Available Liquidity  — getAvailableLiquidity() == totalLiquidity - totalBorrows
 */
contract LendingPoolInvariants is Test {
    LendingPool public pool;
    MockERC20 public token;
    LendingPoolHandler public handler;

    uint256 constant WAD = 1e18;
    uint256 constant ACTOR_COUNT = 5;

    function setUp() public {
        // Deploy mock token
        token = new MockERC20("Test Token", "TEST", 18);

        // Deploy LendingPool behind proxy
        LendingPool implementation = new LendingPool();
        bytes memory initData = abi.encodeCall(
            LendingPool.initialize,
            address(token)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        pool = LendingPool(address(proxy));

        // Create bounded actors
        address[] memory actors = new address[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actors[i] = makeAddr(
                string(abi.encodePacked("actor", vm.toString(i)))
            );
        }

        // Deploy handler
        handler = new LendingPoolHandler(pool, token, actors);

        // Target only the handler for fuzzing
        targetContract(address(handler));

        // Exclude updateGhostBorrowIndex from fuzzer
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LendingPoolHandler.deposit.selector;
        selectors[1] = LendingPoolHandler.withdraw.selector;
        selectors[2] = LendingPoolHandler.borrow.selector;
        selectors[3] = LendingPoolHandler.repay.selector;
        selectors[4] = LendingPoolHandler.liquidate.selector;
        selectors[5] = LendingPoolHandler.warp.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INV-1: TOKEN SOLVENCY (Strict Equality)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pool's token balance must exactly equal net token flow.
     * @dev Formula: asset.balanceOf(pool) == totalIn - totalOut
     *
     *      Inflows:  deposits, repays, liquidation payments
     *      Outflows: withdrawals, borrows, liquidation seizures
     *
     *      Interest is purely accounting (no token movement).
     *      This is the strongest solvency check possible.
     */
    function invariant_tokenSolvency() external view {
        uint256 poolBalance = token.balanceOf(address(pool));

        uint256 totalIn = handler.ghost_totalDeposits() +
            handler.ghost_totalRepays() +
            handler.ghost_totalLiquidations();

        uint256 totalOut = handler.ghost_totalWithdrawals() +
            handler.ghost_totalBorrows() +
            handler.ghost_totalLiquidationSeizures();

        assertEq(
            poolBalance,
            totalIn - totalOut,
            "INV-1: Pool balance != net token flow"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INV-2: PRINCIPAL SAFETY
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice No-free-money: withdrawals can never exceed non-borrow inflows.
     * @dev Formula: deposits + repays + liquidationPayments >= withdrawals
     *      Ensures users cannot extract more principal than was supplied.
     */
    function invariant_principalSafety() external view {
        uint256 inflows = handler.ghost_totalDeposits() +
            handler.ghost_totalRepays() +
            handler.ghost_totalLiquidations();

        uint256 outflows = handler.ghost_totalWithdrawals();

        assertGe(inflows, outflows, "INV-2: Withdrawals exceed inflows");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INV-3: LIQUIDITY SAFETY
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Protocol accounting: totalLiquidity must always cover totalBorrows.
     * @dev Formula: pool.getTotalLiquidity() >= pool.getTotalBorrows()
     *      Prevents the protocol from lending more than deposited.
     */
    function invariant_liquiditySafety() external view {
        assertGe(
            pool.getTotalLiquidity(),
            pool.getTotalBorrows(),
            "INV-3: totalBorrows exceeds totalLiquidity"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INV-4: BORROW INDEX MONOTONICITY (with ghost update)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Borrow index must never decrease.
     * @dev Formula: currentBorrowIndex >= ghost_lastBorrowIndex
     *      After assertion, updates the ghost snapshot to the current value.
     *      This ensures each check validates against the previous state,
     *      not just the initial 1e18.
     */
    function invariant_indexMonotonicity() external {
        uint128 current = uint128(pool.getBorrowIndex());
        uint128 last = handler.ghost_lastBorrowIndex();

        assertGe(current, last, "INV-4: Borrow index decreased");

        // Update ghost for next check — critical for real monotonicity validation
        handler.updateGhostBorrowIndex(current);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INV-5: AVAILABLE LIQUIDITY CONSISTENCY
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice getAvailableLiquidity() must equal totalLiquidity - totalBorrows.
     * @dev Validates that the view function correctly reflects internal state.
     *      Catches any mismatch between packed storage reads in different
     *      code paths.
     */
    function invariant_availableLiquidityConsistency() external view {
        uint256 totalLiquidity = pool.getTotalLiquidity();
        uint256 totalBorrows = pool.getTotalBorrows();
        uint256 available = pool.getAvailableLiquidity();

        assertEq(
            available,
            totalLiquidity - totalBorrows,
            "INV-5: getAvailableLiquidity() inconsistent"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALL SUMMARY
    // ═══════════════════════════════════════════════════════════════════════════

    function invariant_callSummary() external view {
        console.log("--- Call Summary ---");
        console.log("Deposits:     ", handler.calls_deposit());
        console.log("Withdrawals:  ", handler.calls_withdraw());
        console.log("Borrows:      ", handler.calls_borrow());
        console.log("Repays:       ", handler.calls_repay());
        console.log("Liquidations: ", handler.calls_liquidate());
        console.log("Warps:        ", handler.calls_warp());
        console.log("--------------------");
    }
}
