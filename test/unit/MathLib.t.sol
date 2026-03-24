// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/lib/MathLib.sol";

contract MathLibTest is Test {
    using MathLib for *;

    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;

    // ─── calcLTV ───

    function test_calcLTV_basic() public pure {
        // 10 weETH collateral, 7 ETH debt, peg 1:1
        uint256 ltv = MathLib.calcLTV(10 ether, 7 ether, WAD);
        // LTV = 7/10 = 70%
        assertApproxEqAbs(ltv, 0.7e18, 1);
    }

    function test_calcLTV_withDepeg() public pure {
        // 10 weETH, 7 ETH debt, peg 0.90
        uint256 ltv = MathLib.calcLTV(10 ether, 7 ether, 0.9e18);
        // collValue = 10 * 0.9 = 9 ETH, LTV = 7/9 = 77.78%
        assertApproxEqAbs(ltv, 0.7778e18, 0.001e18);
    }

    function test_calcLTV_zeroCollateral() public pure {
        uint256 ltv = MathLib.calcLTV(0, 7 ether, WAD);
        assertEq(ltv, type(uint256).max);
    }

    function test_calcLTV_zeroPeg() public pure {
        uint256 ltv = MathLib.calcLTV(10 ether, 7 ether, 0);
        assertEq(ltv, type(uint256).max);
    }

    function test_calcLTV_noDebt() public pure {
        uint256 ltv = MathLib.calcLTV(10 ether, 0, WAD);
        assertEq(ltv, 0);
    }

    // ─── calcLeverageAmount ───

    function test_calcLeverageAmount_basic() public pure {
        // 10 weETH, 0 debt, peg 1:1, target 85% LTV
        uint256 borrow = MathLib.calcLeverageAmount(10 ether, 0, WAD, 8500);
        // targetDebt = 10 * 0.85 = 8.5 ETH, with 5% margin = 8.075 ETH
        assertApproxEqAbs(borrow, 8.075 ether, 0.001 ether);
    }

    function test_calcLeverageAmount_alreadyAtTarget() public pure {
        // Already at 85% LTV
        uint256 borrow = MathLib.calcLeverageAmount(10 ether, 8.5 ether, WAD, 8500);
        assertEq(borrow, 0);
    }

    function test_calcLeverageAmount_aboveTarget() public pure {
        // Above target (90% LTV)
        uint256 borrow = MathLib.calcLeverageAmount(10 ether, 9 ether, WAD, 8500);
        assertEq(borrow, 0);
    }

    function test_calcLeverageAmount_withDepeg() public pure {
        // 10 weETH, 0 debt, peg 0.95, target 85%
        uint256 borrow = MathLib.calcLeverageAmount(10 ether, 0, 0.95e18, 8500);
        // collValue = 9.5 ETH, targetDebt = 9.5 * 0.85 = 8.075, margin = 7.67
        assertApproxEqAbs(borrow, 7.67125 ether, 0.001 ether);
    }

    // ─── calcUnwindAmount ───

    function test_calcUnwindAmount_partial() public pure {
        // 36 weETH, 26 ETH debt, peg 1:1 → equity = 10 ETH
        // Need 2 ETH
        (uint256 debtRepay, uint256 collWithdraw) =
            MathLib.calcUnwindAmount(36 ether, 26 ether, WAD, 2 ether);

        // 2/10 = 20% of position
        assertApproxEqAbs(debtRepay, 5.2 ether, 0.001 ether);   // 26 * 0.2
        assertApproxEqAbs(collWithdraw, 7.2 ether, 0.001 ether); // 36 * 0.2
    }

    function test_calcUnwindAmount_fullUnwind() public pure {
        // Need more than equity → full unwind
        (uint256 debtRepay, uint256 collWithdraw) =
            MathLib.calcUnwindAmount(36 ether, 26 ether, WAD, 15 ether);

        assertEq(debtRepay, 26 ether);
        assertEq(collWithdraw, 36 ether);
    }

    function test_calcUnwindAmount_underwater() public pure {
        // peg dropped: collValue < debt
        (uint256 debtRepay, uint256 collWithdraw) =
            MathLib.calcUnwindAmount(36 ether, 35 ether, 0.9e18, 1 ether);
        // collValue = 32.4, equity = 32.4 - 35 = underwater → full unwind
        assertEq(debtRepay, 35 ether);
        assertEq(collWithdraw, 36 ether);
    }

    function test_calcUnwindAmount_noDebt() public pure {
        // No debt, just withdraw collateral
        (uint256 debtRepay, uint256 collWithdraw) =
            MathLib.calcUnwindAmount(10 ether, 0, WAD, 3 ether);
        assertEq(debtRepay, 0);
        assertApproxEqAbs(collWithdraw, 3 ether, 0.001 ether);
    }

    // ─── calcExcessDebt ───

    function test_calcExcessDebt_aboveTarget() public pure {
        // 10 weETH, 9 ETH debt (90% LTV), target 80%
        uint256 excess = MathLib.calcExcessDebt(10 ether, 9 ether, WAD, 8000);
        // target debt = 10 * 0.80 = 8.0, excess = 9 - 8 = 1 ETH
        assertApproxEqAbs(excess, 1 ether, 1);
    }

    function test_calcExcessDebt_belowTarget() public pure {
        uint256 excess = MathLib.calcExcessDebt(10 ether, 7 ether, WAD, 8000);
        assertEq(excess, 0);
    }

    function test_calcExcessDebt_withDepeg() public pure {
        // 10 weETH, 8 ETH, peg 0.90, target 80%
        uint256 excess = MathLib.calcExcessDebt(10 ether, 8 ether, 0.9e18, 8000);
        // collValue = 9, targetDebt = 9 * 0.80 = 7.2, excess = 0.8
        assertApproxEqAbs(excess, 0.8 ether, 0.001 ether);
    }

    // ─── Fuzz tests ───

    function testFuzz_calcLTV_neverReverts(uint256 coll, uint256 debt, uint256 peg) public pure {
        coll = bound(coll, 0, 1_000_000 ether);
        debt = bound(debt, 0, 1_000_000 ether);
        peg = bound(peg, 0, 2e18);

        // Should never revert
        MathLib.calcLTV(coll, debt, peg);
    }

    function testFuzz_calcUnwindAmount_neverExceedsPosition(
        uint256 coll,
        uint256 debt,
        uint256 peg,
        uint256 needed
    ) public pure {
        coll = bound(coll, 1 ether, 1_000_000 ether);
        debt = bound(debt, 0, coll - 1); // ensure not underwater at peg 1.0
        peg = bound(peg, 0.5e18, 1.1e18);
        needed = bound(needed, 0, 1_000_000 ether);

        (uint256 debtRepay, uint256 collWithdraw) =
            MathLib.calcUnwindAmount(coll, debt, peg, needed);

        assertLe(debtRepay, debt, "debt repay exceeds total debt");
        assertLe(collWithdraw, coll, "coll withdraw exceeds total coll");
    }

    function testFuzz_calcLeverageAmount_neverExceedsTarget(
        uint256 coll,
        uint256 debt,
        uint256 peg,
        uint256 targetBps
    ) public pure {
        coll = bound(coll, 1 ether, 1_000_000 ether);
        peg = bound(peg, 0.8e18, 1.1e18);
        targetBps = bound(targetBps, 1000, 9500);
        uint256 collValue = coll * peg / WAD;
        debt = bound(debt, 0, collValue); // debt <= collateral value

        uint256 additional = MathLib.calcLeverageAmount(coll, debt, peg, targetBps);
        uint256 newDebt = debt + additional;

        if (collValue > 0 && additional > 0) {
            // When we DO add leverage, new LTV should not exceed target
            assertLe(newDebt * BPS / collValue, targetBps, "leverage exceeds target");
        }
        if (collValue > 0 && debt * BPS / collValue > targetBps) {
            // Already above target → should return 0
            assertEq(additional, 0, "should not add leverage when above target");
        }
    }
}
