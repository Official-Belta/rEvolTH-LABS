#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "numpy",
#     "pandas",
#     "matplotlib",
#     "requests",
#     "scipy",
# ]
# ///
"""
Yield Tranche Vault — weETH Correlated Loop Backtest
======================================================
Base: weETH (EtherFi + EigenLayer restaking)
Loop: weETH collateral → borrow ETH → buy weETH → repeat
Base yield: ~5% (ETH staking 3% + EigenLayer restaking ~2%)
Spread: ~3.5% per loop (5% - 1.5% ETH borrow)

Risk stack:
  L0: Ethereum PoS (staking)
  L1: EigenLayer (restaking, slashing risk)
  L2: EtherFi (weETH wrapper contract risk)
  L3: Morpho Blue (lending protocol risk)
  L4: This vault (smart contract risk)
"""

import math
import time
import itertools
from pathlib import Path
from dataclasses import dataclass

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import requests


DATA_DIR = Path(__file__).parent / "data"
DATA_DIR.mkdir(exist_ok=True)
OUTPUT_DIR = Path(__file__).parent / "output"
OUTPUT_DIR.mkdir(exist_ok=True)


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
# YIELD MODEL — weETH
# ============================================================

def generate_yield_params(eth_prices: pd.Series, seed=42):
    """
    weETH yield = ETH staking (~3%) + EigenLayer restaking (~2%)
    More volatile than stETH due to EigenLayer reward variability.

    weETH/ETH peg: slightly more volatile than stETH/ETH
    due to additional protocol layers.
    """
    rng = np.random.RandomState(seed)
    n = len(eth_prices)
    daily_ret = eth_prices.pct_change().fillna(0).values
    vol_7d = pd.Series(daily_ret).rolling(7).std().fillna(0.02).values * math.sqrt(365)

    # --- weETH base yield (staking + restaking) ---
    staking_base = 0.03
    restaking_base = 0.02
    # Restaking reward is more variable
    staking_noise = np.zeros(n)
    restaking_noise = np.zeros(n)
    for i in range(1, n):
        staking_noise[i] = 0.95 * staking_noise[i-1] + rng.normal(0, 0.001)
        restaking_noise[i] = 0.90 * restaking_noise[i-1] + rng.normal(0, 0.003)

    staking_apr = np.clip(staking_base + staking_noise, 0.025, 0.04)
    restaking_apr = np.clip(restaking_base + restaking_noise, 0.005, 0.05)
    weeth_apr = staking_apr + restaking_apr  # total ~5%

    # --- Morpho supply APR ---
    morpho_supply_apr = np.clip(0.015 + vol_7d * 0.02 + rng.normal(0, 0.002, n),
                                 0.005, 0.04)

    # --- ETH borrow rate (correlated pair market) ---
    eth_borrow_base = 0.008
    stress_spike = np.where(daily_ret < -0.07, 0.015, 0)
    # During high demand (bull market looping), borrow can rise
    demand_premium = np.clip(vol_7d * 0.02, 0, 0.02)
    eth_borrow_apr = np.clip(
        eth_borrow_base + demand_premium + stress_spike + rng.normal(0, 0.001, n),
        0.002, 0.06
    )

    # --- weETH/ETH peg ---
    # More volatile than stETH/ETH due to EigenLayer dependency
    peg = np.ones(n)
    peg_noise = np.zeros(n)
    for i in range(1, n):
        peg_noise[i] = 0.97 * peg_noise[i-1] + rng.normal(0, 0.0004)
        # Rare depeg: EigenLayer slashing event or EtherFi issue
        if vol_7d[i] > 0.6 and rng.random() < 0.008:
            peg_noise[i] -= 0.015  # 1.5% depeg shock
    peg = np.clip(1.0 + peg_noise, 0.92, 1.005)

    return pd.DataFrame({
        "eth_price": eth_prices.values,
        "daily_ret": daily_ret,
        "vol_7d": vol_7d,
        "weeth_apr": weeth_apr,
        "staking_apr": staking_apr,
        "restaking_apr": restaking_apr,
        "morpho_supply_apr": morpho_supply_apr,
        "eth_borrow_apr": eth_borrow_apr,
        "weeth_eth_peg": peg,
    }, index=eth_prices.index)


