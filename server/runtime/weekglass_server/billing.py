"""Hosted billing ledger. External calls belong in an approved provider adapter."""
from dataclasses import dataclass
from datetime import datetime, timedelta
import os
from typing import Protocol
from urllib.parse import urlsplit
from uuid import UUID, uuid4

from psycopg.errors import UniqueViolation
from psycopg.types.json import Jsonb

from .db import connect
from .entitlements import coverage
from .protocol import now, problem, stamp
from .settings import settings

OFFICIAL_ORIGIN = 'https://cloud.viliana.cn'
WAFFO_TEST_PROVIDER = 'waffo_pancake_test'
WAFFO_LIVE_PROVIDER = 'waffo_pancake'
PERIOD_SECONDS = 30 * 24 * 60 * 60
ANNUAL_PERIOD_SECONDS = 365 * 24 * 60 * 60
MONTHLY_PLAN_ID = 'cloud-30d'
MONTHLY_TERMS = 'waffo-cny-30d-v1'
UNRESOLVED = ('pending', 'submitting', 'processing')
IN_FLIGHT = ('submitting', 'processing')


@dataclass(frozen=True)
class VerifiedEvent:
    """Minimal, normalized result of provider verification or authenticated query."""
    event_id: str
    kind: str
    provider: str
    merchant_id: str
    app_id: str
    related_id: UUID  # checkout_id or agreement_id, assigned by WeekGlass
    occurred_at: datetime
    external_id: str | None = None  # provider payment or agreement ID
    amount_minor: int | None = None
    currency: str | None = None
    template_id: str | None = None
    agreement_expires_at: datetime | None = None
    merchant_refund_id: str | None = None
    provider_refund_id: str | None = None
    provider_product_id: str | None = None


class ProviderAdapter(Protocol):
    provider: str
    merchant_id: str
    app_id: str

    def verify_event(self, headers: dict[str, str], raw: bytes) -> VerifiedEvent:
        """Verify provider identity, signature, timestamp and encryption before normalizing."""
        ...


@dataclass(frozen=True)
class BillingPlan:
    plan_id: str
    terms_version: str
    amount_minor: int
    currency: str = 'CNY'
    period_seconds: int = PERIOD_SECONDS
    provider_product_id: str | None = None
    checkout_enabled: bool = True

    def __post_init__(self):
        if (type(self.amount_minor) is not int or not 0 < self.amount_minor <= 2147483647
                or self.currency != 'CNY' or self.period_seconds not in (PERIOD_SECONDS, ANNUAL_PERIOD_SECONDS)
                or not 1 <= len(self.plan_id) <= 64 or not 1 <= len(self.terms_version) <= 64):
            raise ValueError('Invalid WeekGlass billing plan')


@dataclass(frozen=True)
class BillingConfig:
    adapter: ProviderAdapter
    plans: tuple[BillingPlan, ...]
    checkout_enabled: bool = False
    auto_renew_enabled: bool = False
    template_id: str | None = None
    sandbox_origin: str | None = None
    pilot_account_id: UUID | None = None

    def __post_init__(self):
        live = self.adapter.provider == WAFFO_LIVE_PROVIDER
        if (not self.plans or len({plan.plan_id for plan in self.plans}) != len(self.plans)
                or not all(self.scope) or (self.auto_renew_enabled and not self.template_id)
                or (not live and (len(self.plans) != 1 or self.plans[0].period_seconds != PERIOD_SECONDS))):
            raise ValueError('Invalid WeekGlass billing configuration')
        if ((self.adapter.provider == WAFFO_TEST_PROVIDER) != (self.sandbox_origin is not None)
                or (self.sandbox_origin and (self.auto_renew_enabled or not sandbox_database(self.sandbox_origin)))):
            raise ValueError('Waffo test checkout requires an isolated loopback test database')
        if live and (
                self.auto_renew_enabled or self.template_id or settings.mode != 'hosted'
                or settings.public_origin != OFFICIAL_ORIGIN
                or any(not plan.provider_product_id for plan in self.plans)):
            raise ValueError('Waffo live checkout requires official hosted one-time billing')

    def plan(self, plan_id):
        return next((plan for plan in self.plans if plan.plan_id == plan_id), None)

    @property
    def scope(self):
        return self.adapter.provider, self.adapter.merchant_id, self.adapter.app_id

    @property
    def origin(self):
        return self.sandbox_origin or OFFICIAL_ORIGIN


def sandbox_database(origin):
    parsed = urlsplit(origin)
    return (settings.mode == 'hosted' and settings.public_origin == origin and not settings.alternate_origins
            and parsed.hostname == '127.0.0.1' and parsed.scheme == 'http' and parsed.port is not None
            and not settings.database_url and os.environ.get('DB_HOST') == '127.0.0.1'
            and os.environ.get('DB_NAME', '').endswith('_test'))


