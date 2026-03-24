// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Generic DEX swap router interface (weETH <-> WETH swaps)
interface ISwapRouter {
    /// @notice Swap exact input tokens for output tokens
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    /// @param amountIn Amount of input tokens
    /// @param minAmountOut Minimum acceptable output (slippage protection)
    /// @return amountOut Actual output amount received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);
}
