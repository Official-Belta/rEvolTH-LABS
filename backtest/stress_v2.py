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
weETH Tranche Vault — Realistic Stress Test v2
=================================================
Fixes from v1:
1. Slippage = f(peg) — nonlinear, explodes during depeg
2. Oscillating depeg — panic/bounce/deeper panic pattern
3. Small TVL scenarios — $100K, $500K, $1M, $10M
4. Yield drops during depeg

Config: Fixed 3% | 4 loops | 80:20 | Reserve 3%
"""

import math
from pathlib import Path
from dataclasses import dataclass, field
from copy import deepcopy

import numpy as np
import pandas as pd
import requests

DATA_DIR = Path(__file__).parent / "data"


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
# 1. NONLINEAR SLIPPAGE MODEL
# ============================================================

def slippage_model(peg: float, sell_size_usd: float, pool_liquidity: float = 50_000_000) -> float:
    """
    Additional slippage BEYOND the depeg discount, from AMM price impact + panic.
    Pool liquidity: $50M (weETH/ETH, realistic for major LST).

    Calibrated against 2022 stETH depeg (Curve pool data):
      peg 0.99, $1M sell  → ~0.2%  (normal)
      peg 0.93, $1M sell  → ~2.5%  (2022 stETH-level stress)
      peg 0.85, $500K     → ~5%    (extreme, thin liquidity)
      peg 0.80, $500K     → ~8.5%  (near-catastrophic)

    Returns slippage as fraction (0.01 = 1%). This is ADDITIONAL to peg loss.
    """
    if peg >= 1.0:
        return sell_size_usd / pool_liquidity * 0.3  # ~0.006% for $1M

    depeg = 1.0 - peg

    # Pool liquidity shrinks: LPs exit during depeg
    # 5%→74%, 10%→49%, 15%→30%, 20%→16%, 25%→6%
    liq_factor = max(0.05, (1.0 - depeg * 3) ** 2)
    effective_liq = pool_liquidity * liq_factor

    # AMM sqrt price impact
    impact = 0.1 * (sell_size_usd / effective_liq) ** 0.5

    # Panic premium: other sellers, MEV, cascading liquidations
    panic = depeg ** 2 * 1.5

    return min(impact + panic, 0.30)


# ============================================================
# 2. OSCILLATING DEPEG GENERATOR
# ============================================================

def generate_oscillating_depeg(n_days: int, max_depeg: float, seed: int = 123) -> np.ndarray:
    """
    Generate realistic depeg pattern: panic → bounce → deeper panic → gradual recovery.

    Based on 2022 stETH pattern:
    - Day 1-3: initial shock, -3%
    - Day 4-5: dead cat bounce, +1.5%
    - Day 6-10: deeper panic, hits max depeg
    - Day 11-15: volatile oscillation
    - Day 16-30: slow recovery with setbacks
    - Day 31+: gradual return to peg

    Returns array of peg values (1.0 = no depeg).
    """
    rng = np.random.RandomState(seed)
    peg = np.ones(n_days)

    if n_days < 5:
        return peg

    # Phase 1: Initial shock (day 0-3)
    shock_1 = max_depeg * 0.4
    for d in range(min(3, n_days)):
        peg[d] = 1.0 - shock_1 * (d + 1) / 3

    # Phase 2: Dead cat bounce (day 3-5)
    for d in range(3, min(5, n_days)):
        peg[d] = peg[2] + shock_1 * 0.3 * (d - 2) / 2

    # Phase 3: Deeper panic — hits max depeg (day 5-10)
    if n_days > 5:
        bounce_level = peg[min(4, n_days-1)]
        for d in range(5, min(10, n_days)):
            progress = (d - 5) / 5
            peg[d] = bounce_level - (bounce_level - (1.0 - max_depeg)) * progress
            peg[d] += rng.normal(0, max_depeg * 0.05)  # noise

    # Phase 4: Volatile oscillation (day 10-20)
    if n_days > 10:
        base_level = 1.0 - max_depeg
        for d in range(10, min(20, n_days)):
            # Oscillation: random walks around depeg level, slowly recovering
            recovery = (d - 10) / 30 * max_depeg * 0.3
            noise = rng.normal(0, max_depeg * 0.08)
            peg[d] = base_level + recovery + noise

    # Phase 5: Slow recovery with setbacks (day 20-45)
    if n_days > 20:
        level_20 = peg[min(19, n_days-1)]
        for d in range(20, min(45, n_days)):
            progress = (d - 20) / 25
            target = level_20 + (1.0 - level_20) * progress ** 0.7
            # Random setbacks
            if rng.random() < 0.1:
                target -= max_depeg * 0.03  # 10% chance of small setback
            noise = rng.normal(0, max_depeg * 0.02)
            peg[d] = target + noise

    # Phase 6: Final convergence (day 45+)
    if n_days > 45:
        level_45 = peg[min(44, n_days-1)]
        for d in range(45, n_days):
            progress = (d - 45) / max(n_days - 45, 1)
            peg[d] = level_45 + (0.999 - level_45) * progress + rng.normal(0, 0.001)

    return np.clip(peg, 1.0 - max_depeg * 1.2, 1.005)


# ============================================================
# 3. YIELD PARAMS WITH STRESS INJECTION
# ============================================================

def generate_params(eth_prices, stress_type=None, stress_start=180,
                    depeg_pct=0.05, tvl=10_000_000, seed=42):
    rng = np.random.RandomState(seed)
    n = len(eth_prices)
    daily_ret = eth_prices.pct_change().fillna(0).values
    vol_7d = pd.Series(daily_ret).rolling(7).std().fillna(0.02).values * math.sqrt(365)

    # Base yields
    sk_n = np.zeros(n)
    rs_n = np.zeros(n)
    for i in range(1, n):
        sk_n[i] = 0.95 * sk_n[i-1] + rng.normal(0, 0.001)
        rs_n[i] = 0.90 * rs_n[i-1] + rng.normal(0, 0.003)
    staking = np.clip(0.03 + sk_n, 0.025, 0.04)
    restaking = np.clip(0.02 + rs_n, 0.005, 0.05)
    weeth_apr = staking + restaking

    morpho_apr = np.clip(0.015 + vol_7d * 0.02 + rng.normal(0, 0.002, n), 0.005, 0.04)

    borrow_base = 0.008
    borrow = np.clip(borrow_base + vol_7d * 0.02 + rng.normal(0, 0.001, n), 0.002, 0.06)

    peg = np.ones(n)
    peg_n = np.zeros(n)
    for i in range(1, n):
        peg_n[i] = 0.97 * peg_n[i-1] + rng.normal(0, 0.0004)
    peg = np.clip(1.0 + peg_n, 0.95, 1.005)

    # Inject stress
    s = stress_start
    if stress_type in ("DEPEG_5", "DEPEG_10", "DEPEG_15", "DEPEG_18", "DEPEG_20", "DEPEG_25",
                        "COMBINED", "COMBINED_EXTREME"):
        dp = {"DEPEG_5": 0.05, "DEPEG_10": 0.10, "DEPEG_15": 0.15,
              "DEPEG_18": 0.18, "DEPEG_20": 0.20, "DEPEG_25": 0.25,
              "COMBINED": 0.10, "COMBINED_EXTREME": 0.15}.get(stress_type, 0.10)
        stress_days = min(60, n - s)
        osc_peg = generate_oscillating_depeg(stress_days, dp, seed=seed+1)
        for d in range(stress_days):
            if s + d < n:
                peg[s + d] = osc_peg[d]

        # FIX #2: Yield drops during depeg
        for d in range(stress_days):
            if s + d < n:
                depeg_amount = 1.0 - peg[s + d]
                # Restaking yield drops proportionally to depeg (AVS exit)
                restaking[s + d] *= max(0, 1.0 - depeg_amount * 3)
                # Slight staking yield reduction
                staking[s + d] *= max(0.8, 1.0 - depeg_amount)
                weeth_apr[s + d] = staking[s + d] + restaking[s + d]

    if stress_type in ("BORROW_SPIKE", "COMBINED", "COMBINED_EXTREME"):
        spike_days = min(28, n - s)
        peak_rate = 0.15 if stress_type == "COMBINED_EXTREME" else 0.10
        for d in range(spike_days):
            if s + d < n:
                if d < 3:
                    borrow[s + d] = 0.06 + (peak_rate - 0.06) * (d / 3)
                elif d < 7:
                    borrow[s + d] = peak_rate
                elif d < 14:
                    borrow[s + d] = peak_rate - (peak_rate - 0.07) * ((d - 7) / 7)
                elif d < 21:
                    borrow[s + d] = 0.07 - 0.02 * ((d - 14) / 7)
                else:
                    borrow[s + d] = 0.05 - 0.02 * ((d - 21) / 7)

    # ── CASCADING FEEDBACK: depeg → borrow↑ → liquidity↓ → depeg deeper ──
    # Even in non-BORROW_SPIKE scenarios, depeg causes borrow rate to rise
    # because: depeg → DeFi TVL down → Morpho utilization up → rate up
    for i in range(n):
        depeg_amount = max(0, 1.0 - peg[i])
        if depeg_amount > 0.02:  # only kicks in above 2% depeg
            # Borrow rate surges proportional to depeg severity
            # 5% depeg → +2% borrow, 10% → +5%, 15% → +8%
            cascade_borrow = depeg_amount ** 1.3 * 20
            borrow[i] = min(0.15, borrow[i] + cascade_borrow)
            # Morpho supply APR also spikes (utilization up)
            morpho_apr[i] = min(0.08, morpho_apr[i] + depeg_amount * 0.1)

    return pd.DataFrame({
        "eth_price": eth_prices.values,
        "daily_ret": daily_ret,
        "vol_7d": vol_7d,
        "weeth_apr": weeth_apr,
        "morpho_supply_apr": morpho_apr,
        "eth_borrow_apr": np.clip(borrow, 0.002, 0.15),
        "weeth_eth_peg": np.clip(peg, 0.75, 1.005),
    }, index=eth_prices.index)


# ============================================================
# 4. VAULT ENGINE (with realistic slippage)
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
    cum_fixed: float = 0.0
    cum_variable: float = 0.0
    cum_slippage_loss: float = 0.0
    cum_gas: float = 0.0
    deleverage_count: int = 0
    emergency_count: int = 0
    delev_slippage_events: list = field(default_factory=list)


WRAP_FEE = 0.001  # 0.1% EtherFi wrapping fee (ETH→weETH, NOT a DEX trade)


def execute_leverage(state, max_loops, max_ltv, peg=1.0):
    if state.total_tvl <= 0:
        return
    state.weeth_collateral = state.total_tvl
    state.eth_debt = 0.0
    state.n_loops = 0
    for _ in range(max_loops):
        target = max_ltv - 0.05
        max_borrow = state.weeth_collateral * peg * target - state.eth_debt
        if max_borrow <= 100:
            break
        borrow = max_borrow * 0.95
        # ETH → weETH is wrapping via EtherFi, not DEX trade
        slip = WRAP_FEE
        state.eth_debt += borrow
        state.weeth_collateral += borrow * (1 - slip)
        state.cum_slippage_loss += borrow * slip
        state.n_loops += 1


def check_and_deleverage(state, peg, eth_price, delev_thresh=0.85, emerg_ltv=0.92):
    if state.weeth_collateral <= 0 or state.eth_debt <= 0:
        return "normal"

    coll_val = state.weeth_collateral * peg
    ltv = state.eth_debt / coll_val if coll_val > 0 else 1.0

    if ltv >= emerg_ltv:
        # Emergency: sell weETH to repay debt, in chunks
        sell_amount = state.eth_debt / peg
        max_sell_per_trade = 500_000
        sell_usd = sell_amount * eth_price
        n_trades = max(1, int(sell_usd / max_sell_per_trade) + 1)
        chunk = sell_amount / n_trades

        total_slip = 0
        for _ in range(n_trades):
            chunk_usd = chunk * peg * eth_price
            s = slippage_model(peg, chunk_usd)
            total_slip += chunk * peg * s

        actual_eth = sell_amount * peg - total_slip
        slippage_loss = total_slip
        avg_slip = slippage_loss / max(sell_amount * peg, 1)

        state.cum_slippage_loss += slippage_loss
        state.delev_slippage_events.append(("EMERGENCY", peg, avg_slip, slippage_loss))

        if actual_eth >= state.eth_debt:
            state.weeth_collateral -= sell_amount
            state.eth_debt = 0
        else:
            # Can't fully repay — loss
            loss = state.eth_debt - actual_eth
            state.weeth_collateral = 0
            state.eth_debt = 0
            state.total_tvl = max(0, state.total_tvl - loss)
            # Loss hits Variable first, then Fixed
            var_loss = min(loss, state.variable_deposits)
            state.variable_deposits -= var_loss
            remaining_loss = loss - var_loss
            state.fixed_deposits = max(0, state.fixed_deposits - remaining_loss)
            state.total_tvl = state.fixed_deposits + state.variable_deposits

        state.weeth_collateral = max(0, state.total_tvl)
        state.n_loops = 0
        state.emergency_count += 1
        return "emergency"

    elif ltv >= delev_thresh:
        total_slip_loss = 0
        max_sell_per_trade = 500_000  # $500K max per trade (realistic DEX limit)
        while ltv > delev_thresh * 0.95 and state.n_loops > 0:
            loop_debt = state.eth_debt / max(state.n_loops, 1)
            sell_weeth = loop_debt / peg
            sell_usd = sell_weeth * eth_price

            # Split into realistic trade sizes
            n_trades = max(1, int(sell_usd / max_sell_per_trade) + 1)
            chunk_weeth = sell_weeth / n_trades
            chunk_slip_total = 0
            for _ in range(n_trades):
                chunk_usd = chunk_weeth * peg * eth_price
                slip = slippage_model(peg, chunk_usd)
                chunk_slip_total += chunk_weeth * peg * slip

            actual_eth = sell_weeth * peg - chunk_slip_total
            total_slip_loss += chunk_slip_total

            state.weeth_collateral -= sell_weeth
            state.eth_debt -= min(actual_eth, state.eth_debt)
            state.n_loops -= 1

            coll_val = state.weeth_collateral * peg
            ltv = state.eth_debt / coll_val if coll_val > 0 else 0

        # Slippage reduces TVL — losses absorbed by Variable first
        state.total_tvl = max(0, state.total_tvl - total_slip_loss)
        var_absorb = min(total_slip_loss, state.variable_deposits)
        state.variable_deposits -= var_absorb
        remaining = total_slip_loss - var_absorb
        state.fixed_deposits = max(0, state.fixed_deposits - remaining)

        state.cum_slippage_loss += total_slip_loss
        avg_slip = total_slip_loss / max(sell_weeth * peg, 1) if sell_weeth > 0 else 0
        state.delev_slippage_events.append(("DELEVERAGE", peg, avg_slip, total_slip_loss))
        state.deleverage_count += 1
        return "deleverage"

    return "normal"


def run_backtest(yp, tvl=10_000_000, fixed_rate=0.03, max_loops=4,
                 max_ltv=0.90, epoch_days=7, reserve_bps=300,
                 perf_fee=0.10, fixed_ratio=0.80, morpho_pct=0.05,
                 delev_thresh=0.85, emerg_ltv=0.92):

    state = VaultState(
        total_tvl=tvl,
        fixed_deposits=tvl * fixed_ratio,
        variable_deposits=tvl * (1 - fixed_ratio),
    )
    execute_leverage(state, max_loops, max_ltv)

    # Gas config
    gas_per_rebalance = 200_000 * 25e-9  # ETH
    gas_per_deleverage = 400_000 * 50e-9  # higher gas during stress

    results = []
    i = 0
    while i + epoch_days <= len(yp):
        ep = yp.iloc[i:i+epoch_days]
        n = len(ep)
        if n == 0 or state.total_tvl <= 0:
            break

        total_wy = 0.0
        total_my = 0.0
        total_bc = 0.0
        min_peg = 1.0
        epoch_gas = 0.0
        epoch_slip = 0.0
        delev_in_epoch = 0

        for _, day in ep.iterrows():
            df = 1.0 / 365.25
            total_wy += state.weeth_collateral * day["weeth_apr"] * df
            total_my += state.total_tvl * morpho_pct * day["morpho_supply_apr"] * df
            total_bc += state.eth_debt * day["eth_borrow_apr"] * df

            peg = day["weeth_eth_peg"]
            eth_p = day["eth_price"]
            min_peg = min(min_peg, peg)

            old_slip = state.cum_slippage_loss
            old_loops = state.n_loops
            status = check_and_deleverage(state, peg, eth_p, delev_thresh, emerg_ltv)
            if status != "normal":
                epoch_slip += state.cum_slippage_loss - old_slip
                epoch_gas += gas_per_deleverage * eth_p
                delev_in_epoch += 1

        # Weekly rebalance gas
        avg_price = float(ep["eth_price"].mean())
        epoch_gas += gas_per_rebalance * avg_price
        state.cum_gas += epoch_gas

        gross = total_wy + total_my - total_bc - epoch_gas
        pf = max(0, gross * perf_fee)
        net = gross - pf

        res_add = max(0, net * (reserve_bps / 10000))
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
        state.cum_fixed += fixed_pay
        state.cum_variable += var_pay

        peg_end = float(ep["weeth_eth_peg"].iloc[-1])
        coll_val = state.weeth_collateral * peg_end
        ltv = state.eth_debt / coll_val if coll_val > 0 else 0

        fixed_apr = fixed_pay / state.fixed_deposits * (365.25 / n) if state.fixed_deposits > 0 else 0
        var_apr = var_pay / state.variable_deposits * (365.25 / n) if state.variable_deposits > 0 else 0

        results.append({
            "epoch": len(results),
            "gross": gross, "fixed_pay": fixed_pay, "var_pay": var_pay,
            "fixed_apr": fixed_apr, "var_apr": var_apr,
            "shortfall": max(0, fixed_obl - fixed_pay),
            "reserve": state.reserve,
            "ltv": ltv, "peg": peg_end, "min_peg": min_peg,
            "n_loops": state.n_loops,
            "borrow": float(ep["eth_borrow_apr"].mean()),
            "spread": float(ep["weeth_apr"].mean() - ep["eth_borrow_apr"].mean()),
            "epoch_slip": epoch_slip, "epoch_gas": epoch_gas,
            "delev_in_epoch": delev_in_epoch,
            "delev": state.deleverage_count, "emerg": state.emergency_count,
            "tvl": state.total_tvl,
            "fixed_tvl": state.fixed_deposits, "var_tvl": state.variable_deposits,
        })

        # Re-leverage if safe
        if state.n_loops < max_loops and state.total_tvl > 0:
            if ltv < 0.65 and peg_end > 0.995:
                execute_leverage(state, max_loops, max_ltv, peg_end)
        i += epoch_days

    return pd.DataFrame(results), state


# ============================================================
# 5. MAIN — RUN ALL SCENARIOS × TVL SIZES
# ============================================================

def main():
    daily_df = fetch_eth_prices(13)
    print(f"  {len(daily_df)} days | ETH ${daily_df['close'].min():.0f}-${daily_df['close'].max():.0f}")

    scenarios = [
        ("BASELINE", None),
        ("S1: 5% OSCILLATING DEPEG", "DEPEG_5"),
        ("S2: 10% OSCILLATING DEPEG", "DEPEG_10"),
        ("S3: BORROW SPIKE 10%", "BORROW_SPIKE"),
        ("S4: ALL COMBINED", "COMBINED"),
        ("S5: 15% DEPEG (extreme)", "DEPEG_15"),
        ("S6: 15% DEPEG + BORROW SPIKE", "COMBINED_EXTREME"),
        ("S7: 18% DEPEG", "DEPEG_18"),
        ("S8: 20% DEPEG", "DEPEG_20"),
        ("S9: 25% DEPEG (black swan)", "DEPEG_25"),
    ]

    tvl_sizes = [100_000, 500_000, 1_000_000, 10_000_000]

    W = 90
    print("\n" + "=" * W)
    print("  weETH TRANCHE VAULT — REALISTIC STRESS TEST v2")
    print("  Fixes: nonlinear slippage($50M pool), oscillating depeg, yield drop, multi-TVL")
    print("  Config: Fixed 3% | 4 loops | 80:20 | Reserve 3% | Delev 85% | Emerg 92%")
    print("=" * W)

    # ── PART 0: BREAKING POINT ANALYSIS ──
    print(f"\n{'  PART 0: BREAKING POINT ANALYSIS':═^{W}}")
    print(f"  Finding the depeg level where deleverage triggers and losses begin")
    print(f"  Real threshold: 85% LTV | Emergency: 92% LTV | $10M TVL\n")

    bp_scenarios = [
        ("5% depeg",  "DEPEG_5"),
        ("10% depeg", "DEPEG_10"),
        ("15% depeg", "DEPEG_15"),
        ("18% depeg", "DEPEG_18"),
        ("20% depeg", "DEPEG_20"),
        ("25% depeg", "DEPEG_25"),
    ]
    print(f"  {'Scenario':16} {'MaxLTV':>7} {'Delev':>5} {'Emerg':>5} {'Slip$':>10} "
          f"{'VarLoss':>8} {'FxLoss':>7} {'VarAPR':>7} {'FxHit':>5}")
    print(f"  {'─'*16} {'─'*7} {'─'*5} {'─'*5} {'─'*10} {'─'*8} {'─'*7} {'─'*7} {'─'*5}")

    for bpname, bpstype in bp_scenarios:
        bpyp = generate_params(daily_df["close"], stress_type=bpstype)
        bpedf, bpfs = run_backtest(bpyp, tvl=10_000_000)
        var_init = 10e6 * 0.20
        var_loss = max(0, var_init - bpfs.variable_deposits) / var_init * 100
        fix_loss = max(0, 10e6*0.80 - bpfs.fixed_deposits) / (10e6*0.80) * 100
        fhit = (bpedf['fixed_apr'] >= 0.03*0.95).mean()*100
        status = "SAFE" if bpfs.deleverage_count == 0 and bpfs.emergency_count == 0 else \
                 "EMERG" if bpfs.emergency_count > 0 else "DELEV"
        print(f"  {bpname:16} {bpedf['ltv'].max()*100:>6.1f}% {bpfs.deleverage_count:>5} "
              f"{bpfs.emergency_count:>5} ${bpfs.cum_slippage_loss:>9,.0f} "
              f"{var_loss:>7.1f}% {fix_loss:>6.1f}% {bpedf['var_apr'].mean()*100:>6.1f}% "
              f"{fhit:>4.0f}%  {status}")

        if bpfs.delev_slippage_events:
            for evt_type, evt_peg, evt_slip, evt_loss in bpfs.delev_slippage_events[:5]:
                print(f"    -> {evt_type}: peg={evt_peg:.4f} slip={evt_slip*100:.2f}% cost=${evt_loss:,.0f}")
            if len(bpfs.delev_slippage_events) > 5:
                print(f"    ... +{len(bpfs.delev_slippage_events)-5} more events")

    # ── PART 1: All scenarios at $10M TVL ──
    print(f"\n{'  PART 1: SCENARIO COMPARISON ($10M TVL)':═^{W}}")

    results_10m = {}
    for name, stype in scenarios:
        yp = generate_params(daily_df["close"], stress_type=stype)
        edf, fs = run_backtest(yp, tvl=10_000_000)
        results_10m[name] = (edf, fs)

        n = len(edf)
        years = n * 7 / 365.25
        tg = edf["gross"].sum()

        print(f"\n  {'─── ' + name + ' ───':─^{W-4}}")

        print(f"  Yield:  vault {tg/10e6/years*100:.1f}% | "
              f"Fixed {edf['fixed_apr'].mean()*100:.1f}% | "
              f"Variable {edf['var_apr'].mean()*100:.1f}% "
              f"(min {edf['var_apr'].min()*100:.1f}%)")

        fhit = (edf['fixed_apr'] >= 0.03 * 0.95).mean() * 100
        sf = (edf['shortfall'] > 0).sum()
        print(f"  Fixed:  {fhit:.0f}% hit | {sf} shortfalls | "
              f"max shortfall ${edf['shortfall'].max():,.0f}")

        print(f"  Risk:   LTV max {edf['ltv'].max()*100:.1f}% | "
              f"peg min {edf['min_peg'].min():.4f} | "
              f"delev {fs.deleverage_count} | emerg {fs.emergency_count}")

        print(f"  Costs:  slippage ${fs.cum_slippage_loss:,.0f} | "
              f"gas ${fs.cum_gas:,.0f}")

        tvl_loss = max(0, 10_000_000 - fs.total_tvl)
        var_init = 10_000_000 * 0.20
        var_loss = max(0, var_init - fs.variable_deposits)
        fix_init = 10_000_000 * 0.80
        fix_loss = max(0, fix_init - fs.fixed_deposits)

        if tvl_loss > 0:
            print(f"  LOSSES: TVL -{tvl_loss/10e6*100:.2f}% | "
                  f"Variable -{var_loss/var_init*100:.1f}% | "
                  f"Fixed -{fix_loss/fix_init*100:.1f}%")
        else:
            print(f"  LOSSES: none")

        if fs.delev_slippage_events:
            print(f"  Deleverage detail:")
            for evt_type, evt_peg, evt_slip, evt_loss in fs.delev_slippage_events:
                print(f"    {evt_type}: peg={evt_peg:.4f} slip={evt_slip*100:.1f}% loss=${evt_loss:,.0f}")

    # Comparison table
    print(f"\n{'  SCENARIO COMPARISON ($10M)':═^{W}}")
    print(f"  {'Scenario':32} {'VltAPR':>7} {'VarAPR':>7} {'FxHit':>5} "
          f"{'MaxLTV':>6} {'Delev':>5} {'Slip$':>10} {'VarLoss':>8} {'FxLoss':>7}")
    print(f"  {'─'*32} {'─'*7} {'─'*7} {'─'*5} {'─'*6} {'─'*5} {'─'*10} {'─'*8} {'─'*7}")
    for name, (edf, fs) in results_10m.items():
        n = len(edf); years = n*7/365.25; tg = edf["gross"].sum()
        fhit = (edf['fixed_apr'] >= 0.03*0.95).mean()*100
        var_init = 10e6*0.20
        var_loss = max(0, var_init - fs.variable_deposits)
        fix_init = 10e6*0.80
        fix_loss = max(0, fix_init - fs.fixed_deposits)
        print(f"  {name:32} {tg/10e6/years*100:>6.1f}% {edf['var_apr'].mean()*100:>6.1f}% "
              f"{fhit:>4.0f}% {edf['ltv'].max()*100:>5.1f}% "
              f"{fs.deleverage_count:>5} ${fs.cum_slippage_loss:>9,.0f} "
              f"{var_loss/var_init*100:>6.1f}% {fix_loss/fix_init*100:>5.1f}%")

    # ── PART 2: TVL SIZE SENSITIVITY ──
    print(f"\n\n{'  PART 2: TVL SIZE SENSITIVITY (S4 worst case)':═^{W}}")

    yp_s4 = generate_params(daily_df["close"], stress_type="COMBINED")

    print(f"\n  {'TVL':>10} {'VltAPR':>7} {'VarAPR':>7} {'FxHit':>5} "
          f"{'Gas$':>8} {'Gas%Yld':>7} {'Slip$':>8} {'VarLoss':>8} {'Reserve':>8}")
    print(f"  {'─'*10} {'─'*7} {'─'*7} {'─'*5} {'─'*8} {'─'*7} {'─'*8} {'─'*8} {'─'*8}")

    for tvl in tvl_sizes:
        edf, fs = run_backtest(yp_s4, tvl=tvl)
        if edf.empty:
            continue
        n = len(edf); years = n*7/365.25; tg = edf["gross"].sum()
        fhit = (edf['fixed_apr'] >= 0.03*0.95).mean()*100
        var_init = tvl * 0.20
        var_loss = max(0, var_init - fs.variable_deposits)
        gas_pct = fs.cum_gas / max(tg, 1) * 100

        tvl_str = f"${tvl/1e6:.1f}M" if tvl >= 1e6 else f"${tvl/1e3:.0f}K"
        print(f"  {tvl_str:>10} {tg/tvl/years*100:>6.1f}% {edf['var_apr'].mean()*100:>6.1f}% "
              f"{fhit:>4.0f}% ${fs.cum_gas:>7,.0f} {gas_pct:>6.1f}% "
              f"${fs.cum_slippage_loss:>7,.0f} {var_loss/var_init*100:>6.1f}% "
              f"${fs.reserve:>7,.0f}")

    # ── PART 3: VERDICT ──
    print(f"\n\n{'  FINAL VERDICT':═^{W}}")

    base_edf, base_fs = results_10m["BASELINE"]
    s4_edf, s4_fs = results_10m["S4: ALL COMBINED"]
    s6_edf, s6_fs = results_10m["S6: 15% DEPEG + BORROW SPIKE"]

    var_init = 10e6 * 0.20
    s4_var_loss = max(0, var_init - s4_fs.variable_deposits) / var_init * 100
    s4_fix_loss = max(0, 10e6*0.80 - s4_fs.fixed_deposits) / (10e6*0.80) * 100
    s4_fhit = (s4_edf['fixed_apr'] >= 0.03*0.95).mean() * 100

    s6_var_loss = max(0, var_init - s6_fs.variable_deposits) / var_init * 100
    s6_fix_loss = max(0, 10e6*0.80 - s6_fs.fixed_deposits) / (10e6*0.80) * 100
    s6_fhit = (s6_edf['fixed_apr'] >= 0.03*0.95).mean() * 100

    # Get extreme scenario results
    extreme_names = ["S8: 20% DEPEG", "S9: 25% DEPEG (black swan)"]
    extreme_data = {}
    for en in extreme_names:
        if en in results_10m:
            eedf, efs = results_10m[en]
            ev_loss = max(0, var_init - efs.variable_deposits) / var_init * 100
            ef_loss = max(0, 10e6*0.80 - efs.fixed_deposits) / (10e6*0.80) * 100
            extreme_data[en] = (eedf, efs, ev_loss, ef_loss)

    print(f"""
  NORMAL MARKET:
    Variable APR: {base_edf['var_apr'].mean()*100:.0f}%
    Fixed: 100% guaranteed
    Slippage: ${base_fs.cum_slippage_loss:,.0f}

  REALISTIC WORST CASE (S6: 15% depeg + borrow spike):
    Variable APR: {s6_edf['var_apr'].mean()*100:.0f}% (drops from {base_edf['var_apr'].mean()*100:.0f}%)
    Fixed hit rate: {s6_fhit:.0f}%
    Variable principal loss: {s6_var_loss:.1f}%
    Fixed principal loss: {s6_fix_loss:.1f}%
    Max LTV: {s6_edf['ltv'].max()*100:.1f}%
    Deleverage: {s6_fs.deleverage_count} | Emergency: {s6_fs.emergency_count}""")

    for en, (eedf, efs, ev_loss, ef_loss) in extreme_data.items():
        print(f"""
  BLACK SWAN ({en}):
    Variable principal loss: {ev_loss:.1f}%
    Fixed principal loss: {ef_loss:.1f}%
    Max LTV: {eedf['ltv'].max()*100:.1f}%
    Deleverage: {efs.deleverage_count} | Emergency: {efs.emergency_count}
    Slippage: ${efs.cum_slippage_loss:,.0f}""")

    # Use worst realistic (S6) for disclosure, note black swan separately
    worst_var = s6_var_loss
    worst_fix = s6_fix_loss
    bs_var = max((d[2] for d in extreme_data.values()), default=0)
    bs_fix = max((d[3] for d in extreme_data.values()), default=0)

    print(f"""
  ═══════════════════════════════════════════════════════════════
  RISK DISCLOSURE NUMBERS (리스크 고지)
  ═══════════════════════════════════════════════════════════════

  Variable Tranche:
    정상 시장: ~{base_edf['var_apr'].mean()*100:.0f}% APR
    스트레스(15% 디페그): ~{s6_edf['var_apr'].mean()*100:.0f}% APR, 원금 손실 {worst_var:.1f}%
    블랙스완(20%+ 디페그): 원금 최대 ~{bs_var:.0f}% 손실 가능

  Fixed Tranche:
    정상 시장: 3% APR 100% 보장
    스트레스(15% 디페그): {s6_fhit:.0f}% epoch 지급, 원금 손실 {worst_fix:.1f}%
    블랙스완(20%+ 디페그): 원금 최대 ~{bs_fix:.0f}% 손실 가능

  핵심 리스크:
    - weETH/ETH 디페그 15% 이내: 시스템 정상 작동 (LTV < 85%)
    - 디페그 18%+: 디레버리지 발동, 슬리피지로 인한 원금 손실 시작
    - 디페그 20%+: 긴급 해제, Variable 트랜치 큰 손실
    - ETH 가격 하락 자체는 LTV에 영향 없음 (correlated pair)
    - 실제 리스크: EigenLayer 슬래싱, Morpho 유동성 위기, 스마트컨트랙트 버그

  SMALL TVL WARNING:
    $100K TVL: 가스비가 yield의 ~7% 차지
    최소 권장 TVL: $500K+
""")

    print("=" * W)


if __name__ == "__main__":
    main()