# ============================================================
# VAULT ENGINE
# ============================================================

@dataclass
class GasConfig:
    """Gas cost model — all in USD terms."""
    # Base L1 gas costs (Ethereum mainnet)
    # Avg gas price: 20-50 gwei, each loop tx ~300K gas
    loop_tx_gas: float = 300_000       # gas units per loop transaction
    rebalance_tx_gas: float = 200_000  # gas units per rebalance/harvest
    deleverage_tx_gas: float = 400_000 # gas units per deleverage unwind
    deposit_tx_gas: float = 150_000    # gas units per deposit/withdraw

    # Gas price in gwei (varies 5-100+, avg ~25 on mainnet)
    base_gwei: float = 25.0
    # Gas spikes during high vol
    vol_multiplier: float = 2.0  # at 100% vol, gas = base × (1 + 2.0)

    def tx_cost_usd(self, gas_units: float, eth_price: float, vol_7d: float = 0.3) -> float:
        """Calculate transaction cost in USD."""
        gwei = self.base_gwei * (1.0 + self.vol_multiplier * min(vol_7d, 1.0))
        eth_cost = gas_units * gwei * 1e-9
        return eth_cost * eth_price


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
    cum_protocol_fee: float = 0.0
    cum_gas_cost: float = 0.0
    deleverage_count: int = 0
    emergency_count: int = 0


def execute_leverage(state, max_loops, max_ltv, gas_cfg=None,
                     eth_price=2000, vol_7d=0.3):
    """Execute recursive leverage. Returns total gas cost in USD."""
    if state.total_tvl <= 0:
        return 0.0
    state.weeth_collateral = state.total_tvl
    state.eth_debt = 0.0
    state.n_loops = 0
    total_gas = 0.0
    gc = gas_cfg or GasConfig()

    for _ in range(max_loops):
        target_ltv = max_ltv - 0.05
        max_borrow = state.weeth_collateral * target_ltv - state.eth_debt
        if max_borrow <= 100:
            break
        borrow = max_borrow * 0.95
        state.eth_debt += borrow
        slippage = 0.0003
        state.weeth_collateral += borrow * (1 - slippage)
        state.n_loops += 1
        total_gas += gc.tx_cost_usd(gc.loop_tx_gas, eth_price, vol_7d)

    state.cum_gas_cost += total_gas
    return total_gas


def check_health(state, peg, deleverage_threshold, emergency_ltv):
    if state.weeth_collateral <= 0 or state.eth_debt <= 0:
        return "normal"
    coll_val = state.weeth_collateral * peg
    ltv = state.eth_debt / coll_val if coll_val > 0 else 1.0

    if ltv >= emergency_ltv:
        repay = min(state.eth_debt, coll_val * 0.95)
        state.weeth_collateral -= repay / peg * 1.002  # slippage
        state.eth_debt -= repay
        if state.eth_debt > state.weeth_collateral * peg * 0.5:
            loss = state.eth_debt - state.weeth_collateral * peg
            state.total_tvl = max(0, state.total_tvl - max(0, loss))
            state.eth_debt = 0
            state.weeth_collateral = state.total_tvl
        state.n_loops = 0
        state.emergency_count += 1
        return "emergency"

    elif ltv >= deleverage_threshold:
        while ltv > deleverage_threshold * 0.95 and state.n_loops > 0:
            loop_debt = state.eth_debt / max(state.n_loops, 1)
            state.weeth_collateral -= loop_debt / peg * 1.002
            state.eth_debt -= loop_debt
            state.n_loops -= 1
            coll_val = state.weeth_collateral * peg
            ltv = state.eth_debt / coll_val if coll_val > 0 else 0
        state.deleverage_count += 1
        return "deleverage"

    return "normal"


