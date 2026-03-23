# weETH Looping Vault — Final Design v2

> v1 → v2 변경: eng review 반영. nLoops 제거, idle buffer, 증분 루핑,
> flashloan 순서 수정, UUPS proxy, 최소 deposit, epoch 스냅샷 sharePrice.

## Overview

```
"ETH 넣으면 weETH 자동 루핑해서 ~9% APR"
Phase 1: 단일 풀, Tranche 없음. 모든 예치자 동일 수익률.
Phase 2: TVL $5M+ 이후 UUPS upgrade로 Fixed/Variable Tranche 추가.
```

## Architecture

```
                         ┌──────────────────────────────┐
                         │         User (EOA)            │
                         │   deposit ETH / withdraw ETH  │
                         │   min deposit: 0.3 ETH (~$1K) │
                         └────────────┬─────────────────┘
                                      │
                         ┌────────────▼─────────────────┐
                         │  LoopVault.sol                 │
                         │  (ERC-4626 + UUPSUpgradeable)  │
                         │                                │
                         │  ┌──────────────────────────┐ │
                         │  │ Idle Buffer (5-10% TVL)   │ │
                         │  │ 소액 출금 즉시 처리       │ │
                         │  └──────────────────────────┘ │
                         │                                │
                         │  deposit() → idle buffer에 적립 │
                         │  requestWithdraw() → 7일 delay  │
                         │  completeWithdraw() → buffer/   │
                         │                      deloop     │
                         │  sharePrice: epoch 스냅샷 기반   │
                         └──┬──────────────┬──────────────┘
                            │              │
                 ┌──────────▼──┐    ┌──────▼──────────────┐
                 │  EtherFi    │    │  LoopStrategy.sol    │
                 │  ETH→weETH  │    │                      │
                 │  (0.1% fee) │    │  leverageUp(amt)     │
                 └─────────────┘    │  leverageDown(amt)   │
                                    │  emergencyUnwind()   │
                                    │  flashloan callback  │
                                    └──────┬──────────────┘
                                           │
                              ┌────────────▼────────────────┐
                              │  Morpho Blue                  │
                              │  weETH/ETH Market             │
                              │  market ID 하드코딩           │
                              │  Chainlink weETH/ETH oracle   │
                              └───────────────────────────────┘

                         ┌────────────────────────────────┐
                         │  KeeperModule.sol               │
                         │                                 │
                         │  rebalance()                    │
                         │   ├─ LTV 체크 → deleverage      │
                         │   ├─ spread 체크 → deloop/reloop │
                         │   └─ buffer 체크 → harvest       │
                         │                                 │
                         │  harvest()                       │
                         │   ├─ idle buffer → leverage up   │
                         │   └─ yield → buffer 보충         │
                         │                                 │
                         │  Phase 1: whitelist              │
                         │  Phase 2: permissionless + tip   │
                         └────────────────────────────────┘
```

## Contracts (3 + 1 library)

### 1. LoopVault.sol (ERC-4626 + UUPS)

메인 볼트. 유저 인터페이스. 업그레이드 가능.

