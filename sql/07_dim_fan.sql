-- Task 5: one row per resolved fan, built from analytics.fan_xref (written by src/resolve_fans.py).
-- Display fields come from the fan's lead record (the one its fan_id is built from), so an
-- account's details are used whenever the fan has an account.

DROP TABLE IF EXISTS analytics.dim_fan;

CREATE TABLE analytics.dim_fan AS
SELECT
    x.fan_id,
    lead.first_name,
    lead.last_name,
    lead.email,
    lead.zip_code,
    COUNT(*) FILTER (WHERE x.source = 'ACCOUNT') AS account_count,
    COUNT(*) FILTER (WHERE x.source = 'CONTEST_ENTRY') AS contest_entry_count,
    BOOL_OR(r.is_broker) AS is_broker
FROM analytics.fan_xref x
JOIN staging.identity_records r
    ON r.source = x.source AND r.source_id = x.source_id
JOIN staging.identity_records lead
    ON 'F-' || lead.record_key = x.fan_id
GROUP BY x.fan_id, lead.first_name, lead.last_name, lead.email, lead.zip_code;

ALTER TABLE analytics.dim_fan ADD PRIMARY KEY (fan_id);