def billing_capabilities(config):
    if settings.mode != 'hosted':
        return []
    flags = ['subscription']
    if checkout_available(config) and any(plan.checkout_enabled for plan in config.plans):
        flags.append('billing_checkout')
        if config.auto_renew_enabled:
            flags.append('billing_auto_renew')
    return flags


def has_confirmed_waffo_payment(conn, account_id):
    """Mail access comes from a retained Waffo Live payment, not write access.

    A genuine former subscriber can still recover their account to renew it.
    A fully refunded, test, administrative, or merely pending order cannot
    issue mail. Order and period must belong to the same account.
    """
    return settings.mode == 'hosted' and bool(conn.execute('''SELECT 1 FROM billing_periods p
        JOIN billing_orders o ON o.checkout_id=p.checkout_id AND o.account_id=p.account_id
        WHERE p.account_id=%s AND p.revoked_at IS NULL AND o.provider=%s
          AND o.source='checkout' AND o.purchase_mode='single' AND o.status IN ('paid','refund_pending')
          AND NOT o.refund_required AND o.provider_payment_id IS NOT NULL AND o.paid_at IS NOT NULL
        LIMIT 1''', (account_id, WAFFO_LIVE_PROVIDER)).fetchone())


def needs_paid_email_verification(conn, account_id):
    if settings.mode != 'hosted':
        return False
    pending = conn.execute('''SELECT 1 FROM auth_accounts
        WHERE account_id=%s AND enabled AND verified_email IS NULL''', (account_id,)).fetchone()
    return bool(pending and has_confirmed_waffo_payment(conn, account_id))


def checkout_available(config, account_id=None):
    return bool(config and config.checkout_enabled and settings.mode == 'hosted'
                and settings.public_origin == config.origin
                and (not config.sandbox_origin or sandbox_database(config.origin))
                and (account_id is None or config.pilot_account_id in (None, account_id)))


def offers(config, *, account_id=None):
    if not checkout_available(config, account_id):
        return []
    modes = ['single', 'auto_renew'] if config.auto_renew_enabled else ['single']
    return [{'plan_id': plan.plan_id, 'terms_version': plan.terms_version, 'provider': config.scope[0],
             'amount_minor': plan.amount_minor, 'currency': plan.currency, 'period_seconds': plan.period_seconds,
             'purchase_modes': modes} for plan in config.plans if plan.checkout_enabled]


def _slot(conn, account_id, cycle_end):
    row = None
    if cycle_end:
        row = conn.execute('SELECT * FROM billing_renewals WHERE account_id=%s AND cycle_end=%s',
                           (account_id, cycle_end)).fetchone()
    if row:
        return row
    return conn.execute('''INSERT INTO billing_renewals(renewal_id,account_id,cycle_end,status)
      VALUES (%s,%s,%s,'skipped') RETURNING *''', (uuid4(), account_id, cycle_end)).fetchone()


def _insert_order(conn, account_id, slot, agreement, config, plan, instant, source, mode):
    oid = uuid4()
    order = conn.execute('''INSERT INTO billing_orders(checkout_id,account_id,renewal_id,agreement_id,source,
      purchase_mode,provider,merchant_id,app_id,plan_id,terms_version,amount_minor,currency,period_seconds,
      provider_product_id,status,created_at)
      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *''',
      (oid, account_id, slot['renewal_id'], agreement, source, mode, *config.scope, plan.plan_id,
       plan.terms_version, plan.amount_minor, plan.currency, plan.period_seconds, plan.provider_product_id,
       'pending' if source == 'checkout' else 'submitting', instant)).fetchone()
    conn.execute("UPDATE billing_renewals SET order_id=%s,status='reserved' WHERE renewal_id=%s",
                 (oid, slot['renewal_id']))
    return order


