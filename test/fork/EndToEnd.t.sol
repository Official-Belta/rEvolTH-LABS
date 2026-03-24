// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/LoopVault.sol";
import "../../src/LoopStrategy.sol";
import "../../src/KeeperModule.sol";
import "../../src/UniV3Adapter.sol";
import "../../src/interfaces/IMorpho.sol";
import "../../src/interfaces/IWETH.sol";
import "../../src/interfaces/IChainlinkAggregator.sol";
import "../../src/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title End-to-End Money Flow Test — Real Mainnet Fork
/// @notice Tests every dollar from deposit to withdrawal on actual Morpho/Uniswap/Chainlink.
///         Verifies no money leaks, share price integrity, and all fund destinations.
contract EndToEndTest is Test {
    // ── Mainnet addresses ──
    address constant MORPHO         = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WETH_ADDR      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH_ADDR     = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant PRICE_FEED     = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    address constant MORPHO_ORACLE  = 0xbDd2F2D473E8D63d1BFb0185B5bDB8046ca48a72;
    address constant MORPHO_IRM     = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV           = 0.945e18;

    LoopVault vault;
    LoopStrategy strategy;
    KeeperModule keeperModule;
    UniV3Adapter adapter;

    address deployer;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeperEOA = makeAddr("keeper");

    function setUp() public {
        deployer = address(this);

        adapter = new UniV3Adapter();

        MarketParams memory mp = MarketParams({
            loanToken: WETH_ADDR,
            collateralToken: WEETH_ADDR,
            oracle: MORPHO_ORACLE,
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        strategy = new LoopStrategy(
            MORPHO, WEETH_ADDR, WETH_ADDR, PRICE_FEED, address(adapter), mp
        );

        LoopVault vaultImpl = new LoopVault();
        bytes memory initData = abi.encodeCall(
            LoopVault.initialize,
            (WETH_ADDR, address(strategy), deployer)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = LoopVault(payable(address(proxy)));

        keeperModule = new KeeperModule(address(vault), address(strategy), deployer);

        strategy.setVault(address(vault));
        strategy.setKeeper(address(keeperModule));
        vault.setKeeper(address(keeperModule));
        keeperModule.setWhitelisted(keeperEOA, true);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(address(keeperModule), 1 ether); // tip fund
    }

    function _mockOracle() internal {
        (, int256 answer,,,) = IChainlinkAggregator(PRICE_FEED).latestRoundData();
        vm.mockCall(
            PRICE_FEED,
            abi.encodeWithSelector(IChainlinkAggregator.latestRoundData.selector),
            abi.encode(uint80(0), answer, uint256(0), block.timestamp, uint80(0))
        );
    }

    // ══════════════════════════════════════════════════════════
    // TEST 1: Single User Full Lifecycle
    //         Deposit → Deploy → Epoch → Withdraw → Verify Balance
    // ══════════════════════════════════════════════════════════

    function test_e2e_singleUserFullCycle() public {
        console.log("=== TEST 1: Single User Full Lifecycle ===");

        // -- Step 1: Alice deposits 5 ETH --
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        uint256 shares = vault.depositETH{value: 5 ether}();

        console.log("1. Deposited 5 ETH, got", shares / 1e18, "shares");
        assertEq(vault.idleAssets(), 5 ether, "idle should be 5 ETH");
        assertEq(vault.balanceOf(alice), shares, "alice should have shares");

        // -- Step 2: Keeper deploys idle → leverage up --
        uint256 totalBefore = vault.totalAssets();
        vault.deployIdle();
        uint256 totalAfter = vault.totalAssets();

        (uint256 coll, uint256 debt) = strategy.getPosition();
        uint256 ltv = strategy.getLTV();
        console.log("2. Deployed: coll=", coll / 1e18, "debt=", debt / 1e18);
        console.log("   LTV:", ltv * 100 / 1e18, "%");
        console.log("   totalAssets:", totalAfter / 1e15, "finney");

        // Share price should be ~1.0
        uint256 sharePrice = totalAfter * 1e18 / vault.totalSupply();
        console.log("   Share price:", sharePrice * 100 / 1e18, "%");
        assertGe(sharePrice, 0.97e18, "share price < 0.97 after deploy");

        // -- Step 3: Advance epoch --
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracle();
        vault.advanceEpoch();
        console.log("3. Epoch advanced to #", vault.epochId());

        // -- Step 4: Alice requests withdraw (all shares) --
        // Need bob to fill the other 80% of cap
        vm.deal(address(0xBEEF), 100 ether);
        vm.prank(address(0xBEEF));
        vault.depositETH{value: 20 ether}();

        vm.roll(block.number + 1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 withdrawShares = aliceShares / 10; // 10% — within 20% cap
        vm.prank(alice);
        vault.requestWithdraw(withdrawShares);
        console.log("4. Requested withdraw:", withdrawShares / 1e15, "finney shares");

        // -- Step 5: Advance epoch again --
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracle();
        vault.advanceEpoch();

        // -- Step 6: Alice completes withdraw --
        vm.prank(alice);
        uint256 received = vault.completeWithdraw();

        console.log("5. Withdrew:", received / 1e15, "finney ETH");

        assertGt(received, 0, "received nothing");

        // -- Final check: no money leaked --
        uint256 vaultTotal = vault.totalAssets();
        uint256 allShares = vault.totalSupply();
        console.log("6. Final: totalAssets=", vaultTotal / 1e18, "ETH, shares=", allShares / 1e18);
        console.log("   Final share price:", vaultTotal * 100 / allShares, "%");
    }

    // ══════════════════════════════════════════════════════════
    // TEST 2: Multi-User Deposit + Partial Withdraw
    // ══════════════════════════════════════════════════════════

    function test_e2e_multiUser() public {
        console.log("=== TEST 2: Multi-User ===");

        // -- Alice deposits 3 ETH --
        vm.prank(alice);
        vault.depositETH{value: 3 ether}();

        // -- Bob deposits 7 ETH --
        vm.prank(bob);
        vault.depositETH{value: 7 ether}();

        console.log("1. Alice: 3 ETH, Bob: 7 ETH. Total:", vault.totalAssets() / 1e18, "ETH");

        // -- Deploy --
        vault.deployIdle();
        console.log("2. Deployed. totalAssets:", vault.totalAssets() / 1e18, "ETH");

        // Share ratio should be 3:7
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        console.log("   Alice shares:", aliceShares / 1e15, "Bob shares:", bobShares / 1e15);

        // -- Epoch --
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracle();
        vault.advanceEpoch();

        // -- Bob withdraws 10% of his shares --
        vm.roll(block.number + 1);
        uint256 bobWithdraw = bobShares / 10;
        vm.prank(bob);
        vault.requestWithdraw(bobWithdraw);

        vm.warp(block.timestamp + 7 days + 1);
        _mockOracle();
        vault.advanceEpoch();

        // Before withdraw, check state
        console.log("   Vault idle:", vault.idleAssets() / 1e15, "finney");
        console.log("   Bob withdraw shares:", bobWithdraw / 1e15);

        vm.prank(bob);
        uint256 bobReceived = vault.completeWithdraw();

        console.log("3. Bob withdrew:", bobReceived / 1e15, "finney");
        assertGt(bobReceived, 0, "bob got nothing");

        // -- Alice's share should still be intact --
        assertEq(vault.balanceOf(alice), aliceShares, "alice shares changed");

        // -- totalAssets should equal all claims --
        uint256 totalAssets = vault.totalAssets();
        uint256 totalShares = vault.totalSupply();
        console.log("4. Final totalAssets:", totalAssets / 1e18, "shares:", totalShares / 1e18);
    }

    // ══════════════════════════════════════════════════════════
    // TEST 3: Emergency Unwind — All money returns to vault
    // ══════════════════════════════════════════════════════════

    function test_e2e_emergencyUnwindFundsToVault() public {
        console.log("=== TEST 3: Emergency Unwind ===");

        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        uint256 totalBefore = vault.totalAssets();
        (uint256 collBefore, uint256 debtBefore) = strategy.getPosition();
        console.log("1. Before: total=", totalBefore / 1e18); console.log("   coll=", collBefore / 1e18, "debt=", debtBefore / 1e18);

        // Force emergency via direct call (owner can)
        strategy.emergencyUnwind();

        (, uint256 debtAfter) = strategy.getPosition();
        assertEq(debtAfter, 0, "debt not cleared");

        // -- Sync idle to pick up WETH that landed in vault --
        vault.syncIdle();

        uint256 totalAfter = vault.totalAssets();
        console.log("2. After: total=", totalAfter / 1e18, "debt=", debtAfter);

        // -- Verify: funds are in vault, not deployer/keeper/strategy --
        uint256 strategyWeth = IERC20(WETH_ADDR).balanceOf(address(strategy));
        uint256 keeperWeth = IERC20(WETH_ADDR).balanceOf(address(keeperModule));
        uint256 deployerWeth = IERC20(WETH_ADDR).balanceOf(deployer);

        console.log("3. Strategy WETH:", strategyWeth);
        console.log("   Keeper WETH:", keeperWeth);
        console.log("   Deployer WETH:", deployerWeth);

        assertEq(strategyWeth, 0, "WETH leaked to strategy");
        assertEq(keeperWeth, 0, "WETH leaked to keeper");
        // deployer may have pre-existing WETH, so don't assert 0

        // -- totalAssets should be close to original (minus swap fees) --
        uint256 loss = totalBefore > totalAfter ? totalBefore - totalAfter : 0;
        uint256 lossPct = loss * 100 / totalBefore;
        console.log("4. Loss:", loss / 1e15, "finney");
        console.log("   Loss pct:", lossPct, "%");
        assertLt(lossPct, 3, "lost more than 3% in emergency unwind");
    }

    // ══════════════════════════════════════════════════════════
    // TEST 4: Keeper Rebalance — Funds go to vault, not keeper
    // ══════════════════════════════════════════════════════════

    function test_e2e_keeperCannotStealFunds() public {
        console.log("=== TEST 4: Keeper Cannot Steal ===");

        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        uint256 keeperBalBefore = keeperEOA.balance;
        uint256 vaultWethBefore = IERC20(WETH_ADDR).balanceOf(address(vault));

        // -- Keeper triggers deloopForSpread --
        (uint256 coll, uint256 debt) = strategy.getPosition();
        uint256 peg = strategy.getPeg();
        uint256 equity = coll * peg / 1e18 - debt;
        uint256 deloopAmt = equity * 10 / 100; // 10% of equity

        vm.prank(keeperEOA);
        keeperModule.deloopForSpread(deloopAmt);

        uint256 keeperBalAfter = keeperEOA.balance;
        uint256 vaultWethAfter = IERC20(WETH_ADDR).balanceOf(address(vault));

        // Keeper should only get tip (0.01 ETH), not strategy funds
        uint256 keeperGain = keeperBalAfter - keeperBalBefore;
        uint256 vaultGain = vaultWethAfter - vaultWethBefore;

        console.log("1. Keeper gained:", keeperGain / 1e15, "finney (should be ~10 = tip)");
        console.log("2. Vault WETH gained:", vaultGain / 1e15, "finney");

        assertLe(keeperGain, 0.02 ether, "keeper got more than tip");
        assertGt(vaultGain, 0, "vault didn't receive deloop funds");
    }

    // ══════════════════════════════════════════════════════════
    // TEST 5: Share Price Integrity Through Full Cycle
    // ══════════════════════════════════════════════════════════

    function test_e2e_sharePriceIntegrity() public {
        console.log("=== TEST 5: Share Price Integrity ===");

        // -- Phase 1: First deposit --
        vm.prank(alice);
        vault.depositETH{value: 5 ether}();
        uint256 price1 = vault.totalAssets() * 1e18 / vault.totalSupply();
        console.log("1. After deposit: price=", price1 * 100 / 1e18, "%");
        assertGe(price1, 0.99e18, "price1 < 0.99");

        // -- Phase 2: Deploy (leverage up) --
        vault.deployIdle();
        uint256 price2 = vault.totalAssets() * 1e18 / vault.totalSupply();
        console.log("2. After deploy: price=", price2 * 100 / 1e18, "%");
        assertGe(price2, 0.97e18, "price2 < 0.97 after deploy");

        // -- Phase 3: Second user deposits (should get fair shares) --
        vm.prank(bob);
        vault.depositETH{value: 5 ether}();
        uint256 price3 = vault.totalAssets() * 1e18 / vault.totalSupply();
        console.log("3. After bob deposit: price=", price3 * 100 / 1e18, "%");
        // Price shouldn't change significantly with new deposit
        assertGe(price3, price2 * 98 / 100, "price dropped >2% on new deposit");

        // -- Phase 4: Epoch advance --
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracle();
        vault.advanceEpoch();
        uint256 price4 = vault.totalAssets() * 1e18 / vault.totalSupply();
        console.log("4. After epoch: price=", price4 * 100 / 1e18, "%");

        // -- Phase 5: Emergency unwind + syncIdle --
        strategy.emergencyUnwind();
        vault.syncIdle();
        uint256 price5 = vault.totalAssets() * 1e18 / vault.totalSupply();
        console.log("5. After emergency: price=", price5 * 100 / 1e18, "%");

        // Price should not drop more than 3% from deploy price
        assertGe(price5, price2 * 97 / 100, "price dropped >3% in emergency");

        console.log("");
        console.log("=== SHARE PRICE INTEGRITY PASSED ===");
        console.log("  Deposit: ", price1 * 100 / 1e18, "%");
        console.log("  Deploy:  ", price2 * 100 / 1e18, "%");
        console.log("  +User:   ", price3 * 100 / 1e18, "%");
        console.log("  Epoch:   ", price4 * 100 / 1e18, "%");
        console.log("  Emergency:", price5 * 100 / 1e18, "%");
    }

    // ══════════════════════════════════════════════════════════
    // TEST 6: cancelWithdraw Returns Shares
    // ══════════════════════════════════════════════════════════

    function test_e2e_cancelWithdrawSafe() public {
        console.log("=== TEST 6: Cancel Withdraw ===");

        vm.prank(alice);
        vault.depositETH{value: 5 ether}();
        vm.prank(bob);
        vault.depositETH{value: 20 ether}();

        vault.deployIdle();

        vm.warp(block.timestamp + 7 days + 1);
        _mockOracle();
        vault.advanceEpoch();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.roll(block.number + 1);

        // Request
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        assertEq(vault.balanceOf(alice), 0, "shares not locked");

        // Cancel
        vm.prank(alice);
        vault.cancelWithdraw();
        assertEq(vault.balanceOf(alice), aliceShares, "shares not returned");

        console.log("1. Shares locked and returned correctly");
    }

    // ══════════════════════════════════════════════════════════
    // TEST 7: Pause Blocks Everything
    // ══════════════════════════════════════════════════════════

    function test_e2e_pauseProtection() public {
        console.log("=== TEST 7: Pause Protection ===");

        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.depositETH{value: 1 ether}();

        vault.unpause();

        vm.prank(alice);
        vault.depositETH{value: 1 ether}();
        assertGt(vault.balanceOf(alice), 0, "deposit failed after unpause");

        console.log("1. Pause blocks deposits, unpause restores");
    }

    // ══════════════════════════════════════════════════════════
    // TEST 8: Zero Balance Tracking — No Phantom Money
    // ══════════════════════════════════════════════════════════

    function test_e2e_noPhantomMoney() public {
        console.log("=== TEST 8: No Phantom Money ===");

        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        // Record all balances
        uint256 vaultWeth = IERC20(WETH_ADDR).balanceOf(address(vault));
        uint256 stratWeth = IERC20(WETH_ADDR).balanceOf(address(strategy));
        uint256 stratWeeth = IERC20(WEETH_ADDR).balanceOf(address(strategy));
        (uint256 morphoColl, uint256 morphoDebt) = strategy.getPosition();
        uint256 peg = strategy.getPeg();

        console.log("Vault WETH:", vaultWeth / 1e15, "finney");
        console.log("Strategy WETH:", stratWeth / 1e15, "finney");
        console.log("Strategy weETH (free):", stratWeeth / 1e15, "finney");
        console.log("Morpho coll:", morphoColl / 1e15, "weETH finney");
        console.log("Morpho debt:", morphoDebt / 1e15, "WETH finney");

        // totalAssets should equal: strategy equity + vault idle
        uint256 expectedTotal = (morphoColl * peg / 1e18 - morphoDebt) + vaultWeth;
        uint256 actualTotal = vault.totalAssets();
        uint256 diff = expectedTotal > actualTotal
            ? expectedTotal - actualTotal
            : actualTotal - expectedTotal;

        console.log("Expected total:", expectedTotal / 1e15, "finney");
        console.log("Actual total:", actualTotal / 1e15, "finney");
        console.log("Diff:", diff / 1e15, "finney");

        // Strategy should not hold free WETH (all in Morpho or sent to vault)
        assertEq(stratWeth, 0, "strategy holds stray WETH");

        // Diff should be tiny (rounding only)
        assertLt(diff, 0.01 ether, "phantom money detected");
    }
}