```
상태:
  // ── Position tracking (nLoops 없음 — collateral/debt 비율로 관리) ──
  strategy           : ILoopStrategy  // LoopStrategy 주소
  morphoMarketId     : bytes32

  // ── Idle buffer ──
  idleETH            : uint256        // 루핑 안 된 ETH (즉시 출금용)
  IDLE_TARGET_BPS    : 500            // 5% of TVL
  IDLE_MIN_BPS       : 200            // 2% 이하면 harvest 안 함
  IDLE_MAX_BPS       : 1000           // 10% 이상이면 keeper가 루핑

  // ── Epoch & withdrawal ──
  epochId            : uint256
  epochStartTime     : uint256
  EPOCH_DURATION     : 7 days
  MAX_WITHDRAW_PCT   : 2000           // 20% in BPS
  epochWithdrawnBPS  : uint256        // 이번 epoch 누적 출금률
  withdrawalQueue    : mapping(address => WithdrawalRequest)

  // ── Share price (epoch 스냅샷) ──
  lastSnapshotAssets : uint256        // epoch 시작 시 totalAssets
  lastSnapshotSupply : uint256        // epoch 시작 시 totalSupply
  lastSnapshotTime   : uint256

  // ── Fees ──
  PERF_FEE_BPS       : 1000          // 10%
  RESERVE_BPS        : 300            // 3%
  MIN_DEPOSIT        : 0.3 ether     // ~$1K (가스비 대비 최소 의미 있는 금액)

  // ── Safety ──
  lastDepositBlock   : mapping(address => uint256)  // anti-sandwich

함수:

  deposit(uint256 assets) external payable returns (uint256 shares)
    require(msg.value >= MIN_DEPOSIT)
    require(lastDepositBlock[msg.sender] != block.number)  // anti-sandwich
    lastDepositBlock[msg.sender] = block.number

    shares = _convertToShares(msg.value)  // epoch 스냅샷 기반
    _mint(msg.sender, shares)
    idleETH += msg.value

    // deposit은 idle에만 적립. keeper가 배치로 leverage up.
    // 이유: deposit마다 4루프 실행 = 2M gas. 배치가 효율적.
    emit Deposit(msg.sender, msg.value, shares)

  requestWithdraw(uint256 shares) external
    require(lastDepositBlock[msg.sender] < block.number)  // 같은 블록 금지
    require(shares <= balanceOf(msg.sender))

    // epoch cap 체크
    uint256 pct = shares * 10000 / totalSupply()
    require(epochWithdrawnBPS + pct <= MAX_WITHDRAW_PCT, "epoch cap")

    _transfer(msg.sender, address(this), shares)  // lock
    withdrawalQueue[msg.sender] = WithdrawalRequest({
        shares: shares,
        epochId: epochId,
        timestamp: block.timestamp
    })
    epochWithdrawnBPS += pct
    emit WithdrawRequested(msg.sender, shares, epochId)

  completeWithdraw() external returns (uint256 assets)
    WithdrawalRequest memory req = withdrawalQueue[msg.sender]
    require(req.shares > 0, "no request")
    require(epochId > req.epochId, "wait next epoch")

    assets = _convertToAssets(req.shares)  // 실행 시점 스냅샷
    delete withdrawalQueue[msg.sender]
    _burn(address(this), req.shares)

    // idle buffer에서 먼저
    if (idleETH >= assets) {
        idleETH -= assets
    } else {
        uint256 needed = assets - idleETH
        idleETH = 0
        strategy.leverageDown(needed)  // deloop으로 ETH 확보
    }
    payable(msg.sender).transfer(assets)
    emit WithdrawCompleted(msg.sender, assets, req.shares)

  // ── Share price: epoch 스냅샷 기반 ──
  // 매 tx에서 oracle 읽지 않음. epoch 시작 시 1번만 계산.
  totalAssets() public view returns (uint256)
    return lastSnapshotAssets  // 캐시 반환

  _liveAssets() internal view returns (uint256)
    // 실제 자산 계산 (keeper의 epoch 갱신 시에만 호출)
    (uint256 coll, uint256 debt) = strategy.getPosition()
    uint256 peg = _getTWAP()
    return coll * peg / 1e18 - debt + idleETH + reserve

  advanceEpoch() external  // keeper가 호출
    require(block.timestamp >= epochStartTime + EPOCH_DURATION)
    lastSnapshotAssets = _liveAssets()
    lastSnapshotSupply = totalSupply()
    lastSnapshotTime = block.timestamp
    epochId++
    epochStartTime = block.timestamp
    epochWithdrawnBPS = 0
    emit EpochAdvanced(epochId, lastSnapshotAssets)

  // ── TWAP (간소화: Chainlink heartbeat 의존) ──
  _getTWAP() internal view returns (uint256)
    // Chainlink weETH/ETH는 이미 heartbeat + deviation threshold 있음
    // 별도 TWAP 불필요 — Chainlink 자체가 조작 방어
    // stale 체크만 추가
    (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData()
    require(block.timestamp - updatedAt < 1 hours, "oracle stale")
    require(answer > 0, "invalid price")
    return uint256(answer)
```

