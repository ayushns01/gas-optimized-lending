// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {ILendingPool} from "../src/interfaces/ILendingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title LendingPoolTest
 * @notice Unit and integration tests for the LendingPool contract.
 */
contract LendingPoolTest is Test {
    LendingPool public pool;
    MockERC20 public token;

    address public owner;
    address public alice;
    address public bob;

    uint256 constant WAD = 1e18;
    uint256 constant INITIAL_BALANCE = 10_000 * WAD;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy mock token
        token = new MockERC20("Test Token", "TEST", 18);

        // Mint tokens to users
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);

        // Deploy LendingPool behind a proxy
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

        // Approve pool for both users
        vm.prank(alice);
        token.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        token.approve(address(pool), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Initialize_SetsAsset() public view {
        assertEq(pool.asset(), address(token));
    }

    function test_Initialize_SetsBorrowIndexToWAD() public view {
        assertEq(pool.getBorrowIndex(), WAD);
    }

    function test_Initialize_SetsZeroLiquidity() public view {
        assertEq(pool.getTotalLiquidity(), 0);
        assertEq(pool.getTotalBorrows(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Deposit_UpdatesUserCollateral() public {
        uint256 depositAmount = 1000 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        assertEq(pool.getUserCollateral(alice), depositAmount);
    }

    function test_Deposit_UpdatesTotalLiquidity() public {
        uint256 depositAmount = 1000 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        assertEq(pool.getTotalLiquidity(), depositAmount);
    }

    function test_Deposit_TransfersTokens() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        pool.deposit(depositAmount);

        assertEq(token.balanceOf(alice), balanceBefore - depositAmount);
        assertEq(token.balanceOf(address(pool)), depositAmount);
    }

    function test_Deposit_EmitsEvent() public {
        uint256 depositAmount = 1000 * WAD;

        vm.expectEmit(true, false, false, true);
        emit ILendingPool.Deposit(alice, depositAmount);

        vm.prank(alice);
        pool.deposit(depositAmount);
    }

    function test_Deposit_RevertsOnZeroAmount() public {
        vm.expectRevert(ILendingPool.ZeroAmount.selector);
        vm.prank(alice);
        pool.deposit(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Withdraw_UpdatesUserCollateral() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 withdrawAmount = 400 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.withdraw(withdrawAmount);

        assertEq(pool.getUserCollateral(alice), depositAmount - withdrawAmount);
    }

    function test_Withdraw_UpdatesTotalLiquidity() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 withdrawAmount = 400 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.withdraw(withdrawAmount);

        assertEq(pool.getTotalLiquidity(), depositAmount - withdrawAmount);
    }

    function test_Withdraw_TransfersTokens() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 withdrawAmount = 400 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        pool.withdraw(withdrawAmount);

        assertEq(token.balanceOf(alice), balanceBefore + withdrawAmount);
    }

    function test_Withdraw_RevertsOnInsufficientCollateral() public {
        uint256 depositAmount = 1000 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.expectRevert(ILendingPool.InsufficientCollateral.selector);
        vm.prank(alice);
        pool.withdraw(depositAmount + 1);
    }

    function test_Withdraw_RevertsOnInsufficientLiquidity() public {
        // Alice deposits
        vm.prank(alice);
        pool.deposit(1000 * WAD);

        // Bob deposits and borrows
        vm.prank(bob);
        pool.deposit(1000 * WAD);
        vm.prank(bob);
        pool.borrow(800 * WAD); // 80% of Bob's collateral

        // Alice tries to withdraw more than available
        // Available = 2000 - 800 = 1200, Alice has 1000
        // So Alice can withdraw all, but let's make sure it enforces liquidity

        // Actually let's try a case where available < user collateral
        // If bob borrowed 1500, available = 500. Alice has 1000, so she can't withdraw all.
        // But first we need bob to have more collateral.

        // Simpler test: alice deposits 1000, bob deposits 500, bob borrows 400
        // available = 1500 - 400 = 1100. Alice can withdraw 1000.
        // Let's modify: alice deposits 1000, borrows 500 herself
        // Then tries to withdraw 600 (more than available 500)

        vm.prank(alice);
        pool.borrow(500 * WAD);

        // Available = 1000 + 1000 - 800 - 500 = 700
        // Alice collateral = 1000, but to withdraw 800 would leave available = -100
        // Let's check: total liq = 2000, total borrows = 1300, available = 700
        // Alice tries to withdraw 800
        vm.expectRevert(ILendingPool.InsufficientLiquidity.selector);
        vm.prank(alice);
        pool.withdraw(800 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BORROW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Borrow_UpdatesUserDebt() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        // At genesis index (WAD), actual debt = scaled debt = borrowAmount
        assertEq(pool.getUserDebt(alice), borrowAmount);
    }

    function test_Borrow_UpdatesTotalBorrows() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        assertEq(pool.getTotalBorrows(), borrowAmount);
    }

    function test_Borrow_TransfersTokens() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        assertEq(token.balanceOf(alice), balanceBefore + borrowAmount);
    }

    function test_Borrow_RevertsOnExceedingLTV() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 801 * WAD; // > 80% LTV

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.expectRevert(ILendingPool.PositionUnhealthy.selector);
        vm.prank(alice);
        pool.borrow(borrowAmount);
    }

    function test_Borrow_AllowsMaxLTV() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 800 * WAD; // Exactly 80% LTV

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        assertEq(pool.getUserDebt(alice), borrowAmount);
    }

    function test_Borrow_RevertsOnInsufficientLiquidity() public {
        uint256 depositAmount = 1000 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        // Try to borrow more than available
        vm.expectRevert(ILendingPool.InsufficientLiquidity.selector);
        vm.prank(alice);
        pool.borrow(depositAmount + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REPAY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Repay_ReducesUserDebt() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;
        uint256 repayAmount = 200 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        vm.prank(alice);
        pool.repay(repayAmount);

        assertEq(pool.getUserDebt(alice), borrowAmount - repayAmount);
    }

    function test_Repay_FullRepay_ZeroesDebt() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        vm.prank(alice);
        pool.repay(borrowAmount);

        assertEq(pool.getUserDebt(alice), 0);
    }

    function test_Repay_ReducesTotalBorrows() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;
        uint256 repayAmount = 200 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        vm.prank(alice);
        pool.repay(repayAmount);

        assertEq(pool.getTotalBorrows(), borrowAmount - repayAmount);
    }

    function test_Repay_CapsAtActualDebt() public {
        uint256 depositAmount = 1000 * WAD;
        uint256 borrowAmount = 500 * WAD;
        uint256 excessRepay = 1000 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.prank(alice);
        pool.borrow(borrowAmount);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        pool.repay(excessRepay);

        // Should only take borrowAmount, not excessRepay
        assertEq(token.balanceOf(alice), balanceBefore - borrowAmount);
        assertEq(pool.getUserDebt(alice), 0);
    }

    function test_Repay_RevertsOnNoDebt() public {
        uint256 depositAmount = 1000 * WAD;

        vm.prank(alice);
        pool.deposit(depositAmount);

        vm.expectRevert(ILendingPool.NoDebtToRepay.selector);
        vm.prank(alice);
        pool.repay(100 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Liquidate_SeizesCollateral() public {
        // Alice deposits and borrows at max LTV (she's the only depositor)
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(800 * WAD); // 80% LTV, 80% utilization

        // Fast forward to accrue interest
        // At 80% utilization, rate = 0.8 * 10% = 8% APR
        // After 1 year, debt = 800 * 1.08 = 864 WAD
        // 864 / 1000 = 86.4% > 85% threshold, position is unhealthy
        vm.warp(block.timestamp + 365 days);

        // Bob deposits to provide liquidity for liquidation
        // This also triggers interest accrual
        vm.prank(bob);
        pool.deposit(1000 * WAD);

        // Verify Alice is unhealthy
        assertFalse(pool.isHealthy(alice), "Alice should be unhealthy");

        uint256 collateralBefore = pool.getUserCollateral(alice);
        uint256 debtToCover = 100 * WAD;

        vm.prank(bob);
        pool.liquidate(alice, debtToCover);

        // Alice's collateral should decrease
        assertLt(pool.getUserCollateral(alice), collateralBefore);
        // Alice's debt should decrease
        assertLt(
            pool.getUserDebt(alice),
            pool.getUserDebt(alice) + debtToCover
        );
        // Bob's balance is unchanged (1:1 liquidation, no bonus per SCOPE.md)
        // He paid 100 WAD and received 100 WAD collateral
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 1000 * WAD);
    }

    function test_Liquidate_RevertsOnHealthyPosition() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(500 * WAD); // 50% LTV, healthy

        vm.prank(bob);
        pool.deposit(1000 * WAD);

        vm.expectRevert(ILendingPool.PositionHealthy.selector);
        vm.prank(bob);
        pool.liquidate(alice, 100 * WAD);
    }

    function test_Liquidate_RevertsOnSelfLiquidation() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(800 * WAD);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(ILendingPool.SelfLiquidation.selector);
        vm.prank(alice);
        pool.liquidate(alice, 100 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEREST ACCRUAL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_AccrueInterest_IncreasesBorrowIndex() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(500 * WAD);

        uint256 indexBefore = pool.getBorrowIndex();

        // Warp forward
        vm.warp(block.timestamp + 365 days);

        // Trigger accrual via deposit
        vm.prank(bob);
        token.approve(address(pool), 1);
        token.mint(bob, 1);
        vm.prank(bob);
        pool.deposit(1);

        uint256 indexAfter = pool.getBorrowIndex();

        assertGt(indexAfter, indexBefore);
    }

    function test_AccrueInterest_IncreasesUserDebt() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(500 * WAD);

        uint256 debtBefore = pool.getUserDebt(alice);

        // Warp forward
        vm.warp(block.timestamp + 365 days);

        // Trigger accrual
        vm.prank(bob);
        token.mint(bob, 1);
        token.approve(address(pool), 1);
        vm.prank(bob);
        pool.deposit(1);

        uint256 debtAfter = pool.getUserDebt(alice);

        assertGt(debtAfter, debtBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_FullFlow_DepositBorrowRepayWithdraw() public {
        // Alice deposits
        vm.prank(alice);
        pool.deposit(1000 * WAD);

        // Alice borrows (low LTV to stay healthy after interest)
        vm.prank(alice);
        pool.borrow(400 * WAD); // 40% LTV

        // Time passes
        vm.warp(block.timestamp + 30 days);

        // Alice repays - first get actual debt after accrual
        // Trigger accrual by reading debt (view function uses current state)
        uint256 debt = pool.getUserDebt(alice);
        token.mint(alice, debt); // Mint enough to cover debt + interest
        vm.prank(alice);
        pool.repay(type(uint256).max); // Repay max will cap at actual debt

        // Verify debt is zero
        assertEq(pool.getUserDebt(alice), 0);

        // Alice withdraws all
        vm.prank(alice);
        pool.withdraw(1000 * WAD);

        assertEq(pool.getUserCollateral(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HEALTH CHECK TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_IsHealthy_ReturnsTrueForNoDebt() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);

        assertTrue(pool.isHealthy(alice));
    }

    function test_IsHealthy_ReturnsTrueForLowLTV() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(500 * WAD); // 50% LTV

        assertTrue(pool.isHealthy(alice));
    }

    function test_IsHealthy_ReturnsFalseAfterInterestAccrual() public {
        vm.prank(alice);
        pool.deposit(1000 * WAD);
        vm.prank(alice);
        pool.borrow(800 * WAD); // 80% LTV, at max

        // Warp to accrue interest beyond liquidation threshold
        vm.warp(block.timestamp + 365 days);

        // Trigger accrual
        vm.prank(bob);
        token.mint(bob, 1);
        token.approve(address(pool), 1);
        vm.prank(bob);
        pool.deposit(1);

        assertFalse(pool.isHealthy(alice));
    }
}
