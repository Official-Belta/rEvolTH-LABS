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
Yield Tranche Vault — Economics Backtest (v2: Correlated Pair Loop)
====================================================================
Base asset: ETH
Looping: stETH collateral → borrow ETH → buy stETH → repeat
         (correlated pair, NOT stETH→USDC→stETH)

This changes everything:
- Borrow rate = ETH borrow rate (~1-3%), NOT USDC (~4-10%)
- LTV risk from stETH/ETH depeg only, NOT ETH/USD price drops
- Leverage spread = stETH_yield - ETH_borrow = always positive in normal markets
- 3x loop safely adds 3-6% net yield

Yield Stack:
  L1: stETH staking yield ~3% on amplified collateral
  L2: Morpho supply APR 1-3% on idle portion
  L3: Correlated loop leverage (stETH collateral → borrow ETH → buy stETH)
      Net per loop ≈ stETH_yield - ETH_borrow_rate ≈ 1.5% per loop
  L4: Uni V4 (Phase 3, excluded)
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


# ============================================================
# 1. DATA
# ============================================================

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
    raise RuntimeError("No price data available")


# ============================================================
# 2. YIELD MODEL — correlated pair loop
# ============================================================

def generate_yield_params(eth_prices: pd.Series, seed=42):
    """
    Generate realistic daily yield parameters.

    Key difference from v1: borrow rate is ETH (not USDC).
    ETH borrow on Morpho is typically 0.5-3% since supply is abundant.

    stETH/ETH ratio: normally 0.999-1.001, can depeg to 0.95-0.98 in stress.
    We model this as the primary risk factor for leverage.
    """
    rng = np.random.RandomState(seed)
    n = len(eth_prices)
    daily_ret = eth_prices.pct_change().fillna(0).values
    vol_7d = pd.Series(daily_ret).rolling(7).std().fillna(0.02).values * math.sqrt(365)

    # --- stETH staking yield (APR) ---
    steth_base = 0.03
    steth_noise = np.zeros(n)
    for i in range(1, n):
        steth_noise[i] = 0.95 * steth_noise[i-1] + rng.normal(0, 0.001)
    steth_apr = np.clip(steth_base + steth_noise, 0.025, 0.045)

    # --- Morpho supply APR (ETH supplied to earn) ---
    morpho_supply_base = 0.015
    morpho_noise = rng.normal(0, 0.002, n)
    morpho_supply_apr = np.clip(morpho_supply_base + vol_7d * 0.02 + morpho_noise,
                                 0.005, 0.04)

    # --- ETH borrow rate on Morpho (stETH/ETH market) ---
    # Correlated pair market: very low borrow rates
    # Historical Morpho stETH/ETH: typically 0.5-2% APR
    # Can spike to 3-5% during extreme stETH depeg events
    eth_borrow_base = 0.008  # 0.8% base
    eth_borrow_noise = rng.normal(0, 0.001, n)
    stress_spike = np.where(daily_ret < -0.07, 0.01, 0)
    eth_borrow_apr = np.clip(
        eth_borrow_base + vol_7d * 0.01 + stress_spike + eth_borrow_noise,
        0.002, 0.05
    )

    # --- stETH/ETH peg ratio ---
    # Normally ~1.0, slight random walk, rare depeg events
    peg_ratio = np.ones(n)
    peg_noise = np.zeros(n)
    for i in range(1, n):
        # Mean-reverting to 1.0
        peg_noise[i] = 0.98 * peg_noise[i-1] + rng.normal(0, 0.0003)
        # Rare depeg event (0.5% daily chance during high vol)
        if vol_7d[i] > 0.6 and rng.random() < 0.005:
            peg_noise[i] -= 0.01  # 1% depeg shock
    peg_ratio = np.clip(1.0 + peg_noise, 0.95, 1.005)

    return pd.DataFrame({
        "eth_price": eth_prices.values,
        "daily_ret": daily_ret,
        "vol_7d": vol_7d,
        "steth_apr": steth_apr,
        "morpho_supply_apr": morpho_supply_apr,
        "eth_borrow_apr": eth_borrow_apr,
        "steth_eth_peg": peg_ratio,
    }, index=eth_prices.index)


# ============================================================
# 3. VAULT SIMULATION ENGINE
# ============================================================

