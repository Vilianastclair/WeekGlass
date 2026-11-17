"""Opt-in Waffo runtime; payment availability is independent of event intake."""
import asyncio
from datetime import timedelta
import logging
import os
from uuid import UUID

import psycopg
from starlette.concurrency import run_in_threadpool

from . import billing
from .db import connect
from .migrations import migrate_operator_order_checks, migrate_provider_checkout, migrate_provider_reconcile
from .protocol import now
from .settings import settings
from .waffo import BridgeError

LOGGER = logging.getLogger(__name__)
MONTHLY_PRICE_MINOR = 100
ANNUAL_PRICE_MINOR = 999
_POLL_SECONDS = 15


def configured():
    if not (os.environ.get('WEEKGLASS_WAFFO_LIVE_ACCEPT_EVENTS') == 'true'
            and settings.mode == 'hosted' and settings.public_origin == billing.OFFICIAL_ORIGIN):
        return None

    from .waffo import WaffoLive

    try:
        adapter = WaffoLive.load()
    except (BridgeError, ValueError, OSError):
        LOGGER.error('Waffo live event intake unavailable: check the live credential configuration')
        return None

    enabled = os.environ.get('WEEKGLASS_WAFFO_LIVE_ENABLED') == 'true'
    pilot = None
    try:
        pilot_value = os.environ.get('WEEKGLASS_WAFFO_LIVE_ACCOUNT_ID')
        pilot = UUID(pilot_value) if pilot_value else None
    except ValueError:
        enabled = False
        LOGGER.error('Waffo live checkout disabled: invalid pilot account ID')

    annual_enabled = os.environ.get('WEEKGLASS_WAFFO_LIVE_ANNUAL_ENABLED') == 'true'
    monthly = billing.BillingPlan(billing.MONTHLY_PLAN_ID, billing.MONTHLY_TERMS, MONTHLY_PRICE_MINOR,
                                  provider_product_id=adapter.product_id,
                                  checkout_enabled=enabled and _verified_offer(adapter, adapter.product_id, MONTHLY_PRICE_MINOR))
    plans = (monthly,)
    if adapter.annual_product_id:
        annual = billing.BillingPlan('cloud-365d', 'waffo-cny-365d-v1', ANNUAL_PRICE_MINOR,
                                     period_seconds=billing.ANNUAL_PERIOD_SECONDS, provider_product_id=adapter.annual_product_id,
                                     checkout_enabled=enabled and annual_enabled and _verified_offer(
                                         adapter, adapter.annual_product_id, ANNUAL_PRICE_MINOR))
        plans += (annual,)
    elif enabled and annual_enabled:
        LOGGER.error('Waffo annual checkout disabled: missing live annual product ID')
    return billing.BillingConfig(adapter, plans, checkout_enabled=enabled, pilot_account_id=pilot)


def _verified_offer(adapter, product_id, amount):
    try:
        if adapter.catalog_amount(product_id) == amount:
            return True
    except (BridgeError, ValueError, OSError):
        pass
    LOGGER.error('Waffo offer unavailable: could not verify the live catalog price of %d fen', amount)
    return False


def install_schema():
    with connect() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('weekglass_schema'))")
        migrate_provider_checkout(conn)
        migrate_provider_reconcile(conn)
        migrate_operator_order_checks(conn)


def reconcile_one(config, checkout_id=None):
    """Lease one due order across worker/browser races before consulting the provider."""
    return _reconcile(config, checkout_id) != 'not_due'


def reconcile_for_operator(config, checkout_id):
    """Allow a manual check of a submitted order after the shared cooldown."""
    return _reconcile(config, checkout_id, operator=True)


def _reconcile(config, checkout_id, *, operator=False):
    instant = now()
    with connect() as conn:
        row = conn.execute("""SELECT * FROM billing_orders
          WHERE provider=%s AND merchant_id=%s AND app_id=%s
            AND status IN ('submitting','processing') AND provider_next_check_at IS NOT NULL
            AND (provider_next_check_at<=%s OR (%s AND status='processing'
              AND coalesce(provider_last_check_at,provider_checkout_expires_at-interval '15 minutes',created_at)<=%s))
            AND (%s::uuid IS NULL OR checkout_id=%s::uuid)
          ORDER BY provider_next_check_at
          LIMIT 1 FOR UPDATE SKIP LOCKED""",
           (*config.scope, instant, operator, instant-timedelta(minutes=1), checkout_id, checkout_id)).fetchone()
        if not row:
            return 'not_due'
        age = instant - (row['provider_checkout_expires_at'] - timedelta(minutes=15)
                         if row['provider_checkout_expires_at'] else row['created_at'])
        delay = (timedelta(seconds=30) if age < timedelta(minutes=2) else
                 timedelta(minutes=2) if age < timedelta(minutes=30) else
                 timedelta(minutes=15) if age < timedelta(hours=24) else timedelta(days=1))
        conn.execute('''UPDATE billing_orders SET provider_next_check_at=%s,provider_last_check_at=%s
          WHERE checkout_id=%s''', (instant + delay, instant, row['checkout_id']))
        refund_candidates = conn.execute('''SELECT event_data FROM billing_events
          WHERE (provider,merchant_id,app_id)=(%s,%s,%s) AND related_id=%s AND status='deferred'
            AND event_data->>'kind'='refund_succeeded' ORDER BY received_at,event_id''',
          (*config.scope, row['checkout_id']))
        refunds = {}
        ambiguous = False
        for candidate in refund_candidates:
            event = candidate['event_data']
            refund_id = event['provider_refund_id']
            payment_amount = (event['external_id'], event['amount_minor'])
            if (not refund_id or not payment_amount[0] or type(payment_amount[1]) is not int
                    or not 0 < payment_amount[1] <= row['amount_minor']
                    or event['currency'] != row['currency'] or not event['merchant_refund_id']
                    or refund_id in refunds and refunds[refund_id] != payment_amount):
                ambiguous = True
                break
            refunds[refund_id] = payment_amount
        row['verified_refund_amounts'] = {}
        if not ambiguous:
            for payment_id, amount in refunds.values():
                totals = row['verified_refund_amounts']
                totals[payment_id] = totals.get(payment_id, 0) + amount
    if row['status'] == 'submitting' and row['provider_checkout_url'] is None:
        with connect() as conn:
            _, current = billing._lock_target(conn, 'billing_orders', 'checkout_id', row['checkout_id'])
            if current['status'] == 'submitting' and current['provider_checkout_url'] is None:
                # No buyer could receive the link: the browser only gets it after
                # the submitting->processing transaction. This state change also
                # fences out a slow original request before it can publish its URL.
                billing._close_order(conn, current, 'failed')
                return 'no_link'
    rejected = False
    try:
        for event in config.adapter.query_events(row):
            if billing.apply_verified_event(config.adapter, event) == 'rejected':
                rejected = True
                LOGGER.warning('Waffo rejected a reconciled event for order %s', row['checkout_id'])
    except BridgeError:
        # A network or verification failure isn't evidence of unpaid status.
        LOGGER.warning('Waffo could not reconcile order %s; it remains queued', row['checkout_id'])
        return 'unavailable'
    return 'unverified' if rejected else 'checked'


async def reconcile_loop(config):
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        try:
            # No provider request is made without a locally due, unresolved order.
            for _ in range(3):
                if not await run_in_threadpool(reconcile_one, config):
                    break
        except psycopg.Error:
            LOGGER.warning('Waffo reconciliation deferred: database unavailable')
