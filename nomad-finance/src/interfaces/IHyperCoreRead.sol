// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IHyperCoreRead - HyperCore precompile read interface
/// @notice Read price and position data from HyperCore L1
/// @dev Precompile at 0x0000000000000000000000000000000000000800
interface IHyperCoreRead {
    /// @notice Get oracle price for an asset
    /// @param assetIndex Index of the asset on HyperCore
    /// @return price Oracle price (18 decimals)
    function getOraclePrice(uint32 assetIndex) external view returns (uint256 price);

    /// @notice Get mark price for an asset
    /// @param assetIndex Index of the asset on HyperCore
    /// @return price Mark price (18 decimals)
    function getMarkPrice(uint32 assetIndex) external view returns (uint256 price);

    /// @notice Get current funding rate
    /// @param assetIndex Index of the asset on HyperCore
    /// @return rate Funding rate (signed, 18 decimals)
    function getFundingRate(uint32 assetIndex) external view returns (int256 rate);

    /// @notice Get open interest for an asset
    /// @param assetIndex Index of the asset on HyperCore
    /// @return oi Open interest (18 decimals)
    function getOpenInterest(uint32 assetIndex) external view returns (uint256 oi);
}