def simulate_epoch(state, params, epoch_days, fixed_rate, reserve_bps,
                   perf_fee_rate, delev_thresh, emerg_ltv, morpho_pct,
                   gas_cfg=None):
    if state.total_tvl <= 0 or len(params) == 0:
        return None

    gc = gas_cfg or GasConfig()
    n = len(params)
    total_weeth_yield = 0.0
    total_morpho_yield = 0.0
    total_borrow_cost = 0.0
    min_peg = 1.0
    epoch_gas = 0.0

    for _, day in params.iterrows():
        df = 1.0 / 365.25
        total_weeth_yield += state.weeth_collateral * day["weeth_apr"] * df
        total_morpho_yield += state.total_tvl * morpho_pct * day["morpho_supply_apr"] * df
        total_borrow_cost += state.eth_debt * day["eth_borrow_apr"] * df
        peg = day["weeth_eth_peg"]
        min_peg = min(min_peg, peg)
        old_loops = state.n_loops
        check_health(state, peg, delev_thresh, emerg_ltv)
        if state.n_loops < old_loops:
            epoch_gas += gc.tx_cost_usd(gc.deleverage_tx_gas, day["eth_price"], day["vol_7d"])

    # Weekly rebalance/harvest tx
    avg_price = float(params["eth_price"].mean())
    avg_vol = float(params["vol_7d"].mean())
    epoch_gas += gc.tx_cost_usd(gc.rebalance_tx_gas, avg_price, avg_vol)
    state.cum_gas_cost += epoch_gas

    gross = total_weeth_yield + total_morpho_yield - total_borrow_cost - epoch_gas
    perf_fee = max(0, gross * perf_fee_rate)
    net = gross - perf_fee
    state.cum_protocol_fee += perf_fee

    reserve_add = net * (reserve_bps / 10000)
    distributable = net - reserve_add
    state.reserve += reserve_add

    epoch_frac = n / 365.25
    fixed_obligation = state.fixed_deposits * fixed_rate * epoch_frac

    if distributable < fixed_obligation:
        tap = min(fixed_obligation - distributable, state.reserve)
        state.reserve -= tap
        distributable += tap

    fixed_pay = min(fixed_obligation, max(0, distributable))
    variable_pay = max(0, distributable - fixed_pay)
    state.cum_fixed_yield += fixed_pay
    state.cum_variable_yield += variable_pay

    fixed_apr = fixed_pay / state.fixed_deposits * (365.25 / n) if state.fixed_deposits > 0 else 0
    var_apr = variable_pay / state.variable_deposits * (365.25 / n) if state.variable_deposits > 0 else 0

    peg_end = float(params["weeth_eth_peg"].iloc[-1])
    coll_val = state.weeth_collateral * peg_end
    ltv = state.eth_debt / coll_val if coll_val > 0 else 0
    lev = state.weeth_collateral / state.total_tvl if state.total_tvl > 0 else 1

    return {
        "gross": gross, "net": net, "perf_fee": perf_fee,
        "weeth_yield": total_weeth_yield,
        "morpho_yield": total_morpho_yield,
        "borrow_cost": total_borrow_cost,
        "fixed_obligation": fixed_obligation,
        "fixed_pay": fixed_pay, "variable_pay": variable_pay,
        "fixed_apr": fixed_apr, "var_apr": var_apr,
        "reserve": state.reserve,
        "tvl": state.total_tvl,
        "fixed_tvl": state.fixed_deposits, "var_tvl": state.variable_deposits,
        "weeth_coll": state.weeth_collateral, "eth_debt": state.eth_debt,
        "ltv": ltv, "leverage": lev, "n_loops": state.n_loops,
        "peg": peg_end, "min_peg": min_peg,
        "delev": state.deleverage_count, "emerg": state.emergency_count,
        "shortfall": max(0, fixed_obligation - fixed_pay),
        "eth_price": float(params["eth_price"].iloc[-1]),
        "avg_weeth_apr": float(params["weeth_apr"].mean()),
        "avg_borrow": float(params["eth_borrow_apr"].mean()),
        "spread": float(params["weeth_apr"].mean() - params["eth_borrow_apr"].mean()),
        "gas_cost": epoch_gas,
    }


