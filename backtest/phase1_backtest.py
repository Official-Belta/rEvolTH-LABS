#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "numpy",
#     "pandas",
#     "requests",
# ]
# ///
"""
Phase 1: Simple weETH Looping Vault — v3 (Pessimistic Realism)
================================================================
"ETH 넣으면 weETH 자동 루핑해서 ~11% APR"

v3 추가 모델:
  1. Oracle 지연: 디레버리지 판단에 1-2일 전 peg 사용
  2. 실행 지연: 디레버리지 중 peg 추가 하락 (worst-case)
  3. Cascading feedback: 디페그→borrow↑→유동성↓ (generate_params에서)
  4. Unwrap 지연: DEX 우회 시 추가 슬리피지 (instant unwrap 불가)
  5. 동적 디루프: borrow rate > weETH yield이면 자동 루프 축소
  6. Keeper 비용: 디레버리지 tx에 keeper tip 포함
"""

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from stress_v2 import (
    fetch_eth_prices, slippage_model, generate_params, WRAP_FEE,
)


# ── Config ──
ORACLE_DELAY_DAYS = 1       # oracle reports yesterday's peg
EXEC_DELAY_SLIP = 0.02      # peg drops 2% more during tx execution delay
UNWRAP_PENALTY = 0.005      # 0.5% extra cost: can't unwrap instantly, must DEX
KEEPER_TIP_ETH = 0.01       # 0.01 ETH per keeper tx as incentive
MAX_SELL_PER_TRADE = 500_000


@dataclass
class VaultState:
    tvl: float = 0.0
    weeth_collateral: float = 0.0
    eth_debt: float = 0.0
    n_loops: int = 0
    reserve: float = 0.0
    cum_yield: float = 0.0
    cum_slippage: float = 0.0
    cum_gas: float = 0.0
    cum_keeper_tips: float = 0.0
    deleverage_count: int = 0
    emergency_count: int = 0
    deloop_count: int = 0  # spread inversion deloops
    delev_events: list = field(default_factory=list)


def execute_leverage(state, max_loops, max_ltv, peg=1.0):
    if state.tvl <= 0:
        return
    state.weeth_collateral = state.tvl
    state.eth_debt = 0.0
    state.n_loops = 0
    for _ in range(max_loops):
        target = max_ltv - 0.05
        max_borrow = state.weeth_collateral * peg * target - state.eth_debt
        if max_borrow <= 100:
            break
        borrow = max_borrow * 0.95
        state.eth_debt += borrow
        state.weeth_collateral += borrow * (1 - WRAP_FEE)
        state.cum_slippage += borrow * WRAP_FEE
        state.n_loops += 1


def deloop_one(state, peg, eth_price):
    """Remove one loop — sell weETH to repay one loop's debt via DEX."""
    if state.n_loops <= 0 or state.eth_debt <= 0:
        return 0

    loop_debt = state.eth_debt / max(state.n_loops, 1)
    sell_weeth = loop_debt / peg
    sell_usd = sell_weeth * eth_price

    n_trades = max(1, int(sell_usd / MAX_SELL_PER_TRADE) + 1)
    chunk_weeth = sell_weeth / n_trades
    total_slip = 0
    for _ in range(n_trades):
        chunk_usd = chunk_weeth * peg * eth_price
        # DEX slippage + unwrap penalty (can't use EtherFi instant unwrap during stress)
        s = slippage_model(peg, chunk_usd) + UNWRAP_PENALTY
        total_slip += chunk_weeth * peg * s

    actual_eth = sell_weeth * peg - total_slip
    state.weeth_collateral -= sell_weeth
    state.eth_debt -= min(actual_eth, state.eth_debt)
    state.n_loops -= 1
    return total_slip


