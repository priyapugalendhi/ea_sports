@echo off
REM Run from this folder, with the 5 CSV files placed here.
duckdb ea_sql.duckdb -c ".read sql/run_all.sql"
python python\1d_ad_chart.py
python python\2a_arpdau_chart.py
python python\3_bootstrap_and_chart.py
python python\4_churn_model.py
pause
