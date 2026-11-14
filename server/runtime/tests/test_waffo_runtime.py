"""Official-origin HTTP integration; a fake adapter supplies verified provider facts."""
from dataclasses import replace
from datetime import timedelta
import os
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
import pytest

from test_auth import headers, tokens_for
from weekglass_server import auth, billing, main, waffo_runtime
from weekglass_server.db import connect
from weekglass_server.protocol import now, validate
from weekglass_server.settings import settings
from weekglass_server.waffo import BridgeError

ORIGIN = billing.OFFICIAL_ORIGIN
BASE = '/v1/billing'
CASHIER = 'https://pancake.waffo.ai/store/test/checkout/cs_550e8400-e29b-41d4-a716-446655440000'
MONTHLY = billing.BillingPlan('cloud-30d', 'waffo-cny-30d-v1', 100, provider_product_id='PROD_' + 'a' * 22)
ANNUAL = billing.BillingPlan('cloud-365d', 'waffo-cny-365d-v1', 999, period_seconds=billing.ANNUAL_PERIOD_SECONDS,
                            provider_product_id='PROD_' + 'b' * 22)


class LiveFixture:
    provider = billing.WAFFO_LIVE_PROVIDER
    app_id = 'STO_fixture'
    product_id = MONTHLY.provider_product_id
    annual_product_id = ANNUAL.provider_product_id

    def __init__(self):
        self.merchant_id = uuid4().hex
        self.calls = 0
        self.cashier_orders = []
        self.failure = None
        self.queries = []
        self.queried_events = {}
        self.webhooks = {}

    def catalog_amount(self, product_id=None):
        return 999 if product_id == self.annual_product_id else 100

    def create_checkout(self, order):
        self.calls += 1
        self.cashier_orders.append(order)
        if self.failure:
            raise BridgeError(self.failure)
        return CASHIER, now() + timedelta(minutes=15)

    def query_events(self, order):
        oid = order['checkout_id']
        self.queries.append(oid)
        return self.queried_events.get(oid, [])

    def verify_event(self, headers, raw):
        try:
            return self.webhooks[headers['x-waffo-signature']]
        except KeyError:
            raise ValueError('signature mismatch') from None

    def event(self, kind, order_id, external_id=None, **extra):
        return replace(billing.VerifiedEvent(uuid4().hex, kind, self.provider, self.merchant_id,
                                             self.app_id, UUID(order_id), now(), external_id or uuid4().hex,
                                             100, 'CNY', provider_product_id=self.product_id), **extra)


@pytest.fixture
def official(monkeypatch):
    assert os.environ.get('DB_NAME', '').endswith('_test') and not os.environ.get('DATABASE_URL')
    monkeypatch.setattr(settings, 'mode', 'hosted')
    monkeypatch.setattr(settings, 'public_origin', ORIGIN)
    monkeypatch.setattr(settings, 'alternate_origins', (ORIGIN + ':8443',))
    adapter = LiveFixture()
    with TestClient(main.app, base_url=ORIGIN, follow_redirects=False) as client:
        waffo_runtime.install_schema()
        users = []
        for _ in range(2):
            username, password = 'waffo-pilot-' + uuid4().hex, uuid4().hex
            uid = auth.create_account(username, password)
            users.append((uid, headers(tokens_for(client, (uid, username, password)))))
        config = billing.BillingConfig(adapter, (MONTHLY, ANNUAL),
                                       checkout_enabled=True, pilot_account_id=UUID(users[0][0]))
        monkeypatch.setattr(main.app.state, 'billing', config)
        yield SimpleNamespace(client=client, config=config, users=users, adapter=adapter)
        with connect() as conn:
            conn.execute('DELETE FROM billing_checkout_keys WHERE account_id=%s', (users[0][0],))
            for table in ('billing_checkout_handoffs', 'billing_periods'):
                conn.execute(f'''DELETE FROM {table} x USING billing_orders o WHERE x.checkout_id=o.checkout_id
                  AND (o.provider,o.merchant_id,o.app_id)=(%s,%s,%s)''', config.scope)
            conn.execute('DELETE FROM billing_refunds WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', config.scope)
            conn.execute('DELETE FROM billing_events WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', config.scope)
            conn.execute('''UPDATE billing_renewals r SET status='skipped',order_id=NULL FROM billing_orders o
              WHERE r.order_id=o.checkout_id AND (o.provider,o.merchant_id,o.app_id)=(%s,%s,%s)''', config.scope)
            conn.execute('DELETE FROM billing_orders WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', config.scope)
            for uid, _ in users:
                conn.execute('DELETE FROM billing_renewals WHERE account_id=%s', (uid,))
                conn.execute('DELETE FROM accounts WHERE account_id=%s', (uid,))
            for purpose in ('authorize', 'login-ip', 'token'):
                conn.execute('DELETE FROM auth_rate_limits WHERE bucket=%s', (auth.hashed(purpose+':testclient'),))


