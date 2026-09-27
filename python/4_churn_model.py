# 4 Churn model: logistic regression, time-based split, threshold table.
# Input : 4_churn_data.csv  (made by sql/4_churn_dataset.sql)
#         one row per (device, weekly snapshot); churned = 1 if no activity in the next 14 days
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from sklearn.metrics import roc_auc_score, average_precision_score

pd.set_option("display.width", 200)
df = pd.read_csv("4_churn_data.csv", parse_dates=["t"])
df = pd.get_dummies(df, columns=["tier", "channel"], drop_first=True, dtype=int)

# ---------- Time-based split ----------
# Train: snapshots Feb 1 - Mar 8 (their 14-day labels end Mar 22)
# Test : snapshots Mar 29 - Apr 16 (starts after the last training label -> no leakage)
train = df[df.t <= pd.Timestamp("2026-03-08")]
test = df[df.t >= pd.Timestamp("2026-03-29")].copy()

features = [c for c in df.columns if c not in ("t", "device_id", "churned")]
model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=1000))
model.fit(train[features], train.churned)
test["p_churn"] = model.predict_proba(test[features])[:, 1]

print("=== SPLIT ===")
print(f"Train: {len(train):,} rows, churn rate {train.churned.mean():.1%}")
print(f"Test : {len(test):,} rows, churn rate {test.churned.mean():.1%}")

print("\n=== RESULTS (test set) ===")
print(f"ROC AUC: {roc_auc_score(test.churned, test.p_churn):.3f}   (0.5 = coin flip, 1.0 = perfect)")
print(f"PR AUC : {average_precision_score(test.churned, test.p_churn):.3f}   (random model = base rate {test.churned.mean():.3f})")

print("\nCoefficients (features standardised; + = MORE likely to churn):")
print(pd.Series(model[-1].coef_[0], index=features).sort_values().round(3).to_string())
print("Note: days_active_7 and sessions_7 overlap heavily, so their individual signs")
print("should not be read on their own; together they say 'less play last week = more risk'.")

print("\nCalibration by risk decile (10 = highest predicted risk):")
test["decile"] = pd.qcut(test.p_churn.rank(method="first"), 10, labels=range(1, 11))
print(test.groupby("decile", observed=True).agg(rows=("churned", "size"),
                                                avg_predicted=("p_churn", "mean"),
                                                actual_churn=("churned", "mean")).round(3).to_string())

print("\nWhere it works badly - AUC by segment:")
def seg_auc(mask, name):
    s = test[mask]
    print(f"  {name:32s} rows={len(s):7,}  churn={s.churned.mean():5.1%}  AUC={roc_auc_score(s.churned, s.p_churn):.3f}")
seg_auc(test.tenure_days <= 14, "new players (tenure <= 14 days)")
seg_auc(test.tenure_days > 14, "older players")
seg_auc(test.days_active_7 == 1, "played only 1 day last week")
seg_auc(test.days_active_7 >= 3, "played 3+ days last week")
seg_auc(test.is_payer == 1, "payers")
seg_auc(test.is_payer == 0, "non-payers")

print("\n=== USE: who gets the offer at each threshold (test set) ===")
rows = []
for thr in [0.2, 0.3, 0.4, 0.5, 0.6]:
    tgt = test[test.p_churn >= thr]
    rows.append({"threshold": thr,
                 "pct_targeted": round(100 * len(tgt) / len(test), 1),
                 "precision_pct": round(100 * tgt.churned.mean(), 1),
                 "recall_pct": round(100 * tgt.churned.sum() / test.churned.sum(), 1),
                 "wasted_per_100_offers": round(100 * (1 - tgt.churned.mean()), 1)})
print(pd.DataFrame(rows).to_string(index=False))
print("""
Send the offer only if:  p_churn x save_rate x value_of_saved_player > offer_cost
  => threshold = offer_cost / (save_rate x value_of_saved_player)
  e.g. $0.50 / (10% x $10) = 0.5
save_rate is unknown: measure it with a holdout test (offer to half of high-risk players, not the other half).""")