### 2. LoopStrategy.sol

루핑/디루핑 엔진. Vault만 호출 가능.

```
상태:
  vault              : address        // LoopVault (onlyVault modifier)
  morpho             : IMorpho
  marketId           : bytes32
  etherfi            : IEtherFi
  flashloanProvider  : IFlashLoan     // Balancer or Morpho flash
  MAX_LTV_BPS        : 9000           // 90%
  TARGET_LTV_BPS     : 8500           // 85%
  DELEV_THRESH_BPS   : 8500           // 85% — deleverage trigger
  EMERG_LTV_BPS      : 9200           // 92% — emergency

함수:

  leverageUp(uint256 ethAmount) external onlyVaultOrKeeper
    // 증분 루핑: 기존 포지션에 추가 (전체 재구성 아님)
    //
    // 1. ETH → weETH 래핑
    uint256 weethAmount = etherfi.wrap{value: ethAmount}()
    // 2. Morpho에 담보 추가
    morpho.supplyCollateral(marketId, weethAmount)
    // 3. 현재 LTV 확인 후 TARGET까지 루핑
    _leverageToTarget()

  _leverageToTarget() internal
    // flashloan 1번으로 다단계 루핑 처리 (가스 절약)
    //
    // 현재 상태: collateral C, debt D, LTV = D/(C*peg)
    // 목표: LTV = TARGET_LTV_BPS / 10000
    //
    // 필요 추가 차입 = (C * peg * targetLTV - D) / (1 - targetLTV)
    // → flashloan ETH → wrap → supply → borrow → repay flash
    //
    (uint256 coll, uint256 debt) = getPosition()
    uint256 peg = vault._getTWAP()
    uint256 targetDebt = coll * peg * TARGET_LTV_BPS / 10000 / 1e18
    if (targetDebt <= debt) return  // 이미 충분

    uint256 additionalBorrow = targetDebt - debt
    // Safety margin: 95%
    additionalBorrow = additionalBorrow * 95 / 100

    if (additionalBorrow < 0.01 ether) return  // too small

    // Single flashloan: borrow ETH → wrap → supply collateral → borrow from Morpho → repay flash
    flashloanProvider.flashLoan(
        address(this),
        ETH,
        additionalBorrow,
        abi.encode(FlashAction.LEVERAGE_UP, additionalBorrow)
    )

  leverageDown(uint256 ethNeeded) external onlyVaultOrKeeper returns (uint256)
    // 부분 디루핑: 필요한 ETH만큼만 포지션 축소
    //
    // 얼마나 풀어야 하나:
    // 현재 equity = C*peg - D
    // ethNeeded 만큼 equity에서 빼려면
    // repay할 debt = ethNeeded * D / equity (비례적)
    // withdraw할 collateral = ethNeeded * C / equity
    //
    (uint256 coll, uint256 debt) = getPosition()
    uint256 peg = vault._getTWAP()
    uint256 equity = coll * peg / 1e18 - debt
    require(equity > 0, "underwater")

    uint256 debtToRepay = ethNeeded * debt / equity
    uint256 collToWithdraw = ethNeeded * coll / equity

    // Flashloan: borrow ETH → repay Morpho → withdraw weETH → swap weETH→ETH → repay flash
    flashloanProvider.flashLoan(
        address(this),
        ETH,
        debtToRepay,
        abi.encode(FlashAction.LEVERAGE_DOWN, debtToRepay, collToWithdraw)
    )

    // 남은 ETH를 vault으로 전송
    uint256 ethOut = address(this).balance
    payable(vault).transfer(ethOut)
    return ethOut

  emergencyUnwind() external onlyVaultOrKeeper
    // 전체 포지션 해제
    (uint256 coll, uint256 debt) = getPosition()
    if (debt == 0) return

    // Flashloan 전체 debt → repay → withdraw all collateral → swap → repay flash
    flashloanProvider.flashLoan(
        address(this),
        ETH,
        debt,
        abi.encode(FlashAction.EMERGENCY, debt, coll)
    )
    payable(vault).transfer(address(this).balance)
    emit EmergencyUnwind(debt, coll)

  // ── Flashloan callback ──
  onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
    (FlashAction action, ...) = abi.decode(data, ...)

    if action == LEVERAGE_UP:
      // ETH → wrap → supply collateral → borrow from Morpho → have ETH to repay flash
      uint256 weeth = etherfi.wrap{value: amount}()
      morpho.supplyCollateral(marketId, weeth)
      morpho.borrow(marketId, amount + fee)  // borrow to repay flash
      // ETH now available to repay flashloan

    elif action == LEVERAGE_DOWN:
      // repay Morpho debt → withdraw collateral → swap weETH → ETH
      morpho.repay(marketId, debtToRepay)
      morpho.withdrawCollateral(marketId, collToWithdraw)
      uint256 ethReceived = _swapWeETHtoETH(collToWithdraw)
      // ethReceived covers flash amount + fee + profit for vault

    elif action == EMERGENCY:
      morpho.repay(marketId, debt)
      morpho.withdrawCollateral(marketId, coll)
      uint256 ethReceived = _swapWeETHtoETH(coll)

    // repay flashloan
    IERC20(token).transfer(msg.sender, amount + fee)

  _swapWeETHtoETH(uint256 weethAmount) internal returns (uint256)
    // 경로 선택:
    // 1. peg > 0.995: EtherFi requestWithdraw (더 싸지만 즉시 아님)
    //    → Phase 1에서는 항상 DEX 사용 (즉시성 우선)
    // 2. DEX swap via 1inch / Uniswap
    //    → slippage tolerance: max(1%, depeg * 2)
    return router.swap(weETH, ETH, weethAmount, minOut)

  getPosition() public view returns (uint256 collateral, uint256 debt)
    collateral = morpho.collateral(marketId, address(this))
    debt = morpho.borrowBalance(marketId, address(this))

  getLTV() public view returns (uint256)
    (uint256 c, uint256 d) = getPosition()
    uint256 peg = vault._getTWAP()
    return c > 0 ? d * 1e18 / (c * peg / 1e18) : 0
```

