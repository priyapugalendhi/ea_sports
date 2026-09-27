-- =====================================================================
-- 1(a)  DAILY HEALTH BY PLATFORM
--   DAU, gross revenue, ARPDAU, % of active players who purchased
--
-- Judgement calls:
--   * "Active" = has a player_day row OR made a purchase that day.
--     (2,449 purchases - all of them during sales - have no player_day row for that
--      device that day; 2,434 still have none after merging linked devices. Without
--      this rule those buyers would be missing from the denominator of % payers.)
--   * Linked devices are counted as ONE player (player_map follows chains to the root).
--   * Platform = platform of the device used that day. A person who played on an iOS
--     AND an Android device on the same day counts once in each platform.
--   * Gross revenue = positive purchases only, duplicates removed. Refunds excluded.
-- =====================================================================

CREATE OR REPLACE TABLE daily_health AS
WITH active AS (
    SELECT device_id, day FROM activity
    UNION                                               -- UNION removes duplicates
    SELECT device_id, CAST(event_ts AS DATE) FROM purchase_clean WHERE usd_amount > 0
),
active_players AS (
    SELECT DISTINCT a.day, m.player_id, p.platform
    FROM active a
    JOIN player_map m     ON m.device_id = a.device_id
    JOIN player_profile p ON p.device_id = a.device_id
),
dau AS (
    SELECT day, platform, COUNT(DISTINCT player_id) AS dau
    FROM active_players GROUP BY day, platform
),
rev AS (
    SELECT CAST(pc.event_ts AS DATE) AS day, p.platform,
           SUM(pc.usd_amount)          AS gross_revenue,
           COUNT(DISTINCT m.player_id) AS payers
    FROM purchase_clean pc
    JOIN player_map m     ON m.device_id = pc.device_id
    JOIN player_profile p ON p.device_id = pc.device_id
    WHERE pc.usd_amount > 0
    GROUP BY 1, 2
)
SELECT d.day, d.platform, d.dau,
       ROUND(COALESCE(r.gross_revenue, 0), 2)          AS gross_revenue,
       ROUND(COALESCE(r.gross_revenue, 0) / d.dau, 4)  AS arpdau,
       ROUND(100.0 * COALESCE(r.payers, 0) / d.dau, 2) AS pct_payers
FROM dau d
LEFT JOIN rev r ON r.day = d.day AND r.platform = d.platform
ORDER BY d.day, d.platform;

COPY daily_health TO '1a_daily_health.csv' (HEADER);

.print '--- First rows ---'
SELECT * FROM daily_health LIMIT 6;

.print '--- Sanity check: revenue in daily table = revenue in purchase table ---'
SELECT (SELECT ROUND(SUM(gross_revenue), 2) FROM daily_health)                          AS daily_table_total,
       (SELECT ROUND(SUM(usd_amount), 2) FROM purchase_clean WHERE usd_amount > 0)       AS purchase_table_total,
       (SELECT COUNT(DISTINCT day) FROM daily_health)                                    AS days_covered;

.print '--- Summary by platform ---'
SELECT platform,
       ROUND(AVG(dau))                         AS avg_dau,
       ROUND(SUM(gross_revenue), 0)            AS total_revenue,
       ROUND(SUM(gross_revenue) / SUM(dau), 4) AS arpdau,
       ROUND(AVG(pct_payers), 2)               AS avg_pct_payers
FROM daily_health
GROUP BY platform ORDER BY platform;
