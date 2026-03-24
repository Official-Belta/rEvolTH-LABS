// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IMorpho.sol";
import "./interfaces/IEtherFi.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IChainlinkAggregator.sol";
import "./interfaces/ISwapRouter.sol";
import "./lib/MathLib.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title LoopStrategy — weETH/ETH leveraged looping engine
/// @notice Handles all Morpho + EtherFi interactions.
///         Vault deposits ETH → Strategy loops it into leveraged weETH position.
///         Uses Morpho flashloan (0 fee) for atomic leverage/deleverage.
/// @dev H-3: ReentrancyGuard on all external mutative functions prevents cross-contract reentrancy.
///      H-5: OZ 5.x ReentrancyGuard uses transient storage (Cancun EVM) — no persistent storage.
/// @dev L-1: Inherits Ownable for proper ownership transfer support.
contract LoopStrategy is IMorphoFlashLoanCallback, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using MathLib for *;
    using MarketParamsLib for MarketParams;

    // ── Immutables ──
    IMorpho public immutable morpho;
    ILiquidityPool public immutable liquidityPool; // ETH → eETH
    IeETH public immutable eeth;
    IWeETH public immutable weeth;
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

    // ── Slippage Config ──
    uint256 public swapSlippageBps = 100; // 1% default (100 bps)

    function setSwapSlippage(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "max 5%"); // safety cap
        swapSlippageBps = _bps;
    }

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
    error InsufficientOutput();

    modifier onlyVaultOrKeeper() {
        if (msg.sender != vault && msg.sender != keeper && msg.sender != owner()) {
            revert OnlyVaultOrKeeper();
        }
        _;
    }

    constructor(
        address _morpho,
        address _liquidityPool,
        address _eeth,
        address _weeth,
        address _weth,
        address _priceFeed,
        address _swapRouter,
        MarketParams memory _marketParams
    ) Ownable(msg.sender) {
        morpho = IMorpho(_morpho);
        liquidityPool = ILiquidityPool(_liquidityPool);
        eeth = IeETH(_eeth);
        weeth = IWeETH(_weeth);
        weth = IWETH(_weth);
        priceFeed = IChainlinkAggregator(_priceFeed);
        swapRouter = ISwapRouter(_swapRouter);
        marketParams = _marketParams;
        marketId = _marketParams.id();

        // Approvals
        IERC20(_weeth).approve(_morpho, type(uint256).max);
        IERC20(_weth).approve(_morpho, type(uint256).max);
        IERC20(_weeth).approve(_swapRouter, type(uint256).max);
        eeth.approve(_weeth, type(uint256).max);
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    // ══════════════════════════════════════════════
    // LEVERAGE UP
    // ══════════════════════════════════════════════

    /// @notice Add ETH to the leveraged position. Wraps to weETH and loops to TARGET_LTV.
    /// @param ethAmount Amount of ETH (as WETH) to add
    /// @dev H-3: nonReentrant guard prevents cross-contract reentrancy
    function leverageUp(uint256 ethAmount) external onlyVaultOrKeeper nonReentrant {
        if (ethAmount == 0) return;

        // 1. Receive WETH from vault, unwrap to ETH
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), ethAmount);
        weth.withdraw(ethAmount);

        // 2. ETH → eETH → weETH
        uint256 eethAmt = liquidityPool.deposit{value: ethAmount}();
        uint256 weethAmt = weeth.wrap(eethAmt);

        // 3. Supply weETH as collateral
        morpho.supplyCollateral(marketParams, weethAmt, address(this), "");

        // 4. Flash-loop to target LTV
        _leverageToTarget();

        (uint128 coll, uint256 debt) = _getPosition();
        emit LeverageUp(ethAmount, coll, debt);
    }

    /// @dev Iteratively flashloan to reach target LTV. Each round adds collateral
    ///      and borrows more, increasing capacity for the next round.
    function _leverageToTarget() internal {
        for (uint256 i = 0; i < 8; i++) { // max 8 iterations (converges fast)
            (uint128 coll, uint256 debt) = _getPosition();
            if (coll == 0) return;

            uint256 peg = _getPeg();
            uint256 additional = MathLib.calcLeverageAmount(coll, debt, peg, TARGET_LTV_BPS);
            if (additional < 0.001 ether) return; // close enough to target

            morpho.flashLoan(
                address(weth),
                additional,
                abi.encode(FlashAction.LEVERAGE_UP, additional)
            );
        }
    }

    // ══════════════════════════════════════════════
    // LEVERAGE DOWN
    // ══════════════════════════════════════════════

    /// @notice Remove ETH from the position. Proportional unwind.
    /// @param ethNeeded Amount of ETH to extract
    /// @return ethOut Actual ETH returned (as WETH)
    /// @dev H-3: nonReentrant guard prevents cross-contract reentrancy
    function leverageDown(uint256 ethNeeded) external onlyVaultOrKeeper nonReentrant returns (uint256) {
        if (ethNeeded == 0) return 0;

        (uint128 coll, uint256 debt) = _getPosition();
        if (coll == 0) return 0;

        uint256 peg = _getPeg();
        (uint256 debtToRepay, uint256 collToWithdraw) =
            MathLib.calcUnwindAmount(coll, debt, peg, ethNeeded);

        if (debtToRepay == 0 && collToWithdraw == 0) return 0;

        // Flashloan WETH to repay debt, then withdraw collateral, swap weETH→WETH, repay flash
        uint256 balBefore = IERC20(address(weth)).balanceOf(address(this));
        morpho.flashLoan(
            address(weth),
            debtToRepay,
            abi.encode(FlashAction.LEVERAGE_DOWN, debtToRepay, collToWithdraw)
        );

        // Send resulting WETH back to caller
        uint256 ethOut = IERC20(address(weth)).balanceOf(address(this)) - balBefore;
        if (ethOut > 0) {
            IERC20(address(weth)).safeTransfer(msg.sender, ethOut);
        }

        (coll, debt) = _getPosition();
        emit LeverageDown(ethOut, coll, debt);
        return ethOut;
    }

    // ══════════════════════════════════════════════
    // EMERGENCY UNWIND
    // ══════════════════════════════════════════════

    /// @notice Full unwind — repay all debt, withdraw all collateral.
    /// @dev M-4: Single _getPosition call instead of double call.
    /// @dev H-3: nonReentrant guard prevents cross-contract reentrancy.
    function emergencyUnwind() external onlyVaultOrKeeper nonReentrant {
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        if (borrowShares == 0) return;

        // Get debt assets (with buffer for interest accrual during flashloan)
        (, uint256 debt) = _getPosition();
        uint256 flashAmount = debt + (debt / 100); // +1% buffer for interest accrual

        uint256 balBefore = IERC20(address(weth)).balanceOf(address(this));
        morpho.flashLoan(
            address(weth),
            flashAmount,
            abi.encode(FlashAction.EMERGENCY, uint256(borrowShares), uint256(coll))
        );

        // Send resulting WETH back to caller (only net received, not stray balance)
        uint256 bal = IERC20(address(weth)).balanceOf(address(this)) - balBefore;
        if (bal > 0) {
            IERC20(address(weth)).safeTransfer(msg.sender, bal);
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
            _handleLeverageDown(assets, debtToRepay, collToWithdraw);
        } else if (action == FlashAction.EMERGENCY) {
            (, uint256 totalDebt, uint256 totalColl) =
                abi.decode(data, (FlashAction, uint256, uint256));
            _handleEmergency(assets, totalDebt, totalColl);
        }

        // Repay flashloan — Morpho pulls WETH back via transferFrom
        // (approval set in constructor to max)
    }

    /// @dev LEVERAGE_UP: WETH → unwrap → ETH → eETH → weETH → supply → borrow WETH
    function _handleLeverageUp(uint256 flashedWETH) internal {
        // Unwrap WETH → ETH
        weth.withdraw(flashedWETH);

        // ETH → eETH → weETH
        uint256 eethAmt = liquidityPool.deposit{value: flashedWETH}();
        uint256 weethAmt = weeth.wrap(eethAmt);

        // Supply weETH collateral
        morpho.supplyCollateral(marketParams, weethAmt, address(this), "");

        // Borrow WETH to repay flashloan
        morpho.borrow(marketParams, flashedWETH, 0, address(this), address(this));
    }

    /// @dev LEVERAGE_DOWN: repay debt → withdraw weETH → swap weETH→WETH via DEX
    function _handleLeverageDown(uint256 flashedWETH, uint256 debtToRepay, uint256 collToWithdraw)
        internal
    {
        // Repay Morpho debt with flashed WETH
        morpho.repay(marketParams, debtToRepay, 0, address(this), "");

        // Withdraw weETH collateral
        morpho.withdrawCollateral(marketParams, collToWithdraw, address(this), address(this));

        // Swap weETH → WETH via DEX router
        // minOut = weETH amount × oracle peg × 97% (3% slippage tolerance)
        uint256 peg = _getPeg();
        uint256 fairValue = collToWithdraw * peg / WAD;
        uint256 minOut = fairValue * (BPS - swapSlippageBps) / BPS;
        swapRouter.swap(address(weeth), address(weth), collToWithdraw, minOut);
    }

    /// @dev EMERGENCY: repay all debt (by shares) → withdraw all collateral → swap weETH→WETH via DEX
    function _handleEmergency(uint256 flashedWETH, uint256 borrowShares, uint256 totalColl) internal {
        // Repay all debt by shares (ensures full repayment even with interest accrual)
        morpho.repay(marketParams, 0, borrowShares, address(this), "");

        // Withdraw all collateral
        morpho.withdrawCollateral(marketParams, totalColl, address(this), address(this));

        // Swap weETH → WETH via DEX router
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

    /// @dev H-2: Converts borrow shares to borrow assets using Morpho's market state.
    ///      In Morpho Blue, position() returns borrowShares, not borrowAssets.
    ///      Must convert: debtAssets = borrowShares * totalBorrowAssets / totalBorrowShares
    function _getPosition() internal view returns (uint128 collateral, uint256 debt) {
        (, uint128 borrowShares, uint128 coll) = morpho.position(marketId, address(this));
        if (borrowShares == 0) return (coll, 0);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
        if (totalBorrowShares == 0) return (coll, 0);
        debt = uint256(borrowShares) * uint256(totalBorrowAssets) / uint256(totalBorrowShares);
        return (coll, debt);
    }

    /// @notice Public accessor for the weETH/ETH peg from Chainlink oracle
    function getPeg() public view returns (uint256) {
        return _getPeg();
    }

    /// @dev Get weETH/ETH peg from Chainlink oracle with stale + validity checks.
    ///      Chainlink weETH/ETH feed returns 18 decimals.
    function _getPeg() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(block.timestamp - updatedAt < 86400, "oracle stale"); // 24h — matches Chainlink heartbeat
        require(answer > 0, "invalid price");
        return uint256(answer);  // Chainlink weETH/ETH has 18 decimals
    }

    // ── Receive ETH (needed for WETH.withdraw and EtherFi deposit) ──
    receive() external payable {}
}
