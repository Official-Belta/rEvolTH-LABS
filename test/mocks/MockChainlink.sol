// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../src/interfaces/IChainlinkAggregator.sol";

/// @notice Mock Chainlink price feed for testing
contract MockChainlink is IChainlinkAggregator {
    int256 public price = 1e18;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        return (0, price, 0, updatedAt, 0);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