def create_checkout(conn, account, config, key, intent):
    """Reserve under the account lock; idempotency is the account and original intent."""
    account_id = account['account_id']
    existing = conn.execute('''SELECT o.*,k.requested_terms_version FROM billing_checkout_keys k
      JOIN billing_orders o USING(checkout_id) WHERE k.account_id=%s AND k.idempotency_key=%s''',
      (account_id, key)).fetchone()
    plan_id, mode, terms = intent['plan_id'], intent['purchase_mode'], intent.get('terms_version')
    expected = UUID(intent['expected_checkout_id']) if intent.get('expected_checkout_id') else None
    if existing:
        if expected is not None and existing['checkout_id'] != expected:
            problem(409, 'idempotency_key_reused')
        if (plan_id, mode, terms) != (existing['plan_id'], existing['purchase_mode'], existing['requested_terms_version']):
            problem(409, 'idempotency_key_reused')
        return existing
    if mode == 'auto_renew' and not config.auto_renew_enabled:
        problem(409, 'auto_renew_unavailable')
    instant = now()
    if expected is not None:
        order = conn.execute('SELECT * FROM billing_orders WHERE account_id=%s AND checkout_id=%s',
                             (account_id, expected)).fetchone()
        if (not order or order['source'] != 'checkout' or not same_scope(order, config)
                or (order['plan_id'], order['purchase_mode']) != (plan_id, mode)):
            problem(409, 'billing_order_unresolved')
        if terms is not None and terms != order['terms_version']:
            problem(409, 'billing_terms_changed')
    else:
        if not any(plan.checkout_enabled for plan in config.plans):
            problem(503, 'billing_not_configured')
        plan = config.plan(plan_id)
        if not plan or not plan.checkout_enabled:
            problem(404, 'billing_plan_unavailable')
        if terms is not None and terms != plan.terms_version:
            problem(409, 'billing_terms_changed')
        order = conn.execute('''SELECT * FROM billing_orders WHERE account_id=%s AND status=ANY(%s)''',
                             (account_id, list(UNRESOLVED))).fetchone()
        if order and (order['source'] != 'checkout' or mode != order['purchase_mode']
                      or not _same_quote(order, config, plan)):
            problem(409, 'billing_order_unresolved')
    if not order:
        if _has_future_period(conn, account_id, instant):
            problem(409, 'billing_period_already_reserved')
        agreement = None
        if mode == 'auto_renew':
            conn.execute("""UPDATE billing_agreements SET status='expired' WHERE account_id=%s
              AND status='active' AND expires_at<=%s""", (account_id, instant))
            if _open_agreement(conn, account_id):
                problem(409, 'billing_agreement_open')
            agreement = uuid4()
            conn.execute('''INSERT INTO billing_agreements(agreement_id,account_id,provider,merchant_id,app_id,
              plan_id,terms_version,template_id,amount_minor,currency,period_seconds,status,consented_at)
              VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'pending',%s)''',
              (agreement, account_id, *config.scope, plan.plan_id, plan.terms_version, config.template_id,
               plan.amount_minor, plan.currency, plan.period_seconds, instant))
        slot = _slot(conn, account_id, coverage(conn, account, instant).end)
        if slot['status'] in ('reserved', 'settled'):
            problem(409, 'billing_order_unresolved')
        order = _insert_order(conn, account_id, slot, agreement, config, plan, instant, 'checkout', mode)
    conn.execute('''INSERT INTO billing_checkout_keys(account_id,idempotency_key,checkout_id,requested_terms_version)
      VALUES (%s,%s,%s,%s)''', (account_id, key, order['checkout_id'], terms))
    return order


def same_scope(row, config):
    return (row['provider'], row['merchant_id'], row['app_id']) == config.scope


def live_order_product_id(adapter, row):
    # Pre-migration live rows all used the original 30-day SKU. Only those old
    # rows lack a product ID; keep that SKU configured for their reconciliation.
    if row.get('provider_product_id'):
        return row['provider_product_id']
    if (row.get('plan_id'), row.get('terms_version'), row.get('period_seconds')) == (
            MONTHLY_PLAN_ID, MONTHLY_TERMS, PERIOD_SECONDS):
        return adapter.product_id
    return None


def _same_quote(row, config, plan):
    return (same_scope(row, config) and (row['plan_id'], row['terms_version'], row['amount_minor'],
            row['currency'], row['period_seconds']) == (plan.plan_id, plan.terms_version, plan.amount_minor,
                                                       plan.currency, plan.period_seconds)
            and (config.scope[0] != WAFFO_LIVE_PROVIDER
                 or live_order_product_id(config.adapter, row) == plan.provider_product_id))


def _open_agreement(conn, account_id):
    return conn.execute('''SELECT * FROM billing_agreements WHERE account_id=%s
      AND status IN ('pending','active','canceling')''', (account_id,)).fetchone()


def lock_account(conn, account_id):
    return conn.execute('SELECT * FROM accounts WHERE account_id=%s FOR UPDATE', (account_id,)).fetchone()


def _enabled(conn, account):
    return bool(account and conn.execute('SELECT 1 FROM auth_accounts WHERE account_id=%s AND enabled',
                                         (account['account_id'],)).fetchone())


def _has_future_period(conn, account_id, instant):
    return bool(conn.execute('''SELECT 1 FROM billing_periods WHERE account_id=%s AND revoked_at IS NULL
      AND start_at>%s LIMIT 1''', (account_id, instant)).fetchone())


