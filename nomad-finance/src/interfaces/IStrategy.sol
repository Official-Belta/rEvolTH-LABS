// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStrategy - Interface for Nomad strategy modules
/// @notice Each option strategy (CC, CSP, IC, etc.) implements this interface
interface IStrategy {
    /// @notice Strategy identifier
    function strategyId() external view returns (bytes32);

    /// @notice Execute the strategy for a given epoch
    /// @param amount Capital allocated to this strategy (in USDC)
    /// @return premium Net premium collected (in USDC)
    function execute(uint256 amount) external returns (uint256 premium);

    /// @notice Close all positions for this strategy
    /// @return pnl Realized PnL (positive = profit, negative = loss)
    function closePositions() external returns (int256 pnl);

    /// @notice Get current portfolio Greeks for this strategy
    /// @return delta Net delta exposure
    /// @return gamma Net gamma exposure
    /// @return theta Net theta (daily decay)
    /// @return vega Net vega exposure
    function getGreeks() external view returns (int256 delta, int256 gamma, int256 theta, int256 vega);

    /// @notice Get current unrealized PnL
    function unrealizedPnL() external view returns (int256);

    /// @notice Whether the strategy needs rolling (epoch expired)
    function needsRolling() external view returns (bool);

    /// @notice Roll positions to next epoch
    function roll() external returns (uint256 newPremium);
}
