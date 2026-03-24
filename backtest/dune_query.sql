-- ═══════════════════════════════════════════════════════════════
-- Morpho Blue weETH/WETH (94.5% LLTV) — Historical Borrow Rate
-- Market ID: 0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7
-- Chain: Ethereum Mainnet
--
-- Paste into dune.com and run.
-- Export CSV → feed into apr_distribution.py for vault APR histogram.
-- ═══════════════════════════════════════════════════════════════

WITH market_id AS (
    SELECT 0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7 AS id
),

-- Borrow rate from AccrueInterest events
-- prevBorrowRate = per-second, WAD-scaled (1e18)
-- APR = prevBorrowRate * 365.25 * 86400 / 1e18 * 100
accrue_events AS (
    SELECT
        evt_block_time,
        evt_block_number,
        evt_tx_hash,
        prevBorrowRate,
        interest
    FROM morpho_blue_ethereum.morphoblue_evt_AccrueInterest
    WHERE id = (SELECT id FROM market_id)
      AND evt_block_time >= NOW() - INTERVAL '12' MONTH
),

-- Track asset flows to reconstruct supply/borrow totals
supply_flows AS (
    SELECT evt_block_time, evt_block_number, evt_tx_hash,
           CAST(assets AS DOUBLE) AS supply_delta, 0.0 AS borrow_delta
    FROM morpho_blue_ethereum.morphoblue_evt_Supply
    WHERE id = (SELECT id FROM market_id)
),
withdraw_flows AS (
    SELECT evt_block_time, evt_block_number, evt_tx_hash,
           -CAST(assets AS DOUBLE) AS supply_delta, 0.0 AS borrow_delta
    FROM morpho_blue_ethereum.morphoblue_evt_Withdraw
    WHERE id = (SELECT id FROM market_id)
),
borrow_flows AS (
    SELECT evt_block_time, evt_block_number, evt_tx_hash,
           0.0 AS supply_delta, CAST(assets AS DOUBLE) AS borrow_delta
    FROM morpho_blue_ethereum.morphoblue_evt_Borrow
    WHERE id = (SELECT id FROM market_id)
),
repay_flows AS (
    SELECT evt_block_time, evt_block_number, evt_tx_hash,
           0.0 AS supply_delta, -CAST(assets AS DOUBLE) AS borrow_delta
    FROM morpho_blue_ethereum.morphoblue_evt_Repay
    WHERE id = (SELECT id FROM market_id)
),
liquidate_flows AS (
    SELECT evt_block_time, evt_block_number, evt_tx_hash,
           0.0 AS supply_delta, -CAST(repaidAssets AS DOUBLE) AS borrow_delta
    FROM morpho_blue_ethereum.morphoblue_evt_Liquidate
    WHERE id = (SELECT id FROM market_id)
),
interest_flows AS (
    SELECT evt_block_time, evt_block_number, evt_tx_hash,
           CAST(interest AS DOUBLE) AS supply_delta,
           CAST(interest AS DOUBLE) AS borrow_delta
    FROM accrue_events
),

all_flows AS (
    SELECT * FROM supply_flows UNION ALL
    SELECT * FROM withdraw_flows UNION ALL
    SELECT * FROM borrow_flows UNION ALL
    SELECT * FROM repay_flows UNION ALL
    SELECT * FROM liquidate_flows UNION ALL
    SELECT * FROM interest_flows
),

cumulative AS (
    SELECT evt_block_time, evt_block_number,
        SUM(supply_delta) OVER (ORDER BY evt_block_number, evt_tx_hash) AS total_supply,
        SUM(borrow_delta) OVER (ORDER BY evt_block_number, evt_tx_hash) AS total_borrow
    FROM all_flows
),

daily_state AS (
    SELECT DISTINCT
        DATE_TRUNC('day', evt_block_time) AS day,
        LAST_VALUE(total_supply) OVER (
            PARTITION BY DATE_TRUNC('day', evt_block_time)
            ORDER BY evt_block_number ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS total_supply,
        LAST_VALUE(total_borrow) OVER (
            PARTITION BY DATE_TRUNC('day', evt_block_time)
            ORDER BY evt_block_number ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS total_borrow
    FROM cumulative
),

daily_rates AS (
    SELECT
        DATE_TRUNC('day', evt_block_time) AS day,
        AVG(CAST(prevBorrowRate AS DOUBLE)) * 31557600.0 / 1e18 * 100.0 AS borrow_apr_pct,
        COUNT(*) AS n_accruals
    FROM accrue_events
    GROUP BY 1
)

SELECT
    r.day AS date,
    r.borrow_apr_pct AS borrow_apr_percent,
    CASE WHEN s.total_supply > 0
         THEN s.total_borrow / s.total_supply * 100.0 ELSE 0
    END AS utilization_pct,
    s.total_supply / 1e18 AS total_supply_eth,
    s.total_borrow / 1e18 AS total_borrow_eth,
    r.n_accruals
FROM daily_rates r
LEFT JOIN daily_state s ON r.day = s.day
ORDER BY r.day DESC
