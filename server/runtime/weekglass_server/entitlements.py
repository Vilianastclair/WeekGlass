"""Resolve hosted sync access and the separate post-expiry export allowance."""
from dataclasses import dataclass
from datetime import datetime, timedelta

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


def allow_sync(conn, account, *, instant=None):
    return settings.mode == 'self_hosted' or coverage(conn, account, instant or now()).end is not None


def last_service_end(conn, account, instant):
    """Final boundary of the latest ended coverage, called only while inactive.

    A refund can cut an active period short but cannot invent coverage for a
    future period or move the end of an already-expired period.
    """
    paid_end = conn.execute('''SELECT max(least(end_at,revoked_at)) AS ended_at FROM billing_periods
      WHERE account_id=%s AND least(end_at,revoked_at)<=%s AND least(end_at,revoked_at)>start_at''',
      (account['account_id'], instant)).fetchone()['ended_at']
    grant = account['grant_until']
    ends = (paid_end, grant if grant and grant <= instant else None)
    return max((end for end in ends if end is not None), default=None)


def set_grant(conn, account_id, days, instant):
    # When a live grant is removed, keep its actual end as the export boundary.
    # Removing a grant that never existed must not create an export allowance.
    return conn.execute('''UPDATE accounts SET grant_until=CASE
      WHEN %s>0 THEN %s WHEN grant_until>%s THEN %s ELSE grant_until END
      WHERE account_id=%s RETURNING grant_until''',
      (days, instant + timedelta(days=days), instant, instant, account_id)).fetchone()


def export_claim(conn, account_id, ended_at):
    if ended_at:
        return conn.execute('''SELECT * FROM calendar_export_claims WHERE account_id=%s AND ended_at=%s''',
                            (account_id, ended_at)).fetchone()
    return None


def entitlement(conn, account):
    instant = now()
    free = settings.mode == 'self_hosted'
    rights = Coverage(None, None, None) if free else coverage(conn, account, instant)
    can_sync = free or rights.end is not None
    ended_at, claim = None, None
    if free:
        status = 'self_hosted'
    elif rights.end:
        status = 'active'
    else:
        ended_at = last_service_end(conn, account, instant)
        status = 'expired' if ended_at else 'not_subscribed'
        claim = export_claim(conn, account['account_id'], ended_at)
    return {'mode': settings.mode, 'status': status, 'sync_read': can_sync, 'sync_write': can_sync,
            'export_allowed': can_sync or bool(ended_at and not (claim and claim['completed_at'])),
            'current_period_end': stamp(rights.end or ended_at) if rights.end or ended_at else None,
            'retention_until': None, 'plan_id': rights.plan_id,
            'limits': {'max_devices': settings.max_devices, 'storage_bytes': settings.storage_bytes}}, claim