@dataclass
class VaultState:
    total_tvl: float = 0.0          # in ETH terms
    fixed_deposits: float = 0.0
    variable_deposits: float = 0.0

    # Leverage state (all in ETH terms)
    steth_collateral: float = 0.0   # stETH held (ETH-equivalent at peg)
    eth_debt: float = 0.0           # ETH borrowed
    n_loops: int = 0

    # Reserve
    reserve: float = 0.0

    # Tracking
    deleverage_count: int = 0
    emergency_count: int = 0


def execute_leverage(state: VaultState, max_loops: int, max_ltv: float):
    """
    Correlated pair loop: stETH collateral → borrow ETH → swap to stETH → repeat.
    All in ETH terms. stETH/ETH ≈ 1:1 so slippage is minimal.
    """
    if state.total_tvl <= 0:
        return

    state.steth_collateral = state.total_tvl
    state.eth_debt = 0.0
    state.n_loops = 0

    for _ in range(max_loops):
        target_ltv = max_ltv - 0.05
        max_borrow = state.steth_collateral * target_ltv - state.eth_debt
        if max_borrow <= 100:  # minimum $100 worth
            break

        borrow = max_borrow * 0.95
        state.eth_debt += borrow
        # Swap ETH → stETH (correlated pair, very low slippage)
        slippage = 0.0002  # 2bps for correlated pair
        steth_bought = borrow * (1 - slippage)
        state.steth_collateral += steth_bought
        state.n_loops += 1


def check_health(state: VaultState, steth_eth_peg: float,
                 deleverage_threshold: float, emergency_ltv: float):
    """
    Check health factor based on stETH/ETH peg.
    ETH/USD price doesn't matter — both sides are ETH-denominated.
    Only stETH depeg affects LTV.
    """
    if state.steth_collateral <= 0 or state.eth_debt <= 0:
        return "normal"

    # Collateral value in ETH = stETH amount × peg ratio
    collateral_eth_value = state.steth_collateral * steth_eth_peg
    ltv = state.eth_debt / collateral_eth_value if collateral_eth_value > 0 else 1.0

    if ltv >= emergency_ltv:
        # Emergency unwind
        repay = min(state.eth_debt, collateral_eth_value * 0.95)
        state.steth_collateral -= repay / steth_eth_peg
        state.eth_debt -= repay
        if state.eth_debt > collateral_eth_value * 0.5:
            loss = state.eth_debt - state.steth_collateral * steth_eth_peg
            state.total_tvl = max(0, state.total_tvl - max(0, loss))
            state.eth_debt = 0
            state.steth_collateral = state.total_tvl
        state.n_loops = 0
        state.emergency_count += 1
        return "emergency"

    elif ltv >= deleverage_threshold:
        while ltv > deleverage_threshold * 0.95 and state.n_loops > 0:
            loop_debt = state.eth_debt / max(state.n_loops, 1)
            sell_steth = loop_debt / steth_eth_peg * 1.001
            state.steth_collateral -= sell_steth
            state.eth_debt -= loop_debt
            state.n_loops -= 1
            collateral_eth_value = state.steth_collateral * steth_eth_peg
            ltv = state.eth_debt / collateral_eth_value if collateral_eth_value > 0 else 0
        state.deleverage_count += 1
        return "deleverage"

    return "normal"


