-- Runs every SQL file in order. From the folder with the CSVs:
--   duckdb ea_sql.duckdb < sql/run_all.sql
.read sql/00_load_and_clean.sql
.read sql/01_data_quality.sql
.read sql/1a_daily_health.sql
.read sql/1b_retention.sql
.read sql/1c_spender_behaviour.sql
.read sql/1d_ad_engagement.sql
.read sql/2a_arpdau_mix.sql
.read sql/3_channels.sql
.read sql/4_churn_dataset.sql
