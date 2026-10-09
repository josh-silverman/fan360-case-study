-- Modeled layer, part 1: dimensions.
-- Dimensions describe the who and the what: the game and the account.
-- Built from the staging views with CREATE TABLE AS, then keys are added.

CREATE SCHEMA IF NOT EXISTS analytics;

-- The fact tables and ticket_lifecycle have foreign keys to these dimensions, so drop them first.
DROP TABLE IF EXISTS analytics.game_summary;
DROP TABLE IF EXISTS analytics.fan_summary;
DROP TABLE IF EXISTS analytics.ticket_lifecycle;
DROP TABLE IF EXISTS analytics.fct_scan;
DROP TABLE IF EXISTS analytics.fct_ticket_transaction;
DROP TABLE IF EXISTS analytics.dim_account;
DROP TABLE IF EXISTS analytics.dim_event;


-- One row per event.
-- is_bruins_game: every NHL event is a Bruins home game at TD Garden (preseason and regular season).
-- has_scan_data: FALSE for upcoming games and for EV1027, a past game with no scans.
--   Task 4 uses it to report attendance as unknown instead of 0%.
CREATE TABLE analytics.dim_event AS
SELECT
    e.event_id,
    e.event_name,
    e.event_type,
    e.event_subtype,
    e.opponent,
    e.season,
    e.venue,
    e.event_datetime_local,
    e.event_datetime_utc,
    e.event_type = 'NHL' AS is_bruins_game,
    EXISTS (
        SELECT 1 FROM staging.stg_scans s WHERE s.event_id = e.event_id
    ) AS has_scan_data
FROM staging.stg_events e;

ALTER TABLE analytics.dim_event ADD PRIMARY KEY (event_id);


-- One row per ticketing account. Task 5 adds a resolved fan_id on top of this.
CREATE TABLE analytics.dim_account AS
SELECT
    account_id,
    first_name,
    last_name,
    company_name,
    email,
    email_normalized,
    phone,
    zip_code,
    account_type,
    is_club_member,
    created_datetime_utc
FROM staging.stg_accounts;

ALTER TABLE analytics.dim_account ADD PRIMARY KEY (account_id);
