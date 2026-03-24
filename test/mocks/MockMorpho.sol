// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../src/interfaces/IMorpho.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Morpho Blue — tracks collateral/debt per user, supports flashloan
/// @dev Uses shares = assets (1:1) for simplicity. Tracks totalBorrowShares alongside totalBorrowAssets
///      so that H-2 share→asset conversion works correctly.
contract MockMorpho is IMorpho {
    // Per-user position (simplified: one market)
    mapping(address => uint128) public collateralOf;
    mapping(address => uint256) public debtOf;

    // Total state
    uint128 public totalBorrowAssets;
    uint128 public totalBorrowShares;

    // Tokens
    address public loanToken;       // WETH
    address public collateralToken; // weETH

    constructor(address _loanToken, address _collateralToken) {
        loanToken = _loanToken;
        collateralToken = _collateralToken;
    }

    // ── Seed liquidity (for borrow/flashloan to work) ──
    function seedLiquidity(uint256 amount) external {
        IERC20(loanToken).transferFrom(msg.sender, address(this), amount);
    }

    function supplyCollateral(MarketParams memory, uint256 assets, address onBehalf, bytes memory)
        external
    {
        IERC20(collateralToken).transferFrom(msg.sender, address(this), assets);
        collateralOf[onBehalf] += uint128(assets);
    }

    function withdrawCollateral(MarketParams memory, uint256 assets, address onBehalf, address receiver)
        external
    {
        require(collateralOf[onBehalf] >= uint128(assets), "insufficient collateral");
        collateralOf[onBehalf] -= uint128(assets);
        IERC20(collateralToken).transfer(receiver, assets);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        debtOf[onBehalf] += assets;
        totalBorrowAssets += uint128(assets);
        totalBorrowShares += uint128(assets); // 1:1 shares = assets in mock
        IERC20(loanToken).transfer(receiver, assets);
        return (assets, assets); // simplified: shares = assets
    }

    function repay(MarketParams memory, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        // If assets is 0, use shares (1:1 in mock) to determine repay amount
        uint256 repayAmount = assets > 0 ? assets : shares;
        IERC20(loanToken).transferFrom(msg.sender, address(this), repayAmount);
        uint256 repaid = repayAmount > debtOf[onBehalf] ? debtOf[onBehalf] : repayAmount;
        debtOf[onBehalf] -= repaid;
        totalBorrowAssets -= uint128(repaid);
        totalBorrowShares -= uint128(repaid); // 1:1 shares = assets in mock
        return (repaid, repaid);
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        // Real Morpho: sends tokens, then pulls them back via transferFrom
        IERC20(token).transfer(msg.sender, assets);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        // Pull flash amount back (strategy must have approved or have balance)
        IERC20(token).transferFrom(msg.sender, address(this), assets);
    }

    /// @dev Test helper: directly set a user's debt
    function setDebt(address user, uint256 newDebt) external {
        uint256 oldDebt = debtOf[user];
        debtOf[user] = newDebt;
        if (newDebt > oldDebt) {
            uint128 diff = uint128(newDebt - oldDebt);
            totalBorrowAssets += diff;
            totalBorrowShares += diff;
        } else {
            uint128 diff = uint128(oldDebt - newDebt);
            totalBorrowAssets -= diff;
            totalBorrowShares -= diff;
        }
    }

    function position(Id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)
    {
        return (0, uint128(debtOf[user]), collateralOf[user]);
    }

    function market(Id)
        external
        view
        returns (uint128, uint128, uint128, uint128, uint128, uint128)
    {
        return (0, 0, totalBorrowAssets, totalBorrowShares, uint128(block.timestamp), 0);
    }
}
