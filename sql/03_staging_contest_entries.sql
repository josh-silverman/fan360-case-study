-- Staging for the contest platform and for identity resolution (Task 5).
-- Same pattern as the ticketing staging views: read raw, clean types and text, never add or remove people.
-- Runs after 02_staging_views.sql, which creates the staging schema.


-- One row per contest.
CREATE VIEW staging.stg_contests AS
SELECT
    BTRIM(contest_id) AS contest_id,
    BTRIM(contest_name) AS contest_name,
    NULLIF(BTRIM(sponsor_name), '') AS sponsor_name,
    BTRIM(contest_type) AS contest_type,
    start_datetime_utc::timestamptz AS start_datetime_utc,
    end_datetime_utc::timestamptz AS end_datetime_utc
FROM raw.contests;


-- One row per contest entry (raw has one row per answer).
-- Entrant fields repeat on every answer row. ZIP is blank on one row for 605 entries,
-- so the entry's ZIP is its non-blank value.
CREATE VIEW staging.stg_contest_entrants AS
SELECT
    BTRIM(entry_id) AS entry_id,
    MIN(BTRIM(contest_id)) AS contest_id,
    MIN(entry_datetime_utc)::timestamptz AS entry_datetime_utc,
    MIN(BTRIM(entrant_email)) AS email,
    MIN(LOWER(BTRIM(entrant_email))) AS email_normalized,
    MIN(BTRIM(entrant_first_name)) AS first_name,
    MIN(BTRIM(entrant_last_name)) AS last_name,
    MAX(NULLIF(BTRIM(entrant_zip), '')) AS zip_code,
    COUNT(*) AS answer_rows
FROM raw.contest_entries
GROUP BY BTRIM(entry_id);


-- Nickname seed table. Only the 24 pairs seen under a shared email in this data.
-- Each nickname maps to the full first name, so "Drew" and "Andrew" compare as the same name.
CREATE TABLE staging.nickname_map (
    nickname TEXT PRIMARY KEY,
    canonical_first_name TEXT NOT NULL
);

INSERT INTO staging.nickname_map (nickname, canonical_first_name) VALUES
    ('matt', 'matthew'), ('chris', 'christopher'), ('dave', 'david'), ('jen', 'jennifer'),
    ('dan', 'daniel'), ('tom', 'thomas'), ('trish', 'patricia'), ('jack', 'john'),
    ('bob', 'robert'), ('tony', 'anthony'), ('kate', 'katherine'), ('jim', 'james'),
    ('nikki', 'nicole'), ('drew', 'andrew'), ('liz', 'elizabeth'), ('josh', 'joshua'),
    ('mike', 'michael'), ('joe', 'joseph'), ('rick', 'richard'), ('pat', 'patrick'),
    ('bill', 'william'), ('sue', 'susan'), ('meg', 'megan'), ('steve', 'steven');


-- One row per person record to resolve: every ticketing account and every contest entry,
-- with the normalized keys the matching rules compare.
-- record_key sorts accounts (A...) before entries (E...), so a fan's ID comes from an account when it has one.
CREATE VIEW staging.identity_records AS
WITH records AS (
    SELECT
        'ACCOUNT' AS source,
        account_id AS source_id,
        first_name,
        last_name,
        email,
        email_normalized,
        zip_code,
        REGEXP_REPLACE(phone, '[^0-9]', '', 'g') AS phone_digits,
        account_type = 'BROKER' AS is_broker
    FROM staging.stg_accounts
    UNION ALL
    SELECT
        'CONTEST_ENTRY',
        entry_id,
        first_name,
        last_name,
        email,
        email_normalized,
        zip_code,
        NULL,
        FALSE
    FROM staging.stg_contest_entrants
)
SELECT
    r.source,
    r.source_id,
    r.source_id AS record_key,
    r.first_name,
    r.last_name,
    r.email,
    r.zip_code,
    r.phone_digits,
    r.is_broker,
    COALESCE(n.canonical_first_name, LOWER(r.first_name)) AS first_name_match,
    LOWER(r.last_name) AS last_name_match,
    -- Gmail ignores dots before the @. Other domains are left as they are.
    CASE
        WHEN SPLIT_PART(r.email_normalized, '@', 2) = 'gmail.com'
        THEN REPLACE(SPLIT_PART(r.email_normalized, '@', 1), '.', '') || '@gmail.com'
        ELSE r.email_normalized
    END AS email_match
FROM records r
LEFT JOIN staging.nickname_map n
    ON n.nickname = LOWER(r.first_name);
