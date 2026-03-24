// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/LoopVault.sol";
import "../../src/LoopStrategy.sol";
import "../../src/KeeperModule.sol";
import "../../src/interfaces/IMorpho.sol";
import "../../src/interfaces/IEtherFi.sol";
import "../../src/interfaces/IWETH.sol";
import "../../src/interfaces/IChainlinkAggregator.sol";
import "../../src/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Uniswap V3 SwapRouter interface (exactInputSingle only)
///         The original SwapRouter (not SwapRouter02) requires a deadline field.
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

/// @notice Thin adapter wrapping Uniswap V3 behind our ISwapRouter interface
contract UniV3Adapter is ISwapRouter {
    IUniswapV3Router public constant UNI_ROUTER = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(UNI_ROUTER), amountIn);
        amountOut = UNI_ROUTER.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 100, // 0.01% fee tier — deepest liquidity for correlated pairs
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        }));
    }
}

/// @title Fork Test — Real Morpho, Real EtherFi, Real Chainlink on Ethereum Mainnet
/// @dev Run with: forge test --match-path test/fork/ForkTest.t.sol --fork-url $ETH_RPC_URL -vv
contract ForkTest is Test {
    // ── Mainnet addresses ──
    address constant MORPHO         = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WETH_ADDR      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant EETH_ADDR      = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant WEETH_ADDR     = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant PRICE_FEED     = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;

    // Morpho weETH/WETH market (94.5% LLTV)
    address constant MORPHO_ORACLE  = 0xbDd2F2D473E8D63d1BFb0185B5bDB8046ca48a72;
    address constant MORPHO_IRM     = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV           = 0.945e18;

    LoopVault vault;
    LoopStrategy strategy;
    KeeperModule keeperModule;
    UniV3Adapter adapter;

    address deployer;
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        deployer = address(this);

        // Deploy UniV3Adapter for weETH→WETH swaps
        adapter = new UniV3Adapter();

        // Market params
        MarketParams memory mp = MarketParams({
            loanToken: WETH_ADDR,
            collateralToken: WEETH_ADDR,
            oracle: MORPHO_ORACLE,
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        // Deploy strategy (talks to real Morpho, EtherFi, Chainlink)
        strategy = new LoopStrategy(
            MORPHO, LIQUIDITY_POOL, EETH_ADDR, WEETH_ADDR, WETH_ADDR, PRICE_FEED,
            address(adapter), mp
        );

        // Deploy vault via UUPS proxy
        LoopVault vaultImpl = new LoopVault();
        bytes memory initData = abi.encodeCall(
            LoopVault.initialize,
            (WETH_ADDR, address(strategy), deployer)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = LoopVault(payable(address(proxy)));

        // Deploy keeper module
        keeperModule = new KeeperModule(address(vault), address(strategy), deployer);

        // Wire up
        strategy.setVault(address(vault));
        strategy.setKeeper(address(keeperModule));
        vault.setKeeper(address(keeperModule));
        keeperModule.setWhitelisted(keeper, true);

        // Fund alice
        vm.deal(alice, 100 ether);

        // Sync block.timestamp to real time so oracle isn't "stale"
        vm.warp(block.timestamp);
    }

    // ── Helper: mock oracle timestamp so it's not stale after vm.warp ──
    function _mockOracleTimestamp() internal {
        // Get current price from the real oracle
        (, int256 answer,,,) = IChainlinkAggregator(PRICE_FEED).latestRoundData();
        // Mock latestRoundData to return the same price but with current timestamp
        vm.mockCall(
            PRICE_FEED,
            abi.encodeWithSelector(IChainlinkAggregator.latestRoundData.selector),
            abi.encode(uint80(0), answer, uint256(0), block.timestamp, uint80(0))
        );
    }

    // ══════════════════════════════════════════════
    // 1. BASIC CONNECTIVITY — Can we talk to real contracts?
    // ══════════════════════════════════════════════

    function test_fork_chainlinkOracleWorks() public view {
        uint256 peg = strategy.getPeg();
        // weETH/ETH should be roughly 1.0-1.1 (weETH accrues value)
        assertGt(peg, 0.95e18, "peg too low");
        assertLt(peg, 1.2e18, "peg too high");
        console.log("weETH/ETH peg:", peg);
    }

    function test_fork_morphoMarketExists() public view {
        Id marketId = MarketParamsLib.id(MarketParams({
            loanToken: WETH_ADDR,
            collateralToken: WEETH_ADDR,
            oracle: MORPHO_ORACLE,
            irm: MORPHO_IRM,
            lltv: LLTV
        }));

        (uint128 totalSupplyAssets,,uint128 totalBorrowAssets,,,) =
            IMorpho(MORPHO).market(marketId);

        assertGt(totalSupplyAssets, 0, "market has no supply");
        assertGt(totalBorrowAssets, 0, "market has no borrows");
        console.log("Morpho supply:", totalSupplyAssets / 1e18, "ETH");
        console.log("Morpho borrow:", totalBorrowAssets / 1e18, "ETH");
    }

    function test_fork_etherFiWrapWorks() public {
        // ETH → eETH → weETH
        vm.deal(address(this), 1 ether);
        uint256 eethAmt = ILiquidityPool(LIQUIDITY_POOL).deposit{value: 1 ether}();
        assertGt(eethAmt, 0, "eETH mint failed");

        IeETH(EETH_ADDR).approve(WEETH_ADDR, eethAmt);
        uint256 weethAmt = IWeETH(WEETH_ADDR).wrap(eethAmt);
        assertGt(weethAmt, 0, "weETH wrap failed");

        console.log("1 ETH -> eETH:", eethAmt);
        console.log("eETH -> weETH:", weethAmt);
    }

    // ══════════════════════════════════════════════
    // 2. DEPOSIT — ETH → vault → idle buffer
    // ══════════════════════════════════════════════

    function test_fork_depositETH() public {
        vm.prank(alice);
        uint256 shares = vault.depositETH{value: 1 ether}();

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.idleAssets(), 1 ether, "idle not updated");
        console.log("Deposited 1 ETH, got shares:", shares);
    }

    // ══════════════════════════════════════════════
    // 3. DEPLOY IDLE → LEVERAGE UP (the real test)
    // ══════════════════════════════════════════════

    function test_fork_deployIdleLeveragesUp() public {
        // Deposit enough to trigger deploy (need idle > 10%)
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        // Deploy idle to strategy
        vault.deployIdle();

        // Check strategy has a leveraged position
        (uint256 coll, uint256 debt) = strategy.getPosition();
        console.log("Collateral (weETH):", coll / 1e18);
        console.log("Debt (WETH):", debt / 1e18);

        assertGt(coll, 0, "no collateral");
        assertGt(debt, 0, "no debt - leverage failed");

        // LTV should be near target (85%)
        uint256 ltv = strategy.getLTV();
        console.log("LTV:", ltv * 100 / 1e18, "%");
        assertGt(ltv, 0.70e18, "LTV too low");
        assertLt(ltv, 0.90e18, "LTV too high");

        // Leverage ratio: collateral value / initial deposit
        uint256 peg = strategy.getPeg();
        uint256 collValueETH = coll * peg / 1e18;
        uint256 leverage = collValueETH * 100 / 10 ether;
        console.log("Leverage:", leverage, "% of deposit");
        assertGt(leverage, 250, "leverage < 2.5x");
    }

    // ══════════════════════════════════════════════
    // 4. FULL FLOW — deposit → deploy → epoch → withdraw
    // ══════════════════════════════════════════════

    function test_fork_fullFlow() public {
        // 1. Deposit
        vm.prank(alice);
        vault.depositETH{value: 5 ether}();
        uint256 shares = vault.balanceOf(alice);
        console.log("1. Deposited 5 ETH, shares:", shares);

        // 2. Deploy idle
        vault.deployIdle();
        (uint256 coll, uint256 debt) = strategy.getPosition();
        console.log("2. Deployed: coll=", coll/1e18, "debt=", debt/1e18);

        // 3. Advance epoch
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracleTimestamp();
        vault.advanceEpoch();
        uint256 snap = vault.snapshotAssets();
        console.log("3. Epoch advanced, snapshot:", snap/1e18, "ETH");

        // 4. Request withdraw — use small amount that idle can cover
        //    Idle is ~5% of total. Request ~2% of shares so it stays within idle buffer.
        vm.roll(block.number + 1);
        uint256 withdrawShares = shares / 50; // 2% of shares
        vm.prank(alice);
        vault.requestWithdraw(withdrawShares);
        console.log("4. Requested withdraw:", withdrawShares, "shares");

        // 5. Advance another epoch
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracleTimestamp();
        vault.advanceEpoch();

        // 6. Complete withdraw
        vm.prank(alice);
        uint256 received = vault.completeWithdraw();
        console.log("5. Withdrew ETH:", received / 1e15, "finney");

        assertGt(received, 0, "got nothing back");
    }

    // ══════════════════════════════════════════════
    // 5. LEVERAGE DOWN — partial deloop works with real Morpho
    // ══════════════════════════════════════════════

    function test_fork_leverageDown() public {
        // Setup: deposit and leverage
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        (uint256 collBefore, uint256 debtBefore) = strategy.getPosition();
        uint256 ltvBefore = strategy.getLTV();
        console.log("Before: coll=", collBefore/1e18, "debt=", debtBefore/1e18);
        console.log("Before LTV:", ltvBefore*100/1e18, "%");

        // Deleverage 2 ETH
        strategy.leverageDown(2 ether);

        (uint256 collAfter, uint256 debtAfter) = strategy.getPosition();
        uint256 ltvAfter = strategy.getLTV();
        console.log("After:  coll=", collAfter/1e18, "debt=", debtAfter/1e18);
        console.log("After LTV:", ltvAfter*100/1e18, "%");

        assertLt(collAfter, collBefore, "collateral didn't decrease");
        assertLt(debtAfter, debtBefore, "debt didn't decrease");
    }

    // ══════════════════════════════════════════════
    // 6. EMERGENCY UNWIND — full unwind with real Morpho
    // ══════════════════════════════════════════════

    function test_fork_emergencyUnwind() public {
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        (, uint256 debtBefore) = strategy.getPosition();
        assertGt(debtBefore, 0, "no position to unwind");
        console.log("Before emergency: debt=", debtBefore/1e18);

        strategy.emergencyUnwind();

        (, uint256 debtAfter) = strategy.getPosition();
        console.log("After emergency: debt=", debtAfter/1e18);
        assertEq(debtAfter, 0, "debt not cleared");
    }

    // ══════════════════════════════════════════════
    // 7. GAS MEASUREMENT — how much does each operation cost?
    // ══════════════════════════════════════════════

    function test_fork_gasMeasurement() public {
        // Deposit gas
        vm.prank(alice);
        uint256 g1 = gasleft();
        vault.depositETH{value: 5 ether}();
        uint256 depositGas = g1 - gasleft();
        console.log("Gas - deposit:", depositGas);

        // Deploy idle (leverage up) gas
        uint256 g2 = gasleft();
        vault.deployIdle();
        uint256 deployGas = g2 - gasleft();
        console.log("Gas - deployIdle (leverage up):", deployGas);

        // Advance epoch gas
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracleTimestamp();
        uint256 g3 = gasleft();
        vault.advanceEpoch();
        uint256 epochGas = g3 - gasleft();
        console.log("Gas - advanceEpoch:", epochGas);

        // Leverage down gas
        uint256 g4 = gasleft();
        strategy.leverageDown(1 ether);
        uint256 delevGas = g4 - gasleft();
        console.log("Gas - leverageDown(1 ETH):", delevGas);
    }

    // ══════════════════════════════════════════════
    // 8. REAL YIELD CHECK — does the position actually earn?
    // ══════════════════════════════════════════════

    function test_fork_totalAssetsReflectsPosition() public {
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        uint256 assetsBefore = vault.totalAssets();
        console.log("totalAssets before deploy:", assetsBefore / 1e18);

        vault.deployIdle();

        uint256 assetsAfter = vault.totalAssets();
        console.log("totalAssets after deploy:", assetsAfter / 1e18);

        // Should be roughly the same (minus wrap fees + rate difference)
        // weETH rate ~1.09 means 1 ETH -> ~0.84 weETH, then Chainlink peg * coll ~ original
        // But totalAssets uses equity (coll*peg - debt), which can differ due to wrap/rate fees
        assertGt(assetsAfter, 5 ether, "lost too much in deployment");
        assertApproxEqRel(assetsAfter, 10 ether, 0.35e18); // within 35%
    }

    // ══════════════════════════════════════════════
    // 9. KEEPER MODULE — works with real contracts
    // ══════════════════════════════════════════════

    function test_fork_keeperAdvanceEpoch() public {
        vm.prank(alice);
        vault.depositETH{value: 1 ether}();

        vm.warp(block.timestamp + 7 days + 1);
        _mockOracleTimestamp();

        vm.deal(address(keeperModule), 1 ether); // fund tips
        vm.prank(keeper);
        keeperModule.advanceEpochIfNeeded();

        assertEq(vault.epochId(), 2);
    }

    function test_fork_keeperDeployIdle() public {
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        vm.deal(address(keeperModule), 1 ether);
        vm.prank(keeper);
        keeperModule.deployIdle();

        (uint256 coll,) = strategy.getPosition();
        assertGt(coll, 0, "keeper deploy didn't leverage");
    }

    // ══════════════════════════════════════════════
    // 10. EDGE CASES — verify audit fixes work on mainnet
    // ══════════════════════════════════════════════

    /// @dev Fix 1: leverageDown should NOT sweep stray WETH
    function test_fork_noStrayWethSweep() public {
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        // Send stray WETH directly to strategy (simulating dust/accidental transfer)
        vm.deal(address(this), 1 ether);
        IWETH(WETH_ADDR).deposit{value: 1 ether}();
        IERC20(WETH_ADDR).transfer(address(strategy), 1 ether);

        uint256 strayBefore = IERC20(WETH_ADDR).balanceOf(address(strategy));
        console.log("Stray WETH in strategy:", strayBefore / 1e15, "finney");

        // leverageDown should return only what it unwound, not the stray
        uint256 returned = strategy.leverageDown(1 ether);
        uint256 strayAfter = IERC20(WETH_ADDR).balanceOf(address(strategy));

        console.log("Returned from leverageDown:", returned / 1e15, "finney");
        console.log("Stray WETH remaining:", strayAfter / 1e15, "finney");

        // Stray should still be there (not swept)
        assertGt(strayAfter, 0, "stray WETH was swept - Fix 1 failed!");
    }

    /// @dev Fix 5: slippage 1% default — verify actual swap slippage is under 1%
    function test_fork_slippageUnder1Percent() public {
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        (uint256 collBefore, uint256 debtBefore) = strategy.getPosition();
        uint256 equityBefore = collBefore * strategy.getPeg() / 1e18 - debtBefore;

        strategy.leverageDown(1 ether);

        (uint256 collAfter, uint256 debtAfter) = strategy.getPosition();
        uint256 equityAfter = collAfter * strategy.getPeg() / 1e18 - debtAfter;

        // Equity should decrease by ~1 ETH. Slippage means we lose a bit more.
        uint256 equityLost = equityBefore - equityAfter;
        uint256 slippageBps = (equityLost - 1 ether) * 10000 / 1 ether;

        console.log("Equity lost:", equityLost / 1e15, "finney (expected ~1000)");
        console.log("Actual slippage:", slippageBps, "bps");

        // Slippage should be under 1% (100 bps) for a correlated pair
        assertLt(slippageBps, 100, "slippage exceeded 1% - too high for pegged pair");
    }

    /// @dev Fix 3: idle accounting — excess WETH tracked after partial unwind
    function test_fork_idleAccountingAfterWithdraw() public {
        // Alice deposits, deploy to strategy
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        vault.deployIdle();

        // Bob deposits (adds to idle)
        address bob = makeAddr("bob");
        vm.deal(bob, 50 ether);
        vm.prank(bob);
        vault.depositETH{value: 50 ether}();

        // Advance epoch
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracleTimestamp();
        vault.advanceEpoch();

        // Bob requests small withdraw (should come from idle)
        uint256 bobShares = vault.balanceOf(bob);
        uint256 smallWithdraw = bobShares / 50; // 2%
        vm.roll(block.number + 1);
        vm.prank(bob);
        vault.requestWithdraw(smallWithdraw);

        // Advance another epoch
        vm.warp(block.timestamp + 7 days + 1);
        _mockOracleTimestamp();
        vault.advanceEpoch();

        uint256 idleBefore = vault.idleAssets();
        vm.prank(bob);
        vault.completeWithdraw();
        uint256 idleAfter = vault.idleAssets();

        console.log("Idle before withdraw:", idleBefore / 1e18, "ETH");
        console.log("Idle after withdraw:", idleAfter / 1e18, "ETH");

        // Idle should decrease by roughly the withdraw amount, not go to 0
        assertGt(idleAfter, 0, "idle went to 0 - accounting broken");
    }

    /// @dev Fix 6: epoch drift — verify consistent epoch cadence
    function test_fork_epochNoDrift() public {
        vm.prank(alice);
        vault.depositETH{value: 1 ether}();

        uint256 start1 = vault.epochStartTime();

        // Advance epoch 3 hours late
        vm.warp(block.timestamp + 7 days + 3 hours);
        _mockOracleTimestamp();
        vault.advanceEpoch();

        uint256 start2 = vault.epochStartTime();

        // Epoch start should be exactly 7 days after first, NOT block.timestamp
        assertEq(start2, start1 + 7 days, "epoch drifted - Fix 6 failed!");
        console.log("Epoch 1 start:", start1);
        console.log("Epoch 2 start:", start2);
        console.log("Difference:", (start2 - start1) / 1 days, "days (should be 7)");
    }
}
