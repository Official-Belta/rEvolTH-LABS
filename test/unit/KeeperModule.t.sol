// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/KeeperModule.sol";
import "../../src/LoopVault.sol";
import "../../src/LoopStrategy.sol";
import "../../src/interfaces/IMorpho.sol";
import "../mocks/MockMorpho.sol";
import "../mocks/MockEtherFi.sol";
import "../mocks/MockWETH.sol";
import "../mocks/MockChainlink.sol";
import "../mocks/MockSwapRouter.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KeeperModuleTest is Test {
    KeeperModule keeperModule;
    LoopVault vault;
    LoopStrategy strategy;
    MockMorpho morpho;
    MockWeETH weeth;
    MockWETH weth;
    MockChainlink chainlink;
    MockSwapRouter swapRouter;

    address owner = address(this);
    address keeper = address(0xCAFE);
    address alice = address(0xA11CE);
    address rando = address(0xDEAD);

    function setUp() public {
        // Warp to a realistic timestamp
        vm.warp(1000000);

        // Deploy mocks
        MockEETH eeth = new MockEETH();
        weeth = new MockWeETH(payable(address(eeth)));
        weth = new MockWETH();
        morpho = new MockMorpho(address(weth), address(weeth));
        chainlink = new MockChainlink();
        swapRouter = new MockSwapRouter();

        // Seed Morpho liquidity
        vm.deal(address(this), 10000 ether);
        weth.deposit{value: 10000 ether}();
        weth.approve(address(morpho), type(uint256).max);
        morpho.seedLiquidity(10000 ether);

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
            address(morpho), address(weeth), address(weth), address(chainlink),
            address(swapRouter), mp
        );

        // Deploy vault via proxy
        LoopVault vaultImpl = new LoopVault();
        bytes memory initData = abi.encodeCall(
            LoopVault.initialize,
            (address(weth), address(strategy), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = LoopVault(payable(address(proxy)));

        // Deploy keeper module
        keeperModule = new KeeperModule(address(vault), address(strategy), owner);

        // Wire up
        strategy.setVault(address(vault));
        strategy.setKeeper(address(keeperModule));
        // C-2: Set keeperModule as the vault's keeper so it can call advanceEpoch/deployIdle
        vault.setKeeper(address(keeperModule));
        keeperModule.setWhitelisted(keeper, true);

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(keeper, 10 ether);

        // Fund keeper module for tips
        vm.deal(address(keeperModule), 1 ether);
    }

    // ─── Helpers ───

    function _depositAsAlice(uint256 ethAmt) internal returns (uint256 shares) {
        vm.prank(alice);
        shares = vault.depositETH{value: ethAmt}();
    }

    function _deployIdleViaVault() internal {
        // Owner can call deployIdle (onlyKeeper allows owner)
        vault.deployIdle();
    }

    function _createLeveragedPosition() internal {
        _depositAsAlice(10 ether);
        _deployIdleViaVault();
    }

    // ─── Rebalance: safe LTV (no-op) ───

    function test_rebalance_safeLTV_reverts() public {
        _createLeveragedPosition();

        // LTV should be ~80-85%, which is below deleverage threshold
        uint256 ltv = strategy.getLTV();
        // The position should have been leveraged to ~80.75% (target 85% with 5% margin)
        // This is below the 85% deleverage threshold

        vm.prank(keeper);
        vm.expectRevert(KeeperModule.NoActionNeeded.selector);
        keeperModule.rebalance();
    }

    // ─── Rebalance: deleverage trigger ───

    function test_rebalance_deleverageTrigger() public {
        _createLeveragedPosition();

        // Artificially inflate debt to push LTV above 85%
        (uint256 coll, uint256 debt) = strategy.getPosition();
        uint256 targetDebt = coll * 88 / 100; // 88% LTV
        morpho.setDebt(address(strategy), targetDebt);

        uint256 ltv = strategy.getLTV();
        assertGe(ltv, 0.85e18, "LTV should be above 85%");

        (uint256 collBefore,) = strategy.getPosition();

        vm.prank(keeper);
        keeperModule.rebalance();

        // Position should have changed (deleverage action taken)
        (uint256 collAfter, uint256 debtAfter) = strategy.getPosition();
        assertLt(collAfter, collBefore, "collateral should decrease after deleverage");
    }

    // ─── Rebalance: emergency trigger ───

    function test_rebalance_emergencyTrigger() public {
        _createLeveragedPosition();

        (uint256 coll,) = strategy.getPosition();
        uint256 emergDebt = coll * 93 / 100; // 93% LTV
        morpho.setDebt(address(strategy), emergDebt);

        uint256 ltv = strategy.getLTV();
        assertGe(ltv, 0.92e18, "LTV should be above 92%");

        vm.prank(keeper);
        keeperModule.rebalance();

        // Position should be fully unwound
        (, uint256 newDebt) = strategy.getPosition();
        assertEq(newDebt, 0, "debt should be 0 after emergency");
    }

    // ─── Epoch advance ───

    function test_advanceEpochIfNeeded() public {
        _depositAsAlice(10 ether);

        // Warp past epoch duration
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);

        uint256 epochBefore = vault.epochId();
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        assertEq(vault.epochId(), epochBefore + 1, "epoch should advance");
    }

    function test_advanceEpochIfNeeded_tooEarly() public {
        _depositAsAlice(10 ether);

        vm.prank(keeper);
        vm.expectRevert(KeeperModule.NoActionNeeded.selector);
        keeperModule.advanceEpochIfNeeded();
    }

    // ─── Deploy idle ───

    function test_deployIdle_trigger() public {
        // Deposit enough that idle > 10%
        _depositAsAlice(10 ether);

        // All assets are idle (100%), so should trigger
        uint256 idleBefore = vault.idleAssets();
        vm.prank(keeper);
        keeperModule.deployIdle();

        assertLt(vault.idleAssets(), idleBefore, "idle should decrease");
    }

    function test_deployIdle_noActionWhenLow() public {
        _depositAsAlice(10 ether);
        _deployIdleViaVault(); // Deploy first so idle is at target

        vm.prank(keeper);
        vm.expectRevert(KeeperModule.NoActionNeeded.selector);
        keeperModule.deployIdle();
    }

    // ─── Access control ───

    function test_rebalance_notWhitelisted() public {
        _createLeveragedPosition();

        vm.prank(rando);
        vm.expectRevert(KeeperModule.NotWhitelisted.selector);
        keeperModule.rebalance();
    }

    function test_deployIdle_notWhitelisted() public {
        _depositAsAlice(10 ether);

        vm.prank(rando);
        vm.expectRevert(KeeperModule.NotWhitelisted.selector);
        keeperModule.deployIdle();
    }

    function test_advanceEpoch_notWhitelisted() public {
        vm.prank(rando);
        vm.expectRevert(KeeperModule.NotWhitelisted.selector);
        keeperModule.advanceEpochIfNeeded();
    }

    function test_deloopForSpread_notWhitelisted() public {
        vm.prank(rando);
        vm.expectRevert(KeeperModule.NotWhitelisted.selector);
        keeperModule.deloopForSpread(1 ether);
    }

    function test_setWhitelisted_onlyOwner() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        keeperModule.setWhitelisted(rando, true);
    }

    function test_ownerIsAlwaysWhitelisted() public {
        _createLeveragedPosition();

        // Owner can call even without explicit whitelist
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        keeperModule.advanceEpochIfNeeded(); // should not revert
    }

    // ─── Min gap enforcement ───

    function test_rebalance_minGap() public {
        _createLeveragedPosition();

        // Push LTV above 85%
        (uint256 coll,) = strategy.getPosition();
        morpho.setDebt(address(strategy), coll * 88 / 100);

        // First rebalance
        vm.prank(keeper);
        keeperModule.rebalance();

        // Push LTV high again
        (coll,) = strategy.getPosition();
        if (coll > 0) {
            morpho.setDebt(address(strategy), coll * 88 / 100);
        }

        // Second rebalance too soon
        vm.prank(keeper);
        vm.expectRevert(KeeperModule.RebalanceTooSoon.selector);
        keeperModule.rebalance();

        // After gap, should work
        vm.warp(block.timestamp + 1 hours + 1);
        chainlink.setPrice(1e18);
        if (coll > 0) {
            uint256 ltv = strategy.getLTV();
            if (ltv >= 0.85e18) {
                vm.prank(keeper);
                keeperModule.rebalance();
            }
        }
    }

    // ─── DeloopForSpread ───

    function test_deloopForSpread() public {
        _createLeveragedPosition();

        (uint256 collBefore, uint256 debtBefore) = strategy.getPosition();

        vm.prank(keeper);
        keeperModule.deloopForSpread(1 ether);

        (uint256 collAfter, uint256 debtAfter) = strategy.getPosition();
        assertLt(collAfter, collBefore, "collateral should decrease");
        assertLt(debtAfter, debtBefore, "debt should decrease");
    }

    // ─── Tip payment ───

    function test_tipPaid() public {
        _depositAsAlice(10 ether);

        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);

        uint256 keeperBalBefore = keeper.balance;
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        assertEq(keeper.balance - keeperBalBefore, 0.01 ether, "keeper should receive tip");
    }

    function test_noTipWhenModuleEmpty() public {
        // Deploy a new keeper module with no ETH
        KeeperModule emptyModule = new KeeperModule(address(vault), address(strategy), owner);
        emptyModule.setWhitelisted(keeper, true);
        strategy.setKeeper(address(emptyModule));
        // Also register emptyModule as vault keeper
        vault.setKeeper(address(emptyModule));

        _depositAsAlice(10 ether);
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);

        // Should still succeed, just no tip
        vm.prank(keeper);
        emptyModule.advanceEpochIfNeeded();
        assertEq(vault.epochId(), 2);
    }

    // ─── Rebalance no position ───

    function test_rebalance_noPosition() public {
        // No position at all
        vm.prank(keeper);
        vm.expectRevert(KeeperModule.NoActionNeeded.selector);
        keeperModule.rebalance();
    }
}