def checkout(flow, user=0, key=None, **options):
    plan = flow.config.plans[0]
    return flow.client.post(BASE + '/checkout-sessions',
                            headers={**flow.users[user][1], 'Idempotency-Key': str(key or uuid4())},
                            json={'plan_id': plan.plan_id, 'purchase_mode': 'single',
                                  'terms_version': plan.terms_version, **options})


def open_order(flow, response):
    assert response.status_code == 201, response.text
    url = urlsplit(response.json()['url'])
    ticket = parse_qs(url.fragment)['ticket'][0]
    assert flow.client.post(url.path + '/handoff', json={'ticket': ticket},
                            headers={'Origin': ORIGIN}).status_code == 200
    return response.json()['checkout_id'], url.path


def order(flow, oid):
    return flow.client.get(BASE + '/orders/' + oid, headers=flow.users[0][1]).json()


def due(oid):
    with connect() as conn:
        conn.execute('UPDATE billing_orders SET provider_next_check_at=now() WHERE checkout_id=%s', (oid,))


def webhook(flow, event, route='waffo'):
    signature = 'sig-' + uuid4().hex
    flow.adapter.webhooks[signature] = event
    return flow.client.post(BASE + '/webhooks/' + route, headers={'X-Waffo-Signature': signature}, json={})


def test_pilot_payment_and_refund_work_with_sales_paused(official, monkeypatch):
    f = official
    assert f.client.get(BASE + '/plans', headers=f.users[1][1]).json() == {'plans': []}
    assert checkout(f, user=1).status_code == 503
    assert f.client.get(ORIGIN + ':8443/v1/server-info').json()['capabilities'].count('billing_checkout') == 0
    assert f.client.get(ORIGIN + ':8443' + BASE + '/plans', headers=f.users[0][1]).json() == {'plans': []}
    first_key = uuid4()
    oid, path = open_order(f, checkout(f, key=first_key))
    assert checkout(f, key=first_key, expected_checkout_id=oid).json()['checkout_id'] == oid
    assert checkout(f, expected_checkout_id=str(uuid4())).status_code == 409
    assert '不会自动续费' in f.client.get(path).text
    assert f.client.post(path + '/provider', headers={'Origin': 'https://untrusted.invalid'}).status_code == 403
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).json() == {'url': CASHIER}
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).json() == {'url': CASHIER}
    assert f.adapter.calls == 1
    assert order(f, oid)['can_resume_checkout'] is True
    resumed, resumed_path = open_order(f, checkout(f, expected_checkout_id=oid))
    assert resumed == oid and resumed_path == path
    assert f.client.post(resumed_path + '/provider', headers={'Origin': ORIGIN}).json() == {'url': CASHIER}
    assert f.adapter.calls == 1
    # The browser return only renders state; a forged query cannot open entitlements.
    assert '付款结果待确认' in f.client.get(path + '?returned=1').text
    assert order(f, oid)['period_start'] is None
    assert f.client.get(BASE + '/orders/' + oid, headers=f.users[1][1]).status_code == 404
    assert f.client.post(BASE + '/webhooks/waffo', json={}).status_code == 401
    paid = f.adapter.event('payment_paid', oid)
    assert webhook(f, paid, route='waffo-test').status_code == 404
    assert webhook(f, replace(paid, event_id='wrong-amount', amount_minor=99)).status_code == 422

    monkeypatch.setattr(f.client.app.state, 'billing', replace(f.config, checkout_enabled=False))
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 503
    assert checkout(f).status_code == 503
    for _ in range(2):
        assert webhook(f, paid).status_code == 204
    assert order(f, oid)['status'] == 'paid'
    assert order(f, oid)['can_resume_checkout'] is False
    assert '30 天云同步已到账' in f.client.get(path + '?returned=1').text
    with connect() as conn:
        periods = conn.execute('SELECT end_at - start_at AS length FROM billing_periods WHERE checkout_id=%s',
                               (oid,)).fetchall()
        assert periods == [{'length': timedelta(days=30)}]
    monkeypatch.setattr(f.client.app.state, 'billing', f.config)
    assert checkout(f, expected_checkout_id=oid).json() == {'checkout_id': oid, 'url': None, 'expires_at': None}
    refund = f.adapter.event('refund_succeeded', oid, paid.external_id,
                             merchant_refund_id='refund-pilot', provider_refund_id='refund-provider')
    assert webhook(f, refund).status_code == 204
    assert order(f, oid)['status'] == 'refunded'


