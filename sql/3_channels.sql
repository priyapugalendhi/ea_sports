-- =====================================================================
-- 3  IS ONE ACQUISITION CHANNEL BETTER?
--   Players: installed Jan 1 - Mar 31 (everyone has a full 30 days), not re-linked.
--   Revenue measure    : gross $ spent in first 30 days after install (rev30)
--   Engagement measure : number of active days in first 30 days (active_days30)
--   Confidence intervals: normal approximation on the tier-adjusted difference
-- =====================================================================

CREATE OR REPLACE TABLE channel_players AS
WITH c AS (
    SELECT device_id, install_date, country_tier AS tier, acquisition_channel AS channel
    FROM player_profile
    WHERE install_date BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'
      AND original_device_id IS NULL
),
rev AS (
    SELECT c.device_id,
           COALESCE(SUM(pc.usd_amount) FILTER (
               WHERE pc.usd_amount > 0 AND CAST(pc.event_ts AS DATE) < c.install_date + 30), 0) AS rev30
    FROM c LEFT JOIN purchase_clean pc ON pc.device_id = c.device_id
    GROUP BY c.device_id
),
eng AS (
    SELECT c.device_id,
           COUNT(a.day) FILTER (WHERE a.day BETWEEN c.install_date AND c.install_date + 29) AS active_days30
    FROM c LEFT JOIN activity a ON a.device_id = c.device_id
    GROUP BY c.device_id
)
SELECT c.*, rev.rev30, eng.active_days30
FROM c
JOIN rev ON rev.device_id = c.device_id
JOIN eng ON eng.device_id = c.device_id;

.print '=== A. RAW comparison (the misleading one) ==='
SELECT channel, COUNT(*) AS installs,
       ROUND(AVG(rev30), 3)         AS rev30_per_install,
       ROUND(AVG(active_days30), 3) AS active_days30
FROM channel_players GROUP BY channel ORDER BY channel;

.print '=== B. Why it misleads: country-tier mix of each channel (% of installs) ==='
SELECT channel,
       ROUND(100.0 * AVG(CASE WHEN tier = 1 THEN 1 ELSE 0 END), 1) AS tier1_pct,
       ROUND(100.0 * AVG(CASE WHEN tier = 2 THEN 1 ELSE 0 END), 1) AS tier2_pct,
       ROUND(100.0 * AVG(CASE WHEN tier = 3 THEN 1 ELSE 0 END), 1) AS tier3_pct,
       ROUND(100.0 * AVG(CASE WHEN tier = 4 THEN 1 ELSE 0 END), 1) AS tier4_pct
FROM channel_players GROUP BY channel ORDER BY channel;

.print '=== C. Same comparison INSIDE each tier ==='
SELECT tier,
       ROUND(AVG(rev30) FILTER (WHERE channel = 'organic'), 2)             AS rev30_organic,
       ROUND(AVG(rev30) FILTER (WHERE channel = 'paid_social'), 2)         AS rev30_paid_social,
       ROUND(AVG(rev30) FILTER (WHERE channel = 'paid_video'), 2)          AS rev30_paid_video,
       ROUND(AVG(active_days30) FILTER (WHERE channel = 'organic'), 2)     AS days_organic,
       ROUND(AVG(active_days30) FILTER (WHERE channel = 'paid_social'), 2) AS days_paid_social,
       ROUND(AVG(active_days30) FILTER (WHERE channel = 'paid_video'), 2)  AS days_paid_video
FROM channel_players GROUP BY tier ORDER BY tier;

