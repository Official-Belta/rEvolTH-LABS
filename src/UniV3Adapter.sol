// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniV3Adapter — Wraps Uniswap V3 behind ISwapRouter interface
/// @notice Used for weETH <-> WETH swaps via the 0.01% fee tier pool
contract UniV3Adapter is ISwapRouter {
    using SafeERC20 for IERC20;

    IUniswapV3Router public constant UNI_ROUTER = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(UNI_ROUTER), amountIn);
        amountOut = UNI_ROUTER.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 100,
            recipient: msg.sender,
            deadline: block.timestamp + 120, // 2분 내 실행 강제 (MEV 방어)
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        }));
    }
}
