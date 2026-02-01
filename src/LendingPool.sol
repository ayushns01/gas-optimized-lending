// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {TransientGuard} from "./libraries/TransientGuard.sol";
import {OptimizedMath} from "./libraries/OptimizedMath.sol";

/**
 * @title LendingPool
 * @author Gas-Optimized Lending Protocol
 * @notice Core lending pool contract with gas-optimized storage and math.
 * @dev Implements a single-asset lending pool with:
 *      - EIP-1153 transient reentrancy guards
 *      - Bit-packed storage layouts
 *      - Yul-optimized interest calculations
 *      - UUPS upgradeability
 *
 *      STORAGE LAYOUT (per ARCHITECTURE.md):
 *      ─────────────────────────────────────
 *      Slot 0-50:  Reserved (UUPS/Ownable)
 *      Slot 51:    VolumeState [Liquidity(128b MSB)][Borrows(128b LSB)]
 *      Slot 52:    RateState [BorrowIndex(128b)][LiquidityIndex(96b)][Timestamp(32b)]
 *      Slot 53+:   UserConfig mapping [Debt(128b MSB)][Collateral(128b LSB)]
 */
contract LendingPool is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ILendingPool
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS (Frozen per Implementation Plan)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Fixed-point base (1e18)
    uint256 internal constant WAD = 1e18;

    /// @dev Seconds per year for rate calculations
    /// @dev Kept for documentation: SLOPE = 0.1e18 / SECONDS_PER_YEAR
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @dev Base interest rate (0 = no base rate)
    uint256 internal constant BASE_RATE = 0;

    /// @dev Interest rate slope (~10% APR at 100% utilization)
    /// @dev SLOPE = 0.1e18 / SECONDS_PER_YEAR ≈ 3,170,979,198
    uint256 internal constant SLOPE = 3_170_979_198;

    /// @dev Maximum borrow = 80% of collateral
    uint256 internal constant LTV_RATIO = 0.8e18;

    /// @dev Position is unhealthy if debt > 85% of collateral
    uint256 internal constant LIQUIDATION_THRESHOLD = 0.85e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE (Explicit Slot Allocation)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Gap for UUPS/Ownable storage (slots 0-50)
    uint256[51] private __gap;

    /// @dev Slot 51: VolumeState - packed [Liquidity(128b MSB)][Borrows(128b LSB)]
    uint256 private _volumeState;

    /// @dev Slot 52: RateState - packed [BorrowIndex(128b)][LiquidityIndex(96b)][Timestamp(32b)]
    uint256 private _rateState;

    /// @dev Slot 53+: User configurations - packed [Debt(128b MSB)][Collateral(128b LSB)]
    mapping(address => uint256) private _userConfigs;

    /// @dev The underlying ERC-20 asset
    address private _asset;

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the lending pool.
     * @param asset_ The underlying ERC-20 token address.
     * @dev OZ v5 UUPSUpgradeable is stateless (@custom:stateless) - no __UUPSUpgradeable_init() exists.
     *      Initialization is handled by Initializable + OwnableUpgradeable.
     */
    function initialize(address asset_) external initializer {
        __Ownable_init(msg.sender);

        _asset = asset_;

        // Initialize indices to WAD (1e18)
        // liquidityIndex is frozen at WAD, borrowIndex starts at WAD
        _rateState = DataTypes.packRateState(
            uint128(WAD), // borrowIndex
            uint96(WAD), // liquidityIndex (frozen)
            uint32(block.timestamp)
        );

        // VolumeState starts at zero
        _volumeState = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADE AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc ILendingPool
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        // FIX: Type safety - prevent silent uint128 truncation
        if (amount > type(uint128).max) revert AmountOverflow();

        TransientGuard.enter();

        _accrueInterest();

        // Transfer tokens in
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);

        // Update user collateral (raw, not scaled)
        (uint128 collateral, uint128 scaledDebt) = DataTypes.unpackUserConfig(
            _userConfigs[msg.sender]
        );
        collateral += uint128(amount);
        _userConfigs[msg.sender] = DataTypes.packUserConfig(
            collateral,
            scaledDebt
        );

        // Update total liquidity
        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);
        totalLiquidity += uint128(amount);
        _volumeState = DataTypes.packVolumeState(totalLiquidity, totalBorrows);

        TransientGuard.exit();

        emit Deposit(msg.sender, amount);
    }

    /// @inheritdoc ILendingPool
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        // FIX: Type safety - prevent silent uint128 truncation
        if (amount > type(uint128).max) revert AmountOverflow();

        TransientGuard.enter();

        _accrueInterest();

        // Load user state
        (uint128 collateral, uint128 scaledDebt) = DataTypes.unpackUserConfig(
            _userConfigs[msg.sender]
        );

        if (amount > collateral) revert InsufficientCollateral();

        // Check available liquidity
        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);
        uint256 availableLiquidity = totalLiquidity - totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        // Check health after withdrawal
        uint128 newCollateral = collateral - uint128(amount);
        if (!_isHealthyInternal(newCollateral, scaledDebt)) {
            revert PositionUnhealthy();
        }

        // Update user state
        _userConfigs[msg.sender] = DataTypes.packUserConfig(
            newCollateral,
            scaledDebt
        );

        // Update total liquidity
        _volumeState = DataTypes.packVolumeState(
            totalLiquidity - uint128(amount),
            totalBorrows
        );

        // Transfer tokens out
        IERC20(_asset).safeTransfer(msg.sender, amount);

        TransientGuard.exit();

        emit Withdraw(msg.sender, amount);
    }

    /// @inheritdoc ILendingPool
    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        // FIX: Type safety - prevent silent uint128 truncation
        if (amount > type(uint128).max) revert AmountOverflow();

        TransientGuard.enter();

        _accrueInterest();

        // Check available liquidity
        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);
        uint256 availableLiquidity = totalLiquidity - totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        // Load user state
        (uint128 collateral, uint128 scaledDebt) = DataTypes.unpackUserConfig(
            _userConfigs[msg.sender]
        );

        // Get current borrow index
        (uint128 borrowIndex, , ) = DataTypes.unpackRateState(_rateState);

        // Calculate new debt
        uint256 currentActualDebt = OptimizedMath.getActualDebt(
            scaledDebt,
            borrowIndex
        );
        uint256 newActualDebt = currentActualDebt + amount;

        // Check health after borrow (using LTV_RATIO for new borrows)
        uint256 maxBorrow = (uint256(collateral) * LTV_RATIO) / WAD;
        if (newActualDebt > maxBorrow) revert PositionUnhealthy();

        // Calculate scaled debt to add (round UP)
        uint256 scaledDebtToAdd = OptimizedMath.getScaledDebt(
            amount,
            borrowIndex
        );

        // FIX: Prevent scaledDebt accumulation overflow
        if (scaledDebtToAdd > type(uint128).max - scaledDebt)
            revert AmountOverflow();

        // Update user state
        _userConfigs[msg.sender] = DataTypes.packUserConfig(
            collateral,
            scaledDebt + uint128(scaledDebtToAdd)
        );

        // Update total borrows
        _volumeState = DataTypes.packVolumeState(
            totalLiquidity,
            totalBorrows + uint128(amount)
        );

        // Transfer tokens out
        IERC20(_asset).safeTransfer(msg.sender, amount);

        TransientGuard.exit();

        emit Borrow(msg.sender, amount);
    }

    /// @inheritdoc ILendingPool
    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        TransientGuard.enter();

        _accrueInterest();

        // Load user state
        (uint128 collateral, uint128 scaledDebt) = DataTypes.unpackUserConfig(
            _userConfigs[msg.sender]
        );

        if (scaledDebt == 0) revert NoDebtToRepay();

        // Get current borrow index
        (uint128 borrowIndex, , ) = DataTypes.unpackRateState(_rateState);

        // Calculate actual debt
        uint256 actualDebt = OptimizedMath.getActualDebt(
            scaledDebt,
            borrowIndex
        );

        // Cap repayment at actual debt
        uint256 repayAmount = amount > actualDebt ? actualDebt : amount;

        // Transfer tokens in
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        // Calculate scaled debt to remove
        uint128 scaledRepay;
        if (repayAmount == actualDebt) {
            // Full repay: zero out exactly
            scaledRepay = scaledDebt;
        } else {
            // Partial repay: round UP (user pays slightly more in terms of scaled units)
            scaledRepay = uint128(
                OptimizedMath.getScaledDebt(repayAmount, borrowIndex)
            );
        }

        // Update user state
        _userConfigs[msg.sender] = DataTypes.packUserConfig(
            collateral,
            scaledDebt - scaledRepay
        );

        // Update total borrows
        // Note: repayAmount may exceed totalBorrows due to accrued interest
        // Cap the reduction to totalBorrows to prevent underflow
        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);
        uint128 borrowsReduction = repayAmount > totalBorrows
            ? totalBorrows
            : uint128(repayAmount);
        _volumeState = DataTypes.packVolumeState(
            totalLiquidity,
            totalBorrows - borrowsReduction
        );

        TransientGuard.exit();

        emit Repay(msg.sender, repayAmount);
    }

    /// @inheritdoc ILendingPool
    function liquidate(address borrower, uint256 debtToCover) external {
        if (debtToCover == 0) revert ZeroAmount();
        // FIX: Type safety - prevent silent uint128 truncation
        if (debtToCover > type(uint128).max) revert AmountOverflow();
        if (borrower == msg.sender) revert SelfLiquidation();

        TransientGuard.enter();

        _accrueInterest();

        // Load borrower state
        (uint128 collateral, uint128 scaledDebt) = DataTypes.unpackUserConfig(
            _userConfigs[borrower]
        );

        // Get current borrow index
        (uint128 borrowIndex, , ) = DataTypes.unpackRateState(_rateState);

        // Calculate actual debt
        uint256 actualDebt = OptimizedMath.getActualDebt(
            scaledDebt,
            borrowIndex
        );

        // Check if position is liquidatable
        if (_isHealthyInternal(collateral, scaledDebt))
            revert PositionHealthy();

        // Cap debt to cover at actual debt
        uint256 debtCovered = debtToCover > actualDebt
            ? actualDebt
            : debtToCover;

        // Collateral to seize = debtCovered (1:1, no bonus per SCOPE.md)
        uint256 collateralToSeize = debtCovered;
        if (collateralToSeize > collateral) {
            collateralToSeize = collateral;
        }

        // FIX: Use effectiveDebtCovered to prevent bad debt forgiveness
        // When collateral < debtCovered, we can only clear debt equal to seized collateral
        uint256 effectiveDebtCovered = collateralToSeize;

        // Transfer debt payment from liquidator (only pay what's effectively covered)
        IERC20(_asset).safeTransferFrom(
            msg.sender,
            address(this),
            effectiveDebtCovered
        );

        // Calculate scaled debt reduction based on effective debt covered
        uint128 scaledDebtReduction;
        if (effectiveDebtCovered == actualDebt) {
            scaledDebtReduction = scaledDebt;
        } else {
            scaledDebtReduction = uint128(
                OptimizedMath.getScaledDebt(effectiveDebtCovered, borrowIndex)
            );
        }

        // Update borrower state
        _userConfigs[borrower] = DataTypes.packUserConfig(
            collateral - uint128(collateralToSeize),
            scaledDebt - scaledDebtReduction
        );

        // Update total borrows based on effective debt covered
        // Note: effectiveDebtCovered may exceed totalBorrows due to accrued interest
        // Cap the reduction to totalBorrows to prevent underflow
        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);
        uint128 borrowsReduction = effectiveDebtCovered > totalBorrows
            ? totalBorrows
            : uint128(effectiveDebtCovered);
        _volumeState = DataTypes.packVolumeState(
            totalLiquidity,
            totalBorrows - borrowsReduction
        );

        // Transfer seized collateral to liquidator
        IERC20(_asset).safeTransfer(msg.sender, collateralToSeize);

        TransientGuard.exit();

        // Emit with effective values to maintain accounting integrity
        emit Liquidate(
            msg.sender,
            borrower,
            effectiveDebtCovered,
            collateralToSeize
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Accrues interest by updating the borrow index.
     *      Called at the start of every state-changing function.
     */
    function _accrueInterest() internal {
        (
            uint128 borrowIndex,
            uint96 liquidityIndex,
            uint32 lastTimestamp
        ) = DataTypes.unpackRateState(_rateState);

        // Skip if already accrued this block
        if (block.timestamp == lastTimestamp) return;

        uint256 timeDelta = block.timestamp - lastTimestamp;

        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);

        // FIX: Gas hygiene - early return when no borrows (no interest to accrue)
        if (totalBorrows == 0) {
            _rateState = DataTypes.packRateState(
                borrowIndex,
                liquidityIndex,
                uint32(block.timestamp)
            );
            return;
        }

        // If no liquidity, just update timestamp
        if (totalLiquidity == 0) {
            _rateState = DataTypes.packRateState(
                borrowIndex,
                liquidityIndex,
                uint32(block.timestamp)
            );
            return;
        }

        // Calculate utilization: totalBorrows / totalLiquidity
        uint256 utilization = (uint256(totalBorrows) * WAD) / totalLiquidity;

        // Calculate current rate: BASE_RATE + (utilization * SLOPE) / WAD
        uint256 currentRate = BASE_RATE + (utilization * SLOPE) / WAD;

        // Calculate new borrow index
        uint256 newBorrowIndex = OptimizedMath.calculateLinearInterest(
            borrowIndex,
            currentRate,
            timeDelta
        );

        // FIX: Index safety - prevent silent overflow when casting to uint128
        if (newBorrowIndex > type(uint128).max) revert AmountOverflow();

        // FIX: Gas hygiene - skip storage write and emit if index unchanged
        if (newBorrowIndex == borrowIndex) {
            _rateState = DataTypes.packRateState(
                borrowIndex,
                liquidityIndex,
                uint32(block.timestamp)
            );
            return;
        }

        // Update rate state (liquidityIndex stays frozen at WAD)
        _rateState = DataTypes.packRateState(
            uint128(newBorrowIndex),
            liquidityIndex,
            uint32(block.timestamp)
        );

        emit InterestAccrued(newBorrowIndex, block.timestamp);
    }

    /**
     * @dev Checks if a position is healthy using the liquidation threshold.
     * @param collateral The user's collateral amount.
     * @param scaledDebt The user's scaled debt.
     * @return True if healthy, false if liquidatable.
     */
    function _isHealthyInternal(
        uint128 collateral,
        uint128 scaledDebt
    ) internal view returns (bool) {
        if (scaledDebt == 0) return true;

        (uint128 borrowIndex, , ) = DataTypes.unpackRateState(_rateState);
        uint256 actualDebt = OptimizedMath.getActualDebt(
            scaledDebt,
            borrowIndex
        );
        uint256 maxDebt = (uint256(collateral) * LIQUIDATION_THRESHOLD) / WAD;

        return actualDebt <= maxDebt;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc ILendingPool
    function asset() external view returns (address) {
        return _asset;
    }

    /// @inheritdoc ILendingPool
    function isHealthy(address user) external view returns (bool) {
        (uint128 collateral, uint128 scaledDebt) = DataTypes.unpackUserConfig(
            _userConfigs[user]
        );
        return _isHealthyInternal(collateral, scaledDebt);
    }

    /// @inheritdoc ILendingPool
    function getUserCollateral(address user) external view returns (uint256) {
        (uint128 collateral, ) = DataTypes.unpackUserConfig(_userConfigs[user]);
        return collateral;
    }

    /// @inheritdoc ILendingPool
    function getUserDebt(address user) external view returns (uint256) {
        (, uint128 scaledDebt) = DataTypes.unpackUserConfig(_userConfigs[user]);
        if (scaledDebt == 0) return 0;

        (uint128 borrowIndex, , ) = DataTypes.unpackRateState(_rateState);
        return OptimizedMath.getActualDebt(scaledDebt, borrowIndex);
    }

    /// @inheritdoc ILendingPool
    function getBorrowIndex() external view returns (uint256) {
        (uint128 borrowIndex, , ) = DataTypes.unpackRateState(_rateState);
        return borrowIndex;
    }

    /// @inheritdoc ILendingPool
    function getTotalLiquidity() external view returns (uint256) {
        (uint128 totalLiquidity, ) = DataTypes.unpackVolumeState(_volumeState);
        return totalLiquidity;
    }

    /// @inheritdoc ILendingPool
    function getTotalBorrows() external view returns (uint256) {
        (, uint128 totalBorrows) = DataTypes.unpackVolumeState(_volumeState);
        return totalBorrows;
    }

    /// @inheritdoc ILendingPool
    function getAvailableLiquidity() external view returns (uint256) {
        (uint128 totalLiquidity, uint128 totalBorrows) = DataTypes
            .unpackVolumeState(_volumeState);
        return totalLiquidity - totalBorrows;
    }
}