### 3. KeeperModule.sol

Keeper 로직. 누구나 호출 가능하되 조건 충족 시에만 실행.

```
상태:
  vault              : ILoopVault
  strategy           : ILoopStrategy
  lastRebalanceTime  : uint256
  MIN_REBALANCE_GAP  : 1 hours
  KEEPER_TIP         : 0.01 ether
  MIN_SPREAD_BPS     : 0             // spread < 0이면 deloop
  RELOOP_SPREAD_BPS  : 200           // spread > 2%이면 reloop 가능
  RELOOP_MAX_LTV_BPS : 6500          // reloop 시 최대 LTV 65%
  RELOOP_MIN_PEG     : 0.995e18

함수:

  rebalance() external returns (bool executed)
    require(block.timestamp - lastRebalanceTime >= MIN_REBALANCE_GAP)

    uint256 ltv = strategy.getLTV()
    uint256 peg = vault._getTWAP()

    // Priority 1: Emergency
    if (ltv >= strategy.EMERG_LTV_BPS()) {
        strategy.emergencyUnwind()
        _payTip(msg.sender)
        emit Rebalanced("EMERGENCY", ltv, peg)
        return true
    }

    // Priority 2: Deleverage
    if (ltv >= strategy.DELEV_THRESH_BPS()) {
        // LTV를 TARGET × 0.95까지 낮추기
        uint256 targetLTV = strategy.TARGET_LTV_BPS() * 95 / 100
        uint256 excessDebt = _calcExcessDebt(ltv, targetLTV)
        strategy.leverageDown(excessDebt)
        _payTip(msg.sender)
        emit Rebalanced("DELEVERAGE", ltv, peg)
        return true
    }

    // Priority 3: Spread inversion deloop (keeper가 오프체인에서 spread 계산)
    // 온체인에서 weETH yield 읽을 수 없음 → keeper만 판단 가능
    // → deloopForSpread()는 별도 함수, keeper whitelist만 호출

    // Priority 4: Idle buffer → leverage up
    uint256 idle = vault.idleETH()
    uint256 totalAssets = vault._liveAssets()
    uint256 idlePct = idle * 10000 / totalAssets
    if (idlePct > vault.IDLE_MAX_BPS() && peg >= RELOOP_MIN_PEG) {
        uint256 toLeverage = idle - totalAssets * vault.IDLE_TARGET_BPS() / 10000
        strategy.leverageUp(toLeverage)
        _payTip(msg.sender)
        emit Rebalanced("HARVEST", ltv, peg)
        return true
    }

    return false  // nothing to do

  // ── Spread 기반 deloop (keeper only — 오프체인 spread 계산) ──
  deloopForSpread(uint256 ethToDeloop) external onlyWhitelisted
    // keeper가 오프체인에서 spread < 0 확인 후 호출
    // 컨트랙트는 keeper를 신뢰하되, 안전장치 추가:
    require(ethToDeloop <= vault._liveAssets() * 3000 / 10000, "max 30% per call")
    strategy.leverageDown(ethToDeloop)
    _payTip(msg.sender)
    emit Rebalanced("DELOOP_SPREAD", strategy.getLTV(), 0)

  // ── Epoch advance ──
  advanceEpochIfNeeded() external
    vault.advanceEpoch()  // vault 내부에서 시간 체크
    _payTip(msg.sender)

  _payTip(address keeper) internal
    // vault의 idle buffer에서 tip 지급
    vault.payKeeperTip(keeper, KEEPER_TIP)

  _calcExcessDebt(uint256 currentLTV, uint256 targetLTV) internal view returns (uint256)
    (uint256 coll, uint256 debt) = strategy.getPosition()
    uint256 peg = vault._getTWAP()
    uint256 targetDebt = coll * peg * targetLTV / 10000 / 1e18
    return debt > targetDebt ? debt - targetDebt : 0
```

