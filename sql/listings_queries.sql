-- Task 1 analyst queries. These show the two use cases the listings design supports.
-- Run after ./run.sh has loaded the listings files.


-- 1. One listing's full price and status history.
-- Each row is one version of the listing. A version was true from valid_from
-- (the vendor's updated_at) until valid_to. valid_to is NULL on the newest version.
-- Change the listing_id to look at a different listing.
SELECT
    listing_id,
    event_id,
    section,
    "row",
    quantity,
    price_per_ticket,
    status,
    updated_at AS valid_from,
    valid_to,
    valid_to IS NULL AS is_latest_version,
    source_file
FROM analytics.listings_history
WHERE listing_id = 'L60001188'
ORDER BY valid_from;


-- 2. Current active resale listings by game.
-- Events drive the query (LEFT JOIN), so an upcoming game with zero current
-- listings still appears as one row with empty listing columns.
-- "Upcoming" means the game had not started as of the latest vendor extract.
-- event_datetime_local is Boston time, so it is converted to a real timestamp
-- in America/New_York before comparing to the UTC extract time.
WITH latest_extract AS (
    SELECT MAX(extracted_at_utc) AS as_of_utc
    FROM analytics.listings_load_control
    WHERE status = 'LOADED'
),
upcoming_games AS (
    SELECT
        e.event_id,
        e.event_name,
        e.event_datetime_local::timestamp AS event_datetime_local
    FROM raw.events e
    CROSS JOIN latest_extract x
    WHERE e.event_type = 'NHL'
      AND e.venue = 'TD Garden'
      AND (e.event_datetime_local::timestamp AT TIME ZONE 'America/New_York') > x.as_of_utc
)
SELECT
    g.event_id,
    g.event_name,
    g.event_datetime_local,
    c.listing_id,
    c.section,
    c."row",
    c.quantity,
    c.price_per_ticket,
    c.seller_type,
    c.listed_at,
    c.updated_at
FROM upcoming_games g
LEFT JOIN analytics.current_listings c
    ON c.event_id = g.event_id
ORDER BY g.event_datetime_local, c.section, c.price_per_ticket;
