// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IMorpho.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IChainlinkAggregator.sol";
import "./interfaces/ISwapRouter.sol";
import "./lib/MathLib.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title LoopStrategy — weETH/ETH leveraged looping engine (v2: DEX-only)
/// @notice All weETH acquisition via DEX swap (NOT EtherFi deposit).
///         All fund returns go to vault address (NOT msg.sender).
///         Uses Morpho flashloan (0 fee) for atomic leverage/deleverage.
contract LoopStrategy is IMorphoFlashLoanCallback, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using MathLib for *;
    using MarketParamsLib for MarketParams;

    // ── Immutables ──
    IMorpho public immutable morpho;
    IERC20 public immutable weeth;
    IWETH public immutable weth;
    IChainlinkAggregator public immutable priceFeed;
    ISwapRouter public immutable swapRouter;
    MarketParams public marketParams;
    Id public marketId;

    // ── Config ──
    uint256 public constant TARGET_LTV_BPS = 8500;  // 85%
    uint256 public constant MAX_LTV_BPS = 9000;     // 90%
    uint256 public constant DELEV_THRESH_BPS = 8500; // 85%
    uint256 public constant EMERG_LTV_BPS = 9200;    // 92%
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public swapSlippageBps = 100; // 1% default

    // ── Access ──
    address public vault;
    address public keeper;

    // ── Flashloan action enum ──
    enum FlashAction { LEVERAGE_UP, LEVERAGE_DOWN, EMERGENCY }

    // ── Events ──
    event LeverageUp(uint256 ethAmount, uint256 newCollateral, uint256 newDebt);
    event LeverageDown(uint256 ethReturned, uint256 newCollateral, uint256 newDebt);
    event EmergencyUnwind(uint256 debtRepaid, uint256 collateralWithdrawn);

    // ── Errors ──
    error OnlyVaultOrKeeper();
    error OnlyMorpho();

    modifier onlyVaultOrKeeper() {
        if (msg.sender != vault && msg.sender != keeper && msg.sender != owner()) {
            revert OnlyVaultOrKeeper();
        }
        _;
    }

    constructor(
        address _morpho,
        address _weeth,
        address _weth,
        address _priceFeed,
        address _swapRouter,
        MarketParams memory _marketParams
    ) Ownable(msg.sender) {
        morpho = IMorpho(_morpho);
        weeth = IERC20(_weeth);
        weth = IWETH(_weth);
        priceFeed = IChainlinkAggregator(_priceFeed);
        swapRouter = ISwapRouter(_swapRouter);
        marketParams = _marketParams;
        marketId = _marketParams.id();

        // Approvals
        IERC20(_weeth).approve(_morpho, type(uint256).max);
        IERC20(_weth).approve(_morpho, type(uint256).max);
        IERC20(_weth).approve(_swapRouter, type(uint256).max);
        IERC20(_weeth).approve(_swapRouter, type(uint256).max);
    }

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "zero vault");
        vault = _vault;
    }

    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "zero keeper");
        keeper = _keeper;
    }

    function setSwapSlippage(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "max 5%");
        swapSlippageBps = _bps;
    }

    // ══════════════════════════════════════════════
    // LEVERAGE UP — DEX swap (NOT EtherFi deposit)
    // ══════════════════════════════════════════════

    /// @notice Add WETH to the leveraged position. Swaps to weETH via DEX and loops.
    function leverageUp(uint256 ethAmount) external onlyVaultOrKeeper nonReentrant {
        if (ethAmount == 0) return;

        // 1. Receive WETH from vault
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), ethAmount);

        // 2. WETH → weETH via DEX swap (NOT EtherFi — no rate loss)
        uint256 peg = _getPeg();
        uint256 expectedWeeth = ethAmount * WAD / peg;
        uint256 minWeeth = expectedWeeth * (BPS - swapSlippageBps) / BPS;
        uint256 weethAmt = swapRouter.swap(address(weth), address(weeth), ethAmount, minWeeth);

        // 3. Supply weETH as collateral
        morpho.supplyCollateral(marketParams, weethAmt, address(this), "");

        // 4. Flash-loop to target LTV
        _leverageToTarget();

        (uint128 coll, uint256 debt) = _getPosition();
        emit LeverageUp(ethAmount, coll, debt);
    }

    /// @dev Iteratively flashloan to reach target LTV.
    function _leverageToTarget() internal {
        for (uint256 i = 0; i < 8; i++) {
            (uint128 coll, uint256 debt) = _getPosition();
            if (coll == 0) return;

            uint256 peg = _getPeg();
            uint256 additional = MathLib.calcLeverageAmount(coll, debt, peg, TARGET_LTV_BPS);
            if (additional < 0.001 ether) return;

            morpho.flashLoan(
                address(weth),
                additional,
                abi.encode(FlashAction.LEVERAGE_UP, additional)
            );
        }
    }

    // ══════════════════════════════════════════════
    // LEVERAGE DOWN — funds always go to VAULT
    // ══════════════════════════════════════════════

    /// @notice Remove ETH from the position. Proportional unwind. WETH sent to vault.
    function leverageDown(uint256 ethNeeded) external onlyVaultOrKeeper nonReentrant returns (uint256) {
        if (ethNeeded == 0) return 0;

        (uint128 coll, uint256 debt) = _getPosition();
        if (coll == 0) return 0;

        uint256 peg = _getPeg();
        (uint256 debtToRepay, uint256 collToWithdraw) =
            MathLib.calcUnwindAmount(coll, debt, peg, ethNeeded);

        if (debtToRepay == 0 && collToWithdraw == 0) return 0;

        uint256 balBefore = IERC20(address(weth)).balanceOf(address(this));
        morpho.flashLoan(
            address(weth),
            debtToRepay,
            abi.encode(FlashAction.LEVERAGE_DOWN, debtToRepay, collToWithdraw)
        );

        // Send WETH to VAULT (not msg.sender)
        uint256 ethOut = IERC20(address(weth)).balanceOf(address(this)) - balBefore;
        if (ethOut > 0) {
            IERC20(address(weth)).safeTransfer(vault, ethOut);
        }

        (coll, debt) = _getPosition();
        emit LeverageDown(ethOut, coll, debt);
        return ethOut;
    }

    // ══════════════════════════════════════════════
    // EMERGENCY UNWIND — funds always go to VAULT
    // ══════════════════════════════════════════════

    /// @notice Full unwind. All WETH sent to vault.
    function emergencyUnwind() external onlyVaultOrKeeper nonReentrant {
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        if (borrowShares == 0) return;

        (, uint256 debt) = _getPosition();
        uint256 flashAmount = debt + (debt / 100); // +1% buffer

        uint256 balBefore = IERC20(address(weth)).balanceOf(address(this));
        morpho.flashLoan(
            address(weth),
            flashAmount,
            abi.encode(FlashAction.EMERGENCY, uint256(borrowShares), uint256(coll))
        );

        // Send ALL WETH to VAULT (not msg.sender)
        uint256 bal = IERC20(address(weth)).balanceOf(address(this)) - balBefore;
        if (bal > 0) {
            IERC20(address(weth)).safeTransfer(vault, bal);
        }

        emit EmergencyUnwind(debt, coll);
    }

    // ══════════════════════════════════════════════
    // FLASHLOAN CALLBACK
    // ══════════════════════════════════════════════

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();

        FlashAction action = abi.decode(data, (FlashAction));

        if (action == FlashAction.LEVERAGE_UP) {
            _handleLeverageUp(assets);
        } else if (action == FlashAction.LEVERAGE_DOWN) {
            (, uint256 debtToRepay, uint256 collToWithdraw) =
                abi.decode(data, (FlashAction, uint256, uint256));
            _handleLeverageDown(debtToRepay, collToWithdraw);
        } else if (action == FlashAction.EMERGENCY) {
            (, uint256 borrowShares, uint256 totalColl) =
                abi.decode(data, (FlashAction, uint256, uint256));
            _handleEmergency(borrowShares, totalColl);
        }

        // Repay flashloan — Morpho pulls WETH back via transferFrom
    }

    /// @dev LEVERAGE_UP: WETH → DEX swap → weETH → supply → borrow WETH
    function _handleLeverageUp(uint256 flashedWETH) internal {
        // Swap WETH → weETH via DEX
        uint256 peg = _getPeg();
        uint256 expectedWeeth = flashedWETH * WAD / peg;
        uint256 minWeeth = expectedWeeth * (BPS - swapSlippageBps) / BPS;
        uint256 weethAmt = swapRouter.swap(address(weth), address(weeth), flashedWETH, minWeeth);

        // Supply weETH collateral
        morpho.supplyCollateral(marketParams, weethAmt, address(this), "");

        // Borrow WETH to repay flashloan
        morpho.borrow(marketParams, flashedWETH, 0, address(this), address(this));
    }

    /// @dev LEVERAGE_DOWN: repay debt → withdraw weETH → swap weETH→WETH via DEX
    function _handleLeverageDown(uint256 debtToRepay, uint256 collToWithdraw) internal {
        morpho.repay(marketParams, debtToRepay, 0, address(this), "");
        morpho.withdrawCollateral(marketParams, collToWithdraw, address(this), address(this));

        uint256 peg = _getPeg();
        uint256 fairValue = collToWithdraw * peg / WAD;
        uint256 minOut = fairValue * (BPS - swapSlippageBps) / BPS;
        swapRouter.swap(address(weeth), address(weth), collToWithdraw, minOut);
    }

    /// @dev EMERGENCY: repay all debt (by shares) → withdraw all → swap weETH→WETH
    function _handleEmergency(uint256 borrowShares, uint256 totalColl) internal {
        morpho.repay(marketParams, 0, borrowShares, address(this), "");
        morpho.withdrawCollateral(marketParams, totalColl, address(this), address(this));

        uint256 peg = _getPeg();
        uint256 fairValue = totalColl * peg / WAD;
        uint256 minOut = fairValue * (BPS - swapSlippageBps) / BPS;
        swapRouter.swap(address(weeth), address(weth), totalColl, minOut);
    }

    // ══════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════

    function getPosition() external view returns (uint256 collateral, uint256 debt) {
        (uint128 c, uint256 d) = _getPosition();
        return (uint256(c), d);
    }

    function getLTV() external view returns (uint256) {
        (uint128 coll, uint256 debt) = _getPosition();
        return MathLib.calcLTV(coll, debt, _getPeg());
    }

    function getPeg() public view returns (uint256) {
        return _getPeg();
    }

    function _getPosition() internal view returns (uint128 collateral, uint256 debt) {
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        if (borrowShares == 0) return (coll, 0);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
        if (totalBorrowShares == 0) return (coll, 0);
        debt = uint256(borrowShares) * uint256(totalBorrowAssets) / uint256(totalBorrowShares);
        return (coll, debt);
    }

    function _getPeg() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(block.timestamp - updatedAt < 86400, "oracle stale");
        require(answer > 0, "invalid price");
        return uint256(answer);
    }

    receive() external payable {}
}