def test_reconciles_only_due_orders_and_confirmed_cancellation_unlocks_checkout(official):
    f = official
    oid, path = open_order(f, checkout(f))
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 200
    assert not waffo_runtime.reconcile_one(f.config)
    assert f.adapter.queries == []
    due(oid)
    assert waffo_runtime.reconcile_one(f.config)
    assert not waffo_runtime.reconcile_one(f.config)
    assert order(f, oid)['status'] == 'processing'  # absence isn't proof of nonpayment
    f.adapter.queried_events[UUID(oid)] = [f.adapter.event('payment_closed', oid)]
    due(oid)
    assert f.client.post(path + '/refresh', headers={'Origin': ORIGIN}).json() == {'status': 'closed'}
    assert f.adapter.queries == [UUID(oid), UUID(oid)]
    assert checkout(f, expected_checkout_id=oid).json()['url'] is None
    assert checkout(f).json()['checkout_id'] != oid


@pytest.mark.parametrize('failure', ['checkout_preflight_catalog_mismatch', 'provider_unavailable'])
def test_create_failure_never_exposes_a_second_cashier(official, failure):
    f = official
    f.adapter.failure = failure
    oid, path = open_order(f, checkout(f))
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 503
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 409
    assert f.adapter.calls == 1
    if failure == 'provider_unavailable':
        assert order(f, oid)['status'] == 'submitting'
        due(oid)
        assert waffo_runtime.reconcile_one(f.config)
    assert f.adapter.queries == []
    assert order(f, oid)['status'] == 'failed'
    assert checkout(f).json()['checkout_id'] != oid


def test_refund_received_before_payment_is_applied_with_the_period(official, monkeypatch):
    f = official
    oid, path = open_order(f, checkout(f))
    assert f.client.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 200
    paid = f.adapter.event('payment_paid', oid)
    refund = f.adapter.event('refund_succeeded', oid, paid.external_id,
                             merchant_refund_id='early-refund', provider_refund_id='early-provider')
    for _ in range(2):
        assert webhook(f, refund).status_code == 204
    assert order(f, oid)['status'] == 'processing'

    def verified_payment(self, row):
        assert row['verified_refund_amounts'] == {paid.external_id: 100}
        return [paid]

    monkeypatch.setattr(LiveFixture, 'query_events', verified_payment)
    due(oid)
    assert waffo_runtime.reconcile_one(f.config)
    assert order(f, oid)['status'] == 'refunded'
    with connect() as conn:
        rights = conn.execute('SELECT revoked_at FROM billing_periods WHERE checkout_id=%s', (oid,)).fetchone()
        assert rights['revoked_at'] is not None


