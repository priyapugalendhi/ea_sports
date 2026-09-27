-- =====================================================================
-- 1(c)  SPENDER BEHAVIOUR
-- =====================================================================

-- Total gross spend per real player (linked devices merged)
CREATE OR REPLACE TABLE player_spend AS
SELECT m.player_id,
       COALESCE(SUM(pc.usd_amount) FILTER (WHERE pc.usd_amount > 0), 0) AS revenue
FROM player_map m
LEFT JOIN purchase_clean pc ON pc.device_id = m.device_id
GROUP BY m.player_id;

.print '=== 1. REVENUE CONCENTRATION ==='
WITH payers AS (
    SELECT revenue, ROW_NUMBER() OVER (ORDER BY revenue DESC) AS rnk, COUNT(*) OVER () AS n
    FROM player_spend WHERE revenue > 0
),
everyone AS (
    SELECT revenue, ROW_NUMBER() OVER (ORDER BY revenue DESC) AS rnk, COUNT(*) OVER () AS n
    FROM player_spend
),
both_pops AS (
    SELECT 'payers only' AS ranked_among, * FROM payers
    UNION ALL
    SELECT 'all players', * FROM everyone
)
SELECT ranked_among,
       MAX(n) AS population,
       ROUND(100 * SUM(revenue) FILTER (WHERE rnk <= CEIL(n * 0.01)) / SUM(revenue), 1) AS top_1pct_share,
       ROUND(100 * SUM(revenue) FILTER (WHERE rnk <= CEIL(n * 0.10)) / SUM(revenue), 1) AS top_10pct_share,
       ROUND(100 * SUM(revenue) FILTER (WHERE rnk <= CEIL(n * 0.50)) / SUM(revenue), 1) AS top_50pct_share
FROM both_pops
GROUP BY ranked_among
ORDER BY ranked_among DESC;

-- New players only (installed in window, linked devices excluded), so we can see their
-- whole path to first purchase. One row per device.
CREATE OR REPLACE TABLE new_players AS
SELECT p.device_id, p.install_date,
       MIN(CAST(pc.event_ts AS DATE)) AS first_buy
FROM player_profile p
LEFT JOIN purchase_clean pc ON pc.device_id = p.device_id AND pc.usd_amount > 0
WHERE p.install_date >= DATE '2026-01-01'
  AND p.original_device_id IS NULL
GROUP BY p.device_id, p.install_date;

.print '=== 2. TIME TO FIRST PURCHASE (distribution) ==='
-- GREATEST(..., 0): 104 of these new players have their first purchase logged 1-4 days
-- before their install date (110 in the whole file); treated as day 0.
WITH d AS (
    SELECT GREATEST(first_buy - install_date, 0) AS days
    FROM new_players WHERE first_buy IS NOT NULL
)
SELECT CASE WHEN days = 0   THEN 'a) same day'
            WHEN days = 1   THEN 'b) day 1'
            WHEN days <= 3  THEN 'c) day 2-3'
            WHEN days <= 7  THEN 'd) day 4-7'
            WHEN days <= 14 THEN 'e) day 8-14'
            WHEN days <= 30 THEN 'f) day 15-30'
            ELSE                 'g) day 31+' END AS bucket,
       COUNT(*) AS payers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY bucket) / SUM(COUNT(*)) OVER (), 1) AS cumulative_pct
FROM d GROUP BY bucket ORDER BY bucket;

SELECT QUANTILE_CONT(GREATEST(first_buy - install_date, 0), 0.25) AS p25_days,
       MEDIAN(GREATEST(first_buy - install_date, 0))                AS median_days,
       QUANTILE_CONT(GREATEST(first_buy - install_date, 0), 0.75) AS p75_days
FROM new_players WHERE first_buy IS NOT NULL;

.print '--- Share who never paid ---'
SELECT 'all new players' AS grp, COUNT(*) AS players,
       ROUND(100.0 * AVG(CASE WHEN first_buy IS NULL THEN 1 ELSE 0 END), 1) AS never_paid_pct
FROM new_players
UNION ALL
SELECT 'installed by Mar 31 (30+ days to pay)', COUNT(*),
       ROUND(100.0 * AVG(CASE WHEN first_buy IS NULL THEN 1 ELSE 0 END), 1)
FROM new_players WHERE install_date <= DATE '2026-03-31';

.print '=== 3. REPEAT PURCHASE GAP (window function LAG) ==='
CREATE OR REPLACE TABLE purchase_gaps AS
SELECT m.player_id, pc.event_ts,
       date_diff('hour',
                 LAG(pc.event_ts) OVER (PARTITION BY m.player_id ORDER BY pc.event_ts),
                 pc.event_ts) / 24.0 AS gap_days
FROM purchase_clean pc
JOIN player_map m ON m.device_id = pc.device_id
WHERE pc.usd_amount > 0
QUALIFY gap_days IS NOT NULL;

SELECT COUNT(DISTINCT player_id)               AS repeat_buyers,
       COUNT(*)                                AS gaps,
       ROUND(QUANTILE_CONT(gap_days, 0.25), 1) AS p25_days,
       ROUND(MEDIAN(gap_days), 1)              AS median_days,
       ROUND(QUANTILE_CONT(gap_days, 0.75), 1) AS p75_days,
       ROUND(AVG(gap_days), 1)                 AS mean_days
FROM purchase_gaps;

SELECT CASE WHEN gap_days < 1  THEN 'a) under 1 day'
            WHEN gap_days < 7  THEN 'b) 1-7 days'
            WHEN gap_days < 14 THEN 'c) 7-14 days'
            WHEN gap_days < 30 THEN 'd) 14-30 days'
            ELSE                    'e) 30+ days' END AS bucket,
       COUNT(*) AS gaps,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM purchase_gaps GROUP BY bucket ORDER BY bucket;
