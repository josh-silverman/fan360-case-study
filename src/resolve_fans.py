"""Task 5: assign one fan_id across ticketing accounts and contest entries.

Reads staging.identity_records (one row per account and per contest entry, with
normalized match keys) and links records that are the same person:

  R1  same email (Gmail dots removed) + same first name (nicknames mapped), and the last
      names agree when both are present (261 contest entries have no last name)
  R2  accounts only: same phone + same first name + same last name + same ZIP

Linked records are grouped with union-find, so if A matches B and B matches C, all
three get one fan_id. Every rule requires the same first and last name, so a chain
can never join two differently named people.

Possible matches that are NOT merged go to analytics.fan_match_review:
  POSSIBLE_SAME_PERSON  same first + last name + ZIP, but no shared email or phone
  HOUSEHOLD             same email, different first name

Writes analytics.fan_xref and analytics.fan_match_review. dim_fan is built in SQL afterwards.
"""
from collections import defaultdict

from db import connect


def find(parent, x):
    """Return the group leader for x, flattening the path as it goes."""
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x


def union(parent, a, b):
    """Put a and b in the same group. The smaller key leads, so IDs are stable across runs."""
    ra, rb = find(parent, a), find(parent, b)
    if ra != rb:
        parent[max(ra, rb)] = min(ra, rb)


def main():
    conn = connect()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT record_key, source, source_id, first_name_match, last_name_match,
               zip_code, email_match, phone_digits
        FROM staging.identity_records
        ORDER BY record_key
        """
    )
    records = cur.fetchall()

    parent = {r[0]: r[0] for r in records}
    rules_used = defaultdict(set)  # record_key -> rules that linked it to another record

    # Group records by each rule's key, then link everyone who shares a key.
    r1_groups = defaultdict(list)
    r2_groups = defaultdict(list)
    last_name = {}
    for key, source, _, first, last, zip_code, email, phone in records:
        last_name[key] = last
        r1_groups[(email, first)].append(key)
        if source == "ACCOUNT":
            r2_groups[(phone, first, last, zip_code)].append(key)

    def link(rule, keys):
        if len(keys) > 1:
            for k in keys:
                rules_used[k].add(rule)
            for k in keys[1:]:
                union(parent, keys[0], k)

    for keys in r1_groups.values():
        known_last_names = {last_name[k] for k in keys if last_name[k] is not None}
        if len(known_last_names) <= 1:
            # Last names agree, or are blank: same inbox and same first name.
            link("R1", keys)
        else:
            # Conflicting last names under one email (none in this data): only link exact
            # last-name matches, and leave blank last names unlinked.
            for name in known_last_names:
                link("R1", [k for k in keys if last_name[k] == name])

    for keys in r2_groups.values():
        link("R2", keys)

    # fan_id comes from the smallest record key in the group (accounts sort before entries).
    fan_of = {key: "F-" + find(parent, key) for key in parent}
    group_size = defaultdict(int)
    for fan in fan_of.values():
        group_size[fan] += 1

    xref_rows = []
    for key, source, source_id, *_ in records:
        fan = fan_of[key]
        if group_size[fan] == 1:
            rule, confidence = "NO_MATCH", "SINGLE_RECORD"
        else:
            rule, confidence = "+".join(sorted(rules_used[key])), "HIGH"
        xref_rows.append((source, source_id, fan, rule, confidence))

    # Review queue: pairs of different fans that look related but were not merged.
    review = set()
    by_name_zip = defaultdict(set)
    by_email = defaultdict(set)
    for key, _, _, first, last, zip_code, email, _ in records:
        if last is not None:
            by_name_zip[(first, last, zip_code)].add(fan_of[key])
        by_email[email].add(fan_of[key])
    for fans in by_name_zip.values():
        for a in fans:
            for b in fans:
                if a < b:
                    review.add((a, b, "POSSIBLE_SAME_PERSON", "Same first name, last name and ZIP, but no shared email or phone"))
    for fans in by_email.values():
        for a in fans:
            for b in fans:
                if a < b:
                    review.add((a, b, "HOUSEHOLD", "Same email, different first name"))

    cur.execute(
        """
        DROP TABLE IF EXISTS analytics.fan_xref;
        CREATE TABLE analytics.fan_xref (
            source TEXT NOT NULL,
            source_id TEXT NOT NULL,
            fan_id TEXT NOT NULL,
            match_rule TEXT NOT NULL,
            confidence TEXT NOT NULL,
            PRIMARY KEY (source, source_id)
        );
        DROP TABLE IF EXISTS analytics.fan_match_review;
        CREATE TABLE analytics.fan_match_review (
            fan_id_1 TEXT NOT NULL,
            fan_id_2 TEXT NOT NULL,
            review_reason TEXT NOT NULL,
            detail TEXT NOT NULL,
            PRIMARY KEY (fan_id_1, fan_id_2, review_reason)
        );
        """
    )
    cur.executemany("INSERT INTO analytics.fan_xref VALUES (%s, %s, %s, %s, %s)", xref_rows)
    cur.executemany("INSERT INTO analytics.fan_match_review VALUES (%s, %s, %s, %s)", sorted(review))
    conn.commit()
    conn.close()

    fans = len(group_size)
    merged = sum(1 for n in group_size.values() if n > 1)
    print(f"RESOLVED: {len(records)} records -> {fans} fans ({merged} with more than one record), "
          f"{len(review)} review pairs")


if __name__ == "__main__":
    main()
