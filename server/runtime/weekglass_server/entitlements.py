"""Resolve hosted write access from independent admin and paid periods."""
from dataclasses import dataclass
from datetime import datetime

from .protocol import now, stamp
from .settings import settings


@dataclass(frozen=True)
class Coverage:
    end: datetime | None
    paid_end: datetime | None
    plan_id: str | None


def coverage(conn, account, instant):
    grant = account['grant_until']
    end = grant if grant and grant > instant else None
    paid_end, plan_id = None, None
    for row in conn.execute('''SELECT p.start_at,p.end_at,o.plan_id FROM billing_periods p
          JOIN billing_orders o USING(checkout_id) WHERE p.account_id=%s AND p.revoked_at IS NULL
          AND p.end_at>%s ORDER BY p.start_at,p.end_at''', (account['account_id'], instant)):
        if row['start_at'] > (end or instant):
            break
        if paid_end is None or row['end_at'] > paid_end:
            paid_end, plan_id = row['end_at'], row['plan_id']
        end = max(end or instant, row['end_at'])
    return Coverage(end, paid_end, plan_id)


def entitlement(conn, account):
    free = settings.mode == 'self_hosted'
    rights = Coverage(None, None, None) if free else coverage(conn, account, now())
    if free:
        status = 'self_hosted'
    elif rights.end:
        status = 'active'
    elif account['grant_until'] is not None or conn.execute(
            'SELECT 1 FROM billing_periods WHERE account_id=%s LIMIT 1', (account['account_id'],)).fetchone():
        status = 'expired'
    else:
        status = 'not_subscribed'
    return {'mode': settings.mode, 'status': status, 'sync_read': True, 'sync_write': free or rights.end is not None,
            'export_allowed': True, 'current_period_end': stamp(rights.end) if rights.end else None,
            'retention_until': None, 'plan_id': rights.plan_id,
            'limits': {'max_devices': settings.max_devices, 'storage_bytes': settings.storage_bytes}}