def run_backtest(daily_df, yp, fixed_rate=0.03, max_loops=4, max_ltv=0.90,
                 epoch_days=7, reserve_bps=200, perf_fee=0.10,
                 fixed_ratio=0.80, tvl=10_000_000, morpho_pct=0.05,
                 delev_thresh=0.85, emerg_ltv=0.92):
    state = VaultState(
        total_tvl=tvl,
        fixed_deposits=tvl * fixed_ratio,
        variable_deposits=tvl * (1 - fixed_ratio),
    )
    gc = GasConfig()
    eth0 = float(yp["eth_price"].iloc[0])
    vol0 = float(yp["vol_7d"].iloc[0]) if yp["vol_7d"].iloc[0] > 0 else 0.3
    initial_gas = execute_leverage(state, max_loops, max_ltv, gc, eth0, vol0)

    results = []
    i = 0
    while i + epoch_days <= len(yp):
        ep = yp.iloc[i:i+epoch_days]
        r = simulate_epoch(state, ep, epoch_days, fixed_rate, reserve_bps,
                           perf_fee, delev_thresh, emerg_ltv, morpho_pct, gc)
        if r is None:
            break
        r["epoch_start"] = yp.index[i]
        results.append(r)

        if state.n_loops < max_loops:
            peg = r["peg"]
            coll_val = state.weeth_collateral * peg
            ltv = state.eth_debt / coll_val if coll_val > 0 else 0
            if ltv < delev_thresh * 0.8 and peg > 0.995:
                ep_price = float(yp.iloc[min(i+epoch_days, len(yp)-1)]["eth_price"])
                ep_vol = float(yp.iloc[min(i+epoch_days, len(yp)-1)]["vol_7d"])
                execute_leverage(state, max_loops, max_ltv, gc, ep_price, ep_vol)
        i += epoch_days

    return pd.DataFrame(results), state


# ============================================================
# SWEEP
# ============================================================

def run_sweep(daily_df, yp):
    configs = list(itertools.product(
        [0.03, 0.05],              # fixed_rate
        [0, 1, 2, 3, 4],           # max_loops
        [0.50, 0.70, 0.80, 0.90],  # fixed_ratio
        [0.03, 0.05, 0.10],        # cap_rate (reserve)
    ))
    print(f"  [sweep] {len(configs)} configs...")

    sums = []
    best = None
    best_score = -999

    for fr, ml, ratio, cap in configs:
        edf, fs = run_backtest(daily_df, yp, fixed_rate=fr, max_loops=ml,
                               fixed_ratio=ratio, reserve_bps=int(cap*10000))
        if edf.empty:
            continue
        n = len(edf)
        years = n * 7 / 365.25
        total_gross = edf["gross"].sum()
        fixed_hit = (edf["fixed_apr"] >= fr * 0.95).mean()

        s = {
            "fixed_rate": fr, "max_loops": ml, "fixed_ratio": ratio,
            "reserve_pct": cap,
            "n_epochs": n,
            "total_apr": total_gross / 10e6 / years * 100 if years > 0 else 0,
            "avg_fixed_apr": edf["fixed_apr"].mean() * 100,
            "avg_var_apr": edf["var_apr"].mean() * 100,
            "min_var_apr": edf["var_apr"].min() * 100,
            "max_var_apr": edf["var_apr"].max() * 100,
            "fixed_hit": fixed_hit * 100,
            "shortfalls": (edf["shortfall"] > 0).sum(),
            "var_positive": (edf["variable_pay"] > 0).mean() * 100,
            "max_ltv": edf["ltv"].max(),
            "avg_leverage": edf["leverage"].mean(),
            "avg_spread": edf["spread"].mean() * 100,
            "delev": fs.deleverage_count,
            "emerg": fs.emergency_count,
            "reserve_final": fs.reserve,
            "tvl_growth": (fs.total_tvl - 10e6) / 10e6 * 100,
            "protocol_fees": fs.cum_protocol_fee,
            "total_gas": fs.cum_gas_cost,
            "gas_pct_of_yield": fs.cum_gas_cost / max(total_gross, 1) * 100,
        }
        sums.append(s)

        score = fixed_hit * 5 + s["avg_var_apr"] * 0.3 - fs.emergency_count * 20
        if score > best_score:
            best_score = score
            best = (edf, fs, s)

    print(f"  [sweep] Done. {len(sums)} valid.")
    return pd.DataFrame(sums), best


