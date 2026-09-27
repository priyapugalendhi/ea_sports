-- =====================================================================
-- 1(b)  RETENTION COHORT TABLE
--   Cohort = install week. Cell = % of cohort active on exactly day N after install.
--
-- Judgement calls:
--   * Only NEW players: installed on/after 2026-01-01.
--   * Devices flagged as linked (original_device_id filled) are excluded: they are
--     an existing person on a new phone, not a new player.
--   * Measured per device: a cohort member counts as retained on day N if that
--     device has a player_day row on install_date + N.
--   * RULE FOR RECENT COHORTS: a cell is left BLANK unless every player in the
--     cohort has reached day N by 2026-04-30. Showing 0% would look like everyone
--     quit; showing a partial % would mix players with and without time to return.
-- =====================================================================

CREATE OR REPLACE TABLE retention AS
WITH cohort AS (
    SELECT device_id, install_date,
           date_trunc('week', install_date)::DATE AS install_week
    FROM player_profile
    WHERE install_date >= DATE '2026-01-01'
      AND original_device_id IS NULL
),
cells AS (
    SELECT c.install_week, m.n,
           COUNT(DISTINCT c.device_id) AS cohort_size,
           COUNT(DISTINCT a.device_id) AS retained,
           (c.install_week + 6 + m.n) <= DATE '2026-04-30' AS complete
    FROM cohort c
    CROSS JOIN (VALUES (1), (7), (14), (30)) AS m(n)
    LEFT JOIN activity a
           ON a.device_id = c.device_id AND a.day = c.install_date + m.n
    GROUP BY c.install_week, m.n
)
SELECT install_week,
       MAX(cohort_size) AS cohort_size,
       MAX(CASE WHEN n = 1  AND complete THEN ROUND(100.0 * retained / cohort_size, 1) END) AS d1_pct,
       MAX(CASE WHEN n = 7  AND complete THEN ROUND(100.0 * retained / cohort_size, 1) END) AS d7_pct,
       MAX(CASE WHEN n = 14 AND complete THEN ROUND(100.0 * retained / cohort_size, 1) END) AS d14_pct,
       MAX(CASE WHEN n = 30 AND complete THEN ROUND(100.0 * retained / cohort_size, 1) END) AS d30_pct
FROM cells
GROUP BY install_week
ORDER BY install_week;

COPY retention TO '1b_retention.csv' (HEADER);

.print '--- Retention grid (NULL = not enough time has passed yet) ---'
SELECT * FROM retention;
