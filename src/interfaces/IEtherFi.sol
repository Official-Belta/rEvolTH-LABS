// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice EtherFi LiquidityPool — deposit ETH to get eETH
interface ILiquidityPool {
    function deposit() external payable returns (uint256 eETHAmount);
}

/// @notice EtherFi eETH token (extends IERC20, only non-standard funcs here)
interface IeETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice EtherFi weETH — wrap eETH to get weETH
interface IWeETH {
    function wrap(uint256 eETHAmount) external returns (uint256 weETHAmount);
    function unwrap(uint256 weETHAmount) external returns (uint256 eETHAmount);
    function getRate() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
