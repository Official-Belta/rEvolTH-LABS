# rEvolETH Vault

> ETH to automated leveraged weETH looping. Target APR 8-10%.

## How It Works

```
User deposits ETH
    |
    v
LoopVault (ERC-4626)
    |-- idle buffer (5%) for instant withdrawals
    |-- keeper batches idle into strategy
    |
    v
LoopStrategy
    |-- ETH -> eETH -> weETH (EtherFi)
    |-- weETH collateral -> Morpho Blue
    |-- Borrow ETH -> wrap -> collateral -> repeat (x4)
    |-- 3.47x leverage, LTV 81%
    |
    v
Yield: weETH 5% x 3.47 - borrow ~2% x 2.47 = ~9% net APR
```

**Why it works:** Collateral (weETH) and debt (ETH) are both ETH-denominated. ETH price drops don't affect LTV. Only weETH/ETH depeg matters — historically max 7% (stETH 2022).

## Architecture

```
LoopVault.sol          ERC-4626 + UUPS proxy + Pausable + idle buffer + epoch withdrawals
LoopStrategy.sol       Morpho flashloan (0-fee) looping engine + Chainlink oracle
KeeperModule.sol       Auto-rebalance + deloop + epoch advance + tip mechanism
MathLib.sol            Pure math: LTV, leverage, unwind calculations
```

## Fork Test Results (Ethereum Mainnet)

| Metric | Value |
|--------|-------|
| Chainlink weETH/ETH peg | 1.0908 |
| Leverage | 3.47x |
| LTV | 81% |
| DEX slippage (Uni V3 0.01%) | 0 bps |
| Morpho market supply | 41,329 ETH |
| Morpho market borrow | 34,179 ETH |
| Gas: deposit | 210K |
| Gas: leverage up | 1.6M |
| Gas: deleverage | 295K |

## Backtest Results (Dune On-Chain Data, 92 days)

| Borrow Rate | Probability | Vault APR |
|-------------|-------------|-----------|
| 1-2% | 24% | 11.1% |
| 2-3% | 57% | 9.9% |
| 3-4% | 13% | 7.6% |
| 4-5% | 7% | 5.4% |

**Median APR: 10.0% | Mean: 9.6% | Range: 4.6-11.4%**

## Audit Status

```
Round 1:  20 findings -> all fixed (3 Critical, 5 High, 7 Medium, 5 Low)
Round 2:   5 findings -> all fixed (2 Medium, 3 Low)
Wave 1:    5 tools parallel (scv-scan, semgrep, entry-points, maturity, sharp-edges)
           6 findings -> all fixed
Final:     0 Critical, 0 High, 0 Medium remaining
```

**Tools used:** Semgrep, SCV-Scan (36 vuln classes), Trail of Bits code maturity framework, entry point analysis, sharp edges analysis.

## Tests

```bash
# Unit + integration tests (no RPC needed)
forge test

# Fork tests (requires Ethereum mainnet RPC)
forge test --match-path test/fork/* --fork-url $ETH_RPC_URL

# Results: 102 tests (86 unit + 16 fork), 0 failures
```

## Deploy

```bash
# 1. Set environment
cp .env.example .env
# Edit .env: set PRIVATE_KEY and ETH_RPC_URL

# 2. Deploy to mainnet
forge script script/Deploy.s.sol --broadcast --rpc-url $ETH_RPC_URL

# 3. Verify contracts
forge verify-contract <address> src/LoopVault.sol:LoopVault --chain mainnet
```

## Risk Disclosure

```
Normal market:      ~9% APR
10% depeg:          ~8% APR, no principal loss
15% depeg:          ~8% APR, no principal loss (dynamic deloop)
20%+ depeg:         Principal loss possible (historical max: stETH 7%)

ETH price drops do NOT affect principal (correlated pair).

Risks NOT covered by backtest:
- EigenLayer slashing
- Morpho/EtherFi smart contract bugs
- Regulatory changes
```

## Key Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Max Loops | 4 | 3.47x leverage |
| Target LTV | 85% | 9.5% margin to Morpho LLTV (94.5%) |
| Deleverage | 85% LTV | Keeper triggers deloop |
| Emergency | 92% LTV | Full unwind |
| Epoch | 7 days | Withdrawal delay |
| Withdraw Cap | 20%/epoch | Bank run protection |
| Slippage | 1% default | Configurable, max 5% |
| Perf Fee | 10% | Protocol revenue |
| Min Deposit | 0.3 ETH | Gas efficiency |

## License

BUSL-1.1 (Business Source License). See [LICENSE](./LICENSE).