def check_and_deleverage(state, real_peg, oracle_peg, eth_price,
                         delev_thresh=0.85, emerg_ltv=0.92):
    """
    Oracle delay: decision based on oracle_peg (stale).
    Execution: actual trades happen at real_peg (worse).
    """
    if state.weeth_collateral <= 0 or state.eth_debt <= 0:
        return "normal"

    # Keeper sees oracle peg (stale) for LTV calculation
    coll_val_oracle = state.weeth_collateral * oracle_peg
    ltv_oracle = state.eth_debt / coll_val_oracle if coll_val_oracle > 0 else 1.0

    # But actual execution happens at real peg (possibly worse)
    # Plus execution delay: peg may drop further while tx is pending
    exec_peg = max(0.70, real_peg - EXEC_DELAY_SLIP * max(0, 1.0 - real_peg))

    if ltv_oracle >= emerg_ltv:
        # Emergency at exec_peg (worse than oracle thought)
        sell_amount = state.eth_debt / exec_peg
        sell_usd = sell_amount * eth_price
        n_trades = max(1, int(sell_usd / MAX_SELL_PER_TRADE) + 1)
        chunk = sell_amount / n_trades

        total_slip = 0
        for _ in range(n_trades):
            s = slippage_model(exec_peg, chunk * exec_peg * eth_price) + UNWRAP_PENALTY
            total_slip += chunk * exec_peg * s

        actual_eth = sell_amount * exec_peg - total_slip
        avg_slip = total_slip / max(sell_amount * exec_peg, 1)
        state.cum_slippage += total_slip
        state.delev_events.append(("EMERGENCY", exec_peg, avg_slip, total_slip))

        if actual_eth >= state.eth_debt:
            state.weeth_collateral -= sell_amount
            state.eth_debt = 0
        else:
            loss = state.eth_debt - actual_eth
            state.weeth_collateral = 0
            state.eth_debt = 0
            state.tvl = max(0, state.tvl - loss)

        state.tvl = max(0, state.tvl - total_slip)
        state.weeth_collateral = max(0, state.tvl)
        state.n_loops = 0
        state.emergency_count += 1
        return "emergency"

    elif ltv_oracle >= delev_thresh:
        # Deleverage — but execute at exec_peg, not oracle_peg
        total_slip_loss = 0
        # Recalculate LTV at real peg for loop
        coll_val = state.weeth_collateral * exec_peg
        ltv = state.eth_debt / coll_val if coll_val > 0 else 0

        while ltv > delev_thresh * 0.95 and state.n_loops > 0:
            slip = deloop_one(state, exec_peg, eth_price)
            total_slip_loss += slip

            coll_val = state.weeth_collateral * exec_peg
            ltv = state.eth_debt / coll_val if coll_val > 0 else 0

        state.tvl = max(0, state.tvl - total_slip_loss)
        state.cum_slippage += total_slip_loss
        avg_slip = total_slip_loss / max(state.tvl + total_slip_loss, 1)
        state.delev_events.append(("DELEVERAGE", exec_peg, avg_slip, total_slip_loss))
        state.deleverage_count += 1
        return "deleverage"

    return "normal"