def _lock_target(conn, table, key, target_id):
    # Fixed table/column names supplied by callers. Follow account → ledger lock order,
    # including when deletion detaches finance records during the initial read.
    lookup = f'SELECT * FROM {table} WHERE {key}=%s'
    row = conn.execute(lookup, (target_id,)).fetchone()
    account = lock_account(conn, row['account_id']) if row and row['account_id'] else None
    return account, conn.execute(lookup + ' FOR UPDATE', (target_id,)).fetchone() if row else None


def claim_checkout(config, checkout_id):
    """Internal adapter hook: reserve submission before any external provider call."""
    with connect() as conn:
        account, order = _lock_target(conn, 'billing_orders', 'checkout_id', checkout_id)
        if (not _enabled(conn, account)
                or not checkout_payable(conn, order, config)):
            return None
        if config.adapter.provider == WAFFO_LIVE_PROVIDER:
            return conn.execute('''UPDATE billing_orders SET status='submitting',provider_next_check_at=%s
              WHERE checkout_id=%s RETURNING *''', (now() + timedelta(seconds=40), checkout_id)).fetchone()
        return conn.execute("UPDATE billing_orders SET status='submitting' WHERE checkout_id=%s RETURNING *",
                            (checkout_id,)).fetchone()


def checkout_quote_available(order, config):
    if not order or order['source'] != 'checkout' or not checkout_available(config, order['account_id']):
        return False
    plan = config.plan(order['plan_id'])
    return bool(plan and plan.checkout_enabled and _same_quote(order, config, plan))


def checkout_payable(conn, order, config):
    if not order or order['status'] != 'pending' or not checkout_quote_available(order, config):
        return False
    if order['purchase_mode'] == 'single':
        return True
    agreement = conn.execute('SELECT status,template_id FROM billing_agreements WHERE agreement_id=%s',
                             (order['agreement_id'],)).fetchone()
    return config.auto_renew_enabled and agreement['status'] == 'pending' and agreement['template_id'] == config.template_id


def _close_order(conn, order, status):
    conn.execute('UPDATE billing_orders SET status=%s WHERE checkout_id=%s', (status, order['checkout_id']))
    conn.execute("""UPDATE billing_renewals SET status='skipped',order_id=NULL
      WHERE renewal_id=%s AND order_id=%s""", (order['renewal_id'], order['checkout_id']))
    order['status'] = status


def close_unsubmitted(conn, order, instant):
    if order['status'] in IN_FLIGHT:
        problem(409, 'billing_order_processing')
    if order['status'] not in ('pending', 'closed', 'failed'):
        problem(409, 'billing_order_not_open')
    if order['status'] == 'pending':
        _close_order(conn, order, 'closed')
        if order['agreement_id']:
            conn.execute("""UPDATE billing_agreements SET status='canceled',stopped_at=%s
              WHERE agreement_id=%s AND status='pending'""", (instant, order['agreement_id']))
    return order


def stop_renewal(conn, account_id, instant):
    agreement = _open_agreement(conn, account_id)
    if not agreement or agreement['status'] == 'canceling':
        return
    pending = conn.execute("SELECT * FROM billing_orders WHERE agreement_id=%s AND status='pending'",
                           (agreement['agreement_id'],)).fetchone()
    if pending and agreement['status'] == 'pending':
        close_unsubmitted(conn, pending, instant)
    else:
        if pending:
            _close_order(conn, pending, 'closed')
        conn.execute("UPDATE billing_agreements SET status='canceling',stopped_at=%s WHERE agreement_id=%s",
                     (instant, agreement['agreement_id']))
    conn.execute("UPDATE billing_renewals SET status='skipped' WHERE agreement_id=%s AND status='ready'",
                 (agreement['agreement_id'],))


def detach_account(conn, account_id):
    """Called before account deletion, in its transaction and under its row lock."""
    instant = now()
    stop_renewal(conn, account_id, instant)
    for order in conn.execute("SELECT * FROM billing_orders WHERE account_id=%s AND status='pending'", (account_id,)):
        close_unsubmitted(conn, order, instant)
    conn.execute('''DELETE FROM billing_checkout_handoffs h USING billing_orders o
      WHERE o.account_id=%s AND h.checkout_id=o.checkout_id''', (account_id,))
    conn.execute('UPDATE billing_periods SET revoked_at=%s WHERE account_id=%s AND revoked_at IS NULL',
                 (instant, account_id))


