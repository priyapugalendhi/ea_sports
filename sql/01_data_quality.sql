-- =====================================================================
-- 01  DATA QUALITY CHECKS
-- =====================================================================

.print '--- 1. Players installed before the window (cannot see their early days) ---'
SELECT COUNT(*) AS total_players,
       COUNT(*) FILTER (WHERE install_date < DATE '2026-01-01') AS installed_before_window
FROM player_profile;

.print '--- 2. Linked devices: links, chains and self-links ---'
SELECT COUNT(original_device_id)                                          AS rows_with_original,
       COUNT(*) FILTER (WHERE original_device_id = device_id)            AS self_links,
       COUNT(*) FILTER (WHERE original_device_id IN
             (SELECT device_id FROM player_profile
              WHERE original_device_id IS NOT NULL
                AND original_device_id <> device_id)
             AND original_device_id <> device_id)                         AS chains_c_to_b_to_a,
       (SELECT COUNT(DISTINCT player_id) FROM player_map)                 AS real_players_after_merge
FROM player_profile;

.print '--- 3. first_purchase_date BEFORE install_date (impossible) ---'
SELECT COUNT(*) AS bad_rows,
       MIN(install_date - first_purchase_date) AS min_days_early,
       MAX(install_date - first_purchase_date) AS max_days_early
FROM player_profile
WHERE first_purchase_date < install_date;

.print '--- 4. Negative purchase amounts = refunds ---'
SELECT COUNT(*) AS refund_rows,
       ROUND(SUM(usd_amount), 2) AS refund_usd,
       COUNT(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM purchase o
           WHERE o.device_id = r.device_id AND o.pack_name = r.pack_name
             AND o.usd_amount = -r.usd_amount AND o.event_ts <= r.event_ts)) AS matches_earlier_purchase
FROM purchase r
WHERE usd_amount < 0;

.print '--- 5. Duplicate purchase_ids ---'
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT purchase_id) AS unique_ids,
       COUNT(*) - COUNT(DISTINCT purchase_id) AS extra_rows
FROM purchase;

.print '--- 6. Purchases on a day with no activity row (clean, positive purchases) ---'
.print '    device level = that exact device has no player_day row that day'
.print '    player level = none of the linked devices of that person has a row that day'
WITH player_activity AS (
    SELECT DISTINCT m.player_id, a.day
    FROM activity a JOIN player_map m ON m.device_id = a.device_id
)
SELECT p.sale_flag,
       COUNT(*) AS purchases,
       COUNT(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM activity a
           WHERE a.device_id = p.device_id AND a.day = CAST(p.event_ts AS DATE)))  AS no_row_device_level,
       COUNT(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM player_activity pa
           WHERE pa.player_id = m.player_id AND pa.day = CAST(p.event_ts AS DATE))) AS no_row_player_level
FROM purchase_clean p
JOIN player_map m ON m.device_id = p.device_id
WHERE p.usd_amount > 0
GROUP BY p.sale_flag ORDER BY p.sale_flag;

.print '--- 7. Ad status counts (started = never finished, reward 0) ---'
SELECT status, COUNT(*) AS n, ROUND(AVG(reward_amount), 1) AS avg_reward
FROM ad_view GROUP BY status ORDER BY n DESC;

.print '--- 8. Ad clock is 8 hours ahead: time range before and after the fix ---'
SELECT 'raw ad_view' AS version, MIN(event_ts) AS first_event, MAX(event_ts) AS last_event FROM ad_view
UNION ALL SELECT 'ad_view_clean', MIN(event_ts), MAX(event_ts) FROM ad_view_clean
UNION ALL SELECT 'purchase (reference)', MIN(event_ts), MAX(event_ts) FROM purchase
UNION ALL SELECT 'currency_spend (reference)', MIN(event_ts), MAX(event_ts) FROM currency_spend;

.print '--- 8a. Why exactly 8? Hours of the day in which events happen ---'
.print '    Every other table only has events between 06:00 and 23:59.'
.print '    Raw ad_view has events 14:00-07:59, i.e. the same 18-hour window moved +8 hours.'
SELECT 'purchase'       AS source, MIN(hour(event_ts)) AS first_hour, MAX(hour(event_ts)) AS last_hour,
       COUNT(DISTINCT hour(event_ts)) AS hours_with_events FROM purchase
UNION ALL SELECT 'currency_spend', MIN(hour(event_ts)), MAX(hour(event_ts)), COUNT(DISTINCT hour(event_ts)) FROM currency_spend
UNION ALL SELECT 'ad_view raw',    MIN(hour(event_ts)) FILTER (WHERE hour(event_ts) >= 8), MAX(hour(event_ts)) FILTER (WHERE hour(event_ts) < 8),
                                   COUNT(DISTINCT hour(event_ts)) FROM ad_view
UNION ALL SELECT 'ad_view shifted -8h', MIN(hour(event_ts)), MAX(hour(event_ts)), COUNT(DISTINCT hour(event_ts)) FROM ad_view_clean;

.print '--- 8a-2. Test every shift: % of ad views on an active day, and earliest hour after shifting ---'
.print '    Shifts of 8 to 12 all give 100% match, but only 8 puts the earliest event at 06:00'
.print '    like every other table. 9+ would create events at 05:00 or earlier, which never happen elsewhere.'
WITH shifts AS (SELECT unnest(range(5, 13)) AS h),
v AS (SELECT device_id, event_ts FROM ad_view WHERE status = 'completed')
SELECT s.h AS shift_hours,
       ROUND(100.0 * AVG(CASE WHEN a.device_id IS NOT NULL THEN 1 ELSE 0 END), 2) AS pct_on_active_day,
       MIN(hour(v.event_ts - to_hours(s.h)))                                       AS earliest_hour_after_shift
FROM shifts s
CROSS JOIN v
LEFT JOIN activity a
       ON a.device_id = v.device_id AND a.day = CAST(v.event_ts - to_hours(s.h) AS DATE)
GROUP BY s.h ORDER BY s.h;

.print '--- 8b. Proof: completed ad views with NO active day for that player ---'
SELECT 'before fix' AS version, COUNT(*) AS unmatched_views
FROM ad_view a
WHERE status = 'completed' AND NOT EXISTS (
    SELECT 1 FROM activity d WHERE d.device_id = a.device_id AND d.day = CAST(a.event_ts AS DATE))
UNION ALL
SELECT 'after fix', COUNT(*)
FROM ad_view_clean a
WHERE status = 'completed' AND NOT EXISTS (
    SELECT 1 FROM activity d WHERE d.device_id = a.device_id AND d.day = CAST(a.event_ts AS DATE));

.print '--- 9. Ad logging outage: early March (after the clock fix) vs active players ---'
SELECT d.day,
       COUNT(DISTINCT d.device_id) AS active_players,
       (SELECT COUNT(*) FROM ad_view_clean v
        WHERE v.status = 'completed' AND CAST(v.event_ts AS DATE) = d.day) AS completed_ad_views
FROM activity d
WHERE d.day BETWEEN DATE '2026-03-02' AND DATE '2026-03-09'
GROUP BY d.day ORDER BY d.day;