### 4. MathLib.sol (library)

```
library MathLib {
  function calcLTV(uint256 collateral, uint256 debt, uint256 peg)
    internal pure returns (uint256)
    if (collateral == 0) return type(uint256).max
    return debt * 1e18 / (collateral * peg / 1e18)

  function calcLeverageAmount(
    uint256 collateral, uint256 debt, uint256 peg, uint256 targetLTV
  ) internal pure returns (uint256 additionalBorrow)
    // 현재 LTV에서 target LTV까지 추가 차입 필요량
    uint256 targetDebt = collateral * peg / 1e18 * targetLTV / 1e18
    if (targetDebt <= debt) return 0
    return (targetDebt - debt) * 95 / 100  // 5% safety margin

  function calcUnwindAmount(
    uint256 collateral, uint256 debt, uint256 peg, uint256 ethNeeded
  ) internal pure returns (uint256 debtToRepay, uint256 collToWithdraw)
    // ethNeeded 확보를 위해 비례적으로 포지션 축소
    uint256 equity = collateral * peg / 1e18 - debt
    require(equity > 0, "underwater")
    debtToRepay = ethNeeded * debt / equity
    collToWithdraw = ethNeeded * collateral / equity
}
```

## Flows

### Deposit Flow
```
User → deposit(1 ETH)
  │
  ├─ 1. require(msg.value >= 0.3 ETH)
  ├─ 2. shares = 1 ETH × lastSnapshotSupply / lastSnapshotAssets
  ├─ 3. mint shares to user
  ├─ 4. idleETH += 1 ETH
  ├─ 5. emit Deposit
  │
  └─ 끝. (루핑은 keeper가 나중에 배치로 처리)

Keeper → rebalance() (idle > 10%)
  │
  ├─ idle = 2 ETH (10% 초과분)
  ├─ strategy.leverageUp(2 ETH - buffer)
  │   ├─ wrap 2 ETH → weETH
  │   ├─ supply collateral
  │   ├─ flashloan으로 한 번에 target LTV까지 루핑
  │   └─ 결과: 기존 포지션 + 증분만큼 확대
  └─ keeper tip 0.01 ETH 지급
```