def simulate_epoch(state: VaultState, params: pd.DataFrame, epoch_days: int,
                   fixed_rate_apr: float, reserve_bps: int, performance_fee: float,
                   deleverage_threshold: float, emergency_ltv: float):
    """Simulate one epoch."""
    if state.total_tvl <= 0:
        return None
    n_days = len(params)
    if n_days == 0:
        return None

    total_steth_yield = 0.0
    total_morpho_yield = 0.0
    total_borrow_cost = 0.0
    min_peg = 1.0

    for _, day in params.iterrows():
        df = 1.0 / 365.25

        # L1: stETH yield on ALL stETH held (including leveraged)
        steth_daily = state.steth_collateral * day["steth_apr"] * df
        total_steth_yield += steth_daily

        # L2: Morpho supply (small idle portion, e.g. 10% of base TVL)
        morpho_portion = state.total_tvl * 0.10
        morpho_daily = morpho_portion * day["morpho_supply_apr"] * df
        total_morpho_yield += morpho_daily

        # L3: Borrow cost on ETH debt
        borrow_daily = state.eth_debt * day["eth_borrow_apr"] * df
        total_borrow_cost += borrow_daily

        # Check health based on stETH/ETH peg
        peg = day["steth_eth_peg"]
        min_peg = min(min_peg, peg)
        check_health(state, peg, deleverage_threshold, emergency_ltv)

    # All yield in USD terms (TVL is in USD, rates are APR on USD value)
    # No ETH price conversion needed — TVL is already USD-denominated
    eth_price_end = float(params["eth_price"].iloc[-1])
    gross_yield = total_steth_yield + total_morpho_yield - total_borrow_cost
    leverage_net = (total_steth_yield -
                    state.total_tvl * params["steth_apr"].mean() / 365.25 * n_days -
                    total_borrow_cost)

    perf_fee = max(0, gross_yield * performance_fee)
    net_yield = gross_yield - perf_fee

    reserve_contrib = net_yield * (reserve_bps / 10000)
    distributable = net_yield - reserve_contrib
    state.reserve += reserve_contrib

    # WATERFALL
    epoch_frac = n_days / 365.25
    fixed_obligation = state.fixed_deposits * fixed_rate_apr * epoch_frac

    if distributable < fixed_obligation:
        shortfall = fixed_obligation - distributable
        tap = min(shortfall, state.reserve)
        state.reserve -= tap
        distributable += tap

    fixed_payout = min(fixed_obligation, max(0, distributable))
    variable_payout = max(0, distributable - fixed_payout)

    # NO TVL compounding — yield is withdrawn, not reinvested
    # APR calculated on INITIAL deposits (constant principal)

    # APRs (annualized, on initial principal)
    fixed_apr = (fixed_payout / state.fixed_deposits * (365.25 / n_days)
                 if state.fixed_deposits > 0 else 0)
    variable_apr = (variable_payout / state.variable_deposits * (365.25 / n_days)
                    if state.variable_deposits > 0 else 0)

    # LTV
    peg = float(params["steth_eth_peg"].iloc[-1])
    coll_val = state.steth_collateral * peg
    ltv = state.eth_debt / coll_val if coll_val > 0 else 0

    # Leverage multiplier
    leverage_mult = state.steth_collateral / state.total_tvl if state.total_tvl > 0 else 1.0

    return {
        "gross_yield": gross_yield,
        "net_yield": net_yield,
        "perf_fee": perf_fee,
        "steth_yield": total_steth_yield,
        "morpho_yield": total_morpho_yield,
        "borrow_cost": total_borrow_cost,
        "leverage_net": leverage_net,
        "fixed_obligation": fixed_obligation,
        "fixed_payout": fixed_payout,
        "variable_payout": variable_payout,
        "fixed_apr": fixed_apr,
        "variable_apr": variable_apr,
        "reserve": state.reserve,
        "tvl": state.total_tvl,
        "fixed_tvl": state.fixed_deposits,
        "variable_tvl": state.variable_deposits,
        "steth_collateral": state.steth_collateral,
        "eth_debt": state.eth_debt,
        "ltv": ltv,
        "leverage_mult": leverage_mult,
        "n_loops": state.n_loops,
        "steth_eth_peg": peg,
        "min_peg_epoch": min_peg,
        "deleverage_count": state.deleverage_count,
        "emergency_count": state.emergency_count,
        "fixed_shortfall": max(0, fixed_obligation - fixed_payout),
        "eth_price": eth_price_end,
        "avg_steth_apr": float(params["steth_apr"].mean()),
        "avg_borrow_apr": float(params["eth_borrow_apr"].mean()),
        "spread": float(params["steth_apr"].mean() - params["eth_borrow_apr"].mean()),
    }


# ============================================================
# 4. FULL BACKTEST
# ============================================================