def plan_renewal(config, agreement_id, due_at, window_end_at, delivered_at, notice_reference, channel_ready_at):
    """Persist the scheduler's proposed window and actual reminder evidence.

    This is an internal hook, not user-supplied state. A delivery receipt and
    the approved provider window must both be verified before calling it;
    the adapter owns the provider-specific earliest and latest allowed times.
    """
    if 'billing_auto_renew' not in billing_capabilities(config):
        return None
    with connect() as conn:
        account, agreement = _lock_target(conn, 'billing_agreements', 'agreement_id', agreement_id)
        instant = now()
        if not _enabled(conn, account) or not _authorized(agreement, config, instant):
            return None
        rights = coverage(conn, account, instant)
        # No debit against a grant alone. A renewal attaches to a real paid cycle.
        if (not rights.paid_end or not instant < window_end_at <= rights.end or not due_at < window_end_at
                or _has_future_period(conn, account['account_id'], instant)):
            return None
        slot = _slot(conn, account['account_id'], rights.end)
        if slot['status'] in ('reserved', 'settled') or conn.execute('''SELECT 1 FROM billing_orders
          WHERE renewal_id=%s AND source='renewal' LIMIT 1''', (slot['renewal_id'],)).fetchone():
            return None
        conn.execute('''UPDATE billing_renewals SET agreement_id=%s,status='ready',due_at=%s,window_end_at=%s,
          notice_delivered_at=%s,notice_reference=%s,channel_ready_at=%s WHERE renewal_id=%s''',
          (agreement_id, due_at, window_end_at, delivered_at, notice_reference, channel_ready_at, slot['renewal_id']))
        return slot['renewal_id']


def _authorized(agreement, config, instant):
    plan = config.plan(agreement['plan_id']) if agreement else None
    return (plan and plan.checkout_enabled and agreement['status'] == 'active' and agreement['provider_agreement_id']
            and (not agreement['expires_at'] or instant < agreement['expires_at'])
            and agreement['template_id'] == config.template_id and _same_quote(agreement, config, plan))


def claim_renewal(config, renewal_id):
    """Make the only automatic submission decision, without holding a lock across provider I/O."""
    if 'billing_auto_renew' not in billing_capabilities(config):
        return None
    with connect() as conn:
        account, slot = _lock_target(conn, 'billing_renewals', 'renewal_id', renewal_id)
        if not account or slot['status'] != 'ready':
            return None
        instant, aid = now(), account['account_id']
        if instant < slot['due_at']:
            return None
        agreement = _open_agreement(conn, aid)
        rights = coverage(conn, account, instant)
        if (not _enabled(conn, account) or not _authorized(agreement, config, instant)
                or agreement['agreement_id'] != slot['agreement_id']
                or instant >= slot['window_end_at'] or rights.end != slot['cycle_end'] or not rights.paid_end
                or _has_future_period(conn, aid, instant)
                or not slot['notice_reference'] or not slot['notice_delivered_at']
                or slot['notice_delivered_at'] > slot['due_at'] - timedelta(days=5)
                or not slot['channel_ready_at'] or slot['channel_ready_at'] > instant):
            conn.execute("UPDATE billing_renewals SET status='skipped' WHERE renewal_id=%s", (renewal_id,))
            return None
        if conn.execute('SELECT 1 FROM billing_orders WHERE account_id=%s AND status=ANY(%s)',
                        (aid, list(UNRESOLVED))).fetchone():
            return None
        return _insert_order(conn, aid, slot, agreement['agreement_id'], config, config.plan(agreement['plan_id']),
                             instant, 'renewal', 'auto_renew')


def _nullable_stamp(value):
    return stamp(value) if value else None


def waffo_checkout_can_resume(order):
    return bool(order['provider'] == WAFFO_LIVE_PROVIDER and order['status'] == 'processing'
                and order.get('provider_checkout_url') and order.get('provider_checkout_expires_at')
                and order['provider_checkout_expires_at'] > now())


def order_json(conn, order):
    period = conn.execute('SELECT start_at,end_at FROM billing_periods WHERE checkout_id=%s',
                          (order['checkout_id'],)).fetchone() or {}
    return {**{key: order[key] for key in ('plan_id', 'purchase_mode', 'amount_minor', 'currency',
             'period_seconds', 'terms_version', 'provider', 'status')}, 'checkout_id': str(order['checkout_id']),
            'created_at': stamp(order['created_at']), 'paid_at': _nullable_stamp(order['paid_at']),
            'period_start': _nullable_stamp(period.get('start_at')), 'period_end': _nullable_stamp(period.get('end_at')),
            **({'can_resume_checkout': waffo_checkout_can_resume(order)}
               if order['provider'] == WAFFO_LIVE_PROVIDER else {})}


