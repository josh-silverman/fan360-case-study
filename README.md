# Fan 360 Case Study

My solution to the TD Garden and Boston Bruins Data Engineer case study. It runs in a local Postgres 16 database, standing in for Redshift, and one script builds everything from the original CSV files.

## Requirements
- Docker with Compose (I tested with Colima on macOS)
- Python 3 (I tested with 3.11)
- Internet access on the first run, to download Postgres and one Python package
- Port 5433 free

## Run it
From the project folder:

```
./run.sh
```

It sets up Python, starts the database, loads the files, builds every table, runs the checks and exports the results. Near the end it prints 36 checks, and every one should say PASS. It is safe to run again, because every run rebuilds from the original files.

## Results
- `outputs/` has every final table as CSV, named by task. Empty cells are NULL, and booleans are `t` or `f`.
- `docs/` has a write-up for each task and `summary.docx`, the 1 to 2 page summary.

## Optional queries
Task 1 example queries, one listing's history and current listings by game:

```
docker exec -i fan360_db psql -U fan360 -d fan360 -f - < sql/listings_queries.sql
```

Task 6 fixed Pre-Arrival audience for EV1035:

```
{ echo "SET search_path = raw;"; cat sql/pre_arrival_audience_fixed.sql; } | docker exec -i fan360_db psql -U fan360 -d fan360 -q --csv -f -
```

To start over from an empty database, run `docker compose down -v`, then `./run.sh`.
