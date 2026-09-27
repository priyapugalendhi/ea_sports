# 3 Channel comparison: bootstrap 95% CIs (cross-check of the SQL normal-approximation CIs) + chart.
# Input : 3_channel_players.csv  (made by sql/3_channels.sql; one row per new player, installed Jan 1 - Mar 31)
# Output: 3_channels.png
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

df = pd.read_csv("3_channel_players.csv")
channels = ["organic", "paid_social", "paid_video"]

# Tier-adjusted mean = what a channel would score with the SAME tier mix as all players
weights = df.tier.value_counts(normalize=True).sort_index()
groups = {key: g for key, g in df.groupby(["channel", "tier"])}
rng = np.random.default_rng(42)          # fixed seed so the result can be reproduced

def adjusted(channel, col, resample=False):
    total = 0.0
    for tier, w in weights.items():
        x = groups[(channel, tier)][col].values
        if resample:                     # bootstrap: resample players with replacement, within each tier
            x = rng.choice(x, size=len(x), replace=True)
        total += w * x.mean()
    return total

print("Tier-adjusted differences with 95% bootstrap CIs (1,000 resamples)")
for col, label in [("rev30", "30-day revenue ($)"), ("active_days30", "active days in first 30")]:
    for a, b in [("organic", "paid_video"), ("organic", "paid_social"), ("paid_social", "paid_video")]:
        diff = adjusted(a, col) - adjusted(b, col)
        boot = [adjusted(a, col, True) - adjusted(b, col, True) for _ in range(1000)]
        lo, hi = np.percentile(boot, [2.5, 97.5])
        sig = "YES" if (lo > 0 or hi < 0) else "no"
        print(f"  {label:24s} {a:11s} - {b:11s}: {diff:+.3f}   95% CI [{lo:+.3f}, {hi:+.3f}]   significant: {sig}")

# Chart: raw vs tier-adjusted 30-day revenue per install
raw = df.groupby("channel").rev30.mean().reindex(channels)
adj = [adjusted(c, "rev30") for c in channels]
fig, ax = plt.subplots(figsize=(8, 4.5))
x = np.arange(len(channels))
ax.bar(x - 0.2, raw, width=0.4, color="#b0b7c3", label="Raw average")
ax.bar(x + 0.2, adj, width=0.4, color="#2a6fdb", label="Same tier mix (adjusted)")
for i in x:
    ax.text(i - 0.2, raw.iloc[i] + 0.04, f"${raw.iloc[i]:.2f}", ha="center")
    ax.text(i + 0.2, adj[i] + 0.04, f"${adj[i]:.2f}", ha="center")
ax.set_xticks(x)
ax.set_xticklabels(channels)
ax.set_ylabel("Revenue per install, first 30 days ($)")
ax.set_title("paid_video only looks worse because it buys Tier-4 players")
ax.legend(frameon=False)
ax.spines[["top", "right"]].set_visible(False)
plt.tight_layout()
plt.savefig("3_channels.png", dpi=150)
print("Saved: 3_channels.png")