def run_backtest(daily_df, yield_params,
                 fixed_rate_apr=0.05, max_loops=3, max_ltv=0.90,
                 epoch_days=7, reserve_bps=200, performance_fee=0.10,
                 fixed_ratio=0.50, initial_tvl=10_000_000,
                 deleverage_threshold=0.85, emergency_ltv=0.92):
    """
    Note: LTV thresholds are higher for correlated pair.
    stETH/ETH on Morpho typically allows 90-95% LTV.
    """
    state = VaultState(
        total_tvl=initial_tvl,
        fixed_deposits=initial_tvl * fixed_ratio,
        variable_deposits=initial_tvl * (1 - fixed_ratio),
    )
    execute_leverage(state, max_loops, max_ltv)

    dates = yield_params.index
    results = []
    i = 0

    while i + epoch_days <= len(yield_params):
        ep = yield_params.iloc[i:i+epoch_days]
        result = simulate_epoch(
            state, ep, epoch_days,
            fixed_rate_apr, reserve_bps, performance_fee,
            deleverage_threshold, emergency_ltv
        )
        if result is None:
            break

        result["epoch_start"] = dates[i]
        result["epoch_end"] = dates[min(i+epoch_days-1, len(dates)-1)]
        results.append(result)

        # Re-leverage if loops were unwound
        if state.n_loops < max_loops:
            peg = result["steth_eth_peg"]
            coll_val = state.steth_collateral * peg
            ltv = state.eth_debt / coll_val if coll_val > 0 else 0
            if ltv < deleverage_threshold * 0.8 and peg > 0.995:
                execute_leverage(state, max_loops, max_ltv)

        i += epoch_days

    return pd.DataFrame(results), state


# ============================================================
# 5. SWEEP
# ============================================================

def run_sweep(daily_df, yield_params):
    fixed_rates = [0.03, 0.05, 0.07, 0.10]
    max_loops_list = [0, 1, 2, 3, 4]
    fixed_ratios = [0.30, 0.50, 0.70]

    combos = list(itertools.product(fixed_rates, max_loops_list, fixed_ratios))
    print(f"  [sweep] {len(combos)} combos...")

    summaries = []
    best = None
    best_score = -999

    for fr, ml, ratio in combos:
        edf, fs = run_backtest(daily_df, yield_params,
                               fixed_rate_apr=fr, max_loops=ml, fixed_ratio=ratio)
        if edf.empty:
            continue

        n = len(edf)
        years = n * 7 / 365.25
        total_gross = edf["gross_yield"].sum()
        total_apr = total_gross / 10_000_000 / years * 100 if years > 0 else 0
        fixed_hit = (edf["fixed_apr"] >= fr * 0.95).mean()

        s = {
            "fixed_rate": fr, "max_loops": ml, "fixed_ratio": ratio,
            "n_epochs": n,
            "total_apr": total_apr,
            "avg_fixed_apr": edf["fixed_apr"].mean() * 100,
            "avg_variable_apr": edf["variable_apr"].mean() * 100,
            "fixed_hit_pct": fixed_hit * 100,
            "shortfall_epochs": (edf["fixed_shortfall"] > 0).sum(),
            "var_positive_pct": (edf["variable_payout"] > 0).mean() * 100,
            "min_var_apr": edf["variable_apr"].min() * 100,
            "max_var_apr": edf["variable_apr"].max() * 100,
            "max_ltv": edf["ltv"].max(),
            "avg_leverage": edf["leverage_mult"].mean(),
            "avg_spread": edf["spread"].mean() * 100,
            "deleverage": fs.deleverage_count,
            "emergency": fs.emergency_count,
            "reserve_final": fs.reserve,
            "tvl_growth": (fs.total_tvl - 10_000_000) / 10_000_000 * 100,
        }
        summaries.append(s)

        score = fixed_hit * 5 + s["avg_variable_apr"] * 0.5 - fs.emergency_count * 10
        if score > best_score:
            best_score = score
            best = (edf, fs, s)

    print(f"  [sweep] Done. {len(summaries)} valid.")
    return pd.DataFrame(summaries), best


# ============================================================
# 6. VISUALIZATION
# ============================================================

