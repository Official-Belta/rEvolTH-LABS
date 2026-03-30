# Nomad Protocol — Claude Code Handover Document
## Last Updated: 2026-03-30

---

## 1. 프로젝트 요약

**Nomad**는 Hyperliquid(HyperEVM + HyperCore) 위에 만드는 **자동화 옵션 전략 프로토콜**.

한 줄 설명: **"DeFi의 QYLD. USDC 넣으면 35% APR. 자동. 끝."**

유저가 USDC를 vault에 예치하면, vault가 자동으로:
1. Rysk Finance RFQ에서 option 매도 (premium 수취)
2. HyperCore perp으로 delta hedging
3. 만기마다 auto-rolling
4. Portfolio-level risk management

**타겟 유저:** 높은 APR에 반응하는 패시브 유저. 복잡한 옵션 전략을 모르지만 yield는 원하는 사람.

---

## 2. 핵심 포지셔닝

### Rysk와의 관계
- **Rysk = 거래소** (option RFQ 매매 인프라)
- **Nomad = 자산운용사** (전략 설계 + 자동 실행)
- Rysk에는 전략이 없음. 유저가 수동으로 strike 고르고 매주 반복
- Nomad가 이걸 자동화하고, 매도 측 volume을 대량 공급 → Rysk에도 이익 (win-win)
- 수익의 90%+가 Rysk RFQ에서 발생 (option premium 수취)
- 장기적으로 HIP-4 mainnet 나오면 Rysk 의존도 탈피 가능

### 경쟁 비교 (Nomad vs Rysk, 7개 차별화 항목)
1. Strike 선택: Rysk 수동 (4개 중 택1) → Nomad 자동 (vol surface 기반)
2. Delta hedge: Rysk 없음 → Nomad HyperCore perp 실시간 dynamic
3. Rolling: Rysk 수동 반복 → Nomad 자동
4. 전략 수: Rysk 2개 → Nomad 6개+
5. Risk management: Rysk position별 → Nomad portfolio Greeks 레벨
6. Pricing: Rysk market maker RFQ 의존 → Nomad 자체 BSM engine
7. Capital efficiency: Rysk isolated 1:1 → Nomad portfolio margin

---

## 3. 상품 구조

### Nomad Auto (핵심 상품)
- Multi-strategy vault 하나. Risk tier만 선택 (Conservative/Moderate/Aggressive)
- 내부에서 CC + CSP + IC를 시장 상황에 따라 자동 배분
- Conservative: 70% CC + 20% CSP + 10% 대기
- Moderate: 50% CC + 30% IC + 20% CSP
- Aggressive: 40% CC + 30% IC + 20% BCS + 10% Straddle

### Nomad Select
- 전략별 개별 vault. 직접 골라서 넣음. 파워유저용.

---

## 4. Phase 2 전략 6개 + APR

### Vol 매도 전략 (yield) — vault TVL 90% 집중 예상
- Covered Call: 자산 보유 + OTM call 매도. Base APR 35%, Win 78%
- Cash-Secured Put: USDC + OTM put 매도. Base APR 30%, Win 72%
- Iron Condor: OTM call+put 양쪽 매도. Base APR 28%, Win ~60%

### 방향성/변동성 전략
- Protective Put: 하방 보험 (비용 발생)
- Bull Call Spread: bullish 저비용 베팅 (성공시 100%+)
- Long Straddle: 변동성 매수 (큰 움직임 시 200%+)

### Rysk 실제 APR (2026-03-30)
- UPUMP 307.66%/5.38%, USOL 160.19%/4.12%, kHYPE 140.88%/2.17%
- UBTC 133.18%/4.71%, UETH 130.70%/5.32%
- Max=ATM근처, Min=deep OTM. 현실적 sweet spot 20~50%

### Rysk UETH 4/24만기 실제 vs 모델
- $2,200(+15.8%OTM): Rysk 64%, 모델 58.2%
- $2,450(+28.9%OTM): Rysk 23%, 모델 26.9%
- $2,700(+42.1%OTM): Rysk 8%, 모델 11.7%
- $2,800(+47.4%OTM): Rysk 6%, 모델 8.3%
- Best fit implied vol ~90%. 오차 3~6%. 모델 검증됨.

---

## 5. 시스템 아키텍처

유저 → USDC 예치 → Vault(ERC-4626) → Strategy Module → Rysk RFQ(option매도) + HyperCore CoreWriter(delta hedge) → Risk Manager → Auto-Roll

