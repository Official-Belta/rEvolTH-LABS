// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MathLib — Pure math for the looping vault
/// @dev All values in 18-decimal fixed point unless noted.
///      peg = weETH/ETH price (1e18 = 1:1)
///      LTV = debt * 1e18 / (collateral * peg / 1e18)
library MathLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice Calculate LTV given position and peg.
    /// @return ltv in WAD (1e18 = 100%)
    function calcLTV(uint256 collateral, uint256 debt, uint256 peg) internal pure returns (uint256) {
        if (collateral == 0 || peg == 0) return type(uint256).max;
        uint256 collValue = collateral * peg / WAD;
        if (collValue == 0) return type(uint256).max;
        return debt * WAD / collValue;
    }

    /// @notice How much additional ETH to borrow to reach targetLTV.
    /// @param targetLtvBps Target LTV in basis points (e.g. 8500 = 85%)
    /// @return additionalBorrow ETH amount to borrow (with 5% safety margin)
    function calcLeverageAmount(
        uint256 collateral,
        uint256 debt,
        uint256 peg,
        uint256 targetLtvBps
    ) internal pure returns (uint256) {
        if (collateral == 0 || peg == 0) return 0;
        uint256 collValue = collateral * peg / WAD;
        uint256 targetDebt = collValue * targetLtvBps / BPS;
        if (targetDebt <= debt) return 0;
        // 5% safety margin
        return (targetDebt - debt) * 95 / 100;
    }

    /// @notice Calculate how much collateral to withdraw and debt to repay
    ///         to extract `ethNeeded` of equity from the position.
    /// @dev Proportional unwind: maintains current LTV ratio.
    /// @return debtToRepay Amount of ETH debt to repay
    /// @return collToWithdraw Amount of weETH collateral to withdraw
    function calcUnwindAmount(
        uint256 collateral,
        uint256 debt,
        uint256 peg,
        uint256 ethNeeded
    ) internal pure returns (uint256 debtToRepay, uint256 collToWithdraw) {
        uint256 collValue = collateral * peg / WAD;
        if (collValue <= debt) return (debt, collateral); // underwater: full unwind

        uint256 equity = collValue - debt;
        if (ethNeeded >= equity) return (debt, collateral); // full unwind

        // Proportional: withdraw (ethNeeded / equity) fraction of both sides
        debtToRepay = ethNeeded * debt / equity;
        collToWithdraw = ethNeeded * collateral / equity;
    }

    /// @notice Calculate excess debt above a target LTV.
    /// @param targetLtvBps Target LTV in BPS
    /// @return excessDebt ETH to repay to reach target
    function calcExcessDebt(
        uint256 collateral,
        uint256 debt,
        uint256 peg,
        uint256 targetLtvBps
    ) internal pure returns (uint256) {
        if (collateral == 0 || peg == 0) return debt;
        uint256 collValue = collateral * peg / WAD;
        uint256 targetDebt = collValue * targetLtvBps / BPS;
        if (debt <= targetDebt) return 0;
        return debt - targetDebt;
    }
}
