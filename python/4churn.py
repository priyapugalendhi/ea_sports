import duckdb
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from sklearn.metrics import roc_auc_score, average_precision_score

pd.set_option("display.width", 200)
con = duckdb.connect("ea_sql.duckdb")

# ================= 1. WHY THIS CHURN DEFINITION? =================
print("=== 1. CHOOSING THE CHURN WINDOW ===")
print("Players active in the week before a snapshot (Feb 1 / Feb 15 / Mar 1):")
print(con.sql("""
WITH a AS (SELECT device_id, strptime(CAST(activity_date AS VARCHAR), '%Y%m%d')::DATE AS d FROM player_day),
snaps AS (SELECT unnest([DATE '2026-02-01', DATE '2026-02-15', DATE '2026-03-01']) AS t),
w AS (SELECT unnest([7, 14, 21, 28]) AS n),
x AS (
    SELECT s.t, w.n, a.device_id,
           MAX(CASE WHEN a.d BETWEEN s.t - 6 AND s.t THEN 1 ELSE 0 END)                AS active_now,
           MAX(CASE WHEN a.d BETWEEN s.t + 1 AND s.t + w.n THEN 1 ELSE 0 END)          AS active_next,
           MAX(CASE WHEN a.d BETWEEN s.t + w.n + 1 AND s.t + w.n + 45 THEN 1 ELSE 0 END) AS active_after
    FROM snaps s, w, a
    GROUP BY 1, 2, 3
)
SELECT n AS gone_for_days,
       ROUND(100 * AVG(1 - active_next), 1)                              AS pct_labelled_churned,
       ROUND(100 * AVG(active_after) FILTER (WHERE active_next = 0), 1)  AS pct_of_those_back_within_45d
FROM x WHERE active_now = 1
GROUP BY n ORDER BY n
"""))

# ================= 2. BUILD THE DATASET =================
# One row per (player, snapshot date). Features use ONLY data up to the snapshot.
# Label = 1 if the player has NO active day in the 14 days after the snapshot.
con.execute("""
CREATE OR REPLACE TABLE churn_data AS
WITH a AS (
    SELECT device_id,
           strptime(CAST(activity_date AS VARCHAR), '%Y%m%d')::DATE AS d,
           session_count, playtime_minutes, player_level
    FROM player_day
),
snaps AS (
    SELECT CAST(range AS DATE) AS t
    FROM range(DATE '2026-02-01', DATE '2026-04-17', INTERVAL 7 DAY)   -- weekly, last one Apr 12
    UNION SELECT DATE '2026-04-16'                                      -- last date with a full 14-day future
),
linked AS (   -- linked devices and their originals: a phone switch would look like churn
    SELECT device_id FROM player_profile WHERE original_device_id IS NOT NULL
    UNION
    SELECT original_device_id FROM player_profile WHERE original_device_id IS NOT NULL
),
base AS (
    SELECT s.t, a.device_id,
           COUNT(*) FILTER (WHERE a.d BETWEEN s.t - 6  AND s.t)                       AS days_active_7,
           COUNT(*) FILTER (WHERE a.d BETWEEN s.t - 27 AND s.t)                       AS days_active_28,
           s.t - MAX(a.d) FILTER (WHERE a.d <= s.t)                                   AS days_since_last,
           COALESCE(SUM(a.session_count)    FILTER (WHERE a.d BETWEEN s.t - 6 AND s.t), 0) AS sessions_7,
           COALESCE(SUM(a.playtime_minutes) FILTER (WHERE a.d BETWEEN s.t - 6 AND s.t), 0) AS playtime_7,
           MAX(a.player_level) FILTER (WHERE a.d <= s.t)                              AS level,
           MAX(a.player_level) FILTER (WHERE a.d <= s.t)
             - COALESCE(MAX(a.player_level) FILTER (WHERE a.d <= s.t - 28), 0)        AS level_gain_28,
           CASE WHEN COUNT(*) FILTER (WHERE a.d BETWEEN s.t + 1 AND s.t + 14) = 0
                THEN 1 ELSE 0 END                                                     AS churned
    FROM snaps s
    JOIN a ON a.d <= s.t + 14
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
       COALESCE(sp.spend_28, 0)                                  AS spend_28,
       CASE WHEN COALESCE(sp.purchases_to_date, 0) > 0 THEN 1 ELSE 0 END AS is_payer,
       b.t - p.install_date                                      AS tenure_days,
       CASE WHEN p.platform = 'iOS' THEN 1 ELSE 0 END            AS is_ios,
       p.country_tier                                            AS tier,
       p.acquisition_channel                                     AS channel
FROM base b
JOIN player_profile p ON p.device_id = b.device_id
LEFT JOIN spend sp    ON sp.t = b.t AND sp.device_id = b.device_id
WHERE b.days_active_7 > 0                                         -- "currently active" = played in last 7 days
  AND b.device_id NOT IN (SELECT device_id FROM linked)
""")

