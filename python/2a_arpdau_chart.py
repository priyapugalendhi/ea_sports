# 2(a) Main chart: every tier's ARPDAU went up, but the tier mix shifted to Tier 4.
# Input : 2a_tier_compare.csv  (made by sql/2a_arpdau_mix.sql)
# Output: 2a_arpdau_mix.png
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

t = pd.read_csv("2a_tier_compare.csv").sort_values(["tier", "period"])
first = t[t.period == "1_first30"].set_index("tier")
last = t[t.period == "2_last30"].set_index("tier")

# Overall ARPDAU = share-weighted average of the tier ARPDAUs
overall_first = (first.arpdau * first.dau_share_pct / 100).sum()
overall_last = (last.arpdau * last.dau_share_pct / 100).sum()

labels = ["Tier 1", "Tier 2", "Tier 3", "Tier 4", "OVERALL"]
f_vals = list(first.arpdau) + [overall_first]
l_vals = list(last.arpdau) + [overall_last]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.5), gridspec_kw={"width_ratios": [3, 2]})
x = range(len(labels))
ax1.bar([i - 0.2 for i in x], f_vals, width=0.4, color="#b0b7c3", label="First 30 days (Jan)")
ax1.bar([i + 0.2 for i in x], l_vals, width=0.4, color="#2a6fdb", label="Last 30 days (Apr)")
for i in x:
    ch = 100 * (l_vals[i] / f_vals[i] - 1)
    ax1.text(i + 0.2, l_vals[i] + 0.01, f"{ch:+.0f}%", ha="center", fontsize=10, fontweight="bold",
             color="#1a7f37" if ch > 0 else "#c62828")
ax1.set_xticks(list(x))
ax1.set_xticklabels(labels)
ax1.set_ylabel("ARPDAU ($)")
ax1.set_title("Every tier's ARPDAU went UP, yet the overall went DOWN")
ax1.legend(frameon=False)

colors = ["#0b3d91", "#2a6fdb", "#7fa8e8", "#f28c28"]
for j, df in enumerate([first, last]):
    bottom = 0
    for k, tier in enumerate([1, 2, 3, 4]):
        share = df.loc[tier, "dau_share_pct"]
        ax2.bar(j, share, bottom=bottom, color=colors[k], width=0.6, label=f"Tier {tier}" if j == 0 else None)
        ax2.text(j, bottom + share / 2, f"{share:.0f}%", ha="center", va="center", color="white", fontsize=10)
        bottom += share
ax2.set_xticks([0, 1])
ax2.set_xticklabels(["First 30 days", "Last 30 days"])
ax2.set_ylabel("Share of active players (%)")
ax2.set_title("Because Tier 4 grew from 18% to 46% of players")
ax2.legend(frameon=False, loc="upper left", bbox_to_anchor=(1, 1))

for a in (ax1, ax2):
    a.spines[["top", "right"]].set_visible(False)
plt.tight_layout()
plt.savefig("2a_arpdau_mix.png", dpi=150)
print(f"Overall ARPDAU: {overall_first:.4f} -> {overall_last:.4f} ({100*(overall_last/overall_first-1):+.1f}%)")
print("Saved: 2a_arpdau_mix.png")
