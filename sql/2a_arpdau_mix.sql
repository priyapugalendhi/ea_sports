-- =====================================================================
-- 2(a)  "ARPDAU IS FALLING. FIX IT."
--   First 30 days (Jan 1-30) vs last 30 days (Apr 1-30).
--   Same "active" and "revenue" definitions as 1(a).
-- =====================================================================

CREATE OR REPLACE TABLE player_day_rev AS
WITH active AS (
    SELECT device_id, day FROM activity
    UNION
    SELECT device_id, CAST(event_ts AS DATE) FROM purchase_clean WHERE usd_amount > 0
),
ap AS (
    SELECT DISTINCT a.day, m.player_id, p.country_tier AS tier
    FROM active a
    JOIN player_map m     ON m.device_id = a.device_id
    JOIN player_profile p ON p.device_id = a.device_id
),
rev AS (
    SELECT CAST(pc.event_ts AS DATE) AS day, m.player_id, SUM(pc.usd_amount) AS revenue
    FROM purchase_clean pc JOIN player_map m ON m.device_id = pc.device_id
    WHERE pc.usd_amount > 0
    GROUP BY 1, 2
)
SELECT ap.day, ap.player_id, ap.tier,
       COALESCE(rev.revenue, 0) AS revenue,
       CASE WHEN ap.day <= DATE '2026-01-30' THEN '1_first30'
            WHEN ap.day >= DATE '2026-04-01' THEN '2_last30' END AS period
FROM ap
LEFT JOIN rev ON rev.day = ap.day AND rev.player_id = ap.player_id;

.print '=== A. Overall ARPDAU: first 30 vs last 30 days ==='
SELECT period,
       ROUND(SUM(revenue), 0)            AS revenue,
       COUNT(*)                          AS player_days,
       ROUND(SUM(revenue) / COUNT(*), 4) AS arpdau
FROM player_day_rev WHERE period IS NOT NULL
GROUP BY period ORDER BY period;

CREATE OR REPLACE TABLE tier_compare AS
SELECT tier, period,
       COUNT(*)                                                  AS player_days,
       SUM(revenue) / COUNT(*)                                   AS arpdau,
       1.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY period) AS dau_share
FROM player_day_rev WHERE period IS NOT NULL
GROUP BY tier, period;

.print '=== B. By tier: every tier improves, but Tier 4 share jumps ==='
SELECT f.tier,
       ROUND(f.arpdau, 4)                        AS arpdau_first30,
       ROUND(l.arpdau, 4)                        AS arpdau_last30,
       ROUND(100 * (l.arpdau / f.arpdau - 1), 1) AS arpdau_change_pct,
       ROUND(100 * f.dau_share, 1)               AS dau_share_first30,
       ROUND(100 * l.dau_share, 1)               AS dau_share_last30
FROM tier_compare f
JOIN tier_compare l ON l.tier = f.tier AND l.period = '2_last30'
WHERE f.period = '1_first30'
ORDER BY f.tier;

.print '=== C. Mix decomposition: April tier ARPDAUs, but January tier mix ==='
SELECT ROUND(SUM(f.dau_share * f.arpdau), 4) AS actual_first30,
       ROUND(SUM(l.dau_share * l.arpdau), 4) AS actual_last30,
       ROUND(SUM(f.dau_share * l.arpdau), 4) AS last30_rates_at_first30_mix
FROM tier_compare f
JOIN tier_compare l ON l.tier = f.tier AND l.period = '2_last30'
WHERE f.period = '1_first30';

.print '=== D. Where the new players came from: installs per month ==='
SELECT strftime(install_date, '%Y-%m') AS month,
       COUNT(*) FILTER (WHERE country_tier = 4)                                        AS tier4_installs,
       COUNT(*) FILTER (WHERE country_tier = 4 AND acquisition_channel = 'paid_video') AS tier4_paid_video,
       COUNT(*) FILTER (WHERE country_tier < 4)                                        AS tier1to3_installs
FROM player_profile
WHERE install_date >= DATE '2026-01-01'
GROUP BY month ORDER BY month;

.print '=== E. Are the new Tier-4 players worse? 30-day revenue per install (installed Jan 1 - Mar 31) ==='
WITH c AS (
    SELECT device_id, install_date, country_tier AS tier, acquisition_channel AS channel
    FROM player_profile
    WHERE install_date BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'
      AND original_device_id IS NULL
),
r AS (
    SELECT c.device_id,
           COALESCE(SUM(pc.usd_amount) FILTER (
               WHERE pc.usd_amount > 0 AND CAST(pc.event_ts AS DATE) < c.install_date + 30), 0) AS rev30
    FROM c LEFT JOIN purchase_clean pc ON pc.device_id = c.device_id
    GROUP BY c.device_id
)
SELECT tier, channel, COUNT(*) AS installs, ROUND(AVG(rev30), 2) AS rev30_per_install
FROM c JOIN r ON r.device_id = c.device_id
GROUP BY tier, channel ORDER BY tier, channel;

-- Data for the main chart (open in Excel/Keynote)
COPY (
    SELECT tier, period, ROUND(arpdau, 4) AS arpdau, ROUND(100 * dau_share, 1) AS dau_share_pct
    FROM tier_compare ORDER BY tier, period
) TO '2a_tier_compare.csv' (HEADER);
