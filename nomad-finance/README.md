# Nomad Finance

**Automated options strategy protocol on Hyperliquid — DeFi's QYLD.**

Deposit USDC → earn ~35% APR from automated option selling + delta hedging. No manual management required.

## How It Works

1. User deposits USDC into a vault (ERC-4626)
2. Vault auto-sells options via Rysk Finance RFQ (collects premium)
3. Delta is hedged in real-time using HyperCore perps
4. Positions auto-roll at expiry
5. Portfolio-level risk management (Greeks monitoring, auto-deleverage)

## Architecture

```
User → USDC Deposit → Vault (ERC-4626) → Strategy Module
    → Rysk RFQ (option selling) + HyperCore CoreWriter (delta hedge)
    → Risk Manager → Auto-Roll
```

### Core Components

| Component | Description |
|-----------|-------------|
| **Vault Manager** | ERC-4626 vault — deposit, withdraw, share accounting, fees |
| **Pricing Engine** | BSM pricing, EWMA vol, Greeks, strike selection (offchain → onchain verification) |
| **Strategy Module** | Independent modules per strategy (IStrategy interface) |
| **Delta Hedge Module** | HyperCore precompile reads + CoreWriter perp orders |
| **Risk Manager** | Portfolio Greeks, max loss limits, auto-deleverage |

## Strategies

### Yield (Vol Selling) — 90%+ of vault TVL
- **Covered Call (CC)** — ~35% APR, 78% win rate
- **Cash-Secured Put (CSP)** — ~30% APR, 72% win rate
- **Iron Condor (IC)** — ~28% APR, ~60% win rate

### Directional / Volatility
- Protective Put, Bull Call Spread, Long Straddle

## Products

- **Nomad Auto** — Single vault, pick a risk tier (Conservative / Moderate / Aggressive), auto-allocates across strategies
- **Nomad Select** — Individual strategy vaults for power users

## Tech Stack

- **Chain:** Hyperliquid (HyperEVM + HyperCore)
- **Options:** Rysk Finance RFQ
- **Hedging:** HyperCore perps via CoreWriter
- **Contracts:** Solidity 0.8.26, Foundry
- **Standard:** ERC-4626

## Roadmap

| Phase | Timeline | Milestones |
|-------|----------|------------|
| 0 | Q2 2026 | CoreWriter + Rysk integration tests, Pricing engine, Vault v0.1, Testnet |
| 1 | Q3 2026 | CC + CSP vault mainnet, delta hedge, auto-roll, TVL cap $1M |
| 2 | Q4 2026 | +4 strategies, Nomad Auto, portfolio risk, TVL cap $10M |
| 3 | 2027 | HIP-4 integration, Rysk independence, 15+ strategies |

## Development

```bash
# Build
forge build

# Test
forge test

# Test with fork
forge test --fork-url $HYPEREVM_RPC_URL
```

## Docs

- [Handover Document](docs/HANDOVER.md) — Full project context & specs
