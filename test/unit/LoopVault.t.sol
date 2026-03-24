// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/LoopVault.sol";
import "../../src/LoopStrategy.sol";
import "../../src/interfaces/IMorpho.sol";
import "../mocks/MockMorpho.sol";
import "../mocks/MockEtherFi.sol";
import "../mocks/MockWETH.sol";
import "../mocks/MockChainlink.sol";
import "../mocks/MockSwapRouter.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LoopVaultTest is Test {
    LoopVault vault;
    LoopVault vaultImpl;
    LoopStrategy strategy;
    MockMorpho morpho;
    MockWeETH weeth;
    MockWETH weth;
    MockChainlink chainlink;
    MockSwapRouter swapRouter;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xCAFE);

    function setUp() public {
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
        vaultImpl = new LoopVault();
        bytes memory initData = abi.encodeCall(
            LoopVault.initialize,
            (address(weth), address(strategy), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = LoopVault(payable(address(proxy)));

        // Wire up
        strategy.setVault(address(vault));
        strategy.setKeeper(keeper);

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ─── Helpers ───

    function _depositAsAlice(uint256 ethAmt) internal returns (uint256 shares) {
        vm.prank(alice);
        shares = vault.depositETH{value: ethAmt}();
    }

    function _advanceEpoch() internal {
        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18); // refresh oracle timestamp
        vault.advanceEpoch();
    }

    // ─── Deposit ───

    function test_depositETH_mintsShares() public {
        uint256 shares = _depositAsAlice(1 ether);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_depositETH_firstDeposit1to1() public {
        uint256 shares = _depositAsAlice(1 ether);
        // First deposit: 1 ETH = 1 share
        assertEq(shares, 1 ether);
    }

    function test_depositETH_addsToIdle() public {
        _depositAsAlice(1 ether);
        assertEq(vault.idleAssets(), 1 ether);
    }

    function test_depositETH_belowMin() public {
        vm.prank(alice);
        vm.expectRevert(LoopVault.BelowMinDeposit.selector);
        vault.depositETH{value: 0.1 ether}();
    }

    function test_depositETH_sameBlockRevert() public {
        vm.startPrank(alice);
        vault.depositETH{value: 1 ether}();
        vm.expectRevert(LoopVault.SameBlockDeposit.selector);
        vault.depositETH{value: 1 ether}();
        vm.stopPrank();
    }

    function test_depositWETH() public {
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(address(vault), 1 ether);
        uint256 shares = vault.deposit(1 ether, alice);
        vm.stopPrank();

        assertEq(shares, 1 ether);
        assertEq(vault.idleAssets(), 1 ether);
    }

    // ─── Withdraw ───

    function test_requestWithdraw_locksShares() public {
        // Need multiple depositors to stay under 20% cap
        _depositAsAlice(10 ether);
        vm.prank(bob);
        vault.depositETH{value: 40 ether}();

        // Alice has 20% of supply — exactly at cap
        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), aliceShares);
    }

    function test_completeWithdraw_afterEpoch() public {
        _depositAsAlice(10 ether);
        vm.prank(bob);
        vault.depositETH{value: 40 ether}();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        _advanceEpoch();

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.completeWithdraw();
        uint256 balAfter = alice.balance;

        assertGt(balAfter - balBefore, 9 ether); // ~10 ETH back (from idle)
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_completeWithdraw_beforeEpoch_reverts() public {
        _depositAsAlice(10 ether);
        vm.prank(bob);
        vault.depositETH{value: 40 ether}();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        // Don't advance epoch
        vm.prank(alice);
        vm.expectRevert(LoopVault.EpochNotElapsed.selector);
        vault.completeWithdraw();
    }

    function test_completeWithdraw_fromIdle() public {
        _depositAsAlice(10 ether);
        vm.prank(bob);
        vault.depositETH{value: 40 ether}();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        _advanceEpoch();

        uint256 idleBefore = vault.idleAssets();
        vm.prank(alice);
        vault.completeWithdraw();

        // Should have come from idle
        assertLt(vault.idleAssets(), idleBefore);
    }

    // ─── Epoch ───

    function test_advanceEpoch() public {
        _depositAsAlice(10 ether);

        vm.warp(block.timestamp + 7 days + 1);
        chainlink.setPrice(1e18);
        vault.advanceEpoch();

        assertEq(vault.epochId(), 2);
        assertGt(vault.snapshotAssets(), 0);
    }

    function test_advanceEpoch_tooEarly() public {
        vm.expectRevert("too early");
        vault.advanceEpoch();
    }

    function test_epochCapEnforced() public {
        _depositAsAlice(10 ether);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vault.depositETH{value: 10 ether}();

        // Alice has 50% of shares, cap is 20%
        uint256 aliceShares = vault.balanceOf(alice);

        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(LoopVault.EpochCapExceeded.selector);
        vault.requestWithdraw(aliceShares); // 50% > 20% cap
    }

    function test_epochCapResets() public {
        _depositAsAlice(10 ether);

        // Use some cap
        uint256 small = vault.balanceOf(alice) / 10; // 10%
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(small);

        // Advance epoch — cap resets
        _advanceEpoch();

        // Complete previous withdraw
        vm.prank(alice);
        vault.completeWithdraw();

        // Should be able to request again
        assertEq(vault.epochWithdrawnBps(), 0);
    }

    // ─── Deploy Idle ───

    function test_deployIdle() public {
        _depositAsAlice(10 ether);
        assertEq(vault.idleAssets(), 10 ether);

        // deployIdle should move excess idle to strategy
        vault.deployIdle();

        assertLt(vault.idleAssets(), 10 ether);
        // Strategy should have a position
        (uint256 coll,) = strategy.getPosition();
        assertGt(coll, 0);
    }

    function test_deployIdle_respectsTarget() public {
        _depositAsAlice(10 ether);
        vault.deployIdle();

        // Idle should be ~5% of total (target)
        uint256 total = vault.totalAssets();
        uint256 idle = vault.idleAssets();
        uint256 idlePct = idle * 10000 / total;
        assertApproxEqAbs(idlePct, 500, 200); // ~5% ± 2%
    }

    // ─── ERC-4626 disabled functions ───

    function test_mint_reverts() public {
        vm.expectRevert("use deposit");
        vault.mint(100, alice);
    }

    function test_withdraw_reverts() public {
        vm.expectRevert("use requestWithdraw");
        vault.withdraw(100, alice, alice);
    }

    function test_redeem_reverts() public {
        vm.expectRevert("use requestWithdraw");
        vault.redeem(100, alice, alice);
    }

    // ─── totalAssets ───

    function test_totalAssets_includesIdle() public {
        _depositAsAlice(10 ether);
        assertEq(vault.totalAssets(), 10 ether); // all idle
    }

    function test_totalAssets_afterDeploy() public {
        _depositAsAlice(10 ether);
        vault.deployIdle();

        uint256 total = vault.totalAssets();
        // Should be ~10 ETH (idle + strategy equity, minus wrap fees)
        assertApproxEqRel(total, 10 ether, 0.05e18); // within 5%
    }

    // ─── Anti-sandwich ───

    function test_noWithdrawSameBlockAsDeposit() public {
        vm.startPrank(alice);
        vault.depositETH{value: 1 ether}();
        uint256 shares = vault.balanceOf(alice);

        // Same block — requestWithdraw should fail
        vm.expectRevert(LoopVault.SameBlockDeposit.selector);
        vault.requestWithdraw(shares);
        vm.stopPrank();
    }

    // ─── cancelWithdraw ───

    function test_cancelWithdraw_returnsShares() public {
        _depositAsAlice(10 ether);
        vm.prank(bob);
        vault.depositETH{value: 40 ether}();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        assertEq(vault.balanceOf(alice), 0);

        // Cancel
        vm.prank(alice);
        vault.cancelWithdraw();
        assertEq(vault.balanceOf(alice), aliceShares);
    }

    function test_cancelWithdraw_noRequest_reverts() public {
        vm.prank(alice);
        vm.expectRevert(LoopVault.NoRequest.selector);
        vault.cancelWithdraw();
    }

    function test_cancelWithdraw_thenRequestAgain() public {
        // Alice 5%, Bob 95% — small enough to re-request within cap
        _depositAsAlice(5 ether);
        vm.prank(bob);
        vault.depositETH{value: 95 ether}();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);

        // Request (5%) → cancel → request again (5%)
        // epochWithdrawnBps not restored, so total consumed = 10% < 20% cap
        vm.startPrank(alice);
        vault.requestWithdraw(aliceShares);
        vault.cancelWithdraw();
        vault.requestWithdraw(aliceShares);
        vm.stopPrank();

        (uint256 shares,) = vault.withdrawalQueue(alice);
        assertEq(shares, aliceShares);
    }

    // ─── Pausable ───

    function test_pause_blocksDeposit() public {
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.depositETH{value: 1 ether}();
    }

    function test_pause_blocksRequestWithdraw() public {
        _depositAsAlice(10 ether);
        vm.prank(bob);
        vault.depositETH{value: 40 ether}();

        vm.roll(block.number + 1);
        vault.pause();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.requestWithdraw(aliceShares);
    }

    function test_unpause_restoresFunction() public {
        vault.pause();
        vault.unpause();
        // Should work again
        _depositAsAlice(1 ether);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }
}
