-- Staging layer: one view per ticketing source.
-- Each view reads raw (all TEXT) and only does light cleanup:
-- cast types, trim text, turn blanks into NULL, and add a few derived columns.
-- No rows are added or removed, so every view has the same row count as its raw table.
-- Views, not tables, so staging can never fall out of sync with raw.

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;


-- One row per event.
-- event_datetime_local is Boston time with no zone.
-- event_datetime_utc converts it once so later queries can compare it to UTC timestamps.
CREATE VIEW staging.stg_events AS
SELECT
    BTRIM(event_id) AS event_id,
    BTRIM(event_name) AS event_name,
    BTRIM(event_type) AS event_type,
    BTRIM(event_subtype) AS event_subtype,
    NULLIF(BTRIM(opponent), '') AS opponent,
    event_datetime_local::timestamp AS event_datetime_local,
    event_datetime_local::timestamp AT TIME ZONE 'America/New_York' AS event_datetime_utc,
    BTRIM(season) AS season,
    BTRIM(venue) AS venue
FROM raw.events;


-- One row per ticketing account.
-- email is kept as entered (trimmed). email_normalized is lowercase for matching in Task 5.
-- zip_code stays TEXT so leading zeros are not lost.
CREATE VIEW staging.stg_accounts AS
SELECT
    BTRIM(account_id) AS account_id,
    NULLIF(BTRIM(first_name), '') AS first_name,
    NULLIF(BTRIM(last_name), '') AS last_name,
    NULLIF(BTRIM(company_name), '') AS company_name,
    NULLIF(BTRIM(email), '') AS email,
    NULLIF(LOWER(BTRIM(email)), '') AS email_normalized,
    NULLIF(BTRIM(phone), '') AS phone,
    NULLIF(BTRIM(zip_code), '') AS zip_code,
    BTRIM(account_type) AS account_type,
    BTRIM(club_member) = 'Y' AS is_club_member,
    created_datetime_utc::timestamptz AS created_datetime_utc
FROM raw.accounts;


-- One row per change of ownership of a ticket.
-- section_type is the first word of section (LOGE, CLUB or BAL), used for seat-level reporting and Task 6.
-- seller is NULL on PRIMARY and buyer is NULL on REFUND, as the dictionary describes.
CREATE VIEW staging.stg_ticket_transactions AS
SELECT
    BTRIM(transaction_id) AS transaction_id,
    BTRIM(ticket_id) AS ticket_id,
    BTRIM(event_id) AS event_id,
    BTRIM(section) AS section,
    SPLIT_PART(BTRIM(section), ' ', 1) AS section_type,
    BTRIM("row") AS "row",
    BTRIM(seat) AS seat,
    BTRIM(transaction_type) AS transaction_type,
    NULLIF(BTRIM(seller_account_id), '') AS seller_account_id,
    NULLIF(BTRIM(buyer_account_id), '') AS buyer_account_id,
    price::numeric(10,2) AS price,
    fee::numeric(10,2) AS fee,
    transaction_datetime_utc::timestamptz AS transaction_datetime_utc,
    BTRIM(ticket_status) AS ticket_status
FROM raw.ticket_transactions;


-- One row per entry scan.
CREATE VIEW staging.stg_scans AS
SELECT
    BTRIM(scan_id) AS scan_id,
    BTRIM(ticket_id) AS ticket_id,
    BTRIM(event_id) AS event_id,
    BTRIM(gate) AS gate,
    scan_datetime_utc::timestamptz AS scan_datetime_utc,
    BTRIM(scan_result) AS scan_result
FROM raw.scans;
