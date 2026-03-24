// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/LoopStrategy.sol";
import "../../src/interfaces/IMorpho.sol";
import "../../src/lib/MathLib.sol";
import "../mocks/MockMorpho.sol";
import "../mocks/MockEtherFi.sol";
import "../mocks/MockWETH.sol";
import "../mocks/MockChainlink.sol";
import "../mocks/MockSwapRouter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LoopStrategyTest is Test {
    LoopStrategy strategy;
    MockMorpho morpho;
    MockWeETH weeth;
    MockWETH weth;
    MockChainlink chainlink;
    MockSwapRouter swapRouter;

    address vault = address(0xBEEF);
    address keeper = address(0xCAFE);

    function setUp() public {
        // Deploy mocks
        MockEETH eeth = new MockEETH();
        weeth = new MockWeETH(payable(address(eeth)));
        weth = new MockWETH();

        morpho = new MockMorpho(address(weth), address(weeth));
        chainlink = new MockChainlink();
        swapRouter = new MockSwapRouter();

        // Seed Morpho with WETH liquidity (for borrow/flashloan)
        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 1000 ether}();
        weth.approve(address(morpho), type(uint256).max);
        morpho.seedLiquidity(1000 ether);

        // Fund swap router with WETH for weETH→WETH swaps
        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 1000 ether}();
        weth.transfer(address(swapRouter), 1000 ether);

        // Fund swap router with weETH for WETH→weETH swaps
        weeth.mint(address(swapRouter), 1000 ether);

        // Market params
        MarketParams memory mp = MarketParams({
            loanToken: address(weth),
            collateralToken: address(weeth),
            oracle: address(0),
            irm: address(0),
            lltv: 0.9e18
        });

        // Deploy strategy
        strategy = new LoopStrategy(
            address(morpho),
            address(weeth),
            address(weth),
            address(chainlink),
            address(swapRouter),
            mp
        );
        strategy.setVault(vault);
        strategy.setKeeper(keeper);
    }

    // ─── Helpers ───

    function _depositAndLeverage(uint256 ethAmount) internal {
        vm.deal(vault, ethAmount);
        vm.startPrank(vault);
        weth.deposit{value: ethAmount}();
        weth.approve(address(strategy), ethAmount);
        strategy.leverageUp(ethAmount);
        vm.stopPrank();
    }

    // ─── leverageUp ───

    function test_leverageUp_createsPosition() public {
        _depositAndLeverage(10 ether);

        (uint256 coll, uint256 debt) = strategy.getPosition();
        assertGt(coll, 10 ether, "collateral should exceed deposit (leveraged)");
        assertGt(debt, 0, "should have borrowed");

        uint256 ltv = strategy.getLTV();
        // LTV should be close to target (85%) but with 5% margin → ~80.75%
        assertGt(ltv, 0.70e18, "LTV too low");
        assertLt(ltv, 0.86e18, "LTV too high");
    }

    function test_leverageUp_correctLeverageRatio() public {
        _depositAndLeverage(10 ether);

        (uint256 coll, uint256 debt) = strategy.getPosition();
        // With 85% target LTV, leverage ≈ 1/(1-0.8075) ≈ 5.2x (with safety margin)
        // Collateral should be ~3-5x deposit
        uint256 leverage = coll * 1e18 / 10 ether;
        assertGt(leverage, 2.5e18, "leverage too low");
        assertLt(leverage, 7e18, "leverage too high");

        // Equity should be close to original deposit
        uint256 equity = coll - debt; // at peg 1:1
        assertApproxEqRel(equity, 10 ether, 0.05e18); // within 5%
    }

    function test_leverageUp_incrementalDeposit() public {
        // First deposit
        _depositAndLeverage(10 ether);
        (uint256 coll1, uint256 debt1) = strategy.getPosition();

        // Second deposit — should ADD to position, not recreate
        _depositAndLeverage(5 ether);
        (uint256 coll2, uint256 debt2) = strategy.getPosition();

        assertGt(coll2, coll1, "collateral should increase");
        assertGt(debt2, debt1, "debt should increase");
    }

    function test_leverageUp_zeroAmount() public {
        vm.prank(vault);
        strategy.leverageUp(0); // should not revert
        (uint256 coll, uint256 debt) = strategy.getPosition();
        assertEq(coll, 0);
        assertEq(debt, 0);
    }

    function test_leverageUp_onlyVaultOrKeeper() public {
        address rando = address(0xDEAD);
        vm.deal(rando, 10 ether);
        vm.startPrank(rando);
        weth.deposit{value: 10 ether}();
        weth.approve(address(strategy), 10 ether);
        vm.expectRevert(LoopStrategy.OnlyVaultOrKeeper.selector);
        strategy.leverageUp(10 ether);
        vm.stopPrank();
    }

    // ─── leverageDown ───

    function test_leverageDown_partial() public {
        _depositAndLeverage(10 ether);
        (uint256 collBefore, uint256 debtBefore) = strategy.getPosition();

        // Withdraw 2 ETH worth of equity
        vm.prank(vault);
        uint256 ethOut = strategy.leverageDown(2 ether);

        (uint256 collAfter, uint256 debtAfter) = strategy.getPosition();
        assertLt(collAfter, collBefore, "collateral should decrease");
        assertLt(debtAfter, debtBefore, "debt should decrease");

        // Equity should decrease by ~2 ETH
        uint256 equityBefore = collBefore - debtBefore;
        uint256 equityAfter = collAfter - debtAfter;
        assertApproxEqRel(equityBefore - equityAfter, 2 ether, 0.15e18);
    }

    function test_leverageDown_returnsWETH() public {
        _depositAndLeverage(10 ether);

        uint256 balBefore = weth.balanceOf(vault);
        vm.prank(vault);
        uint256 ethOut = strategy.leverageDown(2 ether);

        uint256 balAfter = weth.balanceOf(vault);
        assertGt(balAfter, balBefore, "vault should receive WETH");
    }

    // ─── emergencyUnwind ───

    function test_emergencyUnwind_clearsPosition() public {
        _depositAndLeverage(10 ether);
        (, uint256 debtBefore) = strategy.getPosition();
        assertGt(debtBefore, 0);

        vm.prank(vault);
        strategy.emergencyUnwind();

        (, uint256 debtAfter) = strategy.getPosition();
        assertEq(debtAfter, 0, "debt should be zero after emergency");
    }

    function test_emergencyUnwind_returnsWETH() public {
        _depositAndLeverage(10 ether);

        uint256 balBefore = weth.balanceOf(vault);
        vm.prank(vault);
        strategy.emergencyUnwind();

        uint256 balAfter = weth.balanceOf(vault);
        // Should get back roughly the original equity (minus slippage/fees)
        assertGt(balAfter - balBefore, 0, "should return WETH");
    }

    function test_emergencyUnwind_noPosition() public {
        vm.prank(vault);
        strategy.emergencyUnwind(); // should not revert
    }

    // ─── getLTV ───

    function test_getLTV_afterLeverage() public {
        _depositAndLeverage(10 ether);
        uint256 ltv = strategy.getLTV();
        assertGt(ltv, 0);
        assertLt(ltv, 0.9e18);
    }

    function test_getLTV_noPosition() public view {
        uint256 ltv = strategy.getLTV();
        assertEq(ltv, type(uint256).max); // no collateral
    }

    // ─── Access control (L-1: Ownable) ───

    function test_setVault_onlyOwner() public {
        address rando = address(0xDEAD);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        strategy.setVault(rando);
    }

    function test_setKeeper_onlyOwner() public {
        address rando = address(0xDEAD);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        strategy.setKeeper(rando);
    }
}