def test_annual_quote_recovery_and_refunds_preserve_monthly_coverage(official, monkeypatch):
    f = official
    auth_headers = f.users[0][1]
    browser_headers = {'Origin': ORIGIN}
    plans = f.client.get(BASE + '/plans', headers=auth_headers).json()
    validate('BillingPlans', plans)
    assert [(p['plan_id'], p['amount_minor'], p['period_seconds'], p['purchase_modes']) for p in plans['plans']] == [
        ('cloud-30d', 100, 2592000, ['single']), ('cloud-365d', 999, 31536000, ['single']),
    ]
    annual = dict(plan_id=ANNUAL.plan_id, terms_version=ANNUAL.terms_version)
    assert checkout(f, **{**annual, 'terms_version': 'old'}).json()['code'] == 'billing_terms_changed'
    assert checkout(f, **annual, purchase_mode='auto_renew').json()['code'] == 'auto_renew_unavailable'

    monthly_key = uuid4()
    monthly_id, monthly_path = open_order(f, checkout(f, key=monthly_key))
    assert checkout(f, key=monthly_key, **annual).json()['code'] == 'idempotency_key_reused'
    assert checkout(f, **annual).json()['code'] == 'billing_order_unresolved'
    assert '¥1.00 / 30 天' in f.client.get(monthly_path).text
    assert f.client.post(monthly_path + '/provider', headers=browser_headers).status_code == 200
    monthly_paid = f.adapter.event('payment_paid', monthly_id)
    assert webhook(f, monthly_paid).status_code == 204
    monthly_end = order(f, monthly_id)['period_end']

    oid, path = open_order(f, checkout(f, **annual))
    assert '¥9.99 / 365 天。单次购买，不会自动续费。' in f.client.get(path).text
    assert 'data-period-days="365"' in f.client.get(path).text
    assert f.client.post(path + '/provider', headers=browser_headers).json() == {'url': CASHIER}
    claimed = f.adapter.cashier_orders[-1]
    assert (claimed['provider_product_id'], claimed['amount_minor'], claimed['period_seconds']) == (
        ANNUAL.provider_product_id, 999, 31536000)
    assert checkout(f, expected_checkout_id=oid).json()['code'] == 'billing_order_unresolved'
    subscription = f.client.get(BASE + '/subscription', headers=auth_headers).json()
    validate('BillingSubscription', subscription)
    assert subscription['auto_renew'] is False and subscription['in_flight_order']['period_seconds'] == 31536000

    paused = replace(f.config, plans=(MONTHLY, replace(ANNUAL, checkout_enabled=False)))
    monkeypatch.setattr(f.client.app.state, 'billing', paused)
    assert [p['plan_id'] for p in f.client.get(BASE + '/plans', headers=auth_headers).json()['plans']] == ['cloud-30d']
    assert checkout(f, **annual).json()['code'] == 'billing_plan_unavailable'
    assert open_order(f, checkout(f, **annual, expected_checkout_id=oid)) == (oid, path)
    assert f.client.post(path + '/provider', headers=browser_headers).json() == {'url': CASHIER}
    assert f.adapter.calls == 2  # exactly one cashier per order
    assert '付款结果待确认' in f.client.get(path + '?returned=1').text
    assert order(f, oid)['period_start'] is None

    annual_paid = f.adapter.event('payment_paid', oid, amount_minor=999, provider_product_id=ANNUAL.provider_product_id)
    assert webhook(f, replace(annual_paid, provider_product_id=MONTHLY.provider_product_id)).status_code == 422
    assert webhook(f, replace(annual_paid, event_id='wrong-annual-amount', amount_minor=998)).status_code == 422
    f.adapter.queried_events[UUID(oid)] = [replace(annual_paid, event_id='query:' + annual_paid.external_id)]
    due(oid)
    assert f.client.post(path + '/refresh', headers=browser_headers).json() == {'status': 'paid'}
    for _ in range(2):
        assert webhook(f, annual_paid).status_code == 204
    annual_order = order(f, oid)
    validate('BillingOrder', annual_order)
    assert annual_order['period_start'] == monthly_end
    assert '365 天云同步已到账' in f.client.get(path + '?returned=1').text
    rights = f.client.get('/v1/me/entitlements', headers=auth_headers).json()
    assert (rights['sync_write'], rights['current_period_end'], rights['plan_id']) == (
        True, annual_order['period_end'], ANNUAL.plan_id)
    assert checkout(f).json()['code'] == 'billing_period_already_reserved'
    with connect() as conn:
        assert conn.execute('SELECT end_at - start_at AS length FROM billing_periods WHERE checkout_id=%s',
                            (oid,)).fetchall() == [{'length': timedelta(days=365)}]

    refund = f.adapter.event('refund_succeeded', oid, annual_paid.external_id, amount_minor=400,
                             provider_product_id=ANNUAL.provider_product_id,
                             merchant_refund_id='annual-partial', provider_refund_id='annual-partial-provider')
    assert webhook(f, replace(refund, provider_product_id=MONTHLY.provider_product_id)).status_code == 422
    assert webhook(f, refund).status_code == 204
    assert order(f, oid)['status'] == 'paid'
    refund_balance = replace(refund, event_id='annual-balance', amount_minor=599,
                             merchant_refund_id='annual-balance', provider_refund_id='annual-balance-provider')
    for _ in range(2):
        assert webhook(f, refund_balance).status_code == 204
    assert order(f, oid)['status'] == 'refunded'
    rights = f.client.get('/v1/me/entitlements', headers=auth_headers).json()
    assert (rights['sync_write'], rights['current_period_end'], rights['plan_id']) == (True, monthly_end, MONTHLY.plan_id)


