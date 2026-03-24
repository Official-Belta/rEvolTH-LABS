// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../src/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock swap router for unit tests — does 1:1 swaps by default.
///         For weETH→WETH: pulls weETH, burns nothing, mints WETH 1:1.
///         Requires being pre-funded with output tokens.
contract MockSwapRouter is ISwapRouter {
    uint256 public rate = 1e18; // 18-decimal rate: amountOut = amountIn * rate / 1e18

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate / 1e18;
        require(amountOut >= minAmountOut, "slippage");
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}
