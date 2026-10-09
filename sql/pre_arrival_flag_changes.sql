-- Task 6: which EV1035 holders' flags change between the original and fixed audience SQL.
-- Uses the same CTEs as both versions, then applies the old rule and the new rule side by
-- side, so the only difference between the two flag columns is the section check.
-- Locally: SET search_path = raw;  Output: one row per holder whose flag changed.

WITH params AS (
    SELECT 'EV1035' AS event_id
),
event_tx AS (
    SELECT t.* FROM ticket_transactions t JOIN params p ON t.event_id = p.event_id
),
latest AS (
    SELECT ticket_id, buyer_account_id, transaction_type, section,
           ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY transaction_datetime_utc DESC) AS rn
    FROM event_tx
),
current_holders AS (
    SELECT ticket_id, buyer_account_id AS holder_account_id, section
    FROM latest
    WHERE rn = 1 AND transaction_type <> 'REFUND'
),
origin AS (
    SELECT ticket_id, buyer_account_id AS original_account_id
    FROM event_tx
    WHERE transaction_type = 'PRIMARY'
),
flags AS (
    SELECT
        h.holder_account_id,
        a.email,
        COUNT(*) AS tickets_held,
        -- Original rule: any ticket that originated from a club member account
        MAX(CASE WHEN oa.club_member = 'Y' THEN 'Y' ELSE 'N' END) AS old_flag,
        -- Fixed rule: a CLUB seat that originated from a club member account
        MAX(CASE WHEN oa.club_member = 'Y' AND h.section LIKE 'CLUB %' THEN 'Y' ELSE 'N' END) AS new_flag,
        STRING_AGG(h.section || CASE WHEN oa.club_member = 'Y' THEN ' (from club acct)' ELSE '' END,
                   '; ' ORDER BY h.section) AS seats_held,
        MAX(a.club_member) AS holder_is_club_member
    FROM current_holders h
    JOIN origin o    ON o.ticket_id = h.ticket_id
    JOIN accounts oa ON oa.account_id = o.original_account_id
    JOIN accounts a  ON a.account_id = h.holder_account_id
    GROUP BY h.holder_account_id, a.email
)
SELECT holder_account_id, email, tickets_held, old_flag, new_flag, holder_is_club_member, seats_held
FROM flags
WHERE old_flag <> new_flag
ORDER BY holder_account_id;
