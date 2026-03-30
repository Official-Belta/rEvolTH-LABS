// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICoreWriter - HyperCore write interface
/// @notice Place and manage orders on HyperCore L1 from HyperEVM
interface ICoreWriter {
    /// @notice Place a perp order on HyperCore
    /// @param assetIndex Index of the asset
    /// @param isBuy True for long, false for short
    /// @param limitPrice Limit price (18 decimals)
    /// @param size Order size (18 decimals)
    /// @param reduceOnly Whether order is reduce-only
    function placeOrder(
        uint32 assetIndex,
        bool isBuy,
        uint256 limitPrice,
        uint256 size,
        bool reduceOnly
    ) external;

    /// @notice Cancel an existing order
    /// @param assetIndex Index of the asset
    /// @param orderId Order ID to cancel
    function cancelOrder(uint32 assetIndex, uint64 orderId) external;

    /// @notice Modify an existing order
    /// @param assetIndex Index of the asset
    /// @param orderId Order ID to modify
    /// @param limitPrice New limit price
    /// @param size New size
    function modifyOrder(uint32 assetIndex, uint64 orderId, uint256 limitPrice, uint256 size) external;

    /// @notice Transfer USDC from HyperEVM to HyperCore
    /// @param amount Amount of USDC to transfer (6 decimals)
    function transferToCore(uint256 amount) external;

    /// @notice Transfer USDC from HyperCore to HyperEVM
    /// @param amount Amount of USDC to transfer (6 decimals)
    function transferFromCore(uint256 amount) external;
}
