// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock eETH token — can burn for ETH (simulates DEX swap path)
contract MockEETH is ERC20 {
    constructor() ERC20("Mock eETH", "eETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Mock: burn eETH to get ETH back (simulates DEX swap)
    function burnForETH(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}
}

/// @notice Mock weETH token — wraps eETH 1:1 for simplicity
contract MockWeETH is ERC20 {
    MockEETH public eeth;

    constructor(address payable _eeth) ERC20("Mock weETH", "weETH") {
        eeth = MockEETH(_eeth);
    }

    function wrap(uint256 eETHAmount) external returns (uint256) {
        eeth.transferFrom(msg.sender, address(this), eETHAmount);
        _mint(msg.sender, eETHAmount);
        return eETHAmount;
    }

    function unwrap(uint256 weETHAmount) external returns (uint256) {
        _burn(msg.sender, weETHAmount);
        eeth.transfer(msg.sender, weETHAmount);
        return weETHAmount;
    }

    function getRate() external pure returns (uint256) {
        return 1e18;
    }
}

/// @notice Mock LiquidityPool — deposit ETH, get eETH
contract MockLiquidityPool {
    MockEETH public eeth;

    constructor(address payable _eeth) {
        eeth = MockEETH(_eeth);
    }

    function deposit() external payable returns (uint256) {
        eeth.mint(msg.sender, msg.value);
        // Send ETH to eETH contract so burnForETH works
        (bool ok,) = address(eeth).call{value: msg.value}("");
        require(ok, "ETH forward failed");
        return msg.value;
    }
}