def subscription_json(conn, account, config):
    instant, aid = now(), account['account_id']
    rights = coverage(conn, account, instant)
    agreement = _open_agreement(conn, aid) or conn.execute('''SELECT * FROM billing_agreements
      WHERE account_id=%s ORDER BY consented_at DESC,agreement_id DESC LIMIT 1''', (aid,)).fetchone()
    status = agreement['status'] if agreement else 'none'
    if status == 'active' and agreement['expires_at'] and agreement['expires_at'] <= instant:
        status = 'expired'
    flight = conn.execute('SELECT * FROM billing_orders WHERE account_id=%s AND status=ANY(%s)',
                          (aid, list(IN_FLIGHT))).fetchone()
    planned = None
    if ('billing_auto_renew' in billing_capabilities(config) and _authorized(agreement, config, instant)
            and not _has_future_period(conn, aid, instant)):
        planned = conn.execute('''SELECT due_at FROM billing_renewals WHERE agreement_id=%s
          AND account_id=%s AND cycle_end=%s AND status='ready' AND window_end_at>%s
          AND notice_reference<>'' AND notice_delivered_at<=due_at-interval '120 hours'
          AND channel_ready_at IS NOT NULL''', (agreement['agreement_id'], aid, rights.end, instant)).fetchone()
    return {'agreement_status': status, 'auto_renew': status == 'active', 'current_period_end': _nullable_stamp(rights.end),
            'paid_period_end': _nullable_stamp(rights.paid_end), 'next_charge_at': _nullable_stamp(planned['due_at']) if planned else None,
            'next_charge_amount_minor': agreement['amount_minor'] if planned else None,
            'currency': agreement['currency'] if agreement else None, 'provider': agreement['provider'] if agreement else None,
            'in_flight_order': order_json(conn, flight) if flight else None}


def _event_json(event):
    return {'kind': event.kind, 'occurred_at': stamp(event.occurred_at), 'external_id': event.external_id,
            'amount_minor': event.amount_minor, 'currency': event.currency, 'template_id': event.template_id,
            'agreement_expires_at': _nullable_stamp(event.agreement_expires_at),
            'merchant_refund_id': event.merchant_refund_id, 'provider_refund_id': event.provider_refund_id}


def _event_from_row(row):
    data = dict(row['event_data'])
    data['occurred_at'] = datetime.fromisoformat(data['occurred_at'])
    if data['agreement_expires_at']:
        data['agreement_expires_at'] = datetime.fromisoformat(data['agreement_expires_at'])
    return VerifiedEvent(row['event_id'], provider=row['provider'], merchant_id=row['merchant_id'],
                         app_id=row['app_id'], related_id=row['related_id'], **data)


def _mark_event(conn, event, result, instant):
    conn.execute('''UPDATE billing_events SET status=%s,processed_at=%s WHERE
      provider=%s AND merchant_id=%s AND app_id=%s AND event_id=%s''',
      (result, None if result == 'deferred' else instant, event.provider, event.merchant_id, event.app_id, event.event_id))


def apply_verified_event(adapter, event):
    """Apply an internal, verified result. Never called with public request data.

    Identities come from the matching stored order/agreement, not the payload.
    An event and its effect commit together; stored pre-payment refunds retry in
    the payment transaction before any new period can become visible.
    """
    scope = (event.provider, event.merchant_id, event.app_id)
    allowed_origin = (sandbox_database(settings.public_origin) if adapter.provider == WAFFO_TEST_PROVIDER
                      else settings.public_origin == OFFICIAL_ORIGIN)
    if (settings.mode != 'hosted' or not allowed_origin
            or scope != (adapter.provider, adapter.merchant_id, adapter.app_id)
            or not event.event_id or not event.occurred_at.utcoffset() == timedelta(0)):
        return 'rejected'
    if event.kind in ('agreement_signed', 'agreement_ended'):
        table, key = 'billing_agreements', 'agreement_id'
    elif event.kind in ('payment_paid', 'payment_processing', 'payment_closed', 'payment_failed',
                        'refund_pending', 'refund_succeeded', 'refund_failed'):
        table, key = 'billing_orders', 'checkout_id'
    else:
        return 'rejected'
    with connect() as conn:
        account, target = _lock_target(conn, table, key, event.related_id)
        if not target or tuple(target[name] for name in ('provider', 'merchant_id', 'app_id')) != scope:
            return 'rejected'
        if event.provider == WAFFO_LIVE_PROVIDER and (table != 'billing_orders' or not event.provider_product_id
                or event.provider_product_id != live_order_product_id(adapter, target)):
            return 'rejected'
        instant = now()
        # Product is checked against the immutable order before deduplication.
        # Keep event_data unchanged so retries of pre-migration events still match.
        data = _event_json(event)
        conn.execute('''INSERT INTO billing_events(provider,merchant_id,app_id,event_id,related_id,event_data,status,received_at)
          VALUES (%s,%s,%s,%s,%s,%s,'deferred',%s) ON CONFLICT DO NOTHING''',
          (*scope, event.event_id, event.related_id, Jsonb(data), instant))
        stored = conn.execute('''SELECT related_id,event_data,status FROM billing_events
          WHERE provider=%s AND merchant_id=%s AND app_id=%s AND event_id=%s FOR UPDATE''', (*scope, event.event_id)).fetchone()
        if stored['related_id'] != event.related_id or stored['event_data'] != data:
            return 'rejected'
        if stored['status'] != 'deferred':
            return stored['status']
        result = _process_event(conn, account, target, event, instant)
        if event.kind == 'payment_paid' and result == 'applied':
            order = conn.execute('SELECT * FROM billing_orders WHERE checkout_id=%s', (event.related_id,)).fetchone()
            if order['paid_at']:
                for row in conn.execute('''SELECT * FROM billing_events WHERE provider=%s AND merchant_id=%s
                  AND app_id=%s AND related_id=%s AND status='deferred' AND event_id<>%s
                  AND event_data->>'kind' LIKE 'refund_%%' ORDER BY received_at,event_id''',
                  (*scope, event.related_id, event.event_id)):
                    refund = _event_from_row(row)
                    _mark_event(conn, refund, _process_event(conn, account, order, refund, instant), instant)
        _mark_event(conn, event, result, instant)
        return result


