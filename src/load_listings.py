import csv
import os
import sys

from db import connect


EXPECTED_COLUMNS = [
    "listing_id",
    "event_id",
    "section",
    "row",
    "quantity",
    "price_per_ticket",
    "currency",
    "seller_type",
    "status",
    "listed_at",
    "updated_at",
    "extracted_at_utc",
]


def check_file(path):
    """Step 1: check the columns and the extract timestamp before loading anything."""

    if not os.path.isfile(path):
        raise FileNotFoundError(f"File not found: {path}")

    # utf-8-sig reads files with or without a byte-order mark the same way.
    with open(path, "r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)

        if reader.fieldnames != EXPECTED_COLUMNS:
            raise ValueError(
                f"Unexpected columns.\n"
                f"Expected: {EXPECTED_COLUMNS}\n"
                f"Found: {reader.fieldnames}"
            )

        extracted_values = set()
        row_count = 0

        for row in reader:
            row_count += 1

            extracted_at = row["extracted_at_utc"].strip()

            if not extracted_at:
                raise ValueError(
                    "File contains a blank extracted_at_utc value."
                )

            extracted_values.add(extracted_at)

        if len(extracted_values) != 1:
            raise ValueError(
                f"Expected exactly one extracted_at_utc value, "
                f"found {len(extracted_values)}."
            )

    return extracted_values.pop(), row_count


def check_load_control(conn, extracted_at_utc):
    """Step 2: check whether this extract was already loaded.

    Matches on extracted_at_utc only, not the filename, so the same extract
    resent under a new name is still skipped. Assumes the vendor never sends
    two different files with the same extract timestamp.

    Only LOADED counts as processed. A QUARANTINED file can be resent and
    loaded once the vendor corrects it.
    """

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT status
            FROM analytics.listings_load_control
            WHERE extracted_at_utc = %s
              AND status = 'LOADED'
            ORDER BY load_id DESC
            LIMIT 1;
            """,
            (extracted_at_utc,),
        )

        return cur.fetchone() is not None


def load_raw(conn, path, source_file):
    """Step 3: COPY the file into a temp table, then append it to raw."""

    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TEMP TABLE current_listings_batch (
                listing_id TEXT,
                event_id TEXT,
                section TEXT,
                "row" TEXT,
                quantity TEXT,
                price_per_ticket TEXT,
                currency TEXT,
                seller_type TEXT,
                status TEXT,
                listed_at TEXT,
                updated_at TEXT,
                extracted_at_utc TEXT,
                source_file TEXT,
                retry_quarantine_id BIGINT  -- set only for rows retried from quarantine
            ) ON COMMIT DROP;
            """
        )

        with open(path, "r", encoding="utf-8", newline="") as f:
            cur.copy_expert(
                """
                COPY current_listings_batch (
                    listing_id,
                    event_id,
                    section,
                    "row",
                    quantity,
                    price_per_ticket,
                    currency,
                    seller_type,
                    status,
                    listed_at,
                    updated_at,
                    extracted_at_utc
                )
                FROM STDIN
                WITH CSV HEADER;
                """,
                f,
            )

        cur.execute(
            "UPDATE current_listings_batch SET source_file = %s;",
            (source_file,),
        )

        cur.execute(
            """
            INSERT INTO raw.listings (
                listing_id,
                event_id,
                section,
                "row",
                quantity,
                price_per_ticket,
                currency,
                seller_type,
                status,
                listed_at,
                updated_at,
                extracted_at_utc,
                source_file
            )
            SELECT
                listing_id,
                event_id,
                section,
                "row",
                quantity,
                price_per_ticket,
                currency,
                seller_type,
                status,
                listed_at,
                updated_at,
                extracted_at_utc,
                source_file
            FROM current_listings_batch;
            """
        )


VENDOR_COLUMNS_SQL = """
    listing_id, event_id, section, "row", quantity, price_per_ticket,
    currency, seller_type, status, listed_at, updated_at, extracted_at_utc
"""


