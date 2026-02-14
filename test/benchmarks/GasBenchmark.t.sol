// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReferencePool} from "../mocks/ReferencePool.sol";

/**
 * @title GasBenchmark
 * @notice Side-by-side gas comparison: Optimized vs Reference.
 * @dev Run with: forge test --match-contract GasBenchmark --gas-report
 *      Snapshot:  forge snapshot --match-contract GasBenchmark
 *
 *      Both pools execute identical operations under identical state.
 *      Gas delta = optimization impact.
 */
contract GasBenchmark is Test {
    LendingPool public pool;
    ReferencePool public refPool;
    MockERC20 public token;

    address public alice;
    address public bob;

    uint256 constant WAD = 1e18;
    uint256 constant DEPOSIT_AMOUNT = 10_000 * WAD;
    uint256 constant BORROW_AMOUNT = 8_000 * WAD;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18);

        // --- Optimized Pool (behind proxy) ---
        LendingPool impl = new LendingPool();
        bytes memory initData = abi.encodeCall(
            LendingPool.initialize,
            address(token)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = LendingPool(address(proxy));

        // --- Reference Pool (no proxy) ---
        refPool = new ReferencePool(address(token));

        // --- Actors ---
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _mintAndApprove(
        address user,
        address spender,
        uint256 amount
    ) internal {
        deal(address(token), user, token.balanceOf(user) + amount);
        vm.prank(user);
        token.approve(spender, type(uint256).max);
    }

    function _setupDeposited() internal {
        _mintAndApprove(alice, address(pool), DEPOSIT_AMOUNT);
        _mintAndApprove(alice, address(refPool), DEPOSIT_AMOUNT);

        vm.prank(alice);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        refPool.deposit(DEPOSIT_AMOUNT);
    }

    function _setupBorrowed() internal {
        _setupDeposited();

        vm.prank(alice);
        pool.borrow(BORROW_AMOUNT);

        vm.prank(alice);
        refPool.borrow(BORROW_AMOUNT);
    }

    function _setupLiquidatable() internal {
        _setupBorrowed();

        // Warp to accrue enough interest to make position unhealthy
        vm.warp(block.timestamp + 730 days);

        // Fund bob as liquidator
        _mintAndApprove(bob, address(pool), BORROW_AMOUNT);
        _mintAndApprove(bob, address(refPool), BORROW_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Gas_Deposit_Optimized() external {
        _mintAndApprove(alice, address(pool), DEPOSIT_AMOUNT);
        vm.prank(alice);
        pool.deposit(DEPOSIT_AMOUNT);
    }

    function test_Gas_Deposit_Reference() external {
        _mintAndApprove(alice, address(refPool), DEPOSIT_AMOUNT);
        vm.prank(alice);
        refPool.deposit(DEPOSIT_AMOUNT);
    }

    function test_Gas_Deposit_Warm_Optimized() external {
        _setupDeposited();

        _mintAndApprove(alice, address(pool), 1_000 * WAD);
        vm.prank(alice);
        pool.deposit(1_000 * WAD);
    }

    function test_Gas_Deposit_Warm_Reference() external {
        _setupDeposited();

        _mintAndApprove(alice, address(refPool), 1_000 * WAD);
        vm.prank(alice);
        refPool.deposit(1_000 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAW BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Gas_Withdraw_Optimized() external {
        _setupDeposited();
        vm.prank(alice);
        pool.withdraw(1_000 * WAD);
    }

    function test_Gas_Withdraw_Reference() external {
        _setupDeposited();
        vm.prank(alice);
        refPool.withdraw(1_000 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BORROW BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Gas_Borrow_Optimized() external {
        _setupDeposited();
        vm.prank(alice);
        pool.borrow(BORROW_AMOUNT);
    }

    function test_Gas_Borrow_Reference() external {
        _setupDeposited();
        vm.prank(alice);
        refPool.borrow(BORROW_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REPAY BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Gas_Repay_Optimized() external {
        _setupBorrowed();

        vm.warp(block.timestamp + 30 days);

        _mintAndApprove(alice, address(pool), 1_000 * WAD);
        vm.prank(alice);
        pool.repay(1_000 * WAD);
    }

    function test_Gas_Repay_Reference() external {
        _setupBorrowed();

        vm.warp(block.timestamp + 30 days);

        _mintAndApprove(alice, address(refPool), 1_000 * WAD);
        vm.prank(alice);
        refPool.repay(1_000 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDATE BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Gas_Liquidate_Optimized() external {
        _setupLiquidatable();
        vm.prank(bob);
        pool.liquidate(alice, 1_000 * WAD);
    }

    function test_Gas_Liquidate_Reference() external {
        _setupLiquidatable();
        vm.prank(bob);
        refPool.liquidate(alice, 1_000 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Gas_GetUserDebt_Optimized() external view {
        pool.getUserDebt(alice);
    }

    function test_Gas_GetUserDebt_Reference() external view {
        refPool.getUserDebt(alice);
    }
}