def print_report(sweep_df, edf, fs, bs):
    W = 78
    print("\n" + "=" * W)
    print("  weETH YIELD TRANCHE VAULT — BACKTEST RESULTS")
    print("=" * W)

    print(f"\n  Base: weETH (EtherFi + EigenLayer)")
    print(f"  Loop: weETH collateral -> borrow ETH -> buy weETH")
    print(f"  Data: ~1yr daily | Initial TVL: $10M")

    print(f"\n  {'BEST CONFIG':─^{W-4}}")
    print(f"  Fixed rate:     {bs['fixed_rate']*100:.0f}% APR")
    print(f"  Loops:          {bs['max_loops']}")
    print(f"  F:V ratio:      {bs['fixed_ratio']*100:.0f}:{(1-bs['fixed_ratio'])*100:.0f}")
    print(f"  Reserve:        {bs['reserve_pct']*100:.0f}%")
    print(f"  Avg leverage:   {bs['avg_leverage']:.1f}x")
    print(f"  Avg spread:     {bs['avg_spread']:.2f}% (weETH ~5% - ETH borrow ~1.5%)")

    print(f"\n  {'YIELD':─^{W-4}}")
    print(f"  Total vault APR:  {bs['total_apr']:.1f}%")
    print(f"  Fixed APR:        {bs['avg_fixed_apr']:.1f}% (target {bs['fixed_rate']*100:.0f}%)")
    print(f"  Variable APR:     {bs['avg_var_apr']:.1f}%")
    print(f"  Variable range:   {bs['min_var_apr']:.1f}% – {bs['max_var_apr']:.1f}%")

    print(f"\n  {'RELIABILITY':─^{W-4}}")
    print(f"  Fixed hit rate:   {bs['fixed_hit']:.0f}%")
    print(f"  Shortfall epochs: {bs['shortfalls']}")
    print(f"  Variable >0:      {bs['var_positive']:.0f}%")
    print(f"  Reserve final:    ${fs.reserve:,.0f}")

    print(f"\n  {'RISK':─^{W-4}}")
    print(f"  Max LTV:          {bs['max_ltv']*100:.1f}%")
    print(f"  Deleverage:       {bs['delev']}")
    print(f"  Emergency:        {bs['emerg']}")
    print(f"  Protocol fees:    ${fs.cum_protocol_fee:,.0f}")

    print(f"\n  {'GAS COSTS':─^{W-4}}")
    print(f"  Total gas (1yr):  ${fs.cum_gas_cost:,.0f}")
    print(f"  Gas as % yield:   {bs['gas_pct_of_yield']:.2f}%")
    print(f"  Avg gas/epoch:    ${edf['gas_cost'].mean():,.0f}")
    print(f"  Max gas/epoch:    ${edf['gas_cost'].max():,.0f}  (deleverage epoch)")

    print(f"\n  {'WEEKLY BREAKDOWN ($1M TVL equivalent)':─^{W-4}}")
    avg_weekly_gross = edf["gross"].mean()
    scale = 1_000_000 / 10_000_000
    print(f"  Weekly gross yield:  ${avg_weekly_gross * scale:,.0f}")
    print(f"  Fixed payout:        ${edf['fixed_pay'].mean() * scale:,.0f}")
    print(f"  Variable payout:     ${edf['variable_pay'].mean() * scale:,.0f}")
    print(f"  Protocol fee:        ${edf['perf_fee'].mean() * scale:,.0f}")
    print(f"  Reserve:             ${edf['reserve'].diff().mean() * scale:,.0f}")

    # VIABLE configs
    viable = sweep_df[(sweep_df["fixed_hit"] >= 95) & (sweep_df["avg_var_apr"] >= 10)]
    print(f"\n  {'VIABLE (Fixed>=95% hit, Variable>=10%)':─^{W-4}}")
    print(f"  Found: {len(viable)} / {len(sweep_df)}")
    if len(viable) > 0:
        top = viable.nlargest(15, "avg_var_apr")
        print(f"    {'FR':>4} {'L':>2} {'F:V':>5} {'Res':>4} {'TotAPR':>7} {'VarAPR':>7} "
              f"{'Hit':>4} {'Lev':>4} {'Risk':>4}")
        print(f"    {'─'*4} {'─'*2} {'─'*5} {'─'*4} {'─'*7} {'─'*7} {'─'*4} {'─'*4} {'─'*4}")
        for _, r in top.iterrows():
            risk = r['delev'] + r['emerg']
            print(f"    {r['fixed_rate']*100:>3.0f}% {r['max_loops']:>2.0f} "
                  f"{r['fixed_ratio']*100:.0f}:{(1-r['fixed_ratio'])*100:.0f}  "
                  f"{r['reserve_pct']*100:>2.0f}%  "
                  f"{r['total_apr']:>6.1f}% {r['avg_var_apr']:>6.1f}% "
                  f"{r['fixed_hit']:>3.0f}% {r['avg_leverage']:>3.1f}x {risk:>3.0f}")

    # RISK DISCLOSURE
    print(f"\n  {'RISK DISCLOSURE':─^{W-4}}")
    print(f"  Protocol dependencies: Ethereum PoS + EigenLayer + EtherFi + Morpho Blue")
    print(f"  weETH depeg risk: higher than stETH (extra EigenLayer slashing layer)")
    print(f"  Variable 50%+ APR = ALL leverage risk concentrated on 20% of TVL")
    print(f"  If weETH depegs >5%: Variable tranche can lose 100% of principal")
    print(f"  Fixed tranche protected by waterfall, but NOT guaranteed in black swan")

    print("\n" + "=" * W)


