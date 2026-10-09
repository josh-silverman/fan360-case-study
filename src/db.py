"""Shared Postgres connection for the pipeline scripts (boilerplate)."""
import os

import psycopg2


def connect():
    """Connect to the local fan360 database. Settings can be overridden with env vars."""
    return psycopg2.connect(
        host=os.getenv("FAN360_DB_HOST", "localhost"),
        port=int(os.getenv("FAN360_DB_PORT", "5433")),
        dbname=os.getenv("FAN360_DB_NAME", "fan360"),
        user=os.getenv("FAN360_DB_USER", "fan360"),
        password=os.getenv("FAN360_DB_PASSWORD", "fan360"),
    )
