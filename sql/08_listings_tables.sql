-- Build the raw listings landing table, load-control table,
-- quarantine table, cleaned history table, and current-listings view.

CREATE SCHEMA IF NOT EXISTS analytics;

-- The drops let ./run.sh rebuild the local project from scratch. In production these
-- tables are created once and never dropped. Each daily file is loaded with src/load_listings.py.
DROP VIEW IF EXISTS analytics.current_listings;
DROP TABLE IF EXISTS analytics.listings_history;
DROP TABLE IF EXISTS analytics.listings_quarantine;
DROP TABLE IF EXISTS analytics.listings_load_control;
DROP TABLE IF EXISTS raw.listings;


-- 1. Raw vendor data
-- Preserves the vendor's values exactly as received.
CREATE TABLE raw.listings (
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
    source_file TEXT NOT NULL,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- 2. File-level load tracking
-- Multiple log entries can exist for the same file/extract
-- (for example, LOADED followed by SKIPPED).
CREATE TABLE analytics.listings_load_control (
    load_id BIGSERIAL PRIMARY KEY,
    extracted_at_utc TIMESTAMPTZ,
    source_file TEXT NOT NULL,
    status TEXT NOT NULL,
    status_reason TEXT,
    rows_received INTEGER NOT NULL DEFAULT 0,
    rows_loaded INTEGER NOT NULL DEFAULT 0,
    rows_quarantined INTEGER NOT NULL DEFAULT 0,
    rows_deduplicated INTEGER NOT NULL DEFAULT 0,
    warning_count INTEGER NOT NULL DEFAULT 0,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CHECK (status IN ('LOADED', 'QUARANTINED', 'SKIPPED'))
);


-- 3. Rows that could not be loaded
CREATE TABLE analytics.listings_quarantine (
    quarantine_id BIGSERIAL PRIMARY KEY,
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
    source_file TEXT NOT NULL,
    quarantine_reason TEXT NOT NULL,
    quarantine_status TEXT NOT NULL DEFAULT 'OPEN',
    quarantined_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMPTZ,

    CHECK (quarantine_status IN ('OPEN', 'RESOLVED'))
);


-- 4. Clean listing history
CREATE TABLE analytics.listings_history (
    listing_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    section TEXT NOT NULL,
    "row" TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    price_per_ticket NUMERIC(12,2),
    currency TEXT NOT NULL,
    seller_type TEXT NOT NULL,
    status TEXT NOT NULL,
    listed_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    extracted_at_utc TIMESTAMPTZ NOT NULL,
    source_file TEXT NOT NULL,
    valid_to TIMESTAMPTZ,

    PRIMARY KEY (listing_id, updated_at),

    CHECK (quantity > 0),
    CHECK (price_per_ticket IS NULL OR price_per_ticket >= 0),
    CHECK (price_per_ticket IS NOT NULL OR status = 'DELISTED'),
    CHECK (status IN ('ACTIVE', 'DELISTED', 'SOLD')),
    CHECK (seller_type IN ('BROKER', 'FAN')),
    CHECK (currency = 'USD'),
    CHECK (listed_at <= updated_at),
    CHECK (updated_at <= extracted_at_utc),
    CHECK (valid_to IS NULL OR valid_to > updated_at)
);


-- 5. Current active listings
CREATE VIEW analytics.current_listings AS
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
    extracted_at_utc
FROM analytics.listings_history
WHERE valid_to IS NULL
  AND status = 'ACTIVE';