// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title LendingPoolHandler
 * @notice Stateful invariant handler with ghost accounting.
 * @dev Ghost variables track actual token flows (not accounting deltas).
 *      Updates only occur after successful protocol calls via try/catch.
 *
 *      Token flow model:
 *        Inflows  → deposit, repay, liquidation payment
 *        Outflows → withdraw, borrow, collateral seizure
 *        No flow  → warp (interest is purely accounting)
 */
contract LendingPoolHandler is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    LendingPool public pool;
    MockERC20 public token;

    address[] public actors;
    address internal currentActor;

    /// @dev The invariant contract that deployed this handler
    address public immutable invariantCaller;

    // ═══════════════════════════════════════════════════════════════════════════
    // GHOST VARIABLES — Token Flow Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Inflows: tokens transferred INTO the pool
    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalRepays;
    uint256 public ghost_totalLiquidations; // debt payment from liquidator → pool

    /// @dev Outflows: tokens transferred OUT of the pool
    uint256 public ghost_totalWithdrawals;
    uint256 public ghost_totalBorrows;
    uint256 public ghost_totalLiquidationSeizures; // collateral from pool → liquidator

    /// @dev Index snapshot — updated after each invariant check
    uint128 public ghost_lastBorrowIndex;

    // ═══════════════════════════════════════════════════════════════════════════
    // CALL COUNTERS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    uint256 public calls_borrow;
    uint256 public calls_repay;
    uint256 public calls_liquidate;
    uint256 public calls_warp;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_DEPOSIT = 1_000_000 * WAD;
    uint256 internal constant MAX_WARP = 365 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(LendingPool pool_, MockERC20 token_, address[] memory actors_) {
        pool = pool_;
        token = token_;
        actors = actors_;
        ghost_lastBorrowIndex = uint128(WAD);
        invariantCaller = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACTOR SELECTION
    // ═══════════════════════════════════════════════════════════════════════════

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function deposit(
        uint256 actorSeed,
        uint256 amount
    ) external useActor(actorSeed) {
        amount = bound(amount, 1, MAX_DEPOSIT);

        deal(
            address(token),
            currentActor,
            token.balanceOf(currentActor) + amount
        );
        token.approve(address(pool), amount);

        try pool.deposit(amount) {
            ghost_totalDeposits += amount;
            calls_deposit++;
        } catch {}
    }

    function withdraw(
        uint256 actorSeed,
        uint256 amount
    ) external useActor(actorSeed) {
        uint256 collateral = pool.getUserCollateral(currentActor);
        if (collateral == 0) return;

        amount = bound(amount, 1, collateral);

        uint256 balBefore = token.balanceOf(currentActor);

        try pool.withdraw(amount) {
            ghost_totalWithdrawals += token.balanceOf(currentActor) - balBefore;
            calls_withdraw++;
        } catch {}
    }

    function borrow(
        uint256 actorSeed,
        uint256 amount
    ) external useActor(actorSeed) {
        uint256 collateral = pool.getUserCollateral(currentActor);
        if (collateral == 0) return;

        uint256 available = pool.getAvailableLiquidity();
        if (available == 0) return;

        uint256 maxBorrow = (collateral * 80) / 100;
        uint256 currentDebt = pool.getUserDebt(currentActor);
        if (currentDebt >= maxBorrow) return;

        uint256 headroom = maxBorrow - currentDebt;
        uint256 cap = headroom < available ? headroom : available;
        if (cap == 0) return;

        amount = bound(amount, 1, cap);

        uint256 balBefore = token.balanceOf(currentActor);

        try pool.borrow(amount) {
            ghost_totalBorrows += token.balanceOf(currentActor) - balBefore;
            calls_borrow++;
        } catch {}
    }

    function repay(
        uint256 actorSeed,
        uint256 amount
    ) external useActor(actorSeed) {
        uint256 debt = pool.getUserDebt(currentActor);
        if (debt == 0) return;

        amount = bound(amount, 1, debt);

        deal(
            address(token),
            currentActor,
            token.balanceOf(currentActor) + amount
        );
        token.approve(address(pool), amount);

        uint256 balBefore = token.balanceOf(currentActor);

        try pool.repay(amount) {
            ghost_totalRepays += balBefore - token.balanceOf(currentActor);
            calls_repay++;
        } catch {}
    }

    /**
     * @notice Liquidate an unhealthy position.
     * @dev Token flows in liquidate():
     *      1. safeTransferFrom(liquidator → pool, effectiveDebtCovered)
     *      2. safeTransfer(pool → liquidator, collateralToSeize)
     *
     *      We derive both from pool balance snapshots + target collateral delta.
     */
    function liquidate(
        uint256 actorSeed,
        uint256 targetSeed,
        uint256 debtToCover
    ) external useActor(actorSeed) {
        address target = actors[targetSeed % actors.length];
        if (target == currentActor) return;

        uint256 targetDebt = pool.getUserDebt(target);
        if (targetDebt == 0) return;

        debtToCover = bound(debtToCover, 1, targetDebt);

        deal(
            address(token),
            currentActor,
            token.balanceOf(currentActor) + debtToCover
        );
        token.approve(address(pool), debtToCover);

        // Snapshot before
        uint256 poolBalBefore = token.balanceOf(address(pool));
        uint256 targetCollateralBefore = pool.getUserCollateral(target);

        try pool.liquidate(target, debtToCover) {
            // Snapshot after
            uint256 poolBalAfter = token.balanceOf(address(pool));
            uint256 targetCollateralAfter = pool.getUserCollateral(target);

            // collateralSeized = reduction in target's collateral
            uint256 collateralSeized = targetCollateralBefore -
                targetCollateralAfter;

            // debtPaid = poolDelta + collateralSeized
            uint256 debtPaid;
            if (poolBalAfter >= poolBalBefore) {
                debtPaid = (poolBalAfter - poolBalBefore) + collateralSeized;
            } else {
                debtPaid = collateralSeized - (poolBalBefore - poolBalAfter);
            }

            ghost_totalLiquidations += debtPaid;
            ghost_totalLiquidationSeizures += collateralSeized;
            calls_liquidate++;
        } catch {}
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, MAX_WARP);
        vm.warp(block.timestamp + seconds_);
        calls_warp++;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GHOST UPDATE (restricted to invariant contract only)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update the borrow index ghost snapshot.
     * @dev Restricted to the invariant contract to prevent fuzzer corruption.
     */
    function updateGhostBorrowIndex(uint128 newIndex) external {
        require(msg.sender == invariantCaller, "only invariant contract");
        ghost_lastBorrowIndex = newIndex;
    }
}
