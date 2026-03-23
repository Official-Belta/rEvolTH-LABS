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
weETH Tranche Vault — Stress Tests
====================================
Config: Fixed 3%, 4 loops, 80:20, Reserve 3%

Scenarios:
  S1: weETH 5% depeg (2022 stETH-lite)
  S2: weETH 10% depeg (EigenLayer slashing)
  S3: ETH borrow rate spike to 8-10%
  S4: S1 + S2 + S3 simultaneous (worst case)

Each stress event injected mid-backtest (week 26 of 55).
Compare vault state before/during/after stress.
"""

import math
import time
from pathlib import Path
from dataclasses import dataclass
from copy import deepcopy

import numpy as np
import pandas as pd
import requests

DATA_DIR = Path(__file__).parent / "data"
OUTPUT_DIR = Path(__file__).parent / "output"


def fetch_eth_prices(months=13):
    cache = DATA_DIR / f"ETHUSDC_1d_{months}m.csv"
    if cache.exists():
        return pd.read_csv(cache, parse_dates=["timestamp"], index_col="timestamp")
    five_min = Path("/home/jj/gamma-swap-backtest/data/ETHUSDC_5m_13m.csv")
    if five_min.exists():
        df5 = pd.read_csv(five_min, parse_dates=["timestamp"], index_col="timestamp")
        daily = df5.resample("1D").agg({
            "open": "first", "high": "max", "low": "min",
            "close": "last", "volume": "sum", "quote_volume": "sum"
        }).dropna()
        daily.to_csv(cache)
        return daily
    raise RuntimeError("No data")


# ============================================================
# YIELD MODEL (same as weeth_backtest but with stress injection)
# ============================================================

def generate_base_params(eth_prices, seed=42):
    rng = np.random.RandomState(seed)
    n = len(eth_prices)
    daily_ret = eth_prices.pct_change().fillna(0).values
    vol_7d = pd.Series(daily_ret).rolling(7).std().fillna(0.02).values * math.sqrt(365)

    staking_base = 0.03
    restaking_base = 0.02
    staking_noise = np.zeros(n)
    restaking_noise = np.zeros(n)
    for i in range(1, n):
        staking_noise[i] = 0.95 * staking_noise[i-1] + rng.normal(0, 0.001)
        restaking_noise[i] = 0.90 * restaking_noise[i-1] + rng.normal(0, 0.003)

    staking_apr = np.clip(staking_base + staking_noise, 0.025, 0.04)
    restaking_apr = np.clip(restaking_base + restaking_noise, 0.005, 0.05)
    weeth_apr = staking_apr + restaking_apr

    morpho_supply_apr = np.clip(0.015 + vol_7d * 0.02 + rng.normal(0, 0.002, n), 0.005, 0.04)

    eth_borrow_base = 0.008
    stress_spike = np.where(daily_ret < -0.07, 0.015, 0)
    demand_premium = np.clip(vol_7d * 0.02, 0, 0.02)
    eth_borrow_apr = np.clip(
        eth_borrow_base + demand_premium + stress_spike + rng.normal(0, 0.001, n),
        0.002, 0.06
    )

    peg = np.ones(n)
    peg_noise = np.zeros(n)
    for i in range(1, n):
        peg_noise[i] = 0.97 * peg_noise[i-1] + rng.normal(0, 0.0004)
        if vol_7d[i] > 0.6 and rng.random() < 0.008:
            peg_noise[i] -= 0.015
    peg = np.clip(1.0 + peg_noise, 0.92, 1.005)

    return pd.DataFrame({
        "eth_price": eth_prices.values,
        "daily_ret": daily_ret,
        "vol_7d": vol_7d,
        "weeth_apr": weeth_apr,
        "morpho_supply_apr": morpho_supply_apr,
        "eth_borrow_apr": eth_borrow_apr,
        "weeth_eth_peg": peg,
    }, index=eth_prices.index)


def inject_stress(base_params, scenario, stress_start_day=180, stress_duration=14):
    """
    Inject stress event into yield params.

    S1: 5% depeg over 7 days, recovery over 21 days
    S2: 10% depeg over 5 days, slow recovery over 42 days
    S3: Borrow rate spike to 8-10% for 21 days
    S4: All of above simultaneously
    """
    yp = base_params.copy()
    n = len(yp)
    s = stress_start_day
    peg = yp["weeth_eth_peg"].values.copy()
    borrow = yp["eth_borrow_apr"].values.copy()

    if scenario in ("S1", "S4"):
        # 5% depeg: sharp drop over 7 days, recovery over 21 days
        drop_days = 7
        recovery_days = 21
        max_depeg = 0.05
        for d in range(min(drop_days, n - s)):
            peg[s + d] -= max_depeg * (d + 1) / drop_days
        for d in range(min(recovery_days, n - s - drop_days)):
            remaining = max_depeg * (1 - (d + 1) / recovery_days)
            peg[s + drop_days + d] -= remaining

    if scenario in ("S2", "S4"):
        # 10% depeg: faster drop over 5 days, slow recovery over 42 days
        drop_days = 5
        recovery_days = 42
        max_depeg = 0.10
        offset = 0 if scenario == "S2" else 0  # same timing for S4
        for d in range(min(drop_days, n - s)):
            peg[s + d] -= max_depeg * (d + 1) / drop_days
        for d in range(min(recovery_days, n - s - drop_days)):
            remaining = max_depeg * (1 - (d + 1) / recovery_days)
            peg[s + drop_days + d] -= remaining

    if scenario in ("S3", "S4"):
        # Borrow rate spike: 8-10% for 21 days
        spike_days = 21
        for d in range(min(spike_days, n - s)):
            # Ramp up to 10%, then taper
            if d < 3:
                borrow[s + d] = 0.08 + 0.02 * (d / 3)
            elif d < 14:
                borrow[s + d] = 0.10
            else:
                borrow[s + d] = 0.10 - 0.06 * ((d - 14) / 7)

    yp["weeth_eth_peg"] = np.clip(peg, 0.85, 1.005)
    yp["eth_borrow_apr"] = np.clip(borrow, 0.002, 0.15)
    return yp


# ============================================================
# VAULT ENGINE (minimal, from weeth_backtest)
# ============================================================

@dataclass
class VaultState:
    total_tvl: float = 0.0
    fixed_deposits: float = 0.0
    variable_deposits: float = 0.0
    weeth_collateral: float = 0.0
    eth_debt: float = 0.0
    n_loops: int = 0
    reserve: float = 0.0
    cum_fixed_yield: float = 0.0
    cum_variable_yield: float = 0.0
    cum_gas: float = 0.0
    deleverage_count: int = 0
    emergency_count: int = 0


def execute_leverage(state, max_loops, max_ltv):
    if state.total_tvl <= 0:
        return
    state.weeth_collateral = state.total_tvl
    state.eth_debt = 0.0
    state.n_loops = 0
    for _ in range(max_loops):
        target_ltv = max_ltv - 0.05
        max_borrow = state.weeth_collateral * target_ltv - state.eth_debt
        if max_borrow <= 100:
            break
        borrow = max_borrow * 0.95
        state.eth_debt += borrow
        state.weeth_collateral += borrow * 0.9997
        state.n_loops += 1


def check_health(state, peg, delev_thresh=0.85, emerg_ltv=0.92):
    if state.weeth_collateral <= 0 or state.eth_debt <= 0:
        return "normal"
    coll_val = state.weeth_collateral * peg
    ltv = state.eth_debt / coll_val if coll_val > 0 else 1.0

    if ltv >= emerg_ltv:
        repay = min(state.eth_debt, coll_val * 0.95)
        state.weeth_collateral -= repay / peg * 1.002
        state.eth_debt -= repay
        if state.eth_debt > state.weeth_collateral * peg * 0.5:
            loss = state.eth_debt - state.weeth_collateral * peg
            state.total_tvl = max(0, state.total_tvl - max(0, loss))
            state.eth_debt = 0
            state.weeth_collateral = max(0, state.total_tvl)
        state.n_loops = 0
        state.emergency_count += 1
        return "emergency"

    elif ltv >= delev_thresh:
        while ltv > delev_thresh * 0.95 and state.n_loops > 0:
            loop_debt = state.eth_debt / max(state.n_loops, 1)
            state.weeth_collateral -= loop_debt / peg * 1.002
            state.eth_debt -= loop_debt
            state.n_loops -= 1
            coll_val = state.weeth_collateral * peg
            ltv = state.eth_debt / coll_val if coll_val > 0 else 0
        state.deleverage_count += 1
        return "deleverage"

    return "normal"


def run_full(yp, fixed_rate=0.03, max_loops=4, max_ltv=0.90,
             epoch_days=7, reserve_bps=300, perf_fee=0.10,
             fixed_ratio=0.80, tvl=10_000_000, morpho_pct=0.05):
    state = VaultState(
        total_tvl=tvl,
        fixed_deposits=tvl * fixed_ratio,
        variable_deposits=tvl * (1 - fixed_ratio),
    )
    execute_leverage(state, max_loops, max_ltv)

    results = []
    i = 0
    while i + epoch_days <= len(yp):
        ep = yp.iloc[i:i+epoch_days]
        n = len(ep)
        if n == 0:
            break

        total_wy = 0.0
        total_my = 0.0
        total_bc = 0.0
        min_peg = 1.0

        for _, day in ep.iterrows():
            df = 1.0 / 365.25
            total_wy += state.weeth_collateral * day["weeth_apr"] * df
            total_my += state.total_tvl * morpho_pct * day["morpho_supply_apr"] * df
            total_bc += state.eth_debt * day["eth_borrow_apr"] * df
            peg = day["weeth_eth_peg"]
            min_peg = min(min_peg, peg)
            check_health(state, peg)

        gross = total_wy + total_my - total_bc
        pf = max(0, gross * perf_fee)
        net = gross - pf
        res_add = net * (reserve_bps / 10000)
        distributable = net - res_add
        state.reserve += res_add

        epoch_frac = n / 365.25
        fixed_obl = state.fixed_deposits * fixed_rate * epoch_frac
        if distributable < fixed_obl:
            tap = min(fixed_obl - distributable, state.reserve)
            state.reserve -= tap
            distributable += tap

        fixed_pay = min(fixed_obl, max(0, distributable))
        var_pay = max(0, distributable - fixed_pay)
        state.cum_fixed_yield += fixed_pay
        state.cum_variable_yield += var_pay

        peg_end = float(ep["weeth_eth_peg"].iloc[-1])
        coll_val = state.weeth_collateral * peg_end
        ltv = state.eth_debt / coll_val if coll_val > 0 else 0
        lev = state.weeth_collateral / state.total_tvl if state.total_tvl > 0 else 0

        fixed_apr = fixed_pay / state.fixed_deposits * (365.25 / n) if state.fixed_deposits > 0 else 0
        var_apr = var_pay / state.variable_deposits * (365.25 / n) if state.variable_deposits > 0 else 0

        results.append({
            "epoch": len(results),
            "gross": gross, "net": net,
            "fixed_pay": fixed_pay, "var_pay": var_pay,
            "fixed_apr": fixed_apr, "var_apr": var_apr,
            "fixed_obl": fixed_obl,
            "shortfall": max(0, fixed_obl - fixed_pay),
            "reserve": state.reserve,
            "ltv": ltv, "leverage": lev,
            "n_loops": state.n_loops,
            "peg": peg_end, "min_peg": min_peg,
            "borrow_rate": float(ep["eth_borrow_apr"].mean()),
            "spread": float(ep["weeth_apr"].mean() - ep["eth_borrow_apr"].mean()),
            "delev": state.deleverage_count,
            "emerg": state.emergency_count,
            "tvl": state.total_tvl,
        })

        # Re-leverage if safe
        if state.n_loops < max_loops:
            if ltv < 0.65 and peg_end > 0.995:
                execute_leverage(state, max_loops, max_ltv)

        i += epoch_days

    return pd.DataFrame(results), state


# ============================================================
# STRESS TEST RUNNER
# ============================================================

def run_stress_tests(daily_df):
    yp_base = generate_base_params(daily_df["close"])

    scenarios = {
        "BASELINE": ("Normal market (no stress)", None),
        "S1: 5% DEPEG": ("weETH/ETH drops to 0.95 over 7d, recovers in 21d", "S1"),
        "S2: 10% DEPEG": ("weETH/ETH drops to 0.90 over 5d, recovers in 42d (EigenLayer slash)", "S2"),
        "S3: BORROW SPIKE": ("ETH borrow rate jumps to 8-10% for 21 days", "S3"),
        "S4: ALL COMBINED": ("S1+S2+S3 simultaneously — worst case", "S4"),
    }

    W = 80
    print("\n" + "=" * W)
    print("  weETH TRANCHE VAULT — STRESS TEST RESULTS")
    print("  Config: Fixed 3% | 4 loops | 80:20 | Reserve 3%")
    print("=" * W)

    all_results = {}

    for name, (desc, scenario) in scenarios.items():
        if scenario is None:
            yp = yp_base
        else:
            yp = inject_stress(yp_base, scenario, stress_start_day=180, stress_duration=14)

        edf, fs = run_full(yp)
        all_results[name] = (edf, fs)

        n = len(edf)
        years = n * 7 / 365.25
        total_gross = edf["gross"].sum()

        # Stress window (epochs 25-30, around day 180)
        stress_epochs = edf[(edf["epoch"] >= 25) & (edf["epoch"] <= 30)]

        print(f"\n  {'─── ' + name + ' ───':─^{W-4}}")
        print(f"  {desc}")

        print(f"\n  YIELD:")
        print(f"    Total APR:      {total_gross / 10e6 / years * 100:.1f}%")
        print(f"    Avg Fixed APR:  {edf['fixed_apr'].mean() * 100:.1f}%")
        print(f"    Avg Var APR:    {edf['var_apr'].mean() * 100:.1f}%")
        print(f"    Min Var APR:    {edf['var_apr'].min() * 100:.1f}%")

        print(f"\n  FIXED TRANCHE:")
        print(f"    Hit rate:       {(edf['fixed_apr'] >= 0.03 * 0.95).mean() * 100:.0f}%")
        print(f"    Shortfalls:     {(edf['shortfall'] > 0).sum()}")
        print(f"    Max shortfall:  ${edf['shortfall'].max():,.0f}")

        print(f"\n  VARIABLE TRANCHE:")
        var_neg = (edf['var_pay'] <= 0).sum()
        print(f"    Zero/neg epochs: {var_neg}")
        if state_loss := (fs.total_tvl < 10_000_000):
            var_loss = (10_000_000 * 0.20) - fs.cum_variable_yield
            print(f"    Principal loss:  ${max(0, -fs.cum_variable_yield + edf['var_pay'].sum()):,.0f}")

        print(f"\n  RISK:")
        print(f"    Max LTV:        {edf['ltv'].max() * 100:.1f}%")
        print(f"    Min peg:        {edf['min_peg'].min():.4f}")
        print(f"    Deleverage:     {fs.deleverage_count}")
        print(f"    Emergency:      {fs.emergency_count}")
        print(f"    Reserve final:  ${fs.reserve:,.0f}")
        print(f"    TVL final:      ${fs.total_tvl:,.0f}")
        if fs.total_tvl < 10_000_000:
            loss_pct = (10_000_000 - fs.total_tvl) / 10_000_000 * 100
            print(f"    TVL LOSS:       {loss_pct:.1f}%")

        # Stress window detail
        if scenario and len(stress_epochs) > 0:
            print(f"\n  STRESS WINDOW (epochs 25-30):")
            print(f"    Min peg:        {stress_epochs['min_peg'].min():.4f}")
            print(f"    Max LTV:        {stress_epochs['ltv'].max() * 100:.1f}%")
            print(f"    Avg borrow:     {stress_epochs['borrow_rate'].mean() * 100:.1f}%")
            print(f"    Avg spread:     {stress_epochs['spread'].mean() * 100:.2f}%")
            print(f"    Fixed paid:     {(stress_epochs['fixed_apr'] >= 0.03 * 0.95).mean() * 100:.0f}%")
            print(f"    Var APR:        {stress_epochs['var_apr'].mean() * 100:.1f}%")
            print(f"    Loops active:   {stress_epochs['n_loops'].min()}")

    # ============================================================
    # COMPARISON TABLE
    # ============================================================
    print(f"\n\n  {'COMPARISON TABLE':═^{W-4}}")
    print(f"  {'Scenario':25} {'VaultAPR':>8} {'FixAPR':>7} {'VarAPR':>7} "
          f"{'FixHit':>6} {'MaxLTV':>6} {'MinPeg':>7} {'Delev':>5} {'Emerg':>5} {'TVLoss':>7}")
    print(f"  {'─'*25} {'─'*8} {'─'*7} {'─'*7} {'─'*6} {'─'*6} {'─'*7} {'─'*5} {'─'*5} {'─'*7}")

    for name, (edf, fs) in all_results.items():
        n = len(edf)
        years = n * 7 / 365.25
        tg = edf["gross"].sum()
        tapr = tg / 10e6 / years * 100 if years > 0 else 0
        fhit = (edf['fixed_apr'] >= 0.03 * 0.95).mean() * 100
        tvl_loss = max(0, (10_000_000 - fs.total_tvl) / 10_000_000 * 100)

        short_name = name[:25]
        print(f"  {short_name:25} {tapr:>7.1f}% {edf['fixed_apr'].mean()*100:>6.1f}% "
              f"{edf['var_apr'].mean()*100:>6.1f}% {fhit:>5.0f}% "
              f"{edf['ltv'].max()*100:>5.1f}% {edf['min_peg'].min():>6.4f} "
              f"{fs.deleverage_count:>5} {fs.emergency_count:>5} "
              f"{tvl_loss:>6.1f}%")

    # ============================================================
    # VERDICT
    # ============================================================
    print(f"\n\n  {'VERDICT':═^{W-4}}")

    base_edf, base_fs = all_results["BASELINE"]
    s4_edf, s4_fs = all_results["S4: ALL COMBINED"]

    base_var = base_edf["var_apr"].mean() * 100
    s4_var = s4_edf["var_apr"].mean() * 100
    s4_fix_hit = (s4_edf['fixed_apr'] >= 0.03 * 0.95).mean() * 100
    s4_tvl_loss = max(0, (10_000_000 - s4_fs.total_tvl) / 10_000_000 * 100)

    print(f"\n  Normal:     Variable {base_var:.0f}% APR, Fixed 100% hit, 0 risk events")
    print(f"  Worst case: Variable {s4_var:.0f}% APR, Fixed {s4_fix_hit:.0f}% hit, "
          f"TVL loss {s4_tvl_loss:.1f}%")

    if s4_tvl_loss > 0:
        # Who absorbs the loss?
        fixed_ok = s4_edf["shortfall"].sum() == 0
        print(f"\n  Fixed tranche: {'PROTECTED (no shortfall)' if fixed_ok else 'IMPACTED — shortfall occurred'}")
        print(f"  Variable tranche: bears ALL losses")
        if s4_tvl_loss > 0:
            var_deposit = 10_000_000 * 0.20
            var_loss_pct = min(100, s4_tvl_loss * 10_000_000 / var_deposit / 100)
            print(f"  Variable principal loss: ~{var_loss_pct:.0f}% of deposit")
    else:
        print(f"\n  BOTH TRANCHES SURVIVE worst case.")
        print(f"  Variable yield drops but no principal loss.")

    print(f"\n  Deleverage system: {'WORKED' if s4_fs.emergency_count == 0 else 'EMERGENCY TRIGGERED'}")
    print(f"  Reserve buffer: {'SUFFICIENT' if s4_fs.reserve > 0 else 'DEPLETED'} (${s4_fs.reserve:,.0f})")

    print("\n" + "=" * W)


# ============================================================
# MAIN
# ============================================================

def main():
    daily_df = fetch_eth_prices(months=13)
    print(f"  {len(daily_df)} days | ETH ${daily_df['close'].min():.0f}-${daily_df['close'].max():.0f}")
    run_stress_tests(daily_df)


if __name__ == "__main__":
    main()
