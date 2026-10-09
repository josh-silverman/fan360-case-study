-- Task 3: ticket lifecycle. One row per ticket_id.
-- Collapses each ticket's history in fct_ticket_transaction (1 to 5 rows) into one row:
-- who bought it first, who holds it now, what it first cost, what it last sold for,
-- how many times it changed hands, and whether it was scanned.

DROP TABLE IF EXISTS analytics.ticket_lifecycle;

CREATE TABLE analytics.ticket_lifecycle AS
WITH first_tx AS (
    -- The PRIMARY sale. Every ticket has exactly one, and it is always first.
    SELECT ticket_id, buyer_account_id, price, transaction_datetime_utc
    FROM analytics.fct_ticket_transaction
    WHERE transaction_sequence = 1
),
latest_tx AS (
    -- The ticket's most recent transaction (ACTIVE or REFUNDED).
    SELECT ticket_id, event_id, section, section_type, "row", seat,
           transaction_type, buyer_account_id, ticket_status,
           transaction_datetime_utc, is_double_sold_seat
    FROM analytics.fct_ticket_transaction
    WHERE is_latest_transaction
),
last_paid AS (
    -- The most recent price someone actually paid. Transfers are $0 and
    -- refunds are negative, so only PRIMARY and RESALE count.
    SELECT DISTINCT ON (ticket_id) ticket_id, price
    FROM analytics.fct_ticket_transaction
    WHERE transaction_type IN ('PRIMARY', 'RESALE')
    ORDER BY ticket_id, transaction_sequence DESC
),
counts AS (
    SELECT
        ticket_id,
        COUNT(*) AS transaction_count,
        COUNT(*) FILTER (WHERE transaction_type = 'RESALE') AS resale_count,
        COUNT(*) FILTER (WHERE transaction_type = 'TRANSFER') AS transfer_count
    FROM analytics.fct_ticket_transaction
    GROUP BY ticket_id
),
first_scan AS (
    -- One row per scanned ticket. is_first_valid_scan already ignores re-entries.
    SELECT ticket_id, scan_datetime_utc
    FROM analytics.fct_scan
    WHERE is_first_valid_scan
)
SELECT
    l.ticket_id,
    l.event_id,
    l.section,
    l.section_type,
    l."row",
    l.seat,

    f.buyer_account_id AS original_owner_account_id,
    f.price AS original_price,
    f.transaction_datetime_utc AS original_purchase_at,

    -- A refunded ticket is void, so it has no current owner or price.
    l.ticket_status,
    CASE WHEN l.ticket_status = 'REFUNDED' THEN NULL ELSE l.buyer_account_id END AS current_owner_account_id,
    CASE WHEN l.ticket_status = 'REFUNDED' THEN NULL ELSE p.price END AS current_price,
    CASE
        WHEN l.ticket_status = 'REFUNDED' THEN NULL
        ELSE ROUND((p.price - f.price) / NULLIF(f.price, 0) * 100, 1)
    END AS price_change_pct,

    c.transaction_count,
    c.resale_count,
    c.transfer_count,
    l.transaction_type AS last_transaction_type,
    l.transaction_datetime_utc AS last_transaction_at,

    s.ticket_id IS NOT NULL AS is_scanned,
    s.scan_datetime_utc AS first_scan_at,
    -- Who held the ticket when it was scanned: the buyer on the latest transaction
    -- before the scan. Differs from the current owner for 4 tickets.
    (
        SELECT t.buyer_account_id
        FROM analytics.fct_ticket_transaction t
        WHERE t.ticket_id = s.ticket_id
          AND t.transaction_datetime_utc <= s.scan_datetime_utc
        ORDER BY t.transaction_sequence DESC
        LIMIT 1
    ) AS holder_at_scan_account_id,

    l.is_double_sold_seat
FROM latest_tx l
JOIN first_tx f ON f.ticket_id = l.ticket_id
JOIN last_paid p ON p.ticket_id = l.ticket_id
JOIN counts c ON c.ticket_id = l.ticket_id
LEFT JOIN first_scan s ON s.ticket_id = l.ticket_id;

ALTER TABLE analytics.ticket_lifecycle
    ADD PRIMARY KEY (ticket_id),
    ADD FOREIGN KEY (event_id) REFERENCES analytics.dim_event (event_id),
    ADD FOREIGN KEY (original_owner_account_id) REFERENCES analytics.dim_account (account_id),
    ADD FOREIGN KEY (current_owner_account_id) REFERENCES analytics.dim_account (account_id),
    ADD FOREIGN KEY (holder_at_scan_account_id) REFERENCES analytics.dim_account (account_id);
