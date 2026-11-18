from contextlib import contextmanager
import os
from pathlib import Path
from threading import BoundedSemaphore
import psycopg
from psycopg.rows import dict_row
from .migrations import (migrate_billing, migrate_billing_plan_periods, migrate_operator_order_checks,
                         migrate_provider_checkout, migrate_provider_reconcile, migrate_sleep_schedule)
from .settings import settings

_slots = BoundedSemaphore(7)


@contextmanager
def connect():
    if not _slots.acquire(timeout=5):
        raise psycopg.OperationalError('Database connection capacity exceeded')
    try:
        kwargs = {'connect_timeout': 5, 'row_factory': dict_row,
                  'options': '-c statement_timeout=30000 -c lock_timeout=10000 -c timezone=UTC'}
        if settings.database_url:
            conn = psycopg.connect(settings.database_url, **kwargs)
        else:
            conn = psycopg.connect(host=os.environ.get('DB_HOST', 'db'), port=int(os.environ.get('DB_PORT', '5432')),
                dbname=os.environ.get('DB_NAME', 'weekglass'), user=os.environ.get('DB_USER', 'weekglass'),
                password=Path(os.environ['DB_PASSWORD_FILE']).read_text().strip(), **kwargs)
        with conn:
            yield conn
    finally:
        _slots.release()


def init_schema():
    with connect() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('weekglass_schema'))")
        conn.execute('''
          CREATE TABLE IF NOT EXISTS accounts (
            account_id uuid PRIMARY KEY, dataset_id uuid NOT NULL, sync_epoch uuid NOT NULL,
            commit_seq bigint NOT NULL DEFAULT 0, retention_floor bigint NOT NULL DEFAULT 0,
            grant_until timestamptz, created_at timestamptz NOT NULL DEFAULT now());
          CREATE TABLE IF NOT EXISTS event_heads (
            account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
            event_id text NOT NULL, revision bigint NOT NULL, record jsonb NOT NULL,
            payload_bytes integer NOT NULL, PRIMARY KEY(account_id,event_id));
          CREATE TABLE IF NOT EXISTS receipts (
            account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
            batch_id uuid NOT NULL, request_hash text NOT NULL, receipt jsonb NOT NULL,
            PRIMARY KEY(account_id,batch_id));
          CREATE TABLE IF NOT EXISTS mutation_ids (
            account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
            mutation_id uuid NOT NULL, batch_id uuid NOT NULL, PRIMARY KEY(account_id,mutation_id));
          CREATE TABLE IF NOT EXISTS changes (
            account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
            seq bigint NOT NULL, batch jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
            payload_bytes integer NOT NULL, PRIMARY KEY(account_id,seq));
          CREATE TABLE IF NOT EXISTS snapshots (
            snapshot_id uuid PRIMARY KEY, account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
            dataset_id uuid NOT NULL, sync_epoch uuid NOT NULL, boundary bigint NOT NULL,
            expires_at timestamptz NOT NULL);
          CREATE INDEX IF NOT EXISTS snapshots_account ON snapshots(account_id);
          CREATE TABLE IF NOT EXISTS snapshot_records (
            snapshot_id uuid NOT NULL REFERENCES snapshots(snapshot_id) ON DELETE CASCADE,
            event_id text NOT NULL, record jsonb NOT NULL, PRIMARY KEY(snapshot_id,event_id));
          CREATE TABLE IF NOT EXISTS sync_acks (
            account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
            device_id uuid NOT NULL, seq bigint NOT NULL, PRIMARY KEY(account_id,device_id));
        ''')
        migrate_billing(conn)
        migrate_billing_plan_periods(conn)
        migrate_provider_checkout(conn)
        migrate_provider_reconcile(conn)
        migrate_operator_order_checks(conn)
        migrate_sleep_schedule(conn)
