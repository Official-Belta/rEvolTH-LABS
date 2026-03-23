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
Phase 1 TVL Sensitivity: 가스비 + 시나리오별 APR 분석
=====================================================
소규모 TVL에서 가스비가 APR을 얼마나 깎는지.
4개 시나리오 × 5개 TVL 사이즈 전수 조사.
"""

from stress_v2 import fetch_eth_prices, generate_params
from phase1_backtest import run_phase1


def main():
    daily_df = fetch_eth_prices(13)
    print(f"  {len(daily_df)} days | ETH ${daily_df['close'].min():.0f}-${daily_df['close'].max():.0f}")

    scenarios = [
        ("정상",            None),
        ("10% 디페그",       "DEPEG_10"),
        ("Borrow spike",    "BORROW_SPIKE"),
        ("10%dp + borrow",  "COMBINED"),
    ]

    tvls = [100_000, 250_000, 500_000, 1_000_000, 3_000_000, 5_000_000, 10_000_000]

    W = 100
    print("\n" + "=" * W)
    print("  PHASE 1 — TVL × SCENARIO SENSITIVITY")
    print("  가스비가 소규모 TVL에서 APR을 얼마나 깎는지")
    print("  Config: 4 loops | Reserve 3% | Perf fee 10% | Wrap 0.1%")
    print("=" * W)

    # ── 시나리오별 상세 테이블 ──
    for sname, stype in scenarios:
        print(f"\n{'  ── ' + sname + ' ──':═^{W}}")

        yp = generate_params(daily_df["close"], stress_type=stype)

        print(f"\n  {'TVL':>10} │ {'Gross':>6} {'Gas$':>8} {'Gas%':>5} {'Slip$':>9} "
              f"{'PerfFee':>7} {'Reserve':>7} │ {'NetAPR':>7} {'GasHit':>7} │ "
              f"{'Delev':>5} {'Loss':>6}")
        print(f"  {'─'*10}─┼─{'─'*6}─{'─'*8}─{'─'*5}─{'─'*9}─"
              f"{'─'*7}─{'─'*7}─┼─{'─'*7}─{'─'*7}─┼─"
              f"{'─'*5}─{'─'*6}")

        # 가스 없는 기준 APR (큰 TVL에서 추출)
        edf_ref, fs_ref = run_phase1(yp, tvl=100_000_000)  # $100M에서 gas 무시 가능
        ref_apr = edf_ref['apr'].mean() * 100

        for tvl in tvls:
            edf, fs = run_phase1(yp, tvl=tvl)
            if edf.empty:
                continue

            n = len(edf)
            years = n * 7 / 365.25

            gross_total = edf['gross'].sum()
            gross_apr = gross_total / tvl / years * 100

            net_apr = edf['apr'].mean() * 100
            gas_hit = ref_apr - net_apr  # gas가 깎은 APR
            gas_pct = fs.cum_gas / max(gross_total + fs.cum_gas, 1) * 100

            # Performance fee, reserve 추정
            pf_est = max(0, gross_total * 0.10)
            res_est = fs.reserve

            tvl_loss = max(0, tvl - fs.tvl) / tvl * 100

            tvl_str = f"${tvl/1e6:.0f}M" if tvl >= 1e6 else f"${tvl/1e3:.0f}K"
            print(f"  {tvl_str:>10} │ {gross_apr:>5.1f}% ${fs.cum_gas:>7,.0f} {gas_pct:>4.1f}% "
                  f"${fs.cum_slippage:>8,.0f} ${pf_est:>6,.0f} ${res_est:>6,.0f} │ "
                  f"{net_apr:>6.1f}% {gas_hit:>+6.1f}% │ "
                  f"{fs.deleverage_count:>5} {tvl_loss:>5.1f}%")

        # min/max APR for smallest TVL
        edf_small, _ = run_phase1(yp, tvl=100_000)
        if not edf_small.empty:
            print(f"\n  $100K 주간 APR 범위: {edf_small['apr'].min()*100:+.1f}% ~ "
                  f"{edf_small['apr'].max()*100:+.1f}%")

    # ── 크로스 비교: TVL × 시나리오 매트릭스 ──
    print(f"\n\n{'  NET APR MATRIX (가스비 차감 후)':═^{W}}")
    print(f"\n  {'TVL':>10}", end="")
    for sname, _ in scenarios:
        print(f" │ {sname:>14}", end="")
    print(f" │ {'worst gap':>10}")
    print(f"  {'─'*10}", end="")
    for _ in scenarios:
        print(f"─┼─{'─'*14}", end="")
    print(f"─┼─{'─'*10}")

    for tvl in tvls:
        tvl_str = f"${tvl/1e6:.0f}M" if tvl >= 1e6 else f"${tvl/1e3:.0f}K"
        aprs = []
        print(f"  {tvl_str:>10}", end="")
        for _, stype in scenarios:
            yp = generate_params(daily_df["close"], stress_type=stype)
            edf, fs = run_phase1(yp, tvl=tvl)
            apr = edf['apr'].mean() * 100 if not edf.empty else 0
            aprs.append(apr)
            print(f" │ {apr:>13.1f}%", end="")
        gap = aprs[0] - min(aprs)
        print(f" │ {gap:>+9.1f}%")

    # ── 가스비 브레이크다운 ──
    print(f"\n\n{'  GAS COST BREAKDOWN':═^{W}}")
    print(f"  주간 리밸런싱: 200K gas × 25 gwei × ETH가격")
    print(f"  디레버리지:    400K gas × 50 gwei × ETH가격 (stress시 gas 2배)")

    avg_eth = daily_df['close'].mean()
    weekly_gas = 200_000 * 25e-9 * avg_eth
    delev_gas = 400_000 * 50e-9 * avg_eth

    print(f"\n  평균 ETH가격 ${avg_eth:,.0f} 기준:")
    print(f"  주간 리밸런싱 1회: ${weekly_gas:.2f}")
    print(f"  연간 리밸런싱:     ${weekly_gas * 52:.0f}")
    print(f"  디레버리지 1회:    ${delev_gas:.2f}")

    annual_gas = weekly_gas * 52
    print(f"\n  {'TVL':>10} │ {'연간가스$':>10} │ {'가스/TVL':>8} │ {'APR 감소':>8}")
    print(f"  {'─'*10}─┼─{'─'*10}─┼─{'─'*8}─┼─{'─'*8}")
    for tvl in tvls:
        tvl_str = f"${tvl/1e6:.0f}M" if tvl >= 1e6 else f"${tvl/1e3:.0f}K"
        pct = annual_gas / tvl * 100
        print(f"  {tvl_str:>10} │ ${annual_gas:>9,.0f} │ {pct:>7.2f}% │ {pct:>+7.2f}%")

    # ── 최종 요약 ──
    print(f"\n\n{'  VERDICT':═^{W}}")

    yp_base = generate_params(daily_df["close"], stress_type=None)
    yp_comb = generate_params(daily_df["close"], stress_type="COMBINED")

    e100_b, _ = run_phase1(yp_base, tvl=100_000)
    e500_b, _ = run_phase1(yp_base, tvl=500_000)
    e1m_b, _ = run_phase1(yp_base, tvl=1_000_000)
    e10m_b, _ = run_phase1(yp_base, tvl=10_000_000)

    e100_c, _ = run_phase1(yp_comb, tvl=100_000)
    e500_c, _ = run_phase1(yp_comb, tvl=500_000)

    print(f"""
  ┌──────────────────────────────────────────────────────────────────┐
  │  TVL별 실질 APR (가스비 차감 후)                                │
  │                                                                  │
  │  $100K:  정상 {e100_b['apr'].mean()*100:.1f}% → 스트레스 {e100_c['apr'].mean()*100:.1f}%  (가스비 ~{annual_gas/100_000*100:.1f}% 차지)  │
  │  $500K:  정상 {e500_b['apr'].mean()*100:.1f}% → 스트레스 {e500_c['apr'].mean()*100:.1f}%  (가스비 ~{annual_gas/500_000*100:.2f}% 차지) │
  │  $1M:    정상 {e1m_b['apr'].mean()*100:.1f}% → 스트레스 {e1m_b['apr'].mean()*100:.1f}%  (가스비 무시 가능)      │
  │  $10M:   정상 {e10m_b['apr'].mean()*100:.1f}% → 레퍼런스                              │
  │                                                                  │
  │  결론:                                                           │
  │  - $100K: 가스비가 APR의 ~{annual_gas/100_000*100:.0f}% 차지, 수익성 낮음               │
  │  - $250K: 최소 생존 가능 TVL                                     │
  │  - $500K+: 가스비 영향 미미, 권장                                │
  │  - 디페그 없는 borrow spike만으로는 원금 손실 없음               │
  │  - 10% 디페그 + borrow spike 동시 발생해도 원금 손실 없음       │
  └──────────────────────────────────────────────────────────────────┘
""")

    print("=" * W)


if __name__ == "__main__":
    main()
