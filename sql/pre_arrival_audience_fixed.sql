-- ============================================================================
-- Pre-Arrival Guide audience (FIXED)
-- Builds one row per current ticket holder for a single event.
-- Holders with club_member_flag = 'Y' receive the Garden Club version of the
-- Pre-Arrival Guide; everyone else receives the standard version.
--
-- Change log
--   Summer 2026: club_member_flag now set to 'Y' when a ticket originated from
--                a Garden Club member account (requested by Marketing).
--   Oct 2026:    A ticket only counts toward the Garden Club version if its seat
--                is in a CLUB section AND it originated from a Garden Club member
--                account. Loge and Balcony tickets always get the standard
--                version (requested by Marketing). The only logic change is the
--                CASE in the final SELECT, which now also checks h.section.
--
-- Runs against the original source tables. Locally: SET search_path = raw;
-- To run for a different event, change the event_id in the params CTE.
-- ============================================================================
WITH params AS (
    SELECT 'EV1035' AS event_id
),

event_tx AS (
    SELECT t.*
    FROM ticket_transactions t
    JOIN params p ON t.event_id = p.event_id
),

-- Most recent transaction per ticket
latest AS (
    SELECT
        ticket_id,
        buyer_account_id,
        transaction_type,
        section,
        ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY transaction_datetime_utc DESC) AS rn
    FROM event_tx
),

current_holders AS (
    SELECT ticket_id, buyer_account_id AS holder_account_id, section
    FROM latest
    WHERE rn = 1
      AND transaction_type <> 'REFUND'
),

-- Account the ticket was originally sold to
origin AS (
    SELECT ticket_id, buyer_account_id AS original_account_id
    FROM event_tx
    WHERE transaction_type = 'PRIMARY'
)

SELECT
    h.holder_account_id,
    a.email,
    COUNT(*) AS tickets_held,
    -- A holder gets the club version if at least one of their tickets is a
    -- CLUB seat that originated from a Garden Club member account.
    MAX(CASE
            WHEN oa.club_member = 'Y'
             AND h.section LIKE 'CLUB %'
            THEN 'Y' ELSE 'N'
        END) AS club_member_flag
FROM current_holders h
JOIN origin o    ON o.ticket_id = h.ticket_id
JOIN accounts oa ON oa.account_id = o.original_account_id
JOIN accounts a  ON a.account_id = h.holder_account_id
GROUP BY h.holder_account_id, a.email
ORDER BY club_member_flag DESC, h.holder_account_id;
