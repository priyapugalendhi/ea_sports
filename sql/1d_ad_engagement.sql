-- =====================================================================
-- 1(d)  REWARDED AD ENGAGEMENT
--   Uses ad_view_clean (clock shifted back 8 hours).
--   Excludes Mar 5-6 (ad logging outage: 0 ad events while ~5,000 players were active).
--   Needs 1a_daily_health.sql to have run first (uses its daily_health table).
-- =====================================================================

-- One row per device per day with any ad interaction.
-- The ad cap and ad_daily_count are tracked per device, so the cap question is
-- answered per device-day (= the brief's "ad-watching player-days").
CREATE OR REPLACE TABLE ad_player_day AS
SELECT device_id,
       CAST(event_ts AS DATE)                       AS day,
       MAX(ad_daily_cap)                            AS cap,
       MAX(ad_daily_count)                          AS attempts,
       COUNT(*)                                     AS events,
       COUNT(*) FILTER (WHERE status = 'completed') AS completed
FROM ad_view_clean
WHERE CAST(event_ts AS DATE) NOT IN (DATE '2026-03-05', DATE '2026-03-06')
GROUP BY device_id, CAST(event_ts AS DATE);

.print '--- Check: does ad_daily_count count EVERY attempt (incl. abandoned/started)? ---'
SELECT ROUND(100.0 * AVG(CASE WHEN attempts = events THEN 1 ELSE 0 END), 1) AS pct_days_counter_equals_events
FROM ad_player_day;

.print '--- Share of ad-watching player-days that hit the cap, by cap value ---'
SELECT COALESCE(CAST(cap AS VARCHAR), 'ALL') AS cap,
       COUNT(*)                                                             AS player_days,
       ROUND(AVG(attempts), 2)                                              AS avg_attempts,
       ROUND(100.0 * AVG(CASE WHEN attempts  >= cap THEN 1 ELSE 0 END), 2)  AS pct_hit_cap,
       ROUND(100.0 * AVG(CASE WHEN completed >= cap THEN 1 ELSE 0 END), 2)  AS pct_cap_all_completed
FROM ad_player_day
GROUP BY ROLLUP (cap)
ORDER BY cap NULLS LAST;

.print '--- Attempts per player-day: cap-5 vs cap-8 players behave the same ---'
SELECT attempts,
       COUNT(*) FILTER (WHERE cap = 5) AS cap5_days,
       COUNT(*) FILTER (WHERE cap = 8) AS cap8_days
FROM ad_player_day
GROUP BY attempts ORDER BY attempts;

-- Daily completed ad views and views per daily active player (for the chart).
-- DAU is taken from daily_health (1a) so it matches the DAU used everywhere else.
CREATE OR REPLACE TABLE daily_ad_views AS
WITH days AS (
    SELECT CAST(range AS DATE) AS day
    FROM range(DATE '2026-01-01', DATE '2026-05-01', INTERVAL 1 DAY)
),
views AS (
    SELECT CAST(event_ts AS DATE) AS day, COUNT(*) AS completed_views
    FROM ad_view_clean WHERE status = 'completed' GROUP BY 1
),
dau AS (
    SELECT day, SUM(dau) AS dau FROM daily_health GROUP BY day
)
SELECT d.day,
       COALESCE(v.completed_views, 0)                   AS completed_views,
       u.dau,
       ROUND(COALESCE(v.completed_views, 0) / u.dau, 3) AS views_per_dau
FROM days d
LEFT JOIN views v ON v.day = d.day
LEFT JOIN dau u   ON u.day = d.day
ORDER BY d.day;

COPY daily_ad_views TO '1d_daily_ad_views.csv' (HEADER);

.print '--- Weekly view of daily ad views (full daily table saved to 1d_daily_ad_views.csv) ---'
SELECT date_trunc('week', day)::DATE AS week,
       ROUND(AVG(completed_views)) AS avg_daily_views,
       MIN(completed_views)        AS min_daily_views,
       ROUND(AVG(views_per_dau), 3) AS avg_views_per_dau
FROM daily_ad_views
GROUP BY 1 ORDER BY 1;