### Withdraw Flow
```
User → requestWithdraw(shares)
  │
  ├─ Day 0: shares lock
  │         epoch cap 20% 체크
  │         emit WithdrawRequested
  │
  ├─ Day 7+: (다음 epoch 이후)
  │   │
  │   User → completeWithdraw()
  │   │
  │   ├─ assets = shares × epoch스냅샷 sharePrice
  │   │
  │   ├─ if idleETH >= assets:
  │   │     idleETH -= assets  ← 즉시! deloop 불필요
  │   │
  │   ├─ else:
  │   │     needed = assets - idleETH
  │   │     strategy.leverageDown(needed)
  │   │       ├─ flashloan ETH
  │   │       ├─ repay Morpho (비례적)
  │   │       ├─ withdraw weETH (비례적)
  │   │       ├─ swap weETH → ETH
  │   │       └─ repay flash, 남은 ETH → vault
  │   │
  │   └─ ETH transfer to user
  │
  └─ 뱅크런: epoch 20% cap → 대기열. idle buffer가 1차 방어선.
```

### Rebalance Flow
```
Keeper → rebalance() (매 1시간)

  ┌─ LTV >= 92% ─────────────── emergencyUnwind()
  │                               flashloan → 전체 repay → withdraw → swap
  │
  ├─ LTV >= 85% ─────────────── leverageDown(excessDebt)
  │                               목표 LTV 81%까지 비례적 축소
  │
  ├─ idle > 10% TVL ──────────── leverageUp(excess idle)
  │  && peg > 0.995               idle에서 target 5%까지 루핑
  │
  └─ else ─────────────────────── no-op

Keeper → deloopForSpread() (오프체인 spread 체크 후)

  ┌─ spread < -1% ────────────── leverageDown(1 loop equivalent)
  │  (keeper가 판단)
  │
  ├─ spread > 2% && LTV < 65% ── leverageUp(idle buffer)
  │  && peg > 0.995
  │
  └─ else ─────────────────────── no-op

Keeper → advanceEpochIfNeeded() (매 7일)
  └─ epoch 갱신 + sharePrice 스냅샷 + 출금 cap 리셋
```

## Parameters

