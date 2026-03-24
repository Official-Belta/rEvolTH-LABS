#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "numpy",
#     "pandas",
# ]
# ///
"""
Vault APR Distribution from Morpho Historical Borrow Rate
==========================================================
Usage:
  1. Run dune_query.sql on dune.com
  2. Export CSV → backtest/data/morpho_borrow_history.csv
  3. Run: uv run apr_distribution.py

If no CSV exists, uses simulated borrow rate distribution.
"""

import numpy as np
import pandas as pd
from pathlib import Path

DATA_FILE = Path(__file__).parent / "data" / "morpho_borrow_history.csv"

# ── Vault parameters (from fork test) ──
WEETH_YIELD = 0.05        # 5% APR (staking 3% + restaking 2%)
LEVERAGE = 3.47           # from fork test
PERF_FEE = 0.10           # 10%
RESERVE = 0.03            # 3%
NET_MULT = 1 - PERF_FEE - RESERVE  # 0.87


def calc_vault_apr(borrow_rate: float) -> float:
    """Calculate net vault APR given a borrow rate."""
    spread = WEETH_YIELD - borrow_rate
    if spread <= 0:
        # Keeper deloops to 1x — just weETH yield minus borrow on remaining
        return max(0, (WEETH_YIELD - borrow_rate * 0.1)) * NET_MULT  # ~1x residual
    gross = spread * LEVERAGE + WEETH_YIELD * (1 - 1/LEVERAGE) * 0  # simplified
    # Better formula: total yield - total cost
    total_yield = WEETH_YIELD * LEVERAGE  # weETH yield on full collateral
    total_cost = borrow_rate * (LEVERAGE - 1)  # borrow cost on debt only
    gross = total_yield - total_cost
    net = gross * NET_MULT
    return max(0, net)


def main():
    W = 80

    if DATA_FILE.exists():
        print(f"  Loading Dune export: {DATA_FILE}")
        df = pd.read_csv(DATA_FILE, parse_dates=["date"])
        borrow_rates = df["borrow_apr_percent"].values / 100  # convert % to decimal
        utilization = df["utilization_pct"].values if "utilization_pct" in df.columns else None
        n_days = len(df)
        source = "Dune (real data)"
    else:
        print(f"  No Dune CSV found at {DATA_FILE}")
        print(f"  Using simulated borrow rate distribution\n")
        # Simulate based on known Morpho weETH/WETH characteristics:
        # - AdaptiveCurveIRM: low rate below 90% util, spikes above
        # - Historical range: ~1% to ~8%
        # - Most of the time: 1-3%
        rng = np.random.RandomState(42)
        n_days = 365
        # Log-normal distribution centered around 2%
        borrow_rates = np.clip(rng.lognormal(np.log(0.02), 0.6, n_days), 0.005, 0.12)
        utilization = np.clip(70 + borrow_rates * 500 + rng.normal(0, 5, n_days), 50, 99)
        source = "Simulated"

    # Calculate vault APR for each day
    vault_aprs = np.array([calc_vault_apr(r) for r in borrow_rates])

    print("=" * W)
    print(f"  VAULT APR DISTRIBUTION ({source}, {n_days} days)")
    print("=" * W)

    # ── Borrow rate distribution ──
    print(f"\n  Borrow Rate Distribution:")
    brackets = [(0, 0.01), (0.01, 0.02), (0.02, 0.03), (0.03, 0.04),
                (0.04, 0.05), (0.05, 0.08), (0.08, 0.15)]
    print(f"  {'Range':>12} {'Days':>6} {'Pct':>6} {'Vault APR':>10}")
    print(f"  {'─'*12} {'─'*6} {'─'*6} {'─'*10}")
    for lo, hi in brackets:
        mask = (borrow_rates >= lo) & (borrow_rates < hi)
        count = mask.sum()
        pct = count / n_days * 100
        avg_apr = vault_aprs[mask].mean() * 100 if count > 0 else 0
        print(f"  {lo*100:>5.1f}-{hi*100:>4.1f}% {count:>6} {pct:>5.1f}% {avg_apr:>9.1f}%")

    # ── Vault APR stats ──
    print(f"\n  Vault APR Statistics:")
    print(f"  Mean:   {vault_aprs.mean()*100:>6.1f}%")
    print(f"  Median: {np.median(vault_aprs)*100:>6.1f}%")
    print(f"  Min:    {vault_aprs.min()*100:>6.1f}%")
    print(f"  Max:    {vault_aprs.max()*100:>6.1f}%")
    print(f"  Std:    {vault_aprs.std()*100:>6.1f}%")

    # ── Percentiles ──
    print(f"\n  Percentiles:")
    for p in [5, 10, 25, 50, 75, 90, 95]:
        v = np.percentile(vault_aprs, p) * 100
        print(f"  P{p:>2}: {v:>6.1f}%")

    # ── Scenarios ──
    print(f"\n  Scenario Analysis:")
    scenarios = [
        ("Ideal (borrow 1%)", 0.01),
        ("Normal (borrow 2%)", 0.02),
        ("Current (borrow 1.87%)", 0.0187),
        ("Elevated (borrow 3%)", 0.03),
        ("High (borrow 5%)", 0.05),
        ("Spike (borrow 8%)", 0.08),
        ("Extreme (borrow 10%)", 0.10),
    ]
    print(f"  {'Scenario':>28} {'Borrow':>7} {'Spread':>7} {'Gross':>7} {'Net APR':>8}")
    print(f"  {'─'*28} {'─'*7} {'─'*7} {'─'*7} {'─'*8}")
    for name, br in scenarios:
        spread = WEETH_YIELD - br
        total_yield = WEETH_YIELD * LEVERAGE
        total_cost = br * (LEVERAGE - 1)
        gross = total_yield - total_cost
        net = calc_vault_apr(br)
        status = "" if spread > 0 else " ← deloop"
        print(f"  {name:>28} {br*100:>6.1f}% {spread*100:>+6.1f}% {gross*100:>6.1f}% {net*100:>7.1f}%{status}")

    # ── Risk disclosure numbers ──
    print(f"\n{'  RISK DISCLOSURE NUMBERS':═^{W}}")
    print(f"""
  "목표 APR: 8~10% (시장 상황에 따라 변동)"

  근거:
    - borrow rate 1~3% (전체 기간의 ~{((borrow_rates >= 0.01) & (borrow_rates < 0.03)).sum()/n_days*100:.0f}%): APR 8~12%
    - borrow rate 3~5% (전체 기간의 ~{((borrow_rates >= 0.03) & (borrow_rates < 0.05)).sum()/n_days*100:.0f}%): APR 5~8%
    - borrow rate 5%+ (전체 기간의 ~{(borrow_rates >= 0.05).sum()/n_days*100:.0f}%): keeper deloop, APR 2~5%

  최악: borrow rate 10%+ → spread 역전 → 1x deloop → APR ~0%
  최선: borrow rate 1% → APR ~12%
  중앙값: {np.median(vault_aprs)*100:.1f}%
""")

    print("=" * W)


if __name__ == "__main__":
    main()