def test_live_flags_fail_closed_and_never_block_self_hosting(monkeypatch):
    from weekglass_server import waffo
    monkeypatch.setattr(settings, 'mode', 'hosted')
    monkeypatch.setattr(settings, 'public_origin', ORIGIN)
    monkeypatch.delenv('WEEKGLASS_WAFFO_LIVE_ACCEPT_EVENTS', raising=False)
    monkeypatch.delenv('WEEKGLASS_WAFFO_LIVE_ANNUAL_ENABLED', raising=False)
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ENABLED', 'true')
    assert waffo_runtime.configured() is None
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ACCEPT_EVENTS', 'true')
    adapter = LiveFixture()
    monkeypatch.setattr(waffo.WaffoLive, 'load', lambda: adapter)
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ACCOUNT_ID', 'not-an-account')
    assert not waffo_runtime.configured().checkout_enabled
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ACCOUNT_ID', str(uuid4()))
    assert [plan['plan_id'] for plan in billing.offers(waffo_runtime.configured())] == ['cloud-30d']
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ANNUAL_ENABLED', 'true')
    assert [plan['plan_id'] for plan in billing.offers(waffo_runtime.configured())] == ['cloud-30d', 'cloud-365d']
    monkeypatch.setattr(adapter, 'catalog_amount', lambda product: 998 if product == adapter.annual_product_id else 100)
    assert [plan['plan_id'] for plan in billing.offers(waffo_runtime.configured())] == ['cloud-30d']
    monkeypatch.setattr(adapter, 'catalog_amount', lambda product: 999 if product == adapter.annual_product_id else 101)
    assert [plan['plan_id'] for plan in billing.offers(waffo_runtime.configured())] == ['cloud-365d']
    monkeypatch.setattr(settings, 'mode', 'self_hosted')
    assert waffo_runtime.configured() is None
