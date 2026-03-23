# Phase 1: weETH Looping Vault — Backtest Results

## 구조
```
ETH → weETH 래핑(EtherFi) → Morpho 담보 → ETH 차입 → weETH 래핑 → 반복(x4)
수익: weETH yield 5% × 3.6배 - ETH 차입 1.5%
리스크: weETH/ETH 디페그만 (ETH 가격 무관, correlated pair)
```

## 백테스트 모델 (v3 — Pessimistic Realism)
- 비선형 슬리피지: $50M 풀 기준, 2022 stETH Curve 데이터 캘리브레이션
- Oscillating 디페그: 공포→반등→더 큰 공포 6단계 패턴
- Yield 하락: 디페그 시 restaking yield 비례 감소
- Cascading feedback: 디페그→borrow rate↑→유동성↓ 피드백 루프
- Oracle 지연: 1일 stale peg으로 디레버리지 판단
- 실행 지연: 디레버리지 tx 중 peg 추가 2% 하락
- Unwrap 비용: DEX 우회 시 +0.5% 추가 슬리피지
- 동적 디루프: spread < 0이면 자동 루프 축소
- Keeper 비용: 디레버리지 tx당 0.01 ETH tip
- $500K 청크 분할 매도

## 핵심 결과

### Performance
| 시나리오 | APR | 원금 손실 | 비고 |
|----------|-----|-----------|------|
| 정상 시장 | **9.2%** | 0% | |
| 5% 디페그 | 8.7% | 0% | 역사적 최대 stETH=7% |
| 10% 디페그 | 8.4% | 0% | |
| 10% 디페그 + borrow spike | 8.4% | 0% | |
| 15% 디페그 + borrow spike | 8.2% | **0%** | 동적 디루프 덕분 |
| 20% 디페그 | 8.2% | 0% | 참고용 |
| 25% 블랙스완 | 8.1% | 0% | 참고용 |

### 핵심 방어 메커니즘
**동적 디루프가 LTV 기반 디레버리지보다 중요.**
- cascading feedback로 디페그 시 borrow rate 상승 → spread 역전
- spread < 0 감지 → 자동 루프 축소 (4→1)
- LTV 위험 전에 미리 루프 해제 → 슬리피지 최소화
- 1루프 상태에서는 25% 디페그도 LTV 안전

### v2(낙관) vs v3(비관) 비교
| | v2 | v3 | 차이 |
|---|-----|-----|------|
| 정상 APR | 10.8% | 9.2% | -1.6% (cascading borrow + deloop 비용) |
| 15%dp 손실 | -7.0% | 0% | 동적 디루프가 선제 방어 |
| 20%dp 손실 | -20.7% | 0% | 동적 디루프가 선제 방어 |

### TVL 가이드
| TVL | 정상 APR | 가스비 비율 |
|-----|---------|-----------|
| $100K | 8.5% | 7.7% |
| $250K | 8.9% | 3.1% |
| $500K | 9.1% | 1.5% |
| $1M+ | 9.2% | <1% |

최소 권장: $250K+

## 리스크 고지 (Risk Disclosure)

### 백테스트 기반
- 디페그 15% 이내: 원금 손실 없음 (비관적 모델 기준)
- APR 변동: 정상 9.2% → 스트레스 8.2% (안정적)
- 역사적 최대 디페그: stETH 7% (2022), weETH 3% (2024)

### 백테스트 미반영 리스크 (컨트랙트 설계로 대응 필요)
1. **EigenLayer 슬래싱** — weETH 자체가 가치 상실
2. **Morpho Blue 스마트컨트랙트 버그** — 담보/부채 접근 불가
3. **EtherFi wrapper 버그** — weETH ↔ ETH 변환 불가
4. **Vault 자체 버그** — 모든 자금 손실 가능
5. **규제 리스크** — staking/restaking 규제 변경

→ 이것들은 백테스트로 커버 불가. "인프라가 죽으면 나도 죽는" 리스크.

## 컨트랙트 설계 포인트 6개

### 1. Keeper 설계
- 전용 keeper bot + Gelato Automation 이중화
- 유저 tx piggyback (deposit/withdraw 시 LTV+spread 체크)
- keeper 다운 → 유저 tx에서도 디레버리지 가능하게

### 2. Flashloan 방어
- TWAP oracle (30분+) for share price
- 같은 블록 deposit→withdraw 금지 (1 epoch delay)
- Morpho Blue는 Chainlink oracle → 조작 난이도 높음

### 3. ERC-4626 Share Price MEV
- share price = (collateral × TWAP_peg - debt) / totalShares
- 출금: 요청 → 다음 epoch(7일) 실행
- anti-sandwich: share price에 EMA 적용

### 4. Morpho Market 선택
- market ID 하드코딩 (governance 변경만 가능)
- 단일 market 집중 (유동성 분산 방지)
- oracle, LTV, IRM 검증 후 선택

### 5. weETH Unwrap 경로
- 정상: EtherFi 직접 unwrap (7일+ queue)
- 긴급: DEX swap (빠름, 슬리피지)
- 뱅크런 대응: epoch당 출금 cap (TVL의 20%)
- queue > 3일 → DEX fallback (슬리피지 유저 부담)

### 6. Dynamic Rebalancing
- keeper가 주기적 spread 체크
- spread < 0 → deloop 1개
- spread < -3% → deloop 2개
- spread 회복 시 → re-loop (가스비 vs 기대수익 비교 후)
- borrow rate 역전 시 루프 유지하면 안 됨 — 이게 핵심 방어선

## Phase 2 업그레이드 경로
TVL $5M+ 달성 후:
- Fixed 3% (안정) + Variable ~42% (레버리지) Tranche 추가
- 기존 유동성 기반 → cold start 없음
- Fixed 유치: "DeFi에서 국채급 고정수익" 포지셔닝

---
Generated: 2026-03-24
Model: v3 pessimistic (oracle delay, exec delay, cascading, unwrap, dynamic deloop, keeper)
Data: 391 days ETH price ($1,472-$4,831)
