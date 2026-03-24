// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IChainlinkAggregator.sol";
import "./LoopStrategy.sol";

/// @title LoopVault — ERC-4626 vault for weETH looping strategy
/// @notice Users deposit ETH (auto-wrapped to WETH). Keeper batches into leveraged weETH position.
///         Withdrawals have 1 epoch (7 day) delay. Idle buffer handles small withdrawals instantly.
/// @dev C-3 (donation attack) mitigated by design: all accounting uses internal state variables
///      (idleAssets, strategy.getPosition()) — never raw balanceOf. Direct token transfers to the
///      vault or strategy do NOT inflate internal accounting.
/// @dev H-5: OZ 5.x ReentrancyGuard uses transient storage (Cancun EVM), no persistent storage
///      slots — safe in upgradeable context without storage gaps.
contract LoopVault is
    ERC4626Upgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ── Structs ──
    struct WithdrawalRequest {
        uint256 shares;
        uint256 epochId;
    }

    // ── State ──
    LoopStrategy public strategy;
    IWETH public weth;

    // Idle buffer
    uint256 public idleAssets;          // WETH not yet deployed to strategy
    uint256 public constant IDLE_TARGET_BPS = 500;   // 5%
    uint256 public constant IDLE_MAX_BPS = 1000;     // 10%

    // Epoch
    uint256 public epochId;
    uint256 public epochStartTime;
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant MAX_WITHDRAW_BPS = 2000; // 20% per epoch
    uint256 public epochWithdrawnBps;

    // Snapshot for share price (updated once per epoch)
    uint256 public snapshotAssets;
    uint256 public snapshotSupply;

    // Withdrawal queue
    mapping(address => WithdrawalRequest) public withdrawalQueue;

    // Fees
    uint256 public constant PERF_FEE_BPS = 1000;    // 10%
    uint256 public constant RESERVE_BPS = 300;       // 3%

    // Safety
    uint256 public constant MIN_DEPOSIT = 0.3 ether;
    mapping(address => uint256) public lastDepositBlock;

    // C-2: Access control for keeper
    address public keeper;

    // C-1: Virtual offset to prevent first-depositor attack
    uint256 private constant _OFFSET = 1e3;

    // ── Events ──
    event EpochAdvanced(uint256 indexed epochId, uint256 totalAssets);
    event WithdrawRequested(address indexed user, uint256 shares, uint256 epochId);
    event WithdrawCompleted(address indexed user, uint256 assets, uint256 shares);
    event IdleDeployed(uint256 amount);
    event KeeperUpdated(address indexed newKeeper);
    event WithdrawCancelled(address indexed user, uint256 shares);

    // ── Errors ──
    error BelowMinDeposit();
    error SameBlockDeposit();
    error EpochCapExceeded();
    error NoRequest();
    error EpochNotElapsed();
    error InsufficientAssets();
    error NotKeeper();

    // C-2: Modifier for keeper-restricted functions
    modifier onlyKeeper() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeper();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
        // NEW-3: Verify Cancun EVM (transient storage required for ReentrancyGuard)
        // tload(0) returns 0 on Cancun, reverts on pre-Cancun
        assembly {
            pop(tload(0))
        }
    }

    function initialize(
        address _weth,
        address _strategy,
        address _owner
    ) external initializer {
        __ERC4626_init(IERC20(_weth));
        __ERC20_init("Loop Vault Share", "lvETH");
        __Ownable_init(_owner);
        __Pausable_init();

        weth = IWETH(_weth);
        strategy = LoopStrategy(payable(_strategy));

        epochStartTime = block.timestamp;
        epochId = 1;

        // Approve strategy to pull WETH
        IERC20(_weth).approve(_strategy, type(uint256).max);
    }

    // ══════════════════════════════════════════════
    // DEPOSIT (ETH → WETH → idle buffer)
    // ══════════════════════════════════════════════

    /// @notice Deposit ETH. Auto-wraps to WETH. Shares minted based on epoch snapshot.
    function depositETH() external payable nonReentrant whenNotPaused returns (uint256 shares) {
        if (msg.value < MIN_DEPOSIT) revert BelowMinDeposit();
        if (lastDepositBlock[msg.sender] == block.number) revert SameBlockDeposit();
        lastDepositBlock[msg.sender] = block.number;

        // Wrap ETH → WETH
        weth.deposit{value: msg.value}();

        // Calculate shares based on snapshot
        shares = _convertToSharesSnapshot(msg.value);
        _mint(msg.sender, shares);

        // Add to idle buffer (keeper will deploy later)
        idleAssets += msg.value;

        emit Deposit(msg.sender, msg.sender, msg.value, shares);
    }

    /// @notice Standard ERC-4626 deposit (WETH). For integrations.
    /// @dev M-2: Uses msg.sender (not receiver) for same-block deposit check
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets < MIN_DEPOSIT) revert BelowMinDeposit();
        if (lastDepositBlock[msg.sender] == block.number) revert SameBlockDeposit();
        lastDepositBlock[msg.sender] = block.number;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        shares = _convertToSharesSnapshot(assets);
        _mint(receiver, shares);
        idleAssets += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ══════════════════════════════════════════════
    // WITHDRAW (request → wait epoch → complete)
    // ══════════════════════════════════════════════

    /// @notice Request withdrawal. Shares locked until next epoch.
    /// @dev H-4: Uses round-up division for epoch cap percentage to prevent rounding bypass
    function requestWithdraw(uint256 shares) external nonReentrant whenNotPaused {
        if (lastDepositBlock[msg.sender] >= block.number) revert SameBlockDeposit();
        require(shares > 0 && shares <= balanceOf(msg.sender), "invalid shares");
        require(withdrawalQueue[msg.sender].shares == 0, "pending request");

        // Epoch cap check — round up to prevent rounding bypass (H-4)
        uint256 pct = (shares * 10000 + totalSupply() - 1) / totalSupply();
        if (pct == 0) pct = 1; // minimum 1 bps
        if (epochWithdrawnBps + pct > MAX_WITHDRAW_BPS) revert EpochCapExceeded();
        epochWithdrawnBps += pct;

        // Lock shares
        _transfer(msg.sender, address(this), shares);

        withdrawalQueue[msg.sender] = WithdrawalRequest({
            shares: shares,
            epochId: epochId
        });

        emit WithdrawRequested(msg.sender, shares, epochId);
    }

    /// @notice Complete withdrawal after epoch has elapsed.
    /// @dev M-6: Reverts if insufficient assets instead of partial fill
    function completeWithdraw() external nonReentrant whenNotPaused returns (uint256 assets) {
        WithdrawalRequest memory req = withdrawalQueue[msg.sender];
        if (req.shares == 0) revert NoRequest();
        if (epochId <= req.epochId) revert EpochNotElapsed();

        assets = _convertToAssetsSnapshot(req.shares);
        delete withdrawalQueue[msg.sender];
        _burn(address(this), req.shares);

        // Try idle buffer first
        if (idleAssets >= assets) {
            idleAssets -= assets;
        } else {
            // Need to unwind some strategy position
            uint256 fromIdle = idleAssets;
            uint256 needed = assets - fromIdle;
            idleAssets = 0;
            uint256 received = strategy.leverageDown(needed);
            // M-6: Revert if insufficient — safer than partial fill
            if (fromIdle + received < assets) {
                revert InsufficientAssets();
            }
            // Track any excess as idle
            idleAssets = fromIdle + received - assets;
        }

        // Transfer WETH then unwrap to ETH for user
        weth.withdraw(assets);
        (bool ok,) = msg.sender.call{value: assets}("");
        require(ok, "ETH transfer failed");

        emit WithdrawCompleted(msg.sender, assets, req.shares);
    }

    /// @notice Cancel a pending withdrawal request. Returns locked shares to user.
    function cancelWithdraw() external nonReentrant {
        WithdrawalRequest memory req = withdrawalQueue[msg.sender];
        if (req.shares == 0) revert NoRequest();

        delete withdrawalQueue[msg.sender];
        // epochWithdrawnBps NOT restored — prevents request→cancel spam to exhaust cap
        _transfer(address(this), msg.sender, req.shares);

        emit WithdrawCancelled(msg.sender, req.shares);
    }

    // ══════════════════════════════════════════════
    // EPOCH MANAGEMENT (keeper calls)
    // ══════════════════════════════════════════════

    /// @notice Advance epoch. Updates share price snapshot. Keeper calls weekly.
    /// @dev C-2: Restricted to owner or registered keeper
    function advanceEpoch() external onlyKeeper nonReentrant {
        require(block.timestamp >= epochStartTime + EPOCH_DURATION, "too early");

        snapshotAssets = _liveAssets();
        snapshotSupply = totalSupply();

        ++epochId;
        epochStartTime += EPOCH_DURATION;
        epochWithdrawnBps = 0;

        emit EpochAdvanced(epochId, snapshotAssets);
    }

    /// @notice Deploy idle buffer to strategy. Keeper calls when idle > target.
    /// @dev C-2: Restricted to owner or registered keeper
    function deployIdle() external onlyKeeper nonReentrant {
        uint256 total = _liveAssets();
        if (total == 0) return;

        uint256 idlePct = idleAssets * 10000 / total;
        if (idlePct <= IDLE_MAX_BPS) return;

        uint256 target = total * IDLE_TARGET_BPS / 10000;
        uint256 toDeploy = idleAssets - target;
        if (toDeploy < 0.1 ether) return;

        idleAssets -= toDeploy;

        // Strategy pulls WETH via transferFrom (approval set in initialize)
        strategy.leverageUp(toDeploy);

        emit IdleDeployed(toDeploy);
    }

    // ══════════════════════════════════════════════
    // SHARE PRICE (snapshot-based)
    // ══════════════════════════════════════════════

    /// @notice Total assets = strategy equity + idle WETH
    /// @dev C-3: Uses internal accounting only — never raw balanceOf — preventing donation attacks
    function totalAssets() public view override returns (uint256) {
        // Return snapshot for consistency within epoch
        if (snapshotAssets > 0) return snapshotAssets + _idleSinceSnapshot();
        return _liveAssets();
    }

    function _liveAssets() internal view returns (uint256) {
        (uint256 coll, uint256 debt) = strategy.getPosition();
        uint256 peg = strategy.getPeg();
        uint256 collValue = coll * peg / 1e18;
        uint256 strategyEquity = collValue > debt ? collValue - debt : 0;
        return strategyEquity + idleAssets;
    }

    function _idleSinceSnapshot() internal view returns (uint256) {
        // Idle deposited since last snapshot
        // This is approximate — actual idle includes new deposits
        return idleAssets > (snapshotAssets * IDLE_TARGET_BPS / 10000)
            ? idleAssets - (snapshotAssets * IDLE_TARGET_BPS / 10000)
            : 0;
    }

    /// @dev C-1: Virtual offset (_OFFSET) prevents first-depositor inflation attack.
    ///      Always applies to both supply and total, making share price manipulation
    ///      economically infeasible even when supply is tiny.
    function _convertToSharesSnapshot(uint256 assets) internal view returns (uint256) {
        uint256 supply = snapshotSupply > 0 ? snapshotSupply : totalSupply();
        uint256 total = snapshotAssets > 0 ? snapshotAssets : _liveAssets();

        return assets * (supply + _OFFSET) / (total + _OFFSET);
    }

    /// @dev C-1: Virtual offset (_OFFSET) prevents first-depositor inflation attack.
    function _convertToAssetsSnapshot(uint256 shares) internal view returns (uint256) {
        uint256 supply = snapshotSupply > 0 ? snapshotSupply : totalSupply();
        uint256 total = snapshotAssets > 0 ? snapshotAssets : _liveAssets();

        return shares * (total + _OFFSET) / (supply + _OFFSET);
    }

    // ══════════════════════════════════════════════
    // ERC-4626 OVERRIDES (disable direct mint/withdraw)
    // ══════════════════════════════════════════════

    /// @dev Disable standard ERC-4626 mint (use deposit or depositETH)
    function mint(uint256, address) public pure override returns (uint256) {
        revert("use deposit");
    }

    /// @dev Disable standard ERC-4626 withdraw (use requestWithdraw + completeWithdraw)
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("use requestWithdraw");
    }

    /// @dev Disable standard ERC-4626 redeem
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("use requestWithdraw");
    }

    // ══════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the authorized keeper address
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Receive ETH (from WETH.withdraw)
    receive() external payable {}

    // ── Storage gap for upgrades ──
    // Original gap: 50. Consumed: 1 (keeper). Parents added: PausableUpgradeable (has own gap).
    // Our slots: strategy, weth, idleAssets, epochId, epochStartTime, epochWithdrawnBps,
    //   snapshotAssets, snapshotSupply, withdrawalQueue(map), lastDepositBlock(map), keeper = 11
    uint256[49] private __gap;
}
