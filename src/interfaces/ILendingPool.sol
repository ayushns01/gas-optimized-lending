// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILendingPool
 * @author Gas-Optimized Lending Protocol
 * @notice Interface for the core lending pool contract.
 */
interface ILendingPool {
    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a user deposits collateral.
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws collateral.
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when a user borrows assets.
    event Borrow(address indexed user, uint256 amount);

    /// @notice Emitted when a user repays debt.
    event Repay(address indexed user, uint256 amount);

    /// @notice Emitted when a position is liquidated.
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtCovered,
        uint256 collateralSeized
    );

    /// @notice Emitted when interest is accrued.
    event InterestAccrued(uint256 newBorrowIndex, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when amount is zero.
    error ZeroAmount();

    /// @notice Thrown when user has insufficient collateral.
    error InsufficientCollateral();

    /// @notice Thrown when pool has insufficient liquidity.
    error InsufficientLiquidity();

    /// @notice Thrown when operation would make position unhealthy.
    error PositionUnhealthy();

    /// @notice Thrown when trying to liquidate a healthy position.
    error PositionHealthy();

    /// @notice Thrown when trying to liquidate self.
    error SelfLiquidation();

    /// @notice Thrown when there is no debt to repay.
    error NoDebtToRepay();

    /// @notice Thrown when amount exceeds uint128 bounds.
    error AmountOverflow();

    /// @notice Thrown when critical view is called during reentrancy.
    error ReadOnlyReentrancy();

    /// @notice Thrown when asset address is zero.
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposits collateral into the pool.
    /// @param amount The amount of tokens to deposit.
    function deposit(uint256 amount) external;

    /// @notice Withdraws collateral from the pool.
    /// @param amount The amount of tokens to withdraw.
    function withdraw(uint256 amount) external;

    /// @notice Borrows assets from the pool.
    /// @param amount The amount of tokens to borrow.
    function borrow(uint256 amount) external;

    /// @notice Repays outstanding debt.
    /// @param amount The amount of tokens to repay.
    function repay(uint256 amount) external;

    /// @notice Liquidates an unhealthy position.
    /// @param borrower The address of the borrower to liquidate.
    /// @param debtToCover The amount of debt to cover.
    function liquidate(address borrower, uint256 debtToCover) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the underlying asset address.
    function asset() external view returns (address);

    /// @notice Returns whether a user's position is healthy.
    /// @param user The user address to check.
    function isHealthy(address user) external view returns (bool);

    /// @notice Returns the user's current collateral balance.
    /// @param user The user address.
    function getUserCollateral(address user) external view returns (uint256);

    /// @notice Returns the user's current actual debt (with interest).
    /// @param user The user address.
    function getUserDebt(address user) external view returns (uint256);

    /// @notice Returns the current borrow index.
    function getBorrowIndex() external view returns (uint256);

    /// @notice Returns the total liquidity in the pool.
    function getTotalLiquidity() external view returns (uint256);

    /// @notice Returns the total borrows from the pool.
    function getTotalBorrows() external view returns (uint256);

    /// @notice Returns the available liquidity (total - borrowed).
    function getAvailableLiquidity() external view returns (uint256);
}
