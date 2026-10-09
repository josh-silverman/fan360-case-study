-- Task 4: fan summary. One row per resolved fan from Task 5 (dim_fan), for Tableau.
-- Every account column is mapped to fan_id through fan_xref, so a person with two accounts is one row.
-- A purchase is a PRIMARY or RESALE transaction.

DROP TABLE IF EXISTS analytics.fan_summary;

CREATE TABLE analytics.fan_summary AS
WITH account_fan AS (
    SELECT source_id AS account_id, fan_id
    FROM analytics.fan_xref
    WHERE source = 'ACCOUNT'
),
tx AS (
    SELECT
        t.*,
        e.event_datetime_utc,
        b.fan_id AS buyer_fan_id,
        s.fan_id AS seller_fan_id
    FROM analytics.fct_ticket_transaction t
    JOIN analytics.dim_event e ON e.event_id = t.event_id
    LEFT JOIN account_fan b ON b.account_id = t.buyer_account_id
    LEFT JOIN account_fan s ON s.account_id = t.seller_account_id
),
purchases AS (
    SELECT
        buyer_fan_id AS fan_id,
        COUNT(DISTINCT event_id) AS events_purchased,
        COUNT(*) AS tickets_purchased,
        SUM(price + fee) AS total_spent,
        -- "Typically" = median days between purchase and event start.
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM event_datetime_utc - transaction_datetime_utc) / 86400
        )::numeric, 1) AS median_days_in_advance,
        ROUND(AVG(EXTRACT(EPOCH FROM event_datetime_utc - transaction_datetime_utc) / 86400)::numeric, 1)
            AS avg_days_in_advance,
        MIN(transaction_datetime_utc) AS first_purchase_at,
        MAX(transaction_datetime_utc) AS last_purchase_at
    FROM tx
    WHERE transaction_type IN ('PRIMARY', 'RESALE')
    GROUP BY buyer_fan_id
),
seller_activity AS (
    -- The seller on a REFUND row is the holder who was refunded (amounts are negative).
    SELECT
        seller_fan_id AS fan_id,
        COALESCE(SUM(price + fee) FILTER (WHERE transaction_type = 'REFUND'), 0) AS total_refunded,
        COUNT(*) FILTER (WHERE transaction_type = 'RESALE') AS tickets_resold,
        COALESCE(SUM(price) FILTER (WHERE transaction_type = 'RESALE'), 0) AS resale_revenue,
        COUNT(*) FILTER (WHERE transaction_type = 'TRANSFER') AS tickets_transferred_out
    FROM tx
    WHERE seller_fan_id IS NOT NULL
    GROUP BY seller_fan_id
),
transfers_in AS (
    SELECT buyer_fan_id AS fan_id, COUNT(*) AS tickets_received_by_transfer
    FROM tx
    WHERE transaction_type = 'TRANSFER'
    GROUP BY buyer_fan_id
),
attendance AS (
    -- Tickets the fan held for games with scan data, refunded tickets excluded.
    -- The holder is whoever held the ticket when it was scanned, otherwise its current owner.
    SELECT
        a.fan_id,
        COUNT(*) AS tickets_held_for_scanned_games,
        COUNT(*) FILTER (WHERE l.is_scanned) AS tickets_attended
    FROM analytics.ticket_lifecycle l
    JOIN analytics.dim_event e ON e.event_id = l.event_id AND e.has_scan_data
    JOIN account_fan a ON a.account_id = COALESCE(l.holder_at_scan_account_id, l.current_owner_account_id)
    WHERE l.ticket_status = 'ACTIVE'
    GROUP BY a.fan_id
),
contests AS (
    SELECT
        x.fan_id,
        COUNT(*) AS contest_entries,
        COUNT(DISTINCT c.contest_id) AS contests_entered
    FROM analytics.fan_xref x
    JOIN staging.stg_contest_entrants c ON c.entry_id = x.source_id
    WHERE x.source = 'CONTEST_ENTRY'
    GROUP BY x.fan_id
),
memberships AS (
    SELECT
        af.fan_id,
        BOOL_OR(d.is_club_member) AS is_club_member,
        BOOL_OR(d.account_type = 'SEASON') AS is_season_member
    FROM account_fan af
    JOIN analytics.dim_account d ON d.account_id = af.account_id
    GROUP BY af.fan_id
)
SELECT
    f.fan_id,
    f.first_name,
    f.last_name,
    f.email,
    f.zip_code,
    f.account_count,
    f.is_broker,
    COALESCE(m.is_club_member, FALSE) AS is_club_member,
    COALESCE(m.is_season_member, FALSE) AS is_season_member,
    (p.fan_id IS NOT NULL OR s.fan_id IS NOT NULL OR ti.fan_id IS NOT NULL) AS has_ticket_activity,

    COALESCE(p.events_purchased, 0) AS events_purchased,
    COALESCE(p.tickets_purchased, 0) AS tickets_purchased,
    -- NULL when the fan held no tickets for a game with scan data.
    ROUND(att.tickets_attended::numeric / NULLIF(att.tickets_held_for_scanned_games, 0), 3) AS attendance_rate,
    COALESCE(att.tickets_held_for_scanned_games, 0) AS tickets_held_for_scanned_games,
    COALESCE(att.tickets_attended, 0) AS tickets_attended,
    p.median_days_in_advance,
    p.avg_days_in_advance,
    COALESCE(p.total_spent, 0) AS total_spent,
    COALESCE(s.total_refunded, 0) AS total_refunded,
    COALESCE(p.total_spent, 0) + COALESCE(s.total_refunded, 0) AS net_spent,
    COALESCE(s.tickets_resold, 0) AS tickets_resold,
    COALESCE(s.resale_revenue, 0) AS resale_revenue,
    COALESCE(s.tickets_transferred_out, 0) AS tickets_transferred_out,
    COALESCE(ti.tickets_received_by_transfer, 0) AS tickets_received_by_transfer,
    p.first_purchase_at,
    p.last_purchase_at,
    COALESCE(c.contest_entries, 0) AS contest_entries,
    COALESCE(c.contests_entered, 0) AS contests_entered
FROM analytics.dim_fan f
LEFT JOIN purchases p ON p.fan_id = f.fan_id
LEFT JOIN seller_activity s ON s.fan_id = f.fan_id
LEFT JOIN transfers_in ti ON ti.fan_id = f.fan_id
LEFT JOIN attendance att ON att.fan_id = f.fan_id
LEFT JOIN contests c ON c.fan_id = f.fan_id
LEFT JOIN memberships m ON m.fan_id = f.fan_id;

ALTER TABLE analytics.fan_summary ADD PRIMARY KEY (fan_id);