def plot_results(edf, sweep_df, bs, output_dir):
    output_dir = Path(output_dir)
    fig = plt.figure(figsize=(22, 30))
    gs = gridspec.GridSpec(5, 2, hspace=0.38, wspace=0.28)
    fig.suptitle(
        f"Yield Tranche Vault (Correlated Loop) — Fixed={bs['fixed_rate']*100:.0f}%, "
        f"Loops={bs['max_loops']}, F:V={bs['fixed_ratio']*100:.0f}:{(1-bs['fixed_ratio'])*100:.0f}\n"
        f"Avg Leverage={bs['avg_leverage']:.1f}x | Spread={bs['avg_spread']:.2f}%",
        fontsize=14, fontweight='bold', y=0.995
    )
    x = range(len(edf))

    # 1. Tranche APRs
    ax = fig.add_subplot(gs[0, 0])
    ax.plot(x, edf["fixed_apr"] * 100, 'b-', lw=1.5, label='Fixed APR')
    ax.plot(x, edf["variable_apr"] * 100, 'r-', lw=1, alpha=0.7, label='Variable APR')
    ax.axhline(bs["fixed_rate"] * 100, color='blue', ls='--', alpha=0.5,
               label=f'Target {bs["fixed_rate"]*100:.0f}%')
    ax.set_ylabel("APR (%)"); ax.set_title(f"Tranche APRs (Fixed hit: {bs['fixed_hit_pct']:.0f}%)")
    ax.legend(fontsize=9); ax.grid(True, alpha=0.3)

    # 2. ETH Price + stETH/ETH peg
    ax = fig.add_subplot(gs[0, 1])
    ax2 = ax.twinx()
    ax.plot(edf["epoch_start"], edf["eth_price"], 'k-', lw=1, label='ETH price')
    ax2.plot(edf["epoch_start"], edf["steth_eth_peg"], 'purple', lw=1, alpha=0.7, label='stETH/ETH')
    ax2.axhline(1.0, color='gray', ls='--', alpha=0.3)
    ax.set_ylabel("ETH ($)"); ax2.set_ylabel("stETH/ETH peg")
    ax.set_title("Price + Peg")
    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1+h2, l1+l2, fontsize=9)
    ax.tick_params(axis='x', rotation=30); ax.grid(True, alpha=0.3)

    # 3. Yield source breakdown
    ax = fig.add_subplot(gs[1, 0])
    ax.bar(x, edf["steth_yield"] / 1e3, color='#2196F3', alpha=0.7, label='stETH (leveraged)')
    ax.bar(x, edf["morpho_yield"] / 1e3,
           bottom=edf["steth_yield"] / 1e3, color='#4CAF50', alpha=0.7, label='Morpho Supply')
    ax.bar(x, -edf["borrow_cost"] / 1e3, color='red', alpha=0.5, label='ETH Borrow Cost')
    ax.set_ylabel("$K"); ax.set_title("Yield Sources per Epoch")
    ax.legend(fontsize=9); ax.grid(True, alpha=0.3)

    # 4. Fixed obligation vs payout
    ax = fig.add_subplot(gs[1, 1])
    ax.bar(x, edf["fixed_obligation"] / 1e3, color='lightblue', alpha=0.7, label='Obligation')
    ax.bar(x, edf["fixed_payout"] / 1e3, color='blue', alpha=0.5, label='Payout')
    sf = edf["fixed_shortfall"] > 0
    if sf.any():
        ax.bar(np.array(list(x))[sf], edf["fixed_shortfall"][sf] / 1e3,
               color='red', alpha=0.8, label='Shortfall')
    ax.set_ylabel("$K"); ax.set_title(f"Fixed: Obligation vs Payout ({sf.sum()} shortfalls)")
    ax.legend(fontsize=9); ax.grid(True, alpha=0.3)

    # 5. TVL growth
    ax = fig.add_subplot(gs[2, 0])
    ax.plot(x, edf["fixed_tvl"] / 1e6, 'b-', lw=1.5, label='Fixed')
    ax.plot(x, edf["variable_tvl"] / 1e6, 'r-', lw=1.5, label='Variable')
    ax.plot(x, edf["tvl"] / 1e6, 'k--', lw=1, label='Total')
    ax.set_ylabel("$M"); ax.set_title(f"TVL ({bs['tvl_growth']:+.1f}%)")
    ax.legend(fontsize=9); ax.grid(True, alpha=0.3)

    # 6. Leverage: stETH/ETH spread + LTV
    ax = fig.add_subplot(gs[2, 1])
    ax.plot(x, edf["spread"] * 100, 'g-', lw=1.5, label='Spread (stETH - borrow)')
    ax.axhline(0, color='gray', ls='-', alpha=0.3)
    ax2 = ax.twinx()
    ax2.plot(x, edf["ltv"] * 100, 'purple', lw=1, alpha=0.7, label='LTV')
    ax2.axhline(85, color='orange', ls='--', alpha=0.5)
    ax.set_ylabel("Spread (%)"); ax2.set_ylabel("LTV (%)")
    ax.set_title("Leverage Spread + LTV")
    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1+h2, l1+l2, fontsize=9); ax.grid(True, alpha=0.3)

    # 7. Variable APR distribution
    ax = fig.add_subplot(gs[3, 0])
    ax.hist(edf["variable_apr"] * 100, bins=30, color='red', alpha=0.6, edgecolor='white')
    ax.axvline(edf["variable_apr"].mean() * 100, color='red', ls='--',
               label=f'Mean={edf["variable_apr"].mean()*100:.1f}%')
    ax.set_xlabel("Variable APR (%)"); ax.set_ylabel("Count")
    ax.set_title("Variable APR Distribution"); ax.legend(fontsize=9); ax.grid(True, alpha=0.3)

    # 8. Reserve buffer
    ax = fig.add_subplot(gs[3, 1])
    ax.plot(x, edf["reserve"] / 1e3, 'g-', lw=1.5)
    ax.set_ylabel("$K"); ax.set_title(f"Reserve (final: ${edf['reserve'].iloc[-1]/1e3:,.0f}K)")
    ax.grid(True, alpha=0.3)

    # 9. Leverage multiplier
    ax = fig.add_subplot(gs[4, 0])
    ax.plot(x, edf["leverage_mult"], 'purple', lw=1.5)
    ax.set_ylabel("x"); ax.set_title(f"Leverage Multiplier (avg: {bs['avg_leverage']:.1f}x)")
    ax.grid(True, alpha=0.3)

    # 10. Loops active
    ax = fig.add_subplot(gs[4, 1])
    ax.plot(x, edf["n_loops"], 'purple', lw=1.5)
    ax.set_ylabel("Loops"); ax.set_title(f"Active Loops (delev: {bs['deleverage']}, emerg: {bs['emergency']})")
    ax.set_ylim(-0.5, 5.5); ax.grid(True, alpha=0.3)

    plt.savefig(output_dir / "dashboard.png", dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  [plot] dashboard.png")

    # --- HEATMAPS ---
    for metric, label, cmap, vmin, vmax in [
        ("avg_variable_apr", "Avg Variable APR (%)", "RdYlGn", -5, 40),
        ("fixed_hit_pct", "Fixed Hit Rate (%)", "YlGn", 0, 100),
        ("total_apr", "Total Vault APR (%)", "RdYlGn", 0, 20),
    ]:
        fig, axes = plt.subplots(1, 4, figsize=(24, 5))
        fig.suptitle(f"{label} by Config", fontsize=13, fontweight='bold')
        for idx, fr in enumerate([0.03, 0.05, 0.07, 0.10]):
            ax = axes[idx]
            sub = sweep_df[sweep_df["fixed_rate"] == fr]
            if sub.empty:
                continue
            piv = sub.pivot_table(index="fixed_ratio", columns="max_loops", values=metric)
            im = ax.imshow(piv.values, cmap=cmap, aspect='auto', vmin=vmin, vmax=vmax)
            ax.set_xticks(range(len(piv.columns)))
            ax.set_xticklabels([f"{l}" for l in piv.columns])
            ax.set_yticks(range(len(piv.index)))
            ax.set_yticklabels([f"{r*100:.0f}%" for r in piv.index])
            ax.set_title(f"FR={fr*100:.0f}%"); ax.set_xlabel("Loops"); ax.set_ylabel("Fixed %")
            for (j, k), val in np.ndenumerate(piv.values):
                fmt = f"{val:.1f}%" if "apr" in metric.lower() else f"{val:.0f}%"
                ax.text(k, j, fmt, ha='center', va='center', fontsize=10, fontweight='bold')
            plt.colorbar(im, ax=ax, shrink=0.8)
        plt.tight_layout()
        fname = f"{metric}_heatmap.png"
        fig.savefig(output_dir / fname, dpi=150, bbox_inches='tight')
        plt.close()
        print(f"  [plot] {fname}")


# ============================================================
# 7. REPORT
# ============================================================

def print_report(sweep_df, edf, fs, bs):
    W = 78
    print("\n" + "=" * W)
    print("  YIELD TRANCHE VAULT — CORRELATED LOOP BACKTEST")
    print("=" * W)

    print(f"\n  Base: ETH | Loop: stETH collateral → borrow ETH → buy stETH")
    print(f"  Data: ~1yr daily | Initial TVL: $10M")

    print(f"\n  {'BEST CONFIG':─^{W-4}}")
    print(f"  Fixed rate:    {bs['fixed_rate']*100:.0f}% APR")
    print(f"  Loops:         {bs['max_loops']}")
    print(f"  F:V ratio:     {bs['fixed_ratio']*100:.0f}:{(1-bs['fixed_ratio'])*100:.0f}")
    print(f"  Avg leverage:  {bs['avg_leverage']:.1f}x")
    print(f"  Avg spread:    {bs['avg_spread']:.2f}% (stETH yield - ETH borrow)")

    print(f"\n  {'YIELD':─^{W-4}}")
    print(f"  Total vault APR:  {bs['total_apr']:.1f}%")
    print(f"  Fixed APR avg:    {bs['avg_fixed_apr']:.1f}% (target: {bs['fixed_rate']*100:.0f}%)")
    print(f"  Variable APR avg: {bs['avg_variable_apr']:.1f}%")
    print(f"  Variable range:   {bs['min_var_apr']:.1f}% – {bs['max_var_apr']:.1f}%")

    print(f"\n  {'RELIABILITY':─^{W-4}}")
    print(f"  Fixed hit rate:   {bs['fixed_hit_pct']:.0f}%")
    print(f"  Shortfall epochs: {bs['shortfall_epochs']}")
    print(f"  Variable >0:      {bs['var_positive_pct']:.0f}%")
    print(f"  Reserve:          ${fs.reserve:,.0f}")

    print(f"\n  {'RISK':─^{W-4}}")
    print(f"  Max LTV:          {bs['max_ltv']*100:.1f}%")
    print(f"  Deleverage:       {bs['deleverage']}")
    print(f"  Emergency:        {bs['emergency']}")
    print(f"  TVL growth:       {bs['tvl_growth']:+.1f}%")

    # Viable configs
    viable = sweep_df[(sweep_df["fixed_hit_pct"] >= 95) & (sweep_df["avg_variable_apr"] >= 5)]
    print(f"\n  {'VIABLE (Fixed≥95% hit, Var≥5%)':─^{W-4}}")
    print(f"  Found: {len(viable)} / {len(sweep_df)}")
    if len(viable) > 0:
        top = viable.nlargest(20, "avg_variable_apr")
        print(f"    {'FR':>4} {'L':>2} {'F:V':>5} {'TotAPR':>7} {'FixAPR':>7} {'VarAPR':>7} "
              f"{'Hit':>4} {'Lev':>4} {'Sprd':>5} {'Risk':>4}")
        print(f"    {'─'*4} {'─'*2} {'─'*5} {'─'*7} {'─'*7} {'─'*7} {'─'*4} {'─'*4} {'─'*5} {'─'*4}")
        for _, r in top.iterrows():
            risk = r['deleverage'] + r['emergency']
            print(f"    {r['fixed_rate']*100:>3.0f}% {r['max_loops']:>2.0f} "
                  f"{r['fixed_ratio']*100:.0f}:{(1-r['fixed_ratio'])*100:.0f}  "
                  f"{r['total_apr']:>6.1f}% {r['avg_fixed_apr']:>6.1f}% {r['avg_variable_apr']:>6.1f}% "
                  f"{r['fixed_hit_pct']:>3.0f}% {r['avg_leverage']:>3.1f}x "
                  f"{r['avg_spread']:>4.2f}% {risk:>3.0f}")

    print("\n" + "=" * W)


# ============================================================
# MAIN
# ============================================================

def main():
    print("=" * 78)
    print("  YIELD TRANCHE VAULT — CORRELATED LOOP BACKTEST")
    print("=" * 78)

    daily_df = fetch_eth_prices(months=13)
    print(f"  {len(daily_df)} days: {daily_df.index[0].date()} → {daily_df.index[-1].date()}")
    print(f"  ETH: ${daily_df['close'].min():.0f} – ${daily_df['close'].max():.0f}")

    yp = generate_yield_params(daily_df["close"])
    print(f"  stETH APR: {yp['steth_apr'].mean()*100:.1f}% avg")
    print(f"  ETH borrow: {yp['eth_borrow_apr'].mean()*100:.2f}% avg")
    print(f"  Spread: {(yp['steth_apr'] - yp['eth_borrow_apr']).mean()*100:.2f}%")

    sweep_df, (best_edf, best_fs, best_bs) = run_sweep(daily_df, yp)
    print_report(sweep_df, best_edf, best_fs, best_bs)
    plot_results(best_edf, sweep_df, best_bs, OUTPUT_DIR)

    sweep_df.to_csv(OUTPUT_DIR / "sweep_results.csv", index=False)
    best_edf.to_csv(OUTPUT_DIR / "best_epochs.csv", index=False)
    print(f"\n  [saved] {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
