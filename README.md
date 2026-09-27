# Analyst Intern Take-Home: Submission

All analysis is in **SQL** (`sql/`). Python (`python/`) is used only for the three things SQL cannot do: draw charts, bootstrap confidence intervals, and fit the churn model. The Python scripts read CSVs that the SQL writes, so there is one pipeline and one set of numbers.

## Where each part of the brief is answered

| Brief | Answer | Files |
|---|---|---|
| **5. Readout** (8 slides) + appendix for 1–4 | Deck | `PRIYA_EAsports.pptx` |
| **1. Get to know the data, in SQL** | 1(a)–1(d) + data-quality note | `sql/01_data_quality.sql`, `sql/1a_…` to `sql/1d_…`, `python/1d_ad_chart.py` |
| **2. Deep-dive** (chose **2a**, "ARPDAU is falling") | Mix shift to Tier 4, not a monetisation problem | `sql/2a_arpdau_mix.sql`, `python/2a_arpdau_chart.py` |
| **3. Acquisition channels** | Raw gap is an artefact; the real gap is too small to prove | `sql/3_channels.sql`, `python/3_bootstrap_and_chart.py` |
| **4. Churn prediction** | Logistic regression, time split, threshold rule | `sql/4_churn_dataset.sql`, `python/4_churn_model.py` |
| **4b. Value of a new install** (optional) | Not done, by choice (see "What I dropped") | — |

---

## How to run

Put the 5 CSVs (`player_profile.csv`, `player_day.csv`, `purchase.csv`, `currency_spend.csv`, `ad_view.csv`) in this top folder. They are not in the zip because you already have them.

**Install once** (Python 3.8+):

```
pip install duckdb-cli pandas numpy matplotlib scikit-learn
```

`duckdb-cli` gives the `duckdb` command (tested on v1.5.5). Alternatives: `winget install DuckDB.cli` (Windows), `brew install duckdb` (Mac).

**Run everything** from the top folder. On Windows you can simply double-click / run `run_all.bat`. Or type:

```
duckdb ea_sql.duckdb -c ".read sql/run_all.sql"
python python/1d_ad_chart.py
python python/2a_arpdau_chart.py
python python/3_bootstrap_and_chart.py
python python/4_churn_model.py
```

(On Mac use `python3`. The SQL step takes about 5-10 seconds and uses a database file, so it can spill to disk and runs even on low-memory laptops.)

**Step 1: SQL** runs every file below in order and writes the CSVs the Python scripts need:

| File | What it does | Writes |
|---|---|---|
| `00_load_and_clean.sql` | Loads CSVs; builds `purchase_clean`, `ad_view_clean`, `player_map`, `activity` | - |
| `01_data_quality.sql` | Every data-quality check quoted below | - |
| `1a_daily_health.sql` | DAU, gross revenue, ARPDAU, % payers, by day x platform | `1a_daily_health.csv` |
| `1b_retention.sql` | D1/D7/D14/D30 retention grid by install week | `1b_retention.csv` |
| `1c_spender_behaviour.sql` | Revenue concentration; time to first purchase; repeat gap (`LAG`) | - |
| `1d_ad_engagement.sql` | Cap-hit rate by cap value; daily ad views (needs 1a first) | `1d_daily_ad_views.csv` |
| `2a_arpdau_mix.sql` | ARPDAU by tier, mix decomposition, where installs came from | `2a_tier_compare.csv` |
| `3_channels.sql` | Channel comparison, tier-adjusted, 95% CI, sample size needed | `3_channels.csv`, `3_channel_players.csv` |
| `4_churn_dataset.sql` | Churn-window check; model dataset | `4_churn_data.csv` |

After one full run, any file can be run on its own, e.g. `duckdb ea_sql.duckdb -c ".read sql/1b_retention.sql"`.

**Step 2: Python** reads only the CSVs written by Step 1 (no database access, so no memory issues):

| Script | Output |
|---|---|
| `python/1d_ad_chart.py` | `1d_daily_ad_views.png` |
| `python/2a_arpdau_chart.py` | `2a_arpdau_mix.png` (main chart) |
| `python/3_bootstrap_and_chart.py` | bootstrap CIs + `3_channels.png` |
| `python/4_churn_model.py` | model results + threshold table |

---

## Data-quality issues and how each was handled

