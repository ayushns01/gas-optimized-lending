// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DataTypes
 * @author Gas-Optimized Lending Protocol
 * @notice Pure library for bit-packed storage encoding and decoding.
 * @dev This library defines the canonical storage layouts and provides helpers
 *      for packing/unpacking data into 256-bit slots.
 *
 *      IMPORTANT: This library contains NO validation logic.
 *      All inputs are assumed to be pre-validated at higher layers.
 *
 *      Storage Layout Reference (Authoritative):
 *      ─────────────────────────────────────────
 *      Slot 0-50:  Reserved for UUPS/Ownable (__gap)
 *      Slot 51:    VolumeState (Total Liquidity + Total Borrows)
 *      Slot 52:    RateState (Borrow Index + Liquidity Index + Timestamp)
 *      Slot 53+:   UserConfig mapping (per-user collateral + debt)
 *
 *      Bit Order Convention:
 *      ─────────────────────
 *      All layouts use LSB-first (least significant bits first) ordering.
 *      Example: [A (32 bits)][B (96 bits)][C (128 bits)]
 *               A = bits 0-31 (LSB), C = bits 128-255 (MSB)
 */
library DataTypes {
    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: UserConfig Layout
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // UserConfig packs a user's collateral and debt into a single 256-bit slot.
    //
    // Layout (256 bits total):
    // ┌────────────────────────────┬────────────────────────────┐
    // │   User Debt (128 bits)     │  User Collateral (128 bits)│
    // │        [MSB]               │         [LSB]              │
    // └────────────────────────────┴────────────────────────────┘
    //   bits 128-255                 bits 0-127
    //
    // WHY THIS LAYOUT?
    // - Reading/writing both values costs only 1 SLOAD/SSTORE (2100/5000 gas cold)
    // - uint128 max = 3.4e38, which exceeds any realistic token supply
    // - Debt in MSB allows easy extraction via right-shift
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Number of bits to shift debt to/from its position (bits 128-255)
    uint256 internal constant USER_DEBT_OFFSET = 128;

    /// @dev Mask to extract collateral from bits 0-127 (128 ones in binary)
    uint256 internal constant USER_COLLATERAL_MASK = (1 << 128) - 1;

    /// @dev Mask to extract debt from bits 128-255 after shifting
    ///      Same as USER_COLLATERAL_MASK since debt is also 128 bits
    uint256 internal constant USER_DEBT_MASK = (1 << 128) - 1;

    /**
     * @notice Packs user collateral and debt into a single uint256.
     * @dev Layout: [debt (128 bits MSB)][collateral (128 bits LSB)]
     *
     *      WARNING: No overflow checks. Caller must ensure:
     *      - collateral <= type(uint128).max
     *      - debt <= type(uint128).max
     *
     * @param collateral User's collateral amount (WAD precision, 128 bits)
     * @param debt User's debt amount (WAD precision, 128 bits)
     * @return packed The packed 256-bit representation
     */
    function packUserConfig(
        uint128 collateral,
        uint128 debt
    ) internal pure returns (uint256 packed) {
        // Shift debt left by 128 bits, then OR with collateral in lower 128 bits
        // Using uint256 cast to ensure full 256-bit arithmetic
        packed = (uint256(debt) << USER_DEBT_OFFSET) | uint256(collateral);
    }

    /**
     * @notice Unpacks a uint256 into user collateral and debt.
     * @dev Extracts:
     *      - collateral from bits 0-127 (mask lower 128 bits)
     *      - debt from bits 128-255 (right-shift then mask)
     *
     * @param packed The packed 256-bit user configuration
     * @return collateral User's collateral amount (128 bits)
     * @return debt User's debt amount (128 bits)
     */
    function unpackUserConfig(
        uint256 packed
    ) internal pure returns (uint128 collateral, uint128 debt) {
        // Extract lower 128 bits for collateral
        collateral = uint128(packed & USER_COLLATERAL_MASK);

        // Shift right by 128, then extract lower 128 bits for debt
        debt = uint128((packed >> USER_DEBT_OFFSET) & USER_DEBT_MASK);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: VolumeState Layout (Slot 51)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // VolumeState tracks total protocol liquidity and borrows.
    //
    // Layout (256 bits total):
    // ┌─────────────────────────────┬────────────────────────────┐
    // │  Total Liquidity (128 bits) │  Total Borrows (128 bits)  │
    // │         [MSB]               │          [LSB]             │
    // └─────────────────────────────┴────────────────────────────┘
    //   bits 128-255                  bits 0-127
    //
    // WHY THIS LAYOUT?
    // - Per Architecture Override (authoritative)
    // - Both values use WAD (1e18) precision
    // - Single SLOAD captures entire protocol volume state
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Number of bits to shift totalLiquidity to/from its position (bits 128-255)
    uint256 internal constant VOLUME_LIQUIDITY_OFFSET = 128;

    /// @dev Mask to extract totalBorrows from bits 0-127
    uint256 internal constant VOLUME_BORROWS_MASK = (1 << 128) - 1;

    /// @dev Mask to extract totalLiquidity after shifting
    uint256 internal constant VOLUME_LIQUIDITY_MASK = (1 << 128) - 1;

    /**
     * @notice Packs total liquidity and borrows into a single uint256.
     * @dev Layout: [totalLiquidity (128 bits MSB)][totalBorrows (128 bits LSB)]
     *
     *      WARNING: No overflow checks. Caller must ensure inputs fit in 128 bits.
     *
     * @param totalLiquidity Protocol's total deposited liquidity (WAD precision)
     * @param totalBorrows Protocol's total outstanding borrows (WAD precision)
     * @return packed The packed 256-bit representation
     */
    function packVolumeState(
        uint128 totalLiquidity,
        uint128 totalBorrows
    ) internal pure returns (uint256 packed) {
        packed =
            (uint256(totalLiquidity) << VOLUME_LIQUIDITY_OFFSET) |
            uint256(totalBorrows);
    }

    /**
     * @notice Unpacks a uint256 into total liquidity and borrows.
     * @dev Extracts:
     *      - totalBorrows from bits 0-127
     *      - totalLiquidity from bits 128-255
     *
     * @param packed The packed 256-bit volume state
     * @return totalLiquidity Protocol's total deposited liquidity
     * @return totalBorrows Protocol's total outstanding borrows
     */
    function unpackVolumeState(
        uint256 packed
    ) internal pure returns (uint128 totalLiquidity, uint128 totalBorrows) {
        totalBorrows = uint128(packed & VOLUME_BORROWS_MASK);
        totalLiquidity = uint128(
            (packed >> VOLUME_LIQUIDITY_OFFSET) & VOLUME_LIQUIDITY_MASK
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: RateState Layout (Slot 52)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // RateState tracks interest indices and last update timestamp.
    //
    // Layout (256 bits total):
    // ┌──────────────────────┬──────────────────────────┬───────────────────┐
    // │ Borrow Index (128b)  │ Liquidity Index (96b)    │ Timestamp (32b)   │
    // │      [MSB]           │       [MIDDLE]           │     [LSB]         │
    // └──────────────────────┴──────────────────────────┴───────────────────┘
    //   bits 128-255           bits 32-127                bits 0-31
    //
    // WHY THIS LAYOUT?
    // - Timestamp (uint32): Seconds since epoch, valid until year 2106
    // - LiquidityIndex (uint96): Supports ~79 billion× growth from WAD base
    // - BorrowIndex (uint128): Full WAD precision for debt tracking accuracy
    //
    // INDEX ACCOUNTING EXPLAINER:
    // ─────────────────────────
    // Indices track cumulative interest growth since protocol inception.
    // - At genesis: liquidityIndex = 1e18 (1 WAD), borrowIndex = 1e18
    // - Over time: indices grow as interest accrues
    //
    // User's actual balance = storedPrincipal * (currentIndex / indexAtDeposit)
    // This avoids storing per-user indices, saving ~5000 gas per user per action.
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Timestamp occupies bits 0-31 (32 bits, no shift needed for extraction)
    uint256 internal constant RATE_TIMESTAMP_OFFSET = 0;

    /// @dev Liquidity index occupies bits 32-127 (96 bits)
    uint256 internal constant RATE_LIQUIDITY_INDEX_OFFSET = 32;

    /// @dev Borrow index occupies bits 128-255 (128 bits)
    uint256 internal constant RATE_BORROW_INDEX_OFFSET = 128;

    /// @dev Mask for timestamp (32 bits)
    uint256 internal constant RATE_TIMESTAMP_MASK = (1 << 32) - 1;

    /// @dev Mask for liquidity index (96 bits)
    uint256 internal constant RATE_LIQUIDITY_INDEX_MASK = (1 << 96) - 1;

    /// @dev Mask for borrow index (128 bits)
    uint256 internal constant RATE_BORROW_INDEX_MASK = (1 << 128) - 1;

    /**
     * @notice Packs rate state (indices + timestamp) into a single uint256.
     * @dev Layout: [borrowIndex (128b MSB)][liquidityIndex (96b)][timestamp (32b LSB)]
     *
     *      WARNING: No overflow checks. Caller must ensure:
     *      - borrowIndex <= type(uint128).max
     *      - liquidityIndex <= type(uint96).max
     *      - timestamp <= type(uint32).max
     *
     *      DANGER: If liquidityIndex exceeds 96 bits, upper bits will be silently
     *      truncated. Higher layers MUST validate bounds.
     *
     * @param borrowIndex Cumulative borrow interest index (WAD precision, 128 bits)
     * @param liquidityIndex Cumulative liquidity interest index (WAD precision, 96 bits)
     * @param timestamp Last update timestamp in seconds (32 bits)
     * @return packed The packed 256-bit representation
     */
    function packRateState(
        uint128 borrowIndex,
        uint96 liquidityIndex,
        uint32 timestamp
    ) internal pure returns (uint256 packed) {
        // Build from LSB to MSB:
        // 1. Start with timestamp in bits 0-31
        // 2. OR liquidityIndex shifted to bits 32-127
        // 3. OR borrowIndex shifted to bits 128-255
        packed =
            uint256(timestamp) |
            (uint256(liquidityIndex) << RATE_LIQUIDITY_INDEX_OFFSET) |
            (uint256(borrowIndex) << RATE_BORROW_INDEX_OFFSET);
    }

    /**
     * @notice Unpacks a uint256 into rate state components.
     * @dev Extracts:
     *      - timestamp from bits 0-31
     *      - liquidityIndex from bits 32-127
     *      - borrowIndex from bits 128-255
     *
     * @param packed The packed 256-bit rate state
     * @return borrowIndex Cumulative borrow interest index (128 bits)
     * @return liquidityIndex Cumulative liquidity interest index (96 bits)
     * @return timestamp Last update timestamp (32 bits)
     */
    function unpackRateState(
        uint256 packed
    )
        internal
        pure
        returns (uint128 borrowIndex, uint96 liquidityIndex, uint32 timestamp)
    {
        // Extract each field by shifting to position 0 and masking
        timestamp = uint32(packed & RATE_TIMESTAMP_MASK);

        liquidityIndex = uint96(
            (packed >> RATE_LIQUIDITY_INDEX_OFFSET) & RATE_LIQUIDITY_INDEX_MASK
        );

        borrowIndex = uint128(
            (packed >> RATE_BORROW_INDEX_OFFSET) & RATE_BORROW_INDEX_MASK
        );
    }
}