```
┌──────────────────────┬───────────┬────────────────────────────────────────┐
│ Parameter            │ Value     │ Rationale                              │
├──────────────────────┼───────────┼────────────────────────────────────────┤
│ MAX_LTV              │ 90%       │ Morpho market 한도                     │
│ TARGET_LTV           │ 85%       │ 루핑 목표 (5% margin)                  │
│ DELEV_THRESHOLD      │ 85%       │ 디레버리지 트리거                      │
│ EMERGENCY_LTV        │ 92%       │ 긴급 전체 해제                         │
│ IDLE_TARGET          │ 5%        │ 출금 buffer 목표                       │
│ IDLE_MIN             │ 2%        │ 이하면 harvest 중단                    │
│ IDLE_MAX             │ 10%       │ 이상이면 keeper가 루핑                 │
│ EPOCH_DURATION       │ 7 days    │ 출금 대기 + sharePrice 갱신 주기       │
│ MAX_WITHDRAW_PCT     │ 20%       │ epoch당 출금 cap                       │
│ PERF_FEE             │ 10%       │ 프로토콜 수수료                        │
│ RESERVE              │ 3%        │ 리저브 버퍼                            │
│ MIN_DEPOSIT          │ 0.3 ETH   │ ~$1K (가스비 대비 최소 의미)           │
│ KEEPER_TIP           │ 0.01 ETH  │ keeper 인센티브                        │
│ MIN_REBALANCE_GAP    │ 1 hour    │ keeper 스팸 방지                       │
│ WRAP_FEE             │ 0.1%      │ EtherFi wrapping                      │
│ MORPHO_MARKET_ID     │ TBD       │ governance로만 변경 (UUPS upgrade)     │
│ RELOOP_SPREAD        │ 2%        │ reloop 조건                            │
│ RELOOP_MAX_LTV       │ 65%       │ reloop 안전 LTV 상한                   │
│ RELOOP_MIN_PEG       │ 0.995     │ reloop 최소 peg                        │
│ DELOOP_MAX_PCT       │ 30%       │ spread deloop 1회 최대                 │
└──────────────────────┴───────────┴────────────────────────────────────────┘
```

## Security

### Attack Vectors & Mitigations
```
1. Flashloan 가격 조작
   공격: flashloan → DEX weETH 덤핑 → peg↓ → vault 디레버리지
   방어: Chainlink oracle (DEX 가격 아님) + heartbeat 1시간 체크
         Morpho 자체 oracle도 Chainlink → 이중 방어

2. Share price manipulation
   공격: oracle stale 시점에 deposit → peg 회복 후 withdraw → 차익
   방어: epoch 스냅샷 sharePrice (매 tx에서 oracle 안 읽음)
         1 epoch (7일) 출금 delay
         같은 블록 deposit→withdraw 금지

3. Sandwich attack on deposit
   공격: front-run deposit → weETH 가격 올리기 → share 적게 발행
   방어: deposit은 idle buffer에만 적립 (루핑 없음)
         sharePrice는 epoch 시작 시 고정 → sandwich 무의미

4. Keeper griefing
   공격: 불필요 rebalance 반복
   방어: MIN_REBALANCE_GAP 1시간
         rebalance() 조건 미충족 시 revert (가스 낭비만)
         spread deloop은 whitelist only (Phase 1)

5. Reentrancy
   방어: ReentrancyGuard on deposit/withdraw/rebalance
         CEI 패턴
         flashloan callback에서 vault 상태 변경 금지

6. Oracle failure
   방어: isStale() → 1시간 초과 시 revert
         stale 상태에서는 deposit/withdraw 모두 중단
         keeper가 emergencyUnwind() 호출 가능 (stale 예외)

7. Idle buffer drain
   공격: 대량 출금으로 idle 고갈 → 다음 출금에 deloop 강제
   방어: epoch 20% cap
         idle < 2% 시 deposit idle가 leverage에 안 감

8. Upgrade attack (UUPS)
   방어: 2-of-3 multisig owner
         timelock 48시간
         upgrade 시 invariant 체크
```

### Invariants
```
1. LTV <= MAX_LTV (92% emergency threshold)
   예외: atomic flashloan tx 내부 (같은 tx에서 복구)

2. idleETH + collateral * peg - debt >= totalSupply * sharePrice
   전체 자산 >= 전체 share 가치

3. epochWithdrawnBPS <= MAX_WITHDRAW_PCT
   epoch당 출금 cap

4. oracle updatedAt < 1 hour ago (else pause)

5. strategy.balance == 0 (strategy는 ETH를 보유하지 않음, vault만)

6. flashloan callback에서 vault 상태 불변 (reentrancy guard)
```