| # | Issue | Evidence | Handling |
|---|---|---|---|
| 1 | **Ad timestamps are 8 hours ahead** of every other table | All other tables have events only 06:00–23:59. Raw `ad_view` has 14:00–07:59: the same 18-hour window moved +8h. 271,176 completed ad views (51%) fall on a day the device was not active | Shift −8h. Unmatched views drop to **0**. Why exactly 8: shifts of 8–12h all give a 100% match, but only 8h puts the earliest event at 06:00 like every other table (9h+ would create 05:00 events, which never happen elsewhere). After the shift, `ad_daily_count` equals that day's event count on 100% of device-days, so the counter resets on the corrected day |
| 2 | **Ad logging outage, Mar 5–6** | 0 ad events on both days while ~5,000 players were active each day | Excluded from ad metrics and marked on the chart. Recommend reconciling ad-network billing for those days and alerting on sudden event drops |
| 3 | **Linked devices, including chains and a self-link** | 3,211 rows have `original_device_id`: 3,210 real links + 1 device linked to itself. 111 links are chains (C→B→A) | `player_map` follows each chain to its root with a recursive query: 80,295 devices → **77,085** people. (A one-step `COALESCE` gives 77,196, because it leaves the 111 chains split in two.) Used for DAU, revenue concentration and ARPDAU. Linked devices are excluded from retention cohorts, channel comparison and churn |
| 4 | **Duplicate purchase_ids** | 122 extra rows: same device and pack, minutes to hours apart | Keep the earliest row per `purchase_id` |
| 5 | **Refunds** stored as negative amounts | 228 rows, −$3,274.72; 224 match an earlier purchase | Gross revenue = positive rows only; refunds shown separately |
| 6 | **Purchases with no activity row that day** | 2,449 clean purchases (2,434 after merging linked devices), **all during sales** | A buyer counts as active that day. Otherwise % payers is overstated on sale days |
| 7 | **Installs before the window** | 16,000 devices installed before 2026-01-01 | Excluded from cohort-based analysis (their early life is not observed) |
| 8 | **First purchase before install** | 110 devices, 1–4 days early | Time to first purchase floored at day 0 |
| 9 | **"started" ad events** | 32,129 rows, never completed, reward 0 | Only `completed` counts as a view; every attempt counts toward the cap, because that is how the counter behaves |

---

## Key judgement calls

- **Grain.** Player-level metrics (DAU, revenue concentration, ARPDAU) use `player_map`, where one person = one id. Device-level metrics (retention cohorts, ad cap, churn) exclude linked devices, so each remaining device is one person.
- **1(a) Active** = a `player_day` row or a purchase that day. Cross-check: daily-table revenue = purchase-table revenue = **$217,593.22**. Platform is the platform of the device used that day.
- **1(b) Recent cohorts:** a cell is blank unless every player in the cohort had reached day N by Apr 30. A zero would read as "everyone quit", and a partial value mixes players with and without time to return.
- **1(c) Concentration** is shown both ways: payers only and all players.
- **2(a) Periods:** Jan 1–30 vs Apr 1–30.
- **3 Measures:** revenue = gross $ in the first 30 days after install; engagement = active days in the first 30 days. Installs Jan 1–Mar 31 only, so everyone has 30 full days. Channels are compared at the same tier mix. CIs use the normal approximation in SQL, cross-checked with a 1,000-sample bootstrap in Python; both agree.
- **4 Churn** = no active day in the 14 days after a weekly snapshot, for devices active in the 7 days before it. Split by time: train on snapshots Feb 1–Mar 8 (labels end Mar 22), test on Mar 29–Apr 16, so there is no leakage.

---

## Headline results

| | Result |
|---|---|
| 1(a) | iOS ARPDAU $0.50 vs Android $0.25; iOS payer rate 3.4% vs 1.7% |
| 1(b) | D1 ≈ 47%, D7 ≈ 25%, D14 ≈ 19%, D30 ≈ 14%, stable across cohorts. Weekly installs rose from ~2,200 to ~6,300 from late February |
| 1(c) | Payers only: top 1% / 10% / 50% = 9.2% / 47.6% / 89.9% of revenue. All players: 39.1% / 96.0% / 100%. Median first purchase = day 13; 82.1% of new players never pay (installs by Mar 31). Median repeat gap = 15.3 days |
| 1(d) | 0.96% of ad-watching days hit the cap (cap 5: 1.27%, cap 8: 0.02%). Cap-5 and cap-8 players make the same number of attempts, so the cap is not binding. Views per active player stay flat (~0.75–0.88) |
| 2(a) | ARPDAU $0.354 → $0.298 (−16%), yet every tier rose (+4% to +13%). Tier 4 went from 18% to 46% of DAU because of a March paid_video push (Tier-4 installs 1,772 → 16,807 a month). At January's mix, April ARPDAU would be $0.382 (+8%). Revenue rose from $29k to $84k |
| 3 | Raw: paid_video $1.54 vs organic $2.48 per install (30 days). That is an artefact: 65% of paid_video installs are Tier 4. Tier-adjusted: organic − paid_video = +$0.17 (95% CI −0.14 to +0.49), not significant; ~59k installs per channel would be needed. Engagement gaps are significant but small (+0.1 to +0.3 days a month) |
| 4 | ROC AUC 0.73, PR AUC 0.38 (base rate 0.19). Top risk decile churns 46%, bottom 4%. Weakest on new players (AUC 0.65). 92% of 14-day lapsers return within 45 days, so offers need a holdout test |

## Missing inputs, and how they would be used

- **Cost per install by channel × tier.** The Tier-4 video campaign pays back in 30 days only if CPI < ~$1.14.
- **Offer cost and save rate.** Target a player if p(churn) × save rate × value of a saved player > offer cost. Measure the save rate with a holdout test.
- **Ad revenue** from finance, to value ad engagement and the Mar 5–6 outage.

## What I dropped, and what I'd do with another week

- **4b** (90-day value from the first 7 days): not done. The difficulty is that only installs up to ~Jan 30 have 90 days observed.
- **Sales pull-forward:** the game runs 8 two-day sales exactly 15 days apart (Jan 8–9 … Apr 23–24), and the median repeat-purchase gap is 15.3 days. That suggests buyers wait for sales. I would test it by comparing purchases in the days before and after each sale.
#   e a _ s p o r t s  
 