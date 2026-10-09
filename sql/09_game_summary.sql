-- Task 4: game summary. One row per event in events.csv (75), for Tableau.
-- A purchase is a PRIMARY or RESALE transaction.
-- Buyers are counted as fans through Task 5's fan_xref, so a person with two accounts counts once.

DROP TABLE IF EXISTS analytics.game_summary;

CREATE TABLE analytics.game_summary AS
WITH account_fan AS (
    SELECT x.source_id AS account_id, x.fan_id, f.is_broker
    FROM analytics.fan_xref x
    JOIN analytics.dim_fan f ON f.fan_id = x.fan_id
    WHERE x.source = 'ACCOUNT'
),
tx AS (
    SELECT
        t.event_id,
        t.ticket_id,
        t.transaction_type,
        t.price,
        t.transaction_datetime_utc,
        e.event_datetime_utc,
        b.fan_id AS buyer_fan_id,
        b.is_broker AS buyer_is_broker
    FROM analytics.fct_ticket_transaction t
    JOIN analytics.dim_event e ON e.event_id = t.event_id
    LEFT JOIN account_fan b ON b.account_id = t.buyer_account_id
),
tx_metrics AS (
    SELECT
        tx.event_id,
        COUNT(*) FILTER (WHERE transaction_type = 'PRIMARY') AS tickets_sold,
        COUNT(*) FILTER (WHERE transaction_type = 'REFUND') AS tickets_refunded,
        -- Brokers buy to resell, so they are not counted as fans.
        COUNT(DISTINCT buyer_fan_id) FILTER (
            WHERE transaction_type IN ('PRIMARY', 'RESALE') AND NOT buyer_is_broker
        ) AS unique_fans_bought,
        COUNT(*) FILTER (
            WHERE transaction_type = 'PRIMARY'
              AND transaction_datetime_utc >= event_datetime_utc - INTERVAL '7 days'
        ) AS tickets_sold_last_7_days,
        COUNT(*) FILTER (
            WHERE transaction_type = 'RESALE'
              AND transaction_datetime_utc >= event_datetime_utc - INTERVAL '7 days'
        ) AS resales_last_7_days,
        COUNT(*) FILTER (WHERE transaction_type = 'RESALE') AS resale_count,
        COUNT(*) FILTER (WHERE transaction_type = 'TRANSFER') AS transfer_count,
        SUM(price) FILTER (WHERE transaction_type = 'PRIMARY') AS primary_revenue,
        ROUND(AVG(price) FILTER (WHERE transaction_type = 'PRIMARY'), 2) AS avg_original_price,
        ROUND(AVG(price) FILTER (WHERE transaction_type = 'RESALE'), 2) AS avg_resale_price,
        -- Each resale compared to that ticket's own face price, then averaged. 1.15 = 15% above face.
        ROUND(AVG(tx.price / NULLIF(l.original_price, 0)) FILTER (WHERE transaction_type = 'RESALE'), 3)
            AS avg_resale_to_original_ratio
    FROM tx
    JOIN analytics.ticket_lifecycle l ON l.ticket_id = tx.ticket_id
    GROUP BY tx.event_id
),
ticket_metrics AS (
    SELECT
        event_id,
        -- Scanned = a valid scan on a ticket that was not refunded.
        COUNT(*) FILTER (WHERE is_scanned AND ticket_status = 'ACTIVE') AS tickets_scanned,
        COUNT(*) FILTER (WHERE is_double_sold_seat) AS double_sold_tickets
    FROM analytics.ticket_lifecycle
    GROUP BY event_id
),
listing_metrics AS (
    -- Task 1: what is listed on the resale market right now (only upcoming games have listings).
    SELECT
        event_id,
        COUNT(*) AS current_listings,
        ROUND(AVG(price_per_ticket), 2) AS avg_current_listing_price
    FROM analytics.current_listings
    GROUP BY event_id
)
SELECT
    e.event_id,
    e.event_name,
    e.event_type,
    e.event_subtype,
    e.opponent,
    e.season,
    e.event_datetime_local,
    e.is_bruins_game,
    e.has_scan_data,

    COALESCE(m.tickets_sold, 0) AS tickets_sold,
    COALESCE(m.tickets_refunded, 0) AS tickets_refunded,
    COALESCE(m.tickets_sold, 0) - COALESCE(m.tickets_refunded, 0) AS net_tickets_sold,
    COALESCE(m.unique_fans_bought, 0) AS unique_fans_bought,
    COALESCE(k.tickets_scanned, 0) AS tickets_scanned,
    -- NULL when the game has no scan data (EV1027 and upcoming games), not 0%.
    CASE
        WHEN e.has_scan_data
        THEN ROUND(k.tickets_scanned::numeric / NULLIF(m.tickets_sold - m.tickets_refunded, 0), 3)
    END AS attendance_rate,
    COALESCE(m.tickets_sold_last_7_days, 0) AS tickets_sold_last_7_days,
    COALESCE(m.resales_last_7_days, 0) AS resales_last_7_days,
    m.avg_resale_to_original_ratio,
    m.avg_original_price,
    m.avg_resale_price,
    COALESCE(m.resale_count, 0) AS resale_count,
    COALESCE(m.transfer_count, 0) AS transfer_count,
    COALESCE(m.primary_revenue, 0) AS primary_revenue,
    COALESCE(k.double_sold_tickets, 0) AS double_sold_tickets,
    COALESCE(lm.current_listings, 0) AS current_listings,
    lm.avg_current_listing_price
FROM analytics.dim_event e
LEFT JOIN tx_metrics m ON m.event_id = e.event_id
LEFT JOIN ticket_metrics k ON k.event_id = e.event_id
LEFT JOIN listing_metrics lm ON lm.event_id = e.event_id;

ALTER TABLE analytics.game_summary ADD PRIMARY KEY (event_id);
