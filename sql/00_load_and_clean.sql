-- =====================================================================
-- 00  LOAD THE 5 CSV FILES AND BUILD CLEAN TABLES
-- Run from the folder that contains the CSVs:
--   duckdb ea_sql.duckdb < sql/00_load_and_clean.sql
-- =====================================================================

-- ---------- Load raw data ----------
CREATE OR REPLACE TABLE player_profile AS SELECT * FROM read_csv_auto('player_profile.csv');
CREATE OR REPLACE TABLE player_day     AS SELECT * FROM read_csv_auto('player_day.csv');
CREATE OR REPLACE TABLE purchase       AS SELECT * FROM read_csv_auto('purchase.csv');
CREATE OR REPLACE TABLE currency_spend AS SELECT * FROM read_csv_auto('currency_spend.csv');
CREATE OR REPLACE TABLE ad_view        AS SELECT * FROM read_csv_auto('ad_view.csv');

-- ---------- Clean 1: purchases ----------
-- 122 purchase_ids appear twice (same player, same pack, logged minutes/hours apart).
-- Keep only the earliest row for each purchase_id.
CREATE OR REPLACE TABLE purchase_clean AS
SELECT *
FROM purchase
QUALIFY ROW_NUMBER() OVER (PARTITION BY purchase_id ORDER BY event_ts) = 1;

-- ---------- Clean 2: ad views ----------
-- ad_view timestamps run 8 hours ahead of every other table
-- (first event 14:00 on Jan 1, last event 07:59 on May 1). Shift them back.
CREATE OR REPLACE TABLE ad_view_clean AS
SELECT device_id,
       event_ts - INTERVAL 8 HOUR AS event_ts,
       status, placement, reward_type, reward_amount,
       ad_daily_count, ad_daily_cap
FROM ad_view;

-- ---------- Clean 3: one id per real person ----------
-- 3,211 rows have original_device_id filled in:
--   * 3,210 real links (same person, new phone)
--   * 1 self-link (device 125989 points to itself) -> ignored
--   * 111 of the links are CHAINS: C -> B -> A (B is itself linked to A).
--     A single COALESCE would map C to B, not A, and leave B and C as two "players".
--     So we follow each chain to its root with a recursive query.
-- Result: 80,295 devices -> 77,085 real players (80,295 - 3,210).
CREATE OR REPLACE TABLE player_map AS
WITH RECURSIVE walk(device_id, current_id, steps) AS (
    SELECT device_id, device_id, 0
    FROM player_profile
    UNION ALL
    SELECT w.device_id, p.original_device_id, w.steps + 1
    FROM walk w
    JOIN player_profile p ON p.device_id = w.current_id
    WHERE p.original_device_id IS NOT NULL
      AND p.original_device_id <> p.device_id      -- skip the self-link
      AND w.steps < 10                              -- safety stop
)
SELECT device_id,
       arg_max(current_id, steps) AS player_id,     -- the last device reached = the root
       MAX(steps)                 AS chain_length
FROM walk
GROUP BY device_id;

-- ---------- Helper: activity with a real DATE column ----------
CREATE OR REPLACE TABLE activity AS
SELECT device_id,
       strptime(CAST(activity_date AS VARCHAR), '%Y%m%d')::DATE AS day,
       player_level, session_count, playtime_minutes
FROM player_day;

-- ---------- Check ----------
SELECT 'player_profile' AS table_name, COUNT(*) AS rows FROM player_profile
UNION ALL SELECT 'player_day',     COUNT(*) FROM player_day
UNION ALL SELECT 'purchase',       COUNT(*) FROM purchase
UNION ALL SELECT 'purchase_clean', COUNT(*) FROM purchase_clean
UNION ALL SELECT 'currency_spend', COUNT(*) FROM currency_spend
UNION ALL SELECT 'ad_view_clean',  COUNT(*) FROM ad_view_clean
UNION ALL SELECT 'real players',   COUNT(DISTINCT player_id) FROM player_map;