# ============================================================
# MAIN
# ============================================================

def main():
    print("=" * 78)
    print("  weETH YIELD TRANCHE VAULT — BACKTEST")
    print("=" * 78)

    daily_df = fetch_eth_prices(months=13)
    print(f"  {len(daily_df)} days: {daily_df.index[0].date()} -> {daily_df.index[-1].date()}")
    print(f"  ETH: ${daily_df['close'].min():.0f} - ${daily_df['close'].max():.0f}")

    yp = generate_yield_params(daily_df["close"])
    print(f"  weETH APR: {yp['weeth_apr'].mean()*100:.1f}% avg "
          f"(staking {yp['staking_apr'].mean()*100:.1f}% + restaking {yp['restaking_apr'].mean()*100:.1f}%)")
    print(f"  ETH borrow: {yp['eth_borrow_apr'].mean()*100:.2f}% avg")
    print(f"  Spread: {(yp['weeth_apr'] - yp['eth_borrow_apr']).mean()*100:.2f}%")

    sweep_df, (best_edf, best_fs, best_bs) = run_sweep(daily_df, yp)
    print_report(sweep_df, best_edf, best_fs, best_bs)

    sweep_df.to_csv(OUTPUT_DIR / "weeth_sweep.csv", index=False)
    best_edf.to_csv(OUTPUT_DIR / "weeth_best_epochs.csv", index=False)
    print(f"\n  [saved] {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
