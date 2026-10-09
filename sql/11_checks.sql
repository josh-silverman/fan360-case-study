-- Model checks for Tasks 2, 3, 4 and 5. One row per check with PASS or FAIL.
-- Three groups: grain (keys are unique), referential integrity (every reference
-- resolves), and row-count preservation (raw = staging = model).

WITH checks AS (

    -- Grain: each table's key is unique
    SELECT 'grain' AS check_group, 'dim_event: one row per event_id' AS check_name,
           COUNT(*) - COUNT(DISTINCT event_id) AS problems
    FROM analytics.dim_event
    UNION ALL
    SELECT 'grain', 'dim_account: one row per account_id',
           COUNT(*) - COUNT(DISTINCT account_id)
    FROM analytics.dim_account
    UNION ALL
    SELECT 'grain', 'fct_ticket_transaction: one row per transaction_id',
           COUNT(*) - COUNT(DISTINCT transaction_id)
    FROM analytics.fct_ticket_transaction
    UNION ALL
    SELECT 'grain', 'fct_scan: one row per scan_id',
           COUNT(*) - COUNT(DISTINCT scan_id)
    FROM analytics.fct_scan
    UNION ALL
    SELECT 'grain', 'fct_ticket_transaction: exactly one latest transaction per ticket',
           COUNT(*)
    FROM (
        SELECT ticket_id
        FROM analytics.fct_ticket_transaction
        GROUP BY ticket_id
        HAVING COUNT(*) FILTER (WHERE is_latest_transaction) <> 1
    ) t

    -- Referential integrity: every reference resolves
    UNION ALL
    SELECT 'integrity', 'transactions -> dim_event',
           COUNT(*)
    FROM analytics.fct_ticket_transaction t
    LEFT JOIN analytics.dim_event e ON e.event_id = t.event_id
    WHERE e.event_id IS NULL
    UNION ALL
    SELECT 'integrity', 'transactions -> dim_account (buyer)',
           COUNT(*)
    FROM analytics.fct_ticket_transaction t
    LEFT JOIN analytics.dim_account a ON a.account_id = t.buyer_account_id
    WHERE t.buyer_account_id IS NOT NULL AND a.account_id IS NULL
    UNION ALL
    SELECT 'integrity', 'transactions -> dim_account (seller)',
           COUNT(*)
    FROM analytics.fct_ticket_transaction t
    LEFT JOIN analytics.dim_account a ON a.account_id = t.seller_account_id
    WHERE t.seller_account_id IS NOT NULL AND a.account_id IS NULL
    UNION ALL
    SELECT 'integrity', 'scans -> dim_event',
           COUNT(*)
    FROM analytics.fct_scan s
    LEFT JOIN analytics.dim_event e ON e.event_id = s.event_id
    WHERE e.event_id IS NULL
    UNION ALL
    SELECT 'integrity', 'scans -> a ticket sold for the same event',
           COUNT(*)
    FROM analytics.fct_scan s
    WHERE NOT EXISTS (
        SELECT 1
        FROM analytics.fct_ticket_transaction t
        WHERE t.ticket_id = s.ticket_id
          AND t.event_id = s.event_id
    )

    -- Task 3: ticket_lifecycle
    UNION ALL
    SELECT 'lifecycle', 'ticket_lifecycle: one row per ticket_id',
           COUNT(*) - COUNT(DISTINCT ticket_id)
    FROM analytics.ticket_lifecycle
    UNION ALL
    SELECT 'lifecycle', 'ticket_lifecycle rows = distinct tickets in transactions',
           ABS((SELECT COUNT(*) FROM analytics.ticket_lifecycle)
             - (SELECT COUNT(DISTINCT ticket_id) FROM analytics.fct_ticket_transaction))
    UNION ALL
    SELECT 'lifecycle', 'sum of transaction_count = transaction rows',
           ABS((SELECT SUM(transaction_count) FROM analytics.ticket_lifecycle)
             - (SELECT COUNT(*) FROM analytics.fct_ticket_transaction))
    UNION ALL
    SELECT 'lifecycle', 'REFUNDED tickets = REFUND transactions',
           ABS((SELECT COUNT(*) FROM analytics.ticket_lifecycle WHERE ticket_status = 'REFUNDED')
             - (SELECT COUNT(*) FROM analytics.fct_ticket_transaction WHERE transaction_type = 'REFUND'))
    UNION ALL
    SELECT 'lifecycle', 'scanned tickets = first valid scans',
           ABS((SELECT COUNT(*) FROM analytics.ticket_lifecycle WHERE is_scanned)
             - (SELECT COUNT(*) FROM analytics.fct_scan WHERE is_first_valid_scan))
    UNION ALL
    SELECT 'lifecycle', 'original owner is never missing',
           COUNT(*)
    FROM analytics.ticket_lifecycle
    WHERE original_owner_account_id IS NULL
    UNION ALL
    SELECT 'lifecycle', 'current owner is missing exactly when REFUNDED',
           COUNT(*)
    FROM analytics.ticket_lifecycle
    WHERE (current_owner_account_id IS NULL) <> (ticket_status = 'REFUNDED')
    UNION ALL
    SELECT 'lifecycle', 'ACTIVE tickets never have a $0 or missing current price',
           COUNT(*)
    FROM analytics.ticket_lifecycle
    WHERE ticket_status = 'ACTIVE'
      AND COALESCE(current_price, 0) <= 0

    -- Task 5: fan identity
    UNION ALL
    SELECT 'identity', 'every account has exactly one fan_id',
           ABS((SELECT COUNT(*) FROM analytics.dim_account)
             - (SELECT COUNT(*) FROM analytics.fan_xref x
                JOIN analytics.dim_account a ON a.account_id = x.source_id
                WHERE x.source = 'ACCOUNT'))
    UNION ALL
    SELECT 'identity', 'every contest entry has exactly one fan_id',
           ABS((SELECT COUNT(*) FROM staging.stg_contest_entrants)
             - (SELECT COUNT(*) FROM analytics.fan_xref x
                JOIN staging.stg_contest_entrants e ON e.entry_id = x.source_id
                WHERE x.source = 'CONTEST_ENTRY'))
    UNION ALL
    SELECT 'identity', 'no fan mixes different last names',
           COUNT(*)
    FROM (
        SELECT x.fan_id
        FROM analytics.fan_xref x
        JOIN staging.identity_records r ON r.source = x.source AND r.source_id = x.source_id
        GROUP BY x.fan_id
        HAVING COUNT(DISTINCT r.last_name_match) > 1
    ) f
    UNION ALL
    SELECT 'identity', 'no fan mixes different first names (households stay apart)',
           COUNT(*)
    FROM (
        SELECT x.fan_id
        FROM analytics.fan_xref x
        JOIN staging.identity_records r ON r.source = x.source AND r.source_id = x.source_id
        GROUP BY x.fan_id
        HAVING COUNT(DISTINCT r.first_name_match) > 1
    ) f
    UNION ALL
    SELECT 'identity', 'dim_fan: one row per fan_id in fan_xref',
           ABS((SELECT COUNT(*) FROM analytics.dim_fan)
             - (SELECT COUNT(DISTINCT fan_id) FROM analytics.fan_xref))

    -- Task 4: game and fan summaries
    UNION ALL
    SELECT 'summaries', 'game_summary: one row per event in events.csv',
           ABS((SELECT COUNT(*) FROM analytics.game_summary) - (SELECT COUNT(*) FROM analytics.dim_event))
         + (SELECT COUNT(*) - COUNT(DISTINCT event_id) FROM analytics.game_summary)
    UNION ALL
    SELECT 'summaries', 'fan_summary: one row per fan in dim_fan',
           ABS((SELECT COUNT(*) FROM analytics.fan_summary) - (SELECT COUNT(*) FROM analytics.dim_fan))
         + (SELECT COUNT(*) - COUNT(DISTINCT fan_id) FROM analytics.fan_summary)
    UNION ALL
    SELECT 'summaries', 'tickets_sold adds up to all PRIMARY sales',
           ABS((SELECT SUM(tickets_sold) FROM analytics.game_summary)
             - (SELECT COUNT(*) FROM analytics.fct_ticket_transaction WHERE transaction_type = 'PRIMARY'))
    UNION ALL
    SELECT 'summaries', 'tickets_scanned adds up to scanned non-refunded tickets',
           ABS((SELECT SUM(tickets_scanned) FROM analytics.game_summary)
             - (SELECT COUNT(*) FROM analytics.ticket_lifecycle WHERE is_scanned AND ticket_status = 'ACTIVE'))
    UNION ALL
    SELECT 'summaries', 'game attendance_rate is NULL exactly when there is no scan data',
           COUNT(*)
    FROM analytics.game_summary
    WHERE (attendance_rate IS NULL) <> (NOT has_scan_data)
    UNION ALL
    SELECT 'summaries', 'attendance rates are between 0 and 1',
           (SELECT COUNT(*) FROM analytics.game_summary WHERE attendance_rate NOT BETWEEN 0 AND 1)
         + (SELECT COUNT(*) FROM analytics.fan_summary WHERE attendance_rate NOT BETWEEN 0 AND 1)
    UNION ALL
    SELECT 'summaries', 'fan tickets_purchased adds up to all PRIMARY and RESALE transactions',
           ABS((SELECT SUM(tickets_purchased) FROM analytics.fan_summary)
             - (SELECT COUNT(*) FROM analytics.fct_ticket_transaction WHERE transaction_type IN ('PRIMARY', 'RESALE')))
    UNION ALL
    SELECT 'summaries', 'fan total_spent adds up to price plus fee on all purchases',
           ABS((SELECT SUM(total_spent) FROM analytics.fan_summary)
             - (SELECT SUM(price + fee) FROM analytics.fct_ticket_transaction WHERE transaction_type IN ('PRIMARY', 'RESALE')))
    UNION ALL
    SELECT 'summaries', 'every ticketing account maps to a fan',
           COUNT(*)
    FROM analytics.dim_account a
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.fan_xref x WHERE x.source = 'ACCOUNT' AND x.source_id = a.account_id
    )

    -- Row-count preservation: no rows gained or lost between layers
    UNION ALL
    SELECT 'row counts', 'events: raw = staging = dim_event',
           ABS((SELECT COUNT(*) FROM raw.events) - (SELECT COUNT(*) FROM staging.stg_events))
         + ABS((SELECT COUNT(*) FROM raw.events) - (SELECT COUNT(*) FROM analytics.dim_event))
    UNION ALL
    SELECT 'row counts', 'accounts: raw = staging = dim_account',
           ABS((SELECT COUNT(*) FROM raw.accounts) - (SELECT COUNT(*) FROM staging.stg_accounts))
         + ABS((SELECT COUNT(*) FROM raw.accounts) - (SELECT COUNT(*) FROM analytics.dim_account))
    UNION ALL
    SELECT 'row counts', 'transactions: raw = staging = fct_ticket_transaction',
           ABS((SELECT COUNT(*) FROM raw.ticket_transactions) - (SELECT COUNT(*) FROM staging.stg_ticket_transactions))
         + ABS((SELECT COUNT(*) FROM raw.ticket_transactions) - (SELECT COUNT(*) FROM analytics.fct_ticket_transaction))
    UNION ALL
    SELECT 'row counts', 'scans: raw = staging = fct_scan',
           ABS((SELECT COUNT(*) FROM raw.scans) - (SELECT COUNT(*) FROM staging.stg_scans))
         + ABS((SELECT COUNT(*) FROM raw.scans) - (SELECT COUNT(*) FROM analytics.fct_scan))
)
SELECT
    check_group,
    check_name,
    problems,
    CASE WHEN problems = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
ORDER BY
    CASE check_group WHEN 'grain' THEN 1 WHEN 'integrity' THEN 2 WHEN 'row counts' THEN 3 WHEN 'lifecycle' THEN 4 WHEN 'identity' THEN 5 ELSE 6 END,
    check_name;
