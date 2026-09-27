# 1(d) Chart: daily completed ad views, and views per daily active player.
# Input : 1d_daily_ad_views.csv  (made by sql/1d_ad_engagement.sql)
# Output: 1d_daily_ad_views.png
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

daily = pd.read_csv("1d_daily_ad_views.csv", parse_dates=["day"])

fig, ax = plt.subplots(2, 1, figsize=(11, 7), sharex=True)
ax[0].plot(daily.day, daily.completed_views, color="#2a6fdb")
ax[0].set_title("Completed rewarded-ad views per day")
ax[0].axvspan(pd.Timestamp("2026-03-05"), pd.Timestamp("2026-03-07"), color="red", alpha=0.15,
              label="Mar 5-6: no ad data (logging outage)")
ax[0].legend(loc="upper left", frameon=False)

ax[1].plot(daily.day, daily.views_per_dau, color="#444444")
ax[1].set_title("Completed ad views per daily active player (flat: growth is just more players)")
ax[1].axvspan(pd.Timestamp("2026-03-05"), pd.Timestamp("2026-03-07"), color="red", alpha=0.15)

for a in ax:
    a.spines[["top", "right"]].set_visible(False)
plt.tight_layout()
plt.savefig("1d_daily_ad_views.png", dpi=150)
print("Saved: 1d_daily_ad_views.png")