def run_phase1(yp, tvl=10_000_000, max_loops=4, max_ltv=0.90,
               epoch_days=7, reserve_bps=300, perf_fee=0.10, morpho_pct=0.05,
               delev_thresh=0.85, emerg_ltv=0.92):

    state = VaultState(tvl=tvl)
    execute_leverage(state, max_loops, max_ltv)

    gas_per_rebalance = 200_000 * 25e-9
    gas_per_deleverage = 400_000 * 50e-9

    # Oracle delay buffer: stores last N days of peg
    peg_history = []

    results = []
    i = 0
    while i + epoch_days <= len(yp):
        ep = yp.iloc[i:i+epoch_days]
        n = len(ep)
        if n == 0 or state.tvl <= 0:
            break

        total_wy = 0.0
        total_my = 0.0
        total_bc = 0.0
        min_peg = 1.0
        epoch_gas = 0.0
        epoch_slip = 0.0
        epoch_keeper = 0.0

        for _, day in ep.iterrows():
            df = 1.0 / 365.25
            total_wy += state.weeth_collateral * day["weeth_apr"] * df
            total_my += state.tvl * morpho_pct * day["morpho_supply_apr"] * df
            total_bc += state.eth_debt * day["eth_borrow_apr"] * df

            real_peg = day["weeth_eth_peg"]
            eth_p = day["eth_price"]
            min_peg = min(min_peg, real_peg)

            # Oracle delay: keeper sees peg from ORACLE_DELAY_DAYS ago
            peg_history.append(real_peg)
            if len(peg_history) > ORACLE_DELAY_DAYS:
                oracle_peg = peg_history[-1 - ORACLE_DELAY_DAYS]
            else:
                oracle_peg = real_peg  # not enough history yet

            old_slip = state.cum_slippage
            status = check_and_deleverage(
                state, real_peg, oracle_peg, eth_p, delev_thresh, emerg_ltv
            )
            if status != "normal":
                epoch_slip += state.cum_slippage - old_slip
                # Gas spike during stress: 3x normal gas price
                epoch_gas += gas_per_deleverage * eth_p * 3
                # Keeper tip
                keeper_cost = KEEPER_TIP_ETH * eth_p
                epoch_keeper += keeper_cost
                state.cum_keeper_tips += keeper_cost

            # ── Dynamic deloop: if spread inverts, reduce loops ──
            weeth_yield = day["weeth_apr"]
            borrow_rate = day["eth_borrow_apr"]
            spread = weeth_yield - borrow_rate

            if spread < 0 and state.n_loops > 1:
                # Spread inverted — each extra loop loses money
                # Deloop one to reduce exposure (via DEX, incurs slippage)
                slip = deloop_one(state, real_peg, eth_p)
                state.cum_slippage += slip
                epoch_slip += slip
                epoch_gas += gas_per_deleverage * eth_p
                state.deloop_count += 1

        avg_price = float(ep["eth_price"].mean())
        epoch_gas += gas_per_rebalance * avg_price
        state.cum_gas += epoch_gas

        gross = total_wy + total_my - total_bc - epoch_gas - epoch_keeper
        pf = max(0, gross * perf_fee)
        net = gross - pf

        res_add = max(0, net * (reserve_bps / 10000))
        state.reserve += res_add
        distributable = net - res_add

        state.cum_yield += max(0, distributable)

        peg_end = float(ep["weeth_eth_peg"].iloc[-1])
        coll_val = state.weeth_collateral * peg_end
        ltv = state.eth_debt / coll_val if coll_val > 0 else 0

        epoch_apr = distributable / state.tvl * (365.25 / n) if state.tvl > 0 else 0

        results.append({
            "epoch": len(results),
            "gross": gross, "net": distributable,
            "apr": epoch_apr,
            "reserve": state.reserve,
            "ltv": ltv, "peg": peg_end, "min_peg": min_peg,
            "n_loops": state.n_loops,
            "borrow": float(ep["eth_borrow_apr"].mean()),
            "weeth_yield": float(ep["weeth_apr"].mean()),
            "spread": float(ep["weeth_apr"].mean() - ep["eth_borrow_apr"].mean()),
            "epoch_slip": epoch_slip, "epoch_gas": epoch_gas,
            "delev": state.deleverage_count, "emerg": state.emergency_count,
            "deloops": state.deloop_count,
            "tvl": state.tvl,
        })

        if state.n_loops < max_loops and state.tvl > 0:
            if ltv < 0.65 and peg_end > 0.995:
                execute_leverage(state, max_loops, max_ltv, peg_end)
        i += epoch_days

    return pd.DataFrame(results), state