### 5개 핵심 컴포넌트
- Vault Manager: ERC-4626. 예치/출금/share/fee
- Pricing Engine: BSM + EWMA vol + Greeks + strike 계산 (offchain→onchain 검증)
- Strategy Module: 전략별 독립 모듈 (IStrategy interface)
- Delta Hedge Module: precompile 가격읽기 + CoreWriter perp 주문
- Risk Manager: portfolio Greeks, max loss, auto-deleverage

---

## 6. Pricing Engine (프로토타입 완성)

- BSM option pricing (call/put)
- EWMA realized vol (lambda 0.94)
- Greeks: delta, gamma, theta, vega
- Target delta 기반 strike 자동 선택
- Risk tier: Conservative(0.15), Moderate(0.25), Aggressive(0.35)
- 3개 전략 pricing (CC, CSP, IC)
- Vol surface + Portfolio Greeks dashboard
- 핵심: 미래 예측 안 함. 현재 vol 측정 + 확률 유리한 자리 선택 + hedge로 관리

---

## 7. HyperCore Integration

### Read (Precompile)
- getOraclePrice, getMarkPrice, getFundingRate, getOpenInterest, getUserState

### Write (CoreWriter)
- placeOrder, cancelOrder, modifyOrder, transferToCore, transferFromCore

### 라이브러리: hyper-evm-lib (https://github.com/hyperliquid-dev/hyper-evm-lib)

---

## 8. Rysk Finance

- 창업자: Dan Ugolini (Bocconi, Citibank, Opyn). 6명팀, 파나마시티
- 펀딩: Pre-seed $1.4M (Lemniscap, Coinbase Ventures 등)
- TVL $4~50M, 누적 $250M notional, $5M premium
- Rysk Premium: 기관용 vault 인프라, $250K 최소, custom strike 가능
- 현재 CC+CSP만, RFQ방식, strike 4개/만기, cap 40%참
- Rysk Premium 팀 그룹 초대됨 (2026-03-30). 기술 논의 진행 중.

---

## 9. 수익 모델

- Performance Fee 10-20%, Management Fee 1-2%/yr, Early Exit 0.5-1%
- 자본 투입 $0. 유저 자금으로 실행.
- TVL $20M시 연 $1.85M 수익 (보수적)

---

## 10. 로드맵

- Phase 0 (Q2 2026): CoreWriter+Rysk 연동 테스트, Pricing engine, Vault v0.1, Testnet
- Phase 1 (Q3 2026): CC+CSP vault mainnet, delta hedge, auto-roll, TVL cap $1M
- Phase 2 (Q4 2026): +4전략, Nomad Auto, portfolio risk, TVL cap $10M
- Phase 3 (2027): HIP-4 통합, Rysk 탈피, 15+전략

---

## 11. 리스크

- Rysk 의존도 90%+ (High) → HIP-4로 탈피
- HyperCore 다운 (High) → emergency close
- SC 취약점 (High) → audit+bounty+TVL cap
- Hedge cost > premium (Med) → dynamic frequency
- Market maker 부족 (Med) → Rysk 성장 의존

---

## 12. 빌드 인프라

- Rysk RFQ: ✅ ryskV12-cli + Premium 그룹
- HyperCore read: ✅ precompile
- HyperCore write: ✅ CoreWriter
- EVM↔Core bridge: ✅ hyper-evm-lib
- 로컬테스트: ✅ Foundry simulation
- Rysk 지원: ✅ Premium 그룹 초대됨

---

## 13. PENDING 액션

1. Rysk Premium 대화 진행 → 인프라 상세 + API docs 수령
2. hyper-evm-lib clone → CoreWriter 테스트
3. ryskV12-cli 분석 → option 매도 flow 파악
4. Pricing engine → Solidity 포팅
5. ERC-4626 vault 컨트랙트 설계

---

## 14. 용어

- CC=Covered Call, CSP=Cash-Secured Put, IC=Iron Condor
- Delta/Gamma/Theta/Vega = option Greeks
- BSM=Black-Scholes-Merton, EWMA=지수가중이동평균
- RFQ=Request for Quote, Epoch=전략 실행 주기
- HyperCore=HL의 L1 trading engine, HyperEVM=EVM 레이어
- Precompile=HyperCore 데이터 읽기, CoreWriter=HyperCore 주문
- HIP-4=outcome trading primitive (binary option)