def _process_event(conn, account, target, event, instant):
    try:
        with conn.transaction():  # A reused external transaction/contract/refund ID fails closed.
            if event.kind.startswith('agreement_'):
                return _apply_agreement(conn, account, target, event, instant)
            if event.kind.startswith('refund_'):
                return _apply_refund(conn, account, target, event, instant)
            return _apply_payment(conn, account, target, event, instant)
    except UniqueViolation:
        return 'rejected'


def _apply_agreement(conn, account, agreement, event, instant):
    if not event.external_id or (agreement['provider_agreement_id'] is not None
                                 and event.external_id != agreement['provider_agreement_id']):
        return 'rejected'
    if event.kind == 'agreement_ended':
        conn.execute('''UPDATE billing_agreements SET status='canceled', provider_agreement_id=%s,
          stopped_at=least(stopped_at,%s), channel_ended_at=least(channel_ended_at,%s) WHERE agreement_id=%s''',
          (event.external_id, event.occurred_at, event.occurred_at, agreement['agreement_id']))
        conn.execute("UPDATE billing_renewals SET status='skipped' WHERE agreement_id=%s AND status='ready'",
                     (agreement['agreement_id'],))
        for order in conn.execute("SELECT * FROM billing_orders WHERE agreement_id=%s AND status='pending'",
                                  (agreement['agreement_id'],)):
            _close_order(conn, order, 'closed')
        for order in conn.execute('''UPDATE billing_orders SET refund_required=true,status='refund_pending'
          WHERE agreement_id=%s AND paid_at>=%s AND status IN ('paid','refund_pending') AND NOT refund_required
          RETURNING checkout_id''', (agreement['agreement_id'], event.occurred_at)):
            _revoke_period(conn, account, order['checkout_id'], instant)
        return 'applied'
    if (event.template_id, event.amount_minor, event.currency) != (
            agreement['template_id'], agreement['amount_minor'], agreement['currency']):
        return 'rejected'
    # A late signing confirmation can supply the ID needed to finish revocation,
    # but it cannot revive a locally stopped or channel-terminated agreement.
    conn.execute('''UPDATE billing_agreements SET provider_agreement_id=%s,signed_at=coalesce(signed_at,%s),
      expires_at=coalesce(expires_at,%s),status=CASE WHEN status='pending' THEN 'active' ELSE status END
      WHERE agreement_id=%s''', (event.external_id, event.occurred_at, event.agreement_expires_at, agreement['agreement_id']))
    return 'applied'


def _apply_payment(conn, account, order, event, instant):
    if (type(event.amount_minor) is not int or (event.amount_minor, event.currency) != (order['amount_minor'], order['currency'])
            or not event.external_id):
        return 'rejected'
    status = order['status']
    if order['paid_at']:
        return 'applied' if event.external_id == order['provider_payment_id'] else 'rejected'
    if event.kind != 'payment_paid':
        if status in IN_FLIGHT:
            if event.kind == 'payment_processing':
                conn.execute("UPDATE billing_orders SET status='processing' WHERE checkout_id=%s", (order['checkout_id'],))
            else:
                _close_order(conn, order, event.kind.removeprefix('payment_'))
        return 'applied'
    agreement = conn.execute('SELECT stopped_at FROM billing_agreements WHERE agreement_id=%s',
                             (order['agreement_id'],)).fetchone() if order['agreement_id'] else None
    refund_required = (not account or status not in IN_FLIGHT or bool(agreement and agreement['stopped_at']
                        and event.occurred_at >= agreement['stopped_at']))
    conn.execute('''UPDATE billing_orders SET status=%s,provider_payment_id=%s,paid_at=%s,refund_required=%s
      WHERE checkout_id=%s''', ('refund_pending' if refund_required else 'paid', event.external_id,
                               event.occurred_at, refund_required, order['checkout_id']))
    conn.execute("UPDATE billing_renewals SET status='settled' WHERE renewal_id=%s AND order_id=%s",
                 (order['renewal_id'], order['checkout_id']))
    if not refund_required:
        start = coverage(conn, account, instant).end or instant
        conn.execute('''INSERT INTO billing_periods(checkout_id,account_id,start_at,end_at) VALUES (%s,%s,%s,%s)''',
                     (order['checkout_id'], account['account_id'], start, start + timedelta(seconds=order['period_seconds'])))
    return 'applied'