def stage_retries(conn):
    """Step 4 (first): add OPEN quarantine rows that failed only on an unknown event_id.

    The events table may have caught up since, so these rows go through the
    same dedupe, validation, and history steps as today's file.
    """

    with conn.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO current_listings_batch (
                {VENDOR_COLUMNS_SQL}, source_file, retry_quarantine_id
            )
            SELECT {VENDOR_COLUMNS_SQL}, source_file, quarantine_id
            FROM analytics.listings_quarantine
            WHERE quarantine_status = 'OPEN'
              AND quarantine_reason = 'unknown_event_id';
            """
        )
        return cur.rowcount


def deduplicate_rows(conn):
    """Step 4: remove exact duplicate rows (all 12 vendor columns match).

    Keeps one copy of each. If a file row and a retried row are identical,
    the file row is kept.
    """

    with conn.cursor() as cur:
        cur.execute(
            f"""
            DELETE FROM current_listings_batch
            WHERE ctid IN (
                SELECT ctid
                FROM (
                    SELECT
                        ctid,
                        ROW_NUMBER() OVER (
                            PARTITION BY {VENDOR_COLUMNS_SQL}
                            ORDER BY retry_quarantine_id NULLS FIRST
                        ) AS copy_number
                    FROM current_listings_batch
                ) copies
                WHERE copy_number > 1
            );
            """
        )
        return cur.rowcount


def quarantine_failed_rows(conn):
    """Save newly failed batch rows to listings_quarantine.

    New rows are inserted. A retried row that fails again updates its
    existing quarantine record instead of creating a duplicate.
    Returns the number of rows quarantined.
    """

    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE analytics.listings_quarantine q
            SET quarantine_reason = c.fail_reason,
                quarantined_at = CURRENT_TIMESTAMP
            FROM batch_checked c
            WHERE c.retry_quarantine_id = q.quarantine_id
              AND c.fail_reason IS NOT NULL
              AND NOT c.quarantined;
            """
        )

        cur.execute(
            f"""
            INSERT INTO analytics.listings_quarantine (
                {VENDOR_COLUMNS_SQL}, source_file, quarantine_reason
            )
            SELECT {VENDOR_COLUMNS_SQL}, source_file, fail_reason
            FROM batch_checked
            WHERE fail_reason IS NOT NULL
              AND NOT quarantined
              AND retry_quarantine_id IS NULL;
            """
        )

        cur.execute(
            """
            UPDATE batch_checked
            SET quarantined = TRUE
            WHERE fail_reason IS NOT NULL
              AND NOT quarantined;
            """
        )
        return cur.rowcount


def validate_and_quarantine_rows(conn):
    """Step 4: give each batch row a fail_reason (NULL = valid), then quarantine failures.

    Every CHECK and NOT NULL on analytics.listings_history has a rule here,
    so the history insert can never fail on a bad row. The first rule that
    fails is the reason. unknown_event_id is checked last, so a row is only
    retried later when the event is its only problem.
    """

    ts_format = r"'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"

    with conn.cursor() as cur:
        cur.execute(
            f"""
            CREATE TEMP TABLE batch_checked ON COMMIT DROP AS
            SELECT
                ROW_NUMBER() OVER () AS batch_row_id,
                b.*,
                CASE
                    WHEN COALESCE(BTRIM(b.listing_id), '') = '' THEN 'missing_listing_id'
                    WHEN COALESCE(BTRIM(b.event_id), '') = '' THEN 'missing_event_id'
                    WHEN COALESCE(BTRIM(b.section), '') = '' THEN 'missing_section'
                    WHEN COALESCE(BTRIM(b."row"), '') = '' THEN 'missing_row'
                    WHEN COALESCE(b.quantity, '') !~ '^[0-9]{{1,9}}$' THEN 'invalid_quantity'
                    WHEN b.quantity::integer = 0 THEN 'invalid_quantity'
                    WHEN COALESCE(b.status, '') NOT IN ('ACTIVE', 'SOLD', 'DELISTED') THEN 'invalid_status'
                    WHEN COALESCE(b.seller_type, '') NOT IN ('BROKER', 'FAN') THEN 'invalid_seller_type'
                    WHEN COALESCE(b.currency, '') <> 'USD' THEN 'invalid_currency'
                    WHEN NULLIF(BTRIM(b.price_per_ticket), '') IS NULL
                         AND b.status <> 'DELISTED' THEN 'missing_price'
                    WHEN NULLIF(BTRIM(b.price_per_ticket), '') IS NOT NULL
                         AND b.price_per_ticket !~ '^[0-9]{{1,10}}(\\.[0-9]+)?$' THEN 'invalid_price'
                    WHEN COALESCE(b.listed_at, '') !~ {ts_format} THEN 'invalid_listed_at'
                    WHEN COALESCE(b.updated_at, '') !~ {ts_format} THEN 'invalid_updated_at'
                    WHEN COALESCE(b.extracted_at_utc, '') !~ {ts_format} THEN 'invalid_extracted_at_utc'
                    WHEN b.listed_at::timestamptz > b.updated_at::timestamptz THEN 'listed_after_updated'
                    WHEN b.updated_at::timestamptz > b.extracted_at_utc::timestamptz THEN 'updated_after_extract'
                    -- Checked against raw.events. In production this would use the modeled events table.
                    WHEN NOT EXISTS (
                        SELECT 1 FROM raw.events e WHERE e.event_id = b.event_id
                    ) THEN 'unknown_event_id'
                END AS fail_reason,
                FALSE AS quarantined
            FROM current_listings_batch b;
            """
        )

    return quarantine_failed_rows(conn)