-- Tier-adjusted mean per channel = what each channel would score with the SAME tier mix.
--   adjusted_mean = SUM over tiers ( weight_t * mean_t )
--   variance      = SUM over tiers ( weight_t^2 * var_t / n_t )
CREATE OR REPLACE TABLE channel_adjusted AS
WITH weights AS (
    SELECT tier, 1.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS w
    FROM channel_players GROUP BY tier
),
cells AS (
    SELECT channel, tier, COUNT(*) AS n,
           AVG(rev30)                AS rev_mean, VAR_SAMP(rev30)         AS rev_var,
           AVG(active_days30)        AS eng_mean, VAR_SAMP(active_days30) AS eng_var
    FROM channel_players GROUP BY channel, tier
)
SELECT c.channel,
       SUM(w.w * c.rev_mean)                  AS rev_adj,
       SUM(w.w * w.w * c.rev_var / c.n)       AS rev_adj_var,
       SUM(w.w * c.eng_mean)                  AS eng_adj,
       SUM(w.w * w.w * c.eng_var / c.n)       AS eng_adj_var
FROM cells c JOIN weights w ON w.tier = c.tier
GROUP BY c.channel;

.print '=== D. Tier-adjusted differences with 95% confidence intervals ==='
WITH pairs AS (
    SELECT a.channel AS channel_a, b.channel AS channel_b,
           'revenue: $ in first 30 days' AS measure,
           a.rev_adj - b.rev_adj AS diff, b.rev_adj AS base,
           SQRT(a.rev_adj_var + b.rev_adj_var) AS se
    FROM channel_adjusted a JOIN channel_adjusted b ON a.channel < b.channel
    UNION ALL
    SELECT a.channel, b.channel,
           'engagement: active days in first 30',
           a.eng_adj - b.eng_adj, b.eng_adj,
           SQRT(a.eng_adj_var + b.eng_adj_var)
    FROM channel_adjusted a JOIN channel_adjusted b ON a.channel < b.channel
)
SELECT measure, channel_a || ' - ' || channel_b AS comparison,
       ROUND(diff, 3)                  AS difference,
       ROUND(100 * diff / base, 1)     AS diff_pct,
       ROUND(diff - 1.96 * se, 3)      AS ci_low,
       ROUND(diff + 1.96 * se, 3)      AS ci_high,
       CASE WHEN diff - 1.96 * se > 0 OR diff + 1.96 * se < 0 THEN 'YES' ELSE 'no' END AS significant
FROM pairs
ORDER BY measure DESC, comparison;

.print '=== E. Installs needed per channel to prove the organic vs paid_video revenue gap ==='
.print '    (95% confidence, 80% power: n = 2 * (1.96 + 0.84)^2 * sd^2 / gap^2)'
SELECT ROUND(STDDEV_SAMP(p.rev30), 2)                                   AS sd_rev30,
       ROUND(o.rev_adj - v.rev_adj, 3)                                  AS observed_gap,
       ROUND(2 * POWER(1.96 + 0.84, 2) * VAR_SAMP(p.rev30) / POWER(o.rev_adj - v.rev_adj, 2)) AS installs_needed_per_channel,
       (SELECT MIN(cnt) FROM (SELECT COUNT(*) AS cnt FROM channel_players GROUP BY channel)) AS installs_we_have
FROM channel_players p,
     (SELECT rev_adj FROM channel_adjusted WHERE channel = 'organic')    o,
     (SELECT rev_adj FROM channel_adjusted WHERE channel = 'paid_video') v
GROUP BY o.rev_adj, v.rev_adj;

-- Data for the chart: raw vs tier-adjusted revenue per install
COPY (
    SELECT r.channel,
           ROUND(r.raw_rev30, 3) AS raw_rev30,
           ROUND(a.rev_adj, 3)   AS tier_adjusted_rev30
    FROM (SELECT channel, AVG(rev30) AS raw_rev30 FROM channel_players GROUP BY channel) r
    JOIN channel_adjusted a ON a.channel = r.channel
    ORDER BY r.channel
) TO '3_channels.csv' (HEADER);

-- Per-player data for the bootstrap CI in python/3_bootstrap_and_chart.py
COPY channel_players TO '3_channel_players.csv' (HEADER);