def _apply_refund(conn, account, order, event, instant):
    if (not all((event.external_id, event.merchant_refund_id, event.provider_refund_id))
            or event.currency != order['currency'] or type(event.amount_minor) is not int
            or not 0 < event.amount_minor <= order['amount_minor']):
        return 'rejected'
    if not order['paid_at']:
        return 'deferred'
    if event.external_id != order['provider_payment_id']:
        return 'rejected'
    scope = (event.provider, event.merchant_id, event.app_id, event.merchant_refund_id)
    old = conn.execute('''SELECT * FROM billing_refunds WHERE provider=%s AND merchant_id=%s
      AND app_id=%s AND merchant_refund_id=%s''', scope).fetchone()
    if old and (old['checkout_id'], old['provider_refund_id'], old['amount_minor']) != (
            order['checkout_id'], event.provider_refund_id, event.amount_minor):
        return 'rejected'
    status = event.kind.removeprefix('refund_')
    if old and (old['status'] == 'succeeded' or (old['status'] == 'failed' and status == 'pending')):
        return 'applied'
    oid = order['checkout_id']
    total = conn.execute('''SELECT coalesce(sum(amount_minor),0) AS amount FROM billing_refunds
      WHERE checkout_id=%s AND status IN ('succeeded','pending') AND merchant_refund_id<>%s''',
      (oid, event.merchant_refund_id)).fetchone()['amount']
    if status != 'failed' and total + event.amount_minor > order['amount_minor']:
        return 'rejected'
    conn.execute('''INSERT INTO billing_refunds(provider,merchant_id,app_id,merchant_refund_id,provider_refund_id,
      checkout_id,amount_minor,status) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
      ON CONFLICT(provider,merchant_id,app_id,merchant_refund_id) DO UPDATE SET status=excluded.status''',
      (*scope, event.provider_refund_id, oid, event.amount_minor, status))
    amounts = conn.execute('''SELECT coalesce(sum(amount_minor) FILTER (WHERE status='succeeded'),0) AS refunded,
      bool_or(status='pending') AS pending FROM billing_refunds WHERE checkout_id=%s''', (oid,)).fetchone()
    full = amounts['refunded'] == order['amount_minor']
    conn.execute('UPDATE billing_orders SET status=%s WHERE checkout_id=%s',
                 ('refunded' if full else 'refund_pending' if amounts['pending'] or order['refund_required'] else 'paid', oid))
    if full:
        conn.execute("""UPDATE billing_renewals SET status='skipped',order_id=NULL
          WHERE renewal_id=%s AND order_id=%s""", (order['renewal_id'], oid))
        _revoke_period(conn, account, oid, instant)
    return 'applied'


def _revoke_period(conn, account, checkout_id, instant):
    revoked = conn.execute('''UPDATE billing_periods SET revoked_at=%s WHERE checkout_id=%s AND revoked_at IS NULL
      RETURNING start_at,end_at''', (instant, checkout_id)).fetchone()
    if account and revoked:
        _fill_refund_gap(conn, account, revoked, instant)


def _fill_refund_gap(conn, account, revoked, instant):
    """Move only future contiguous periods after the refunded one; keep bought time intact."""
    aid = account['account_id']
    grant = account['grant_until']
    start = max(instant, revoked['start_at'], grant or instant)
    previous_end = revoked['end_at']
    for period in conn.execute('''SELECT checkout_id,start_at,end_at FROM billing_periods
      WHERE account_id=%s AND revoked_at IS NULL AND start_at>%s AND start_at>=%s ORDER BY start_at''',
      (aid, instant, previous_end)):
        if period['start_at'] != previous_end or start >= period['start_at']:
            break
        end = start + (period['end_at'] - period['start_at'])
        conn.execute('UPDATE billing_periods SET start_at=%s,end_at=%s WHERE checkout_id=%s',
                     (start, end, period['checkout_id']))
        start, previous_end = end, period['end_at']
