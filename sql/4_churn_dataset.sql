-- =====================================================================
-- 4  CHURN: DEFINITION CHECK + MODEL DATASET
--   The dataset is built here in SQL. The logistic regression itself
--   is trained in Python (python/4_churn_model.py), because SQL cannot fit a model.
-- =====================================================================

.print '=== 1. Choosing the churn window ==='
.print '    Devices active in the week before a snapshot (Feb 1 / Feb 15 / Mar 1):'
.print '    how many go quiet for N days, and how many of THOSE come back within 45 days?'
WITH snaps AS (SELECT unnest([DATE '2026-02-01', DATE '2026-02-15', DATE '2026-03-01']) AS t),
w AS (SELECT unnest([7, 14, 21, 28]) AS n),
x AS (
    SELECT s.t, w.n, a.device_id,
           MAX(CASE WHEN a.day BETWEEN s.t - 6 AND s.t THEN 1 ELSE 0 END)                  AS active_now,
           MAX(CASE WHEN a.day BETWEEN s.t + 1 AND s.t + w.n THEN 1 ELSE 0 END)            AS active_next,
           MAX(CASE WHEN a.day BETWEEN s.t + w.n + 1 AND s.t + w.n + 45 THEN 1 ELSE 0 END) AS active_after
    FROM snaps s, w, activity a
    GROUP BY 1, 2, 3
)
SELECT n AS gone_for_days,
       ROUND(100 * AVG(1 - active_next), 1)                             AS pct_labelled_churned,
       ROUND(100 * AVG(active_after) FILTER (WHERE active_next = 0), 1) AS pct_of_those_back_within_45d
FROM x WHERE active_now = 1
GROUP BY n ORDER BY n;

-- ---------- Model dataset: one row per (device, weekly snapshot) ----------
-- Linked devices are excluded (see below), so every remaining device = one person.
-- Who     : players active in the 7 days up to the snapshot ("currently active")
-- Label   : churned = 1 if NO active day in the 14 days after the snapshot
-- Features: only data up to the snapshot (no peeking into the future)
-- Excluded: linked devices and their originals (a phone switch looks like churn);
--           snapshots after Apr 16 (no full 14-day future yet)
CREATE OR REPLACE TABLE churn_data AS
WITH snaps AS (
    SELECT CAST(range AS DATE) AS t
    FROM range(DATE '2026-02-01', DATE '2026-04-17', INTERVAL 7 DAY)
    UNION SELECT DATE '2026-04-16'
),
linked AS (
    SELECT device_id FROM player_profile WHERE original_device_id IS NOT NULL
    UNION
    SELECT original_device_id FROM player_profile WHERE original_device_id IS NOT NULL
),
base AS (
    SELECT s.t, a.device_id,
           COUNT(*) FILTER (WHERE a.day BETWEEN s.t - 6  AND s.t)                          AS days_active_7,
           COUNT(*) FILTER (WHERE a.day BETWEEN s.t - 27 AND s.t)                          AS days_active_28,
           s.t - MAX(a.day) FILTER (WHERE a.day <= s.t)                                    AS days_since_last,
           COALESCE(SUM(a.session_count)    FILTER (WHERE a.day BETWEEN s.t - 6 AND s.t), 0) AS sessions_7,
           COALESCE(SUM(a.playtime_minutes) FILTER (WHERE a.day BETWEEN s.t - 6 AND s.t), 0) AS playtime_7,
           MAX(a.player_level) FILTER (WHERE a.day <= s.t)                                 AS level,
           MAX(a.player_level) FILTER (WHERE a.day <= s.t)
             - COALESCE(MAX(a.player_level) FILTER (WHERE a.day <= s.t - 28), 0)           AS level_gain_28,
           CASE WHEN COUNT(*) FILTER (WHERE a.day BETWEEN s.t + 1 AND s.t + 14) = 0
                THEN 1 ELSE 0 END                                                          AS churned
    FROM snaps s
    JOIN activity a ON a.day <= s.t + 14
    GROUP BY s.t, a.device_id
),
spend AS (
    SELECT s.t, pc.device_id,
           SUM(pc.usd_amount) FILTER (WHERE CAST(pc.event_ts AS DATE) BETWEEN s.t - 27 AND s.t) AS spend_28,
           COUNT(*) FILTER (WHERE CAST(pc.event_ts AS DATE) <= s.t)                           AS purchases_to_date
    FROM snaps s JOIN purchase_clean pc ON pc.usd_amount > 0
    GROUP BY s.t, pc.device_id
)
SELECT b.*,
       COALESCE(sp.spend_28, 0)                                          AS spend_28,
       CASE WHEN COALESCE(sp.purchases_to_date, 0) > 0 THEN 1 ELSE 0 END AS is_payer,
       b.t - p.install_date                                              AS tenure_days,
       CASE WHEN p.platform = 'iOS' THEN 1 ELSE 0 END                    AS is_ios,
       p.country_tier                                                    AS tier,
       p.acquisition_channel                                             AS channel
FROM base b
JOIN player_profile p ON p.device_id = b.device_id
LEFT JOIN spend sp    ON sp.t = b.t AND sp.device_id = b.device_id
WHERE b.days_active_7 > 0
  AND b.device_id NOT IN (SELECT device_id FROM linked);


.print '=== 2. Dataset: rows and churn rate per snapshot ==='
.print '    Train = Feb 1 - Mar 8 snapshots, Test = Mar 29 - Apr 16 (split by time, no overlap)'
SELECT t AS snapshot, COUNT(*) AS players, ROUND(AVG(churned), 3) AS churn_rate,
       CASE WHEN t <= DATE '2026-03-08' THEN 'train'
            WHEN t >= DATE '2026-03-29' THEN 'test'
            ELSE 'gap (not used)' END AS used_for
FROM churn_data GROUP BY t ORDER BY t;

.print '=== 3. Signal check in plain SQL: churn rate by sessions last week ==='
SELECT CASE WHEN sessions_7 <= 2  THEN 'a) 1-2 sessions'
            WHEN sessions_7 <= 5  THEN 'b) 3-5'
            WHEN sessions_7 <= 10 THEN 'c) 6-10'
            ELSE                       'd) 11+' END AS sessions_last_7_days,
       COUNT(*) AS rows, ROUND(100 * AVG(churned), 1) AS churn_pct
FROM churn_data GROUP BY 1 ORDER BY 1;

.print '=== 4. Signal check: churn rate by tenure ==='
SELECT CASE WHEN tenure_days <= 14  THEN 'a) 0-14 days'
            WHEN tenure_days <= 60  THEN 'b) 15-60 days'
            WHEN tenure_days <= 180 THEN 'c) 61-180 days'
            ELSE                         'd) 180+ days' END AS tenure,
       COUNT(*) AS rows, ROUND(100 * AVG(churned), 1) AS churn_pct
FROM churn_data GROUP BY 1 ORDER BY 1;

-- Model dataset for python/4_churn_model.py
COPY churn_data TO '4_churn_data.csv' (HEADER);