def quarantine_conflicts(conn):
    """Step 5: quarantine valid rows in this file that share listing_id + updated_at.

    Exact copies were already removed, so any key that still appears more
    than once has different values. The loader cannot tell which is right,
    so all rows for that key are quarantined.
    """

    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE batch_checked
            SET fail_reason = 'conflicting_version_in_file'
            WHERE fail_reason IS NULL
              AND (listing_id, updated_at) IN (
                  SELECT listing_id, updated_at
                  FROM batch_checked
                  WHERE fail_reason IS NULL
                  GROUP BY listing_id, updated_at
                  HAVING COUNT(*) > 1
              );
            """
        )

    return quarantine_failed_rows(conn)


def build_typed_batch(conn):
    """Cast the remaining valid rows to the listings_history types.

    Only rows that passed validation reach this point, so every cast is safe.
    """

    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TEMP TABLE batch_typed ON COMMIT DROP AS
            SELECT
                batch_row_id,
                listing_id,
                event_id,
                section,
                "row",
                quantity::integer AS quantity,
                NULLIF(BTRIM(price_per_ticket), '')::numeric(12,2) AS price_per_ticket,
                currency,
                seller_type,
                status,
                listed_at::timestamptz AS listed_at,
                updated_at::timestamptz AS updated_at,
                extracted_at_utc::timestamptz AS extracted_at_utc,
                source_file,
                retry_quarantine_id
            FROM batch_checked
            WHERE fail_reason IS NULL;
            """
        )


def quarantine_history_conflicts(conn):
    """Step 5: quarantine rows whose version key is already in history
    with different values.

    Compares the listing's own values only. extracted_at_utc and source_file
    are left out, because the same version resent in a later file is a
    duplicate, not a conflict.
    """

    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TEMP TABLE history_conflicts ON COMMIT DROP AS
            SELECT t.batch_row_id
            FROM batch_typed t
            JOIN analytics.listings_history h
              ON h.listing_id = t.listing_id
             AND h.updated_at = t.updated_at
            WHERE (h.event_id, h.section, h."row", h.quantity, h.price_per_ticket,
                   h.currency, h.seller_type, h.status, h.listed_at)
                  IS DISTINCT FROM
                  (t.event_id, t.section, t."row", t.quantity, t.price_per_ticket,
                   t.currency, t.seller_type, t.status, t.listed_at);
            """
        )
        cur.execute(
            """
            UPDATE batch_checked
            SET fail_reason = 'conflicts_with_history'
            WHERE batch_row_id IN (SELECT batch_row_id FROM history_conflicts);
            """
        )
        cur.execute(
            """
            DELETE FROM batch_typed
            WHERE batch_row_id IN (SELECT batch_row_id FROM history_conflicts);
            """
        )

    return quarantine_failed_rows(conn)


def load_history(conn):
    """Step 6: insert new versions into listings_history.

    A version already in history is skipped. After the conflict check, any
    existing key here has identical values, so skipping it is safe. This is
    what makes a reload idempotent. NOT EXISTS is used instead of
    ON CONFLICT because it also works in Redshift.
    """

    with conn.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO analytics.listings_history (
                {VENDOR_COLUMNS_SQL}, source_file
            )
            SELECT {VENDOR_COLUMNS_SQL}, source_file
            FROM batch_typed t
            WHERE NOT EXISTS (
                SELECT 1
                FROM analytics.listings_history h
                WHERE h.listing_id = t.listing_id
                  AND h.updated_at = t.updated_at
            );
            """
        )
        return cur.rowcount