## Risk Disclosure (for users)

```
═══════════════════════════════════════════
정상 시장:    ~9% APR
10% 디페그:   ~8% APR, 원금 손실 없음
15% 디페그:   ~8% APR, 원금 손실 없음 (동적 디루프)
20%+ 디페그:  원금 손실 가능 (참고: 역사적 최대 stETH 7%)

ETH 가격 하락은 원금에 영향 없음 (correlated pair)

출금: 요청 후 7일 대기. epoch당 TVL 20%까지.

백테스트 미반영 리스크:
- EigenLayer 슬래싱
- Morpho/EtherFi 스마트컨트랙트 버그
- 규제 변경
═══════════════════════════════════════════
```

## Phase 2 Upgrade Path

```
TVL $5M+ 달성 후 UUPS upgrade:

LoopVault.sol → LoopVaultV2.sol (같은 proxy)
  ├─ 기존 share → vToken (Variable) 자동 전환
  ├─ 신규 fToken (Fixed) 민팅 추가
  │   └─ Fixed 3% APR, 1순위 분배
  ├─ 워터폴 로직 추가:
  │   gross → perf fee → reserve → Fixed → Variable
  └─ storage layout 호환 필수 (gap slots 미리 확보)

기존 유저: 별도 마이그레이션 없음. share가 vToken이 됨.
```

## File Structure

```
contracts/
  ├─ LoopVault.sol             // ERC-4626 + UUPS proxy
  ├─ LoopStrategy.sol          // 루핑/디루핑 + flashloan
  ├─ KeeperModule.sol          // rebalance + harvest
  ├─ lib/
  │   └─ MathLib.sol           // LTV, leverage, unwind 계산
  └─ interfaces/
      ├─ IMorpho.sol
      ├─ IEtherFi.sol
      ├─ ILoopStrategy.sol
      └─ IFlashLoan.sol

test/
  ├─ unit/
  │   ├─ LoopVault.t.sol
  │   ├─ LoopStrategy.t.sol
  │   └─ MathLib.t.sol
  ├─ integration/
  │   ├─ DepositWithdraw.t.sol
  │   ├─ Rebalance.t.sol
  │   └─ Emergency.t.sol
  └─ invariants/
      └─ Invariants.t.sol      // fuzz + invariant

script/
  ├─ Deploy.s.sol
  ├─ Upgrade.s.sol             // UUPS upgrade
  └─ Configure.s.sol
```

## Eng Review Changelog (v1 → v2)

```
[CRITICAL] deposit마다 전체 재루핑 → idle buffer + keeper 배치 루핑
[CRITICAL] flashloan 순서 수정 → flash ETH → repay → withdraw → swap → return
[CRITICAL] nLoops 추적 제거 → collateral/debt 비율로 비례적 관리
[CRITICAL] totalAssets() 매 tx oracle → epoch 스냅샷 캐싱
[HIGH]     출금 시 전체 deloop → 부분 deloop (비례적 축소)
[HIGH]     idle ETH buffer 추가 (5-10%) → 소액 출금 즉시, deloop 빈도↓
[HIGH]     onchain spread 계산 불가 인정 → keeper offchain 판단 + whitelist
[HIGH]     최소 deposit 0.3 ETH (~$1K) → 가스비 문제 해결
[MEDIUM]   UUPS proxy 추가 → Phase 2 upgrade 대비, storage gap 확보
[MEDIUM]   keeper permissionless 전환 로드맵 (Phase 2)
[MEDIUM]   OracleManager.sol 제거 → Chainlink 직접 사용 (자체 TWAP 불필요)
[MEDIUM]   4 contracts → 3 contracts + 1 library (복잡도↓)
```

---
Generated: 2026-03-24
Based on: Phase 1 v3 pessimistic backtest (391 days, ETH $1,472-$4,831)
Eng review: 10 issues fixed (4 critical, 3 high, 3 medium)
