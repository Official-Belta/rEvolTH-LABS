// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./LoopVault.sol";
import "./LoopStrategy.sol";
import "./lib/MathLib.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title KeeperModule — Automated keeper actions for the looping vault
/// @notice Whitelisted keepers call rebalance, deployIdle, advanceEpoch, deloopForSpread.
///         Keeper receives 0.01 ETH tip per successful action.
/// @dev L-2: Inherits Ownable for proper ownership transfer support.
contract KeeperModule is Ownable, ReentrancyGuard {
    using MathLib for *;

    // ── Immutables ──
    LoopVault public immutable vault;
    LoopStrategy public immutable strategy;

    // ── Config ──
    uint256 public constant KEEPER_TIP = 0.01 ether;
    uint256 public constant MIN_REBALANCE_GAP = 1 hours;
    uint256 public constant DELEV_LTV_BPS = 8500;   // 85% — trigger deleverage
    uint256 public constant EMERG_LTV_BPS = 9200;    // 92% — trigger emergency unwind
    uint256 public constant IDLE_DEPLOY_BPS = 1000;   // 10% — deploy when idle > 10%
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    // ── State ──
    mapping(address => bool) public whitelisted;
    uint256 public lastRebalanceTime;

    // ── Events ──
    event Rebalanced(address indexed keeper, uint256 ltv, string action);
    event IdleDeployed(address indexed keeper, uint256 amount);
    event EpochAdvanced(address indexed keeper, uint256 epochId);
    event DeloopedForSpread(address indexed keeper, uint256 amount);
    event KeeperWhitelisted(address indexed keeper, bool status);
    event TipPaid(address indexed keeper, uint256 amount);

    // ── Errors ──
    error NotWhitelisted();
    error RebalanceTooSoon();
    error NoActionNeeded();
    error TipTransferFailed();

    modifier onlyWhitelisted() {
        if (!whitelisted[msg.sender] && msg.sender != owner()) revert NotWhitelisted();
        _;
    }

    constructor(address _vault, address _strategy, address _owner) Ownable(_owner) {
        vault = LoopVault(payable(_vault));
        strategy = LoopStrategy(payable(_strategy));
        whitelisted[_owner] = true;
    }

    // ══════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════

    function setWhitelisted(address _keeper, bool _status) external onlyOwner {
        whitelisted[_keeper] = _status;
        emit KeeperWhitelisted(_keeper, _status);
    }

    // ══════════════════════════════════════════════
    // REBALANCE
    // ══════════════════════════════════════════════

    /// @notice Check LTV and rebalance if needed.
    ///         - LTV >= 92%: emergency unwind
    ///         - LTV >= 85%: deleverage to target (80%)
    ///         - Otherwise: no-op
    function rebalance() external onlyWhitelisted nonReentrant {
        if (lastRebalanceTime > 0 && block.timestamp < lastRebalanceTime + MIN_REBALANCE_GAP) {
            revert RebalanceTooSoon();
        }

        uint256 ltv = strategy.getLTV();

        if (ltv == type(uint256).max) {
            // No position — nothing to rebalance
            revert NoActionNeeded();
        }

        if (ltv >= EMERG_LTV_BPS * WAD / BPS) {
            // Emergency: full unwind
            strategy.emergencyUnwind();
            lastRebalanceTime = block.timestamp;
            _payTip();
            emit Rebalanced(msg.sender, ltv, "emergency");
        } else if (ltv >= DELEV_LTV_BPS * WAD / BPS) {
            // Deleverage: reduce to bring LTV down
            (uint256 coll, uint256 debt) = strategy.getPosition();
            uint256 peg = strategy.getPeg();
            uint256 excessDebt = MathLib.calcExcessDebt(coll, debt, peg, 8000); // target 80%
            if (excessDebt > 0) {
                strategy.leverageDown(excessDebt);
            }
            lastRebalanceTime = block.timestamp;
            _payTip();
            emit Rebalanced(msg.sender, ltv, "deleverage");
        } else {
            revert NoActionNeeded();
        }
    }

    // ══════════════════════════════════════════════
    // DEPLOY IDLE
    // ══════════════════════════════════════════════

    /// @notice Deploy idle buffer when it exceeds 10%.
    function deployIdle() external onlyWhitelisted nonReentrant {
        uint256 idle = vault.idleAssets();
        uint256 total = vault.totalAssets();
        if (total == 0) revert NoActionNeeded();

        uint256 idlePct = idle * BPS / total;
        if (idlePct <= IDLE_DEPLOY_BPS) revert NoActionNeeded();

        vault.deployIdle();
        _payTip();
        emit IdleDeployed(msg.sender, idle);
    }

    // ══════════════════════════════════════════════
    // EPOCH ADVANCE
    // ══════════════════════════════════════════════

    /// @notice Advance epoch when duration has elapsed.
    function advanceEpochIfNeeded() external onlyWhitelisted nonReentrant {
        uint256 epochStart = vault.epochStartTime();
        uint256 duration = vault.EPOCH_DURATION();

        if (block.timestamp < epochStart + duration) revert NoActionNeeded();

        vault.advanceEpoch();
        _payTip();
        emit EpochAdvanced(msg.sender, vault.epochId());
    }

    // ══════════════════════════════════════════════
    // DELOOP FOR SPREAD
    // ══════════════════════════════════════════════

    /// @notice Keeper calls when weETH/ETH spread inverts (off-chain check).
    ///         Unwinds specified amount to lock in spread profit.
    /// @dev L-5: Max 30% of position per call to prevent full drain by compromised keeper
    function deloopForSpread(uint256 amount) external onlyWhitelisted nonReentrant {
        require(amount > 0, "zero amount");
        // Cap at 30% of strategy equity per call
        (uint256 coll, uint256 debt) = strategy.getPosition();
        uint256 peg = strategy.getPeg();
        uint256 collValue = coll * peg / 1e18;
        uint256 equity = collValue > debt ? collValue - debt : 0;
        uint256 maxAmount = equity * 3000 / BPS; // 30%
        require(amount <= maxAmount, "exceeds 30% cap");
        strategy.leverageDown(amount);
        _payTip();
        emit DeloopedForSpread(msg.sender, amount);
    }

    // ══════════════════════════════════════════════
    // TIP MECHANISM
    // ══════════════════════════════════════════════

    function _payTip() internal {
        if (address(this).balance >= KEEPER_TIP) {
            (bool ok,) = msg.sender.call{value: KEEPER_TIP}("");
            if (ok) {
                emit TipPaid(msg.sender, KEEPER_TIP);
            }
            // Don't revert if tip fails — action already completed
        }
    }

    /// @notice Fund the keeper module with ETH for tips
    receive() external payable {}
}