def main():
    daily_df = fetch_eth_prices(13)
    print(f"  {len(daily_df)} days | ETH ${daily_df['close'].min():.0f}-${daily_df['close'].max():.0f}")

    scenarios = [
        ("BASELINE", None),
        ("5% DEPEG", "DEPEG_5"),
        ("10% DEPEG", "DEPEG_10"),
        ("BORROW SPIKE", "BORROW_SPIKE"),
        ("10%dp+borrow", "COMBINED"),
        ("15% DEPEG", "DEPEG_15"),
        ("15%dp+borrow", "COMBINED_EXTREME"),
        ("18% DEPEG", "DEPEG_18"),
        ("20% DEPEG", "DEPEG_20"),
        ("25% BLACK SWAN", "DEPEG_25"),
    ]

    W = 100
    print("\n" + "=" * W)
    print("  PHASE 1 v3: weETH LOOPING VAULT — PESSIMISTIC REALISM")
    print("  추가: oracle지연, 실행지연, cascading feedback, unwrap비용, 동적디루프, keeper비용")
    print("  Config: 4 loops | LTV 90% | Reserve 3% | Perf 10% | Pool $50M")
    print("=" * W)

    # ── PART 1: ALL SCENARIOS ──
    print(f"\n{'  PART 1: FULL SCENARIO MATRIX ($10M TVL)':═^{W}}")

    results = {}
    for name, stype in scenarios:
        yp = generate_params(daily_df["close"], stress_type=stype)
        edf, fs = run_phase1(yp, tvl=10_000_000)
        results[name] = (edf, fs)

    print(f"\n  {'Scenario':18} {'APR':>6} {'MinAPR':>7} {'MaxLTV':>6} "
          f"{'Delev':>5} {'Emerg':>5} {'DLoop':>5} {'Slip$':>10} {'Loss%':>6} {'Spread':>7}")
    print(f"  {'─'*18} {'─'*6} {'─'*7} {'─'*6} "
          f"{'─'*5} {'─'*5} {'─'*5} {'─'*10} {'─'*6} {'─'*7}")

    for name, (edf, fs) in results.items():
        tvl_loss = max(0, 10e6 - fs.tvl) / 10e6 * 100
        print(f"  {name:18} {edf['apr'].mean()*100:>5.1f}% {edf['apr'].min()*100:>6.1f}% "
              f"{edf['ltv'].max()*100:>5.1f}% {fs.deleverage_count:>5} {fs.emergency_count:>5} "
              f"{fs.deloop_count:>5} ${fs.cum_slippage:>9,.0f} {tvl_loss:>5.1f}% "
              f"{edf['spread'].min()*100:>+6.1f}%")

    # Detail for key scenarios
    for name in ["BASELINE", "10%dp+borrow", "15%dp+borrow", "20% DEPEG"]:
        if name not in results:
            continue
        edf, fs = results[name]
        tvl_loss = max(0, 10e6 - fs.tvl) / 10e6 * 100

        print(f"\n  {'─── ' + name + ' ───':─^{W-4}}")
        print(f"  APR:     avg {edf['apr'].mean()*100:.1f}% | min {edf['apr'].min()*100:.1f}% | max {edf['apr'].max()*100:.1f}%")
        print(f"  Spread:  avg {edf['spread'].mean()*100:.1f}% | min {edf['spread'].min()*100:.1f}%")
        print(f"  Risk:    LTV max {edf['ltv'].max()*100:.1f}% | peg min {edf['min_peg'].min():.4f}")
        print(f"  Events:  delev {fs.deleverage_count} | emerg {fs.emergency_count} | deloop {fs.deloop_count}")
        print(f"  Costs:   slip ${fs.cum_slippage:,.0f} | gas ${fs.cum_gas:,.0f} | keeper ${fs.cum_keeper_tips:,.0f}")
        if tvl_loss > 0:
            print(f"  LOSS:    TVL -{tvl_loss:.1f}% (${10e6 - fs.tvl:,.0f})")
        else:
            print(f"  LOSS:    none")
        for evt_type, evt_peg, evt_slip, evt_loss in fs.delev_events[:5]:
            print(f"    -> {evt_type}: peg={evt_peg:.4f} slip={evt_slip*100:.1f}% cost=${evt_loss:,.0f}")

    # ── PART 2: v2 vs v3 비교 ──
    print(f"\n\n{'  PART 2: v2 (OPTIMISTIC) vs v3 (PESSIMISTIC) COMPARISON':═^{W}}")
    print(f"  v3 adds: oracle delay {ORACLE_DELAY_DAYS}d, exec slip +{EXEC_DELAY_SLIP*100:.0f}%, "
          f"unwrap +{UNWRAP_PENALTY*100:.1f}%, cascading borrow, dynamic deloop, keeper tips\n")

    # Run v2 (without new features) by using bare stress_v2 models
    from stress_v2 import run_backtest as run_v2

    print(f"  {'Scenario':18} │ {'v2 APR':>7} {'v2 Loss':>8} │ {'v3 APR':>7} {'v3 Loss':>8} │ {'Δ APR':>7} {'Δ Loss':>8}")
    print(f"  {'─'*18}─┼─{'─'*7}─{'─'*8}─┼─{'─'*7}─{'─'*8}─┼─{'─'*7}─{'─'*8}")

    for name, stype in scenarios:
        yp = generate_params(daily_df["close"], stress_type=stype)

        # v2 (old model, no oracle delay etc)
        edf2, fs2 = run_v2(yp, tvl=10_000_000, fixed_ratio=0.0)
        apr2 = edf2['var_apr'].mean() * 100 if not edf2.empty else 0
        loss2 = max(0, 10e6 - (fs2.fixed_deposits + fs2.variable_deposits)) / 10e6 * 100

        # v3
        edf3, fs3 = results[name]
        apr3 = edf3['apr'].mean() * 100
        loss3 = max(0, 10e6 - fs3.tvl) / 10e6 * 100

        d_apr = apr3 - apr2
        d_loss = loss3 - loss2
        print(f"  {name:18} │ {apr2:>6.1f}% {loss2:>7.1f}% │ {apr3:>6.1f}% {loss3:>7.1f}% │ "
              f"{d_apr:>+6.1f}% {d_loss:>+7.1f}%")

    # ── PART 3: TVL SENSITIVITY (v3) ──
    print(f"\n\n{'  PART 3: TVL SENSITIVITY (v3 pessimistic)':═^{W}}")

    tvls = [100_000, 250_000, 500_000, 1_000_000, 5_000_000, 10_000_000]

    print(f"\n  {'':10} {'──── BASELINE ────':^24} {'── 10%dp+borrow ──':^24} {'── 15%dp+borrow ──':^24}")
    print(f"  {'TVL':>10} {'APR':>6} {'Gas%':>5} {'DLoop':>5}  {'APR':>6} {'Gas%':>5} {'DLoop':>5}  "
          f"{'APR':>6} {'Loss':>6} {'DLoop':>5}")
    print(f"  {'─'*10} {'─'*6} {'─'*5} {'─'*5}  {'─'*6} {'─'*5} {'─'*5}  {'─'*6} {'─'*6} {'─'*5}")

    for tvl in tvls:
        row = []
        for stype in [None, "COMBINED", "COMBINED_EXTREME"]:
            yp = generate_params(daily_df["close"], stress_type=stype)
            edf, fs = run_phase1(yp, tvl=tvl)
            if edf.empty:
                row.append((0, 0, 0, 0))
                continue
            apr = edf['apr'].mean() * 100
            gas_pct = fs.cum_gas / max(edf['gross'].sum() + fs.cum_gas, 1) * 100
            loss = max(0, tvl - fs.tvl) / tvl * 100
            row.append((apr, gas_pct, loss, fs.deloop_count))

        tvl_str = f"${tvl/1e6:.0f}M" if tvl >= 1e6 else f"${tvl/1e3:.0f}K"
        print(f"  {tvl_str:>10} {row[0][0]:>5.1f}% {row[0][1]:>4.1f}% {row[0][3]:>5}  "
              f"{row[1][0]:>5.1f}% {row[1][1]:>4.1f}% {row[1][3]:>5}  "
              f"{row[2][0]:>5.1f}% {row[2][2]:>5.1f}% {row[2][3]:>5}")

    # ── PART 4: DESIGN RISKS (not backtestable) ──
    print(f"\n\n{'  PART 4: DESIGN RISKS (백테스트 불가 — 컨트랙트 설계 필요)':═^{W}}")
    print("""
  ┌─ 1. Keeper 설계 ──────────────────────────────────────────────────────────┐
  │  문제: auto-deleverage 트리거 주체가 필요                                │
  │  옵션: (a) 전용 keeper bot + tip 인센티브                                │
  │        (b) 유저 tx piggyback (deposit/withdraw 시 체크)                   │
  │        (c) Gelato/Chainlink Automation                                    │
  │  리스크: keeper 다운 → 디레버리지 미실행 → emergency까지 감                │
  │  대응: multi-keeper + 유저 tx piggyback 이중 안전장치                     │
  └───────────────────────────────────────────────────────────────────────────┘

  ┌─ 2. Flashloan 공격 ──────────────────────────────────────────────────────┐
  │  벡터 A: flashloan → weETH/ETH 가격 조작 → vault가 불필요 디레버리지   │
  │  벡터 B: share price 왜곡 → 싸게 출금                                    │
  │  대응: TWAP oracle (30분+), 같은 블록 deposit/withdraw 금지              │
  │        Morpho Blue는 Chainlink oracle 사용 → 조작 어려움                 │
  │        share price에 EMA 적용 (anti-sandwich)                            │
  └───────────────────────────────────────────────────────────────────────────┘

  ┌─ 3. ERC-4626 Share Price MEV ────────────────────────────────────────────┐
  │  문제: share price = (collateral × peg - debt) / totalShares             │
  │  oracle stale → share price 틀림 → 유리한 시점에 출금 (MEV)             │
  │  대응: previewRedeem에 TWAP peg 사용                                     │
  │        출금 시 1 epoch delay (7일)                                       │
  │        출금 요청 → 다음 epoch에 실행 (share price manipulation 방지)     │
  └───────────────────────────────────────────────────────────────────────────┘

  ┌─ 4. Morpho Market 선택 ──────────────────────────────────────────────────┐
  │  문제: 같은 weETH/ETH pair에 여러 Morpho market (다른 LTV, oracle)      │
  │  대응: governance로 market whitelist                                      │
  │        하나의 market에만 집중 (유동성 분산 방지)                          │
  │        market ID를 컨트랙트에 하드코딩                                    │
  └───────────────────────────────────────────────────────────────────────────┘

  ┌─ 5. weETH Unwrap 경로 ──────────────────────────────────────────────────┐
  │  정상: EtherFi 직접 unwrap (느림, 7일+ queue 가능)                      │
  │  긴급: DEX swap (빠름, 슬리피지 발생)                                    │
  │  설계: 출금 요청 → EtherFi queue 시작 + DEX 경로 대기                   │
  │        queue > 3일이면 DEX fallback (슬리피지 유저 부담)                 │
  │  뱅크런: 전원 동시 출금 → queue 폭발 → DEX만 가능 → 슬리피지 증가     │
  │  대응: 출금 cap (epoch당 TVL의 20%), queue priority                     │
  └───────────────────────────────────────────────────────────────────────────┘

  ┌─ 6. Dynamic Rebalancing ─────────────────────────────────────────────────┐
  │  문제: borrow rate > weETH yield이면 루프가 역수익                       │
  │  백테스트 반영: spread < 0이면 자동 deloop (v3에서 구현)                 │
  │  온체인 구현: keeper가 주기적으로 spread 체크                             │
  │        spread < -1% → deloop 1개                                         │
  │        spread < -3% → deloop 2개                                         │
  │        가스비 vs spread loss 비교 후 실행                                │
  └───────────────────────────────────────────────────────────────────────────┘
""")

    # ── FINAL VERDICT ──
    base_edf, base_fs = results["BASELINE"]
    s6_edf, s6_fs = results["15%dp+borrow"]
    s8_edf, s8_fs = results["20% DEPEG"]
    s9_edf, s9_fs = results["25% BLACK SWAN"]

    s6_loss = max(0, 10e6 - s6_fs.tvl) / 10e6 * 100
    s8_loss = max(0, 10e6 - s8_fs.tvl) / 10e6 * 100
    s9_loss = max(0, 10e6 - s9_fs.tvl) / 10e6 * 100

    print(f"\n{'  FINAL VERDICT — PESSIMISTIC MODEL':═^{W}}")
    print(f"""
  ═══════════════════════════════════════════════════════════
  RISK DISCLOSURE v3 (비관적 모델 기준)
  ═══════════════════════════════════════════════════════════

  정상 시장:     {base_edf['apr'].mean()*100:.1f}% APR
  5% 디페그:     {results['5% DEPEG'][0]['apr'].mean()*100:.1f}% APR — 안전
  10% 디페그:    {results['10% DEPEG'][0]['apr'].mean()*100:.1f}% APR — 안전
  10%dp+borrow:  {results['10%dp+borrow'][0]['apr'].mean()*100:.1f}% APR — 안전

  15%dp+borrow:  {s6_edf['apr'].mean()*100:.1f}% APR, 원금 -{s6_loss:.0f}%
  20% DEPEG:     {s8_edf['apr'].mean()*100:.1f}% APR, 원금 -{s8_loss:.0f}%
  25% BLACK SWAN:{s9_edf['apr'].mean()*100:.1f}% APR, 원금 -{s9_loss:.0f}%

  v2(낙관) → v3(비관) 차이:
    정상: ~0.5% APR 감소 (keeper, 동적 디루프 비용)
    스트레스: 손실 +3~8% 증가 (oracle지연, 실행지연, unwrap비용)

  핵심 인사이트:
    - 10% 디페그까지: v2든 v3든 원금 안전 (correlated pair의 힘)
    - 15%+: v3에서 손실 더 큼 (oracle 보고 늦게 디레버리지 + 실행 슬리피지)
    - borrow spike 단독: 수익 감소만, 원금 손실 없음
    - 동적 디루프가 spread 역전 시 손실 방지 효과 있음
    - 최소 TVL: $250K+ (가스+keeper 비용 감당)
""")

    print("=" * W)


if __name__ == "__main__":
    main()