def recompute_valid_to(conn):
    """Step 6: set valid_to = the next version's updated_at, for every listing in this batch.

    Recomputes across all of a listing's versions, so a late-arriving version
    that lands between two existing ones fixes its neighbors too. The newest
    version gets NULL. Only rows whose valid_to actually changes are updated.
    """

    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE analytics.listings_history h
            SET valid_to = n.next_updated_at
            FROM (
                SELECT
                    listing_id,
                    updated_at,
                    LEAD(updated_at) OVER (
                        PARTITION BY listing_id
                        ORDER BY updated_at
                    ) AS next_updated_at
                FROM analytics.listings_history
                WHERE listing_id IN (SELECT listing_id FROM batch_typed)
            ) n
            WHERE h.listing_id = n.listing_id
              AND h.updated_at = n.updated_at
              AND h.valid_to IS DISTINCT FROM n.next_updated_at;
            """
        )
        return cur.rowcount


def resolve_retried_rows(conn):
    """Mark retried quarantine rows RESOLVED once they made it through to history."""

    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE analytics.listings_quarantine
            SET quarantine_status = 'RESOLVED',
                resolved_at = CURRENT_TIMESTAMP
            WHERE quarantine_id IN (
                SELECT retry_quarantine_id
                FROM batch_typed
                WHERE retry_quarantine_id IS NOT NULL
            );
            """
        )
        return cur.rowcount


def record_load(conn, extracted_at_utc, source_file, row_count,
                inserted, quarantined, deduplicated):
    """Log the successful load in listings_load_control."""

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO analytics.listings_load_control (
                extracted_at_utc,
                source_file,
                status,
                rows_received,
                rows_loaded,
                rows_quarantined,
                rows_deduplicated
            )
            VALUES (%s, %s, 'LOADED', %s, %s, %s, %s);
            """,
            (extracted_at_utc, source_file, row_count,
             inserted, quarantined, deduplicated),
        )


def load_file(path):
    """Load one vendor file into listings_history (steps 1 to 6 in docs/task1_listings.md, one transaction)."""

    source_file = os.path.basename(path)

    conn = connect()

    try:
        # Step 1. A file that fails these checks is an intentional
        # QUARANTINED outcome: log it, commit, and stop. Other errors
        # (database down, bugs) fall through to the rollback below.
        try:
            extracted_at_utc, row_count = check_file(path)
        except ValueError as e:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO analytics.listings_load_control (
                        extracted_at_utc,
                        source_file,
                        status,
                        status_reason
                    )
                    VALUES (NULL, %s, 'QUARANTINED', %s);
                    """,
                    (source_file, str(e)),
                )

            conn.commit()
            print(f"QUARANTINED: {source_file} ({e})")
            return

        # Step 2
        if check_load_control(conn, extracted_at_utc):
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO analytics.listings_load_control (
                        extracted_at_utc,
                        source_file,
                        status,
                        rows_received
                    )
                    VALUES (%s, %s, 'SKIPPED', %s);
                    """,
                    (extracted_at_utc, source_file, row_count),
                )

            conn.commit()
            print(f"SKIPPED: {source_file}")
            return

        # Step 3
        load_raw(conn, path, source_file)

        # Steps 4 and 5: build the clean batch
        retried = stage_retries(conn)
        deduplicated = deduplicate_rows(conn)
        quarantined = validate_and_quarantine_rows(conn)
        conflicts = quarantine_conflicts(conn)
        build_typed_batch(conn)

        # Step 5 against history, then step 6: insert new versions
        conflicts += quarantine_history_conflicts(conn)
        inserted = load_history(conn)

        # Step 6: keep valid_to correct for every listing this batch touched
        valid_to_updates = recompute_valid_to(conn)
        resolved = resolve_retried_rows(conn)

        # Log the load
        record_load(conn, extracted_at_utc, source_file, row_count,
                    inserted, quarantined + conflicts, deduplicated)

        conn.commit()

        print(
            f"LOADED: {source_file} (extracted {extracted_at_utc}) "
            f"received={row_count} retried={retried} deduplicated={deduplicated} "
            f"quarantined={quarantined} conflicts={conflicts} "
            f"inserted={inserted} valid_to_updates={valid_to_updates} resolved={resolved}"
        )

    except Exception:
        conn.rollback()
        raise

    finally:
        conn.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(
            "Usage: .venv/bin/python src/load_listings.py <file>"
        )

    load_file(sys.argv[1])