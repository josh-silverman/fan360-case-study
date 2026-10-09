-- Modeled layer, part 2: facts.
-- Facts record things that happened: a ticket changing hands, a ticket being scanned.
-- Each flag below encodes a profiling finding so later tasks do not have to rediscover it.


-- One row per change of ownership of a ticket.
-- transaction_sequence: 1 = the PRIMARY sale, then 2, 3, ... in time order.
-- is_latest_transaction: the ticket's most recent row (status ACTIVE or REFUNDED).
--   The buyer on that row is the current owner.
-- is_double_sold_seat: this ticket's seat (event + section + row + seat) also belongs to another
--   ticket_id. Both tickets are kept because the data cannot say which is legitimate.
CREATE TABLE analytics.fct_ticket_transaction AS
WITH double_sold_seats AS (
    SELECT event_id, section, "row", seat
    FROM staging.stg_ticket_transactions
    GROUP BY event_id, section, "row", seat
    HAVING COUNT(DISTINCT ticket_id) > 1
)
SELECT
    t.transaction_id,
    t.ticket_id,
    t.event_id,
    t.section,
    t.section_type,
    t."row",
    t.seat,
    t.transaction_type,
    t.seller_account_id,
    t.buyer_account_id,
    t.price,
    t.fee,
    t.transaction_datetime_utc,
    t.ticket_status,
    ROW_NUMBER() OVER (
        PARTITION BY t.ticket_id
        ORDER BY t.transaction_datetime_utc
    ) AS transaction_sequence,
    t.ticket_status IN ('ACTIVE', 'REFUNDED') AS is_latest_transaction,
    d.event_id IS NOT NULL AS is_double_sold_seat
FROM staging.stg_ticket_transactions t
LEFT JOIN double_sold_seats d
    ON d.event_id = t.event_id
   AND d.section = t.section
   AND d."row" = t."row"
   AND d.seat = t.seat;

ALTER TABLE analytics.fct_ticket_transaction
    ADD PRIMARY KEY (transaction_id),
    ADD FOREIGN KEY (event_id) REFERENCES analytics.dim_event (event_id),
    ADD FOREIGN KEY (seller_account_id) REFERENCES analytics.dim_account (account_id),
    ADD FOREIGN KEY (buyer_account_id) REFERENCES analytics.dim_account (account_id);


-- One row per entry scan.
-- is_first_valid_scan: the first VALID scan of each ticket. Some tickets have a second VALID
--   scan about an hour later, so attendance counts use this flag, not scan rows.
-- is_refunded_ticket: the ticket's latest status is REFUNDED. Task 4 does not count these
--   scans as attendance.
CREATE TABLE analytics.fct_scan AS
WITH refunded_tickets AS (
    SELECT ticket_id
    FROM analytics.fct_ticket_transaction
    WHERE is_latest_transaction
      AND ticket_status = 'REFUNDED'
)
SELECT
    s.scan_id,
    s.ticket_id,
    s.event_id,
    s.gate,
    s.scan_datetime_utc,
    s.scan_result,
    s.scan_result = 'VALID'
        AND ROW_NUMBER() OVER (
            PARTITION BY s.ticket_id, s.scan_result
            ORDER BY s.scan_datetime_utc
        ) = 1 AS is_first_valid_scan,
    r.ticket_id IS NOT NULL AS is_refunded_ticket
FROM staging.stg_scans s
LEFT JOIN refunded_tickets r
    ON r.ticket_id = s.ticket_id;

ALTER TABLE analytics.fct_scan
    ADD PRIMARY KEY (scan_id),
    ADD FOREIGN KEY (event_id) REFERENCES analytics.dim_event (event_id);
