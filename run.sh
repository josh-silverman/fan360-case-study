#!/usr/bin/env bash
# Run the full pipeline from scratch. Requires Docker.
set -euo pipefail
cd "$(dirname "$0")"

# Python environment for the loaders. Created once, reused after that.
if [ ! -d .venv ]; then
    python3 -m venv .venv
    .venv/bin/pip install -q -r requirements.txt
fi

docker compose up -d
until docker exec fan360_db psql -U fan360 -d fan360 -c 'select 1' >/dev/null 2>&1; do sleep 1; done

psql_run() { docker exec -i fan360_db psql -U fan360 -d fan360 -v ON_ERROR_STOP=1 -q -f - < "$1"; echo "ran $1"; }

psql_run sql/01_load_raw.sql
psql_run sql/02_staging_views.sql
psql_run sql/03_staging_contest_entries.sql

# Tasks 2, 3 and 5: modeled ticketing tables, ticket lifecycle, fan identity
psql_run sql/04_dimensions.sql
psql_run sql/05_facts.sql
psql_run sql/06_ticket_lifecycle.sql
.venv/bin/python src/resolve_fans.py
psql_run sql/07_dim_fan.sql

# Task 1: load the listings files in delivery order. Each later daily file is one more line.
psql_run sql/08_listings_tables.sql
.venv/bin/python src/load_listings.py data/listings_2026-09-20_full.csv
.venv/bin/python src/load_listings.py data/listings_2026-09-21_changes.csv

# Task 4: game and fan summaries (the game summary uses Task 1's current listings)
psql_run sql/09_game_summary.sql
psql_run sql/10_fan_summary.sql

# Checks for every modeled table. All should say PASS.
psql_run sql/11_checks.sql

# Export the final tables to outputs/ as CSV, sorted by key so every run gives identical files.
mkdir -p outputs
export_csv() {
    docker exec -i fan360_db psql -U fan360 -d fan360 -v ON_ERROR_STOP=1 -q \
        -c "\copy (SELECT * FROM $1 ORDER BY $2) TO STDOUT WITH CSV HEADER" > "outputs/$3.csv"
    echo "exported outputs/$3.csv"
}
export_csv analytics.listings_history       "listing_id, updated_at"       task1_listings_history
export_csv analytics.current_listings       "listing_id"                   task1_current_listings
export_csv analytics.dim_event              "event_id"                     task2_dim_event
export_csv analytics.dim_account            "account_id"                   task2_dim_account
export_csv analytics.fct_ticket_transaction "transaction_id"               task2_fct_ticket_transaction
export_csv analytics.fct_scan               "scan_id"                      task2_fct_scan
export_csv analytics.ticket_lifecycle       "ticket_id"                    task3_ticket_lifecycle
export_csv analytics.game_summary           "event_id"                     task4_game_summary
export_csv analytics.fan_summary            "fan_id"                       task4_fan_summary
export_csv analytics.fan_xref               "source, source_id"            task5_fan_xref
export_csv analytics.fan_match_review       "review_reason, fan_id_1, fan_id_2" task5_fan_match_review

# Task 6: holders whose Pre-Arrival flag changes for EV1035 (runs against the original raw tables).
{ echo "SET search_path = raw;"; cat sql/pre_arrival_flag_changes.sql; } \
    | docker exec -i fan360_db psql -U fan360 -d fan360 -v ON_ERROR_STOP=1 -q --csv -f - > outputs/task6_ev1035_flag_changes.csv
echo "exported outputs/task6_ev1035_flag_changes.csv"
