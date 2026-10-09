-- Raw layer: land each source CSV exactly as delivered.
-- Every column is TEXT so a bad value never blocks the load. Typing and cleaning happen in staging.
-- Listings files are not loaded here. They are handled by the Task 1 load process.

DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

CREATE TABLE raw.events (
    event_id text, event_name text, event_type text, event_subtype text,
    opponent text, event_datetime_local text, season text, venue text
);

CREATE TABLE raw.accounts (
    account_id text, first_name text, last_name text, company_name text, email text,
    phone text, zip_code text, account_type text, club_member text, created_datetime_utc text
);

CREATE TABLE raw.ticket_transactions (
    transaction_id text, ticket_id text, event_id text, section text, "row" text, seat text,
    transaction_type text, seller_account_id text, buyer_account_id text, price text, fee text,
    transaction_datetime_utc text, ticket_status text
);

CREATE TABLE raw.scans (
    scan_id text, ticket_id text, event_id text, gate text, scan_datetime_utc text, scan_result text
);

CREATE TABLE raw.contests (
    contest_id text, contest_name text, sponsor_name text, contest_type text,
    start_datetime_utc text, end_datetime_utc text
);

CREATE TABLE raw.contest_entries (
    entry_id text, contest_id text, entry_datetime_utc text, entrant_email text,
    entrant_first_name text, entrant_last_name text, entrant_zip text,
    question_id text, question_text text, response text
);

COPY raw.events              FROM '/data/events.csv'              WITH (FORMAT csv, HEADER true);
COPY raw.accounts            FROM '/data/accounts.csv'            WITH (FORMAT csv, HEADER true);
COPY raw.ticket_transactions FROM '/data/ticket_transactions.csv' WITH (FORMAT csv, HEADER true);
COPY raw.scans               FROM '/data/scans.csv'               WITH (FORMAT csv, HEADER true);
COPY raw.contests            FROM '/data/contests.csv'            WITH (FORMAT csv, HEADER true);
COPY raw.contest_entries     FROM '/data/contest_entries.csv'     WITH (FORMAT csv, HEADER true);
