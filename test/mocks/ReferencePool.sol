// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReferenceMath} from "./ReferenceMath.sol";

/**
 * @title ReferencePool
 * @notice Unoptimized lending pool for gas benchmarking.
 * @dev Identical business logic to LendingPool.sol, but uses:
 *      - OpenZeppelin ReentrancyGuard (SSTORE-based)
 *      - Separate storage slots (no bit-packing)
 *      - Checked Solidity math (ReferenceMath)
 *      - No proxy (not upgradeable)
 *
 *      This exists SOLELY for gas comparison. Not production code.
 */
contract ReferencePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS (identical to LendingPool)
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BASE_RATE = 0;
    uint256 internal constant SLOPE = 3_170_979_198;
    uint256 internal constant LTV_RATIO = 0.8e18;
    uint256 internal constant LIQUIDATION_THRESHOLD = 0.85e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE — Unpacked (one value per slot)
    // ═══════════════════════════════════════════════════════════════════════════

    address public immutable asset;

    /// @dev Volume state — separate slots
    uint128 public totalLiquidity;
    uint128 public totalBorrows;

    /// @dev Rate state — separate slots
    uint128 public borrowIndex;
    uint32 public lastTimestamp;

    /// @dev User state — separate mappings
    struct UserState {
        uint128 collateral;
        uint128 scaledDebt;
    }
    mapping(address => UserState) public users;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS (identical to ILendingPool)
    // ═══════════════════════════════════════════════════════════════════════════

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtCovered,
        uint256 collateralSeized
    );
    event InterestAccrued(uint256 newBorrowIndex, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS (identical to ILendingPool)
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error PositionUnhealthy();
    error PositionHealthy();
    error SelfLiquidation();
    error NoDebtToRepay();
    error AmountOverflow();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address asset_) {
        asset = asset_;
        borrowIndex = uint128(WAD);
        lastTimestamp = uint32(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountOverflow();

        _accrueInterest();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        UserState storage user = users[msg.sender];

        if (amount > type(uint128).max - user.collateral)
            revert AmountOverflow();
        user.collateral += uint128(amount);

        if (amount > type(uint128).max - totalLiquidity)
            revert AmountOverflow();
        totalLiquidity += uint128(amount);

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountOverflow();

        _accrueInterest();

        UserState storage user = users[msg.sender];

        if (amount > user.collateral) revert InsufficientCollateral();

        uint256 availableLiquidity = totalLiquidity - totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        uint128 newCollateral = user.collateral - uint128(amount);
        if (!_isHealthy(newCollateral, user.scaledDebt))
            revert PositionUnhealthy();

        user.collateral = newCollateral;

        totalLiquidity -= uint128(amount);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountOverflow();

        _accrueInterest();

        uint256 availableLiquidity = totalLiquidity - totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        UserState storage user = users[msg.sender];

        uint256 currentActualDebt = ReferenceMath.getActualDebt(
            user.scaledDebt,
            borrowIndex
        );
        uint256 newActualDebt = currentActualDebt + amount;

        uint256 maxBorrow = (uint256(user.collateral) * LTV_RATIO) / WAD;
        if (newActualDebt > maxBorrow) revert PositionUnhealthy();

        uint256 scaledDebtToAdd = ReferenceMath.getScaledDebt(
            amount,
            borrowIndex
        );

        if (scaledDebtToAdd > type(uint128).max - user.scaledDebt)
            revert AmountOverflow();

        user.scaledDebt += uint128(scaledDebtToAdd);

        if (amount > type(uint128).max - totalBorrows) revert AmountOverflow();
        totalBorrows += uint128(amount);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrueInterest();

        UserState storage user = users[msg.sender];

        if (user.scaledDebt == 0) revert NoDebtToRepay();

        uint256 actualDebt = ReferenceMath.getActualDebt(
            user.scaledDebt,
            borrowIndex
        );

        uint256 repayAmount = amount > actualDebt ? actualDebt : amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        uint128 scaledRepay;
        if (repayAmount == actualDebt) {
            scaledRepay = user.scaledDebt;
        } else {
            scaledRepay = uint128(
                ReferenceMath.getScaledDebt(repayAmount, borrowIndex)
            );
        }

        user.scaledDebt -= scaledRepay;

        uint128 borrowsReduction = repayAmount > totalBorrows
            ? totalBorrows
            : uint128(repayAmount);
        totalBorrows -= borrowsReduction;

        emit Repay(msg.sender, repayAmount);
    }

    function liquidate(
        address borrower,
        uint256 debtToCover
    ) external nonReentrant {
        if (debtToCover == 0) revert ZeroAmount();
        if (debtToCover > type(uint128).max) revert AmountOverflow();
        if (borrower == msg.sender) revert SelfLiquidation();

        _accrueInterest();

        UserState storage target = users[borrower];

        uint256 actualDebt = ReferenceMath.getActualDebt(
            target.scaledDebt,
            borrowIndex
        );

        if (_isHealthy(target.collateral, target.scaledDebt))
            revert PositionHealthy();

        uint256 debtCovered = debtToCover > actualDebt
            ? actualDebt
            : debtToCover;

        uint256 collateralToSeize = debtCovered;
        if (collateralToSeize > target.collateral) {
            collateralToSeize = target.collateral;
        }

        uint256 effectiveDebtCovered = collateralToSeize;

        IERC20(asset).safeTransferFrom(
            msg.sender,
            address(this),
            effectiveDebtCovered
        );

        uint128 scaledDebtReduction;
        if (effectiveDebtCovered == actualDebt) {
            scaledDebtReduction = target.scaledDebt;
        } else {
            scaledDebtReduction = uint128(
                ReferenceMath.getScaledDebt(effectiveDebtCovered, borrowIndex)
            );
        }

        target.collateral -= uint128(collateralToSeize);
        target.scaledDebt -= scaledDebtReduction;

        uint128 borrowsReduction = effectiveDebtCovered > totalBorrows
            ? totalBorrows
            : uint128(effectiveDebtCovered);
        totalBorrows -= borrowsReduction;

        IERC20(asset).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidate(
            msg.sender,
            borrower,
            effectiveDebtCovered,
            collateralToSeize
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _accrueInterest() internal {
        if (block.timestamp == lastTimestamp) return;

        uint256 timeDelta = block.timestamp - lastTimestamp;

        if (totalBorrows == 0) {
            lastTimestamp = uint32(block.timestamp);
            return;
        }

        if (totalLiquidity == 0) {
            lastTimestamp = uint32(block.timestamp);
            return;
        }

        uint256 utilization = (uint256(totalBorrows) * WAD) / totalLiquidity;
        uint256 currentRate = BASE_RATE + (utilization * SLOPE) / WAD;

        uint256 newBorrowIndex = ReferenceMath.calculateLinearInterest(
            borrowIndex,
            currentRate,
            timeDelta
        );

        if (newBorrowIndex > type(uint128).max) revert AmountOverflow();

        if (newBorrowIndex == borrowIndex) {
            lastTimestamp = uint32(block.timestamp);
            return;
        }

        borrowIndex = uint128(newBorrowIndex);
        lastTimestamp = uint32(block.timestamp);

        emit InterestAccrued(newBorrowIndex, block.timestamp);
    }

    function _isHealthy(
        uint128 collateral,
        uint128 scaledDebt
    ) internal view returns (bool) {
        if (scaledDebt == 0) return true;

        uint256 actualDebt = ReferenceMath.getActualDebt(
            scaledDebt,
            borrowIndex
        );
        uint256 maxDebt = (uint256(collateral) * LIQUIDATION_THRESHOLD) / WAD;

        return actualDebt <= maxDebt;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS (identical signatures)
    // ═══════════════════════════════════════════════════════════════════════════

    function getUserCollateral(address user) external view returns (uint256) {
        return users[user].collateral;
    }

    function getUserDebt(address user) external view returns (uint256) {
        uint128 scaledDebt = users[user].scaledDebt;
        if (scaledDebt == 0) return 0;
        return ReferenceMath.getActualDebt(scaledDebt, borrowIndex);
    }

    function getBorrowIndex() external view returns (uint256) {
        return borrowIndex;
    }

    function getTotalLiquidity() external view returns (uint256) {
        return totalLiquidity;
    }

    function getTotalBorrows() external view returns (uint256) {
        return totalBorrows;
    }

    function getAvailableLiquidity() external view returns (uint256) {
        return totalLiquidity - totalBorrows;
    }
}
