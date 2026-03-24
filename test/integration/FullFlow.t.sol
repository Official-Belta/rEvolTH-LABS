// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/LoopVault.sol";
import "../../src/LoopStrategy.sol";
import "../../src/KeeperModule.sol";
import "../../src/interfaces/IMorpho.sol";
import "../mocks/MockMorpho.sol";
import "../mocks/MockEtherFi.sol";
import "../mocks/MockWETH.sol";
import "../mocks/MockChainlink.sol";
import "../mocks/MockSwapRouter.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FullFlowTest is Test {
    LoopVault vault;
    LoopStrategy strategy;
    KeeperModule keeperModule;
    MockMorpho morpho;
    MockLiquidityPool liquidityPool;
    MockEETH eeth;
    MockWeETH weeth;
    MockWETH weth;
    MockChainlink chainlink;
    MockSwapRouter swapRouter;

    address owner = address(this);
    address keeper = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC0C0);

    function setUp() public {
        // Warp to a realistic timestamp so timing checks work
        vm.warp(1000000);

        // Deploy mocks
        eeth = new MockEETH();
        weeth = new MockWeETH(payable(address(eeth)));
        liquidityPool = new MockLiquidityPool(payable(address(eeth)));
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
            address(morpho), address(liquidityPool),
            address(eeth), address(weeth), address(weth), address(chainlink),
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
        // C-2: Set keeperModule as the vault's keeper
        vault.setKeeper(address(keeperModule));
        keeperModule.setWhitelisted(keeper, true);

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(keeper, 10 ether);
        vm.deal(address(keeperModule), 1 ether);
    }

    // ══════════════════════════════════════════════
    // Full deposit → keeper deploy → epoch advance → withdraw flow
    // ══════════════════════════════════════════════

    function test_fullFlow_singleUser() public {
        // Alice deposits 10 ETH, but we need another large depositor
        // so Alice's withdrawal doesn't exceed 20% epoch cap
        vm.prank(alice);
        uint256 aliceShares = vault.depositETH{value: 10 ether}();

        // Large background depositor to keep Alice under 20%
        vm.prank(bob);
        vault.depositETH{value: 50 ether}();

        assertGt(aliceShares, 0, "should get shares");

        // 2. Keeper deploys idle to strategy
        vm.prank(keeper);
        keeperModule.deployIdle();
        (uint256 coll,) = strategy.getPosition();
        assertGt(coll, 0, "strategy should have position");

        // 3. Advance epoch
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();
        assertEq(vault.epochId(), 2);

        // 4. Alice requests withdrawal (~16.7% of total, under 20% cap)
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        assertEq(vault.balanceOf(alice), 0, "shares locked");

        // 5. Advance another epoch
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();
        assertEq(vault.epochId(), 3);

        // 6. Alice completes withdrawal
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.completeWithdraw();
        uint256 received = alice.balance - balBefore;
        assertGt(received, 5 ether, "should get back meaningful ETH");
    }

    // ══════════════════════════════════════════════
    // Multiple users deposit, partial withdrawals
    // ══════════════════════════════════════════════

    function test_multiUser_partialWithdraw() public {
        // Alice deposits 10 ETH, Bob deposits 40 ETH
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        vm.prank(bob);
        uint256 bobShares = vault.depositETH{value: 40 ether}();

        assertEq(vault.idleAssets(), 50 ether);

        // 2. Keeper deploys idle
        vm.prank(keeper);
        keeperModule.deployIdle();

        // 3. Advance epoch
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        // 4. Bob requests partial withdrawal (5% of total supply = 2.5 ETH worth)
        //    Bob has 80% of shares. We request 6.25% of bob's shares = 5% of total.
        uint256 bobPartial = bobShares * 5 / 80; // ~5% of total supply
        vm.roll(block.number + 1);
        vm.prank(bob);
        vault.requestWithdraw(bobPartial);

        // Bob still has remaining shares
        assertEq(vault.balanceOf(bob), bobShares - bobPartial);

        // 5. Advance epoch and complete
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        vault.completeWithdraw();
        uint256 bobReceived = bob.balance - bobBalBefore;
        assertGt(bobReceived, 1 ether, "Bob should get some ETH back");

        // Alice's shares are untouched
        assertGt(vault.balanceOf(alice), 0);
    }

    // ══════════════════════════════════════════════
    // Epoch cap enforcement across users
    // ══════════════════════════════════════════════

    function test_epochCap_acrossUsers() public {
        // Alice 10 ETH, Bob 10 ETH, Charlie 10 ETH — each has 33.3%
        vm.prank(alice);
        uint256 aliceShares = vault.depositETH{value: 10 ether}();

        vm.prank(bob);
        uint256 bobShares = vault.depositETH{value: 10 ether}();

        vm.prank(charlie);
        uint256 charlieShares = vault.depositETH{value: 10 ether}();

        // Advance to next block for withdraw
        vm.roll(block.number + 1);

        // Alice withdraws ~5% of total (15% of her shares)
        uint256 alicePartial = aliceShares * 15 / 100;
        vm.prank(alice);
        vault.requestWithdraw(alicePartial);

        // Bob tries to withdraw all (33%) — should push past 20% cap
        vm.prank(bob);
        vm.expectRevert(LoopVault.EpochCapExceeded.selector);
        vault.requestWithdraw(bobShares);

        // Bob tries smaller amount (~5% of total)
        uint256 bobPartial = bobShares * 15 / 100;
        vm.prank(bob);
        vault.requestWithdraw(bobPartial);

        // Charlie tries ~5% of total
        uint256 charliePartial = charlieShares * 15 / 100;
        vm.prank(charlie);
        vault.requestWithdraw(charliePartial);

        // More withdrawals should fail since we're near cap (~15% used)
        // Charlie already has a pending request
        uint256 charlieMore = charlieShares * 30 / 100;
        vm.prank(charlie);
        vm.expectRevert("pending request");
        vault.requestWithdraw(charlieMore);
    }

    // ══════════════════════════════════════════════
    // Keeper deploy → rebalance flow
    // ══════════════════════════════════════════════

    function test_keeperDeploy_thenRebalance() public {
        // 1. Deposit and deploy
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        vm.prank(keeper);
        keeperModule.deployIdle();

        // 2. Verify position exists
        (uint256 coll, uint256 debt) = strategy.getPosition();
        assertGt(coll, 0);
        assertGt(debt, 0);

        // 3. Rebalance should be no-op when LTV is safe
        vm.prank(keeper);
        vm.expectRevert(KeeperModule.NoActionNeeded.selector);
        keeperModule.rebalance();
    }

    // ══════════════════════════════════════════════
    // Multiple epoch cycle
    // ══════════════════════════════════════════════

    function test_multipleEpochCycle() public {
        // Deposit with multiple users so withdrawal stays under cap
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        vm.prank(bob);
        vault.depositETH{value: 50 ether}();

        vm.prank(keeper);
        keeperModule.deployIdle();

        // Cycle through 3 epochs
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 7 days + 1);
            chainlink.setPrice(1e18);
            vm.prank(keeper);
            keeperModule.advanceEpochIfNeeded();
        }

        assertEq(vault.epochId(), 4); // started at 1, advanced 3 times

        // Alice can still withdraw after multiple epochs (~16.7% of total, under 20% cap)
        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        // Use keeper to advance epoch (C-2 access control)
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.completeWithdraw();
        assertGt(alice.balance - balBefore, 5 ether, "should get back meaningful ETH");
    }

    // ══════════════════════════════════════════════
    // Second deposit after deployment
    // ══════════════════════════════════════════════

    function test_depositAfterDeploy() public {
        // First deposit and deploy
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vm.prank(keeper);
        keeperModule.deployIdle();

        // Advance epoch (to update snapshot)
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        // Bob deposits after strategy is active
        vm.prank(bob);
        uint256 bobShares = vault.depositETH{value: 10 ether}();
        assertGt(bobShares, 0, "Bob should get shares");

        // Deploy Bob's idle
        vm.prank(keeper);
        keeperModule.deployIdle();

        // Strategy position should be larger now
        (uint256 coll,) = strategy.getPosition();
        assertGt(coll, 10 ether, "position should include Bob's deposit");
    }
}