df = con.sql("SELECT * FROM churn_data ORDER BY t").df()
df = pd.get_dummies(df, columns=["tier", "channel"], drop_first=True, dtype=int)

print("\n=== 2. DATASET ===")
print(df.groupby("t").agg(players=("churned", "size"), churn_rate=("churned", "mean")).round(3))

# ================= 3. TIME-BASED SPLIT =================
# Train on early snapshots, test on later ones. Train labels end Mar 22, before the first test snapshot.
train = df[df.t <= pd.Timestamp("2026-03-08")]
test  = df[df.t >= pd.Timestamp("2026-03-29")]

features = [c for c in df.columns if c not in ("t", "device_id", "churned")]
model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=1000))
model.fit(train[features], train.churned)
test = test.copy()
test["p_churn"] = model.predict_proba(test[features])[:, 1]

print("\n=== 3. SPLIT ===")
print(f"Train: {len(train):,} rows (snapshots Feb 1 - Mar 8), churn rate {train.churned.mean():.1%}")
print(f"Test : {len(test):,} rows (snapshots Mar 29 - Apr 16), churn rate {test.churned.mean():.1%}")

# ================= 4. RESULTS =================
print("\n=== 4. HOW WELL IT WORKS (test set) ===")
print(f"ROC AUC           : {roc_auc_score(test.churned, test.p_churn):.3f}   (0.5 = coin flip, 1.0 = perfect)")
print(f"PR AUC            : {average_precision_score(test.churned, test.p_churn):.3f}   (compare to base rate {test.churned.mean():.3f})")

print("\nCoefficients (standardised: bigger = stronger effect; + means MORE likely to churn):")
coefs = pd.Series(model[-1].coef_[0], index=features).sort_values()
print(coefs.round(3).to_string())

print("\nBy risk decile (10 = highest predicted risk):")
test["decile"] = pd.qcut(test.p_churn.rank(method="first"), 10, labels=range(1, 11))
print(test.groupby("decile", observed=True).agg(players=("churned", "size"),
                                                avg_predicted=("p_churn", "mean"),
                                                actual_churn=("churned", "mean")).round(3).to_string())

print("\nWhere it works badly - AUC by segment:")
def seg_auc(mask, name):
    s = test[mask]
    if s.churned.nunique() == 2:
        print(f"  {name:32s} rows={len(s):6,}  churn={s.churned.mean():.1%}  AUC={roc_auc_score(s.churned, s.p_churn):.3f}")
seg_auc(test.tenure_days <= 14,  "new players (tenure <= 14 days)")
seg_auc(test.tenure_days > 14,   "older players")
seg_auc(test.days_active_7 == 1, "played only 1 day last week")
seg_auc(test.days_active_7 >= 3, "played 3+ days last week")
seg_auc(test.is_payer == 1,      "payers")
seg_auc(test.is_payer == 0,      "non-payers")

# ================= 5. USE: WHERE TO SET THE THRESHOLD =================
print("\n=== 5. TARGETING: who gets the offer at each threshold (test set) ===")
rows = []
for thr in [0.2, 0.3, 0.4, 0.5, 0.6]:
    tgt = test[test.p_churn >= thr]
    rows.append({
        "threshold": thr,
        "pct_players_targeted": round(100 * len(tgt) / len(test), 1),
        "precision_pct": round(100 * tgt.churned.mean(), 1) if len(tgt) else None,
        "recall_pct": round(100 * tgt.churned.sum() / test.churned.sum(), 1),
        "wasted_per_100_offers": round(100 * (1 - tgt.churned.mean()), 1) if len(tgt) else None,
    })
print(pd.DataFrame(rows).to_string(index=False))
print("""
Rule: send the offer if  p_churn x (chance the offer saves them) x (value of a saved player) > offer cost
      => threshold = offer cost / (save rate x player value)
Example: offer costs $0.50, it saves 10% of churners, a saved player is worth $10  => threshold = 0.50 / (0.10 x 10) = 0.5
""")