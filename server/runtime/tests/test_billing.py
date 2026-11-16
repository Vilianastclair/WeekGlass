"""The only payment adapter used in these tests is synthetic and in-process."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta
from types import SimpleNamespace
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient

from weekglass_server import auth, billing
from weekglass_server.db import connect
from weekglass_server.main import app
from weekglass_server.protocol import now, stamp, validate
from weekglass_server.settings import settings
from test_auth import account, client, headers, running_client, tokens_for
from test_sync import batch, event


class SimulatedProvider:
    provider = 'test-only'
    app_id = 'isolated-weekglass'

    def __init__(self):
        self.merchant_id = uuid4().hex

    def verify_event(self, headers, raw):
        raise AssertionError('Synthetic normalized events must never enter through HTTP')

    def result(self, kind, related_id, **fields):
        event = billing.VerifiedEvent(uuid4().hex, kind, self.provider, self.merchant_id, self.app_id,
                                      UUID(str(related_id)), now())
        return replace(event, **fields)


class Flow:
    def __init__(self, client, account, tokens, config):
        self.client, self.account, self.tokens, self.config = client, account, tokens, config
        self.headers = headers(tokens)

    def call(self, method, resource, **kw):
        return self.client.request(method, '/v1/billing' + resource,
                                   headers={**self.headers, **kw.pop('headers', {})}, **kw)

    def checkout(self, mode='single', key=None, **intent):
        plan, = self.config.plans
        return self.call('POST', '/checkout-sessions', headers={'Idempotency-Key': str(key or uuid4())},
                         json={'plan_id': plan.plan_id, 'purchase_mode': mode,
                               'terms_version': plan.terms_version, **intent})

    def claim(self, checkout_id):
        return billing.claim_checkout(self.config, UUID(checkout_id))

    def verified(self, kind, oid, external_id=None, **fields):
        return self.config.adapter.result(kind, oid, amount_minor=self.config.plans[0].amount_minor, currency='CNY',
                                          external_id=external_id or uuid4().hex, **fields)

    def apply(self, event, result='applied'):
        assert billing.apply_verified_event(self.config.adapter, event) == result

    def buy(self, mode='single'):
        checkout = checked(self.checkout(mode), 'CheckoutSession', 201)
        oid = checkout['checkout_id']
        order = self.claim(oid)
        assert order['status'] == 'submitting'
        payment = self.verified('payment_paid', oid)
        self.apply(payment)
        return self.order(oid), order['agreement_id'], payment

    def order(self, oid):
        return checked(self.call('GET', '/orders/' + oid), 'BillingOrder')

    def subscription(self):
        return checked(self.call('GET', '/subscription'), 'BillingSubscription')

    def rights(self):
        return checked(self.client.get('/v1/me/entitlements', headers=self.headers), 'Entitlements')


def checked(response, schema, status=200):
    assert response.status_code == status, response.text
    validate(schema, response.json())
    return response.json()


@pytest.fixture
def flow(client, account, monkeypatch):
    tokens = tokens_for(client, account)
    monkeypatch.setattr(settings, 'mode', 'hosted')
    monkeypatch.setattr(settings, 'public_origin', billing.OFFICIAL_ORIGIN)
    monkeypatch.setattr(settings, 'alternate_origins', (str(client.base_url).rstrip('/'),))
    config = billing.BillingConfig(SimulatedProvider(), (billing.BillingPlan('test-30d', 'test-terms-v1', 1234),),
                                  checkout_enabled=True, auto_renew_enabled=True, template_id='test-template')
    monkeypatch.setattr(app.state, 'billing', config)
    yield Flow(client, account, tokens, config)
    # This fixture only removes rows belonging to its synthetic merchant/account.
    # The FK cycle intentionally retains real finance records on account deletion.
    scope = config.scope
    with connect() as conn:
        conn.execute('DELETE FROM billing_checkout_keys WHERE account_id=%s', (account[0],))
        for table in ('billing_checkout_handoffs', 'billing_periods'):
            conn.execute(f'''DELETE FROM {table} x USING billing_orders o WHERE x.checkout_id=o.checkout_id
              AND (o.provider,o.merchant_id,o.app_id)=(%s,%s,%s)''', scope)
        conn.execute('DELETE FROM billing_refunds WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', scope)
        conn.execute('DELETE FROM billing_events WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', scope)
        conn.execute('''UPDATE billing_renewals r SET status='skipped',order_id=NULL FROM billing_orders o
          WHERE r.order_id=o.checkout_id AND (o.provider,o.merchant_id,o.app_id)=(%s,%s,%s)''', scope)
        conn.execute('DELETE FROM billing_orders WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', scope)
        conn.execute('''DELETE FROM billing_renewals WHERE account_id=%s OR agreement_id IN (
          SELECT agreement_id FROM billing_agreements WHERE (provider,merchant_id,app_id)=(%s,%s,%s))''',
          (account[0], *scope))
        conn.execute('DELETE FROM billing_agreements WHERE (provider,merchant_id,app_id)=(%s,%s,%s)', scope)


def test_closed_runtime_and_self_hosted_free(flow, monkeypatch):
    monkeypatch.setattr(app.state, 'billing', None)
    info = flow.client.get('/v1/server-info').json()
    assert 'subscription' in info['capabilities'] and 'billing_checkout' not in info['capabilities']
    assert 'billing_auto_renew' not in info['capabilities']
    assert checked(flow.call('GET', '/plans'), 'BillingPlans') == {'plans': []}
    assert flow.call('POST', '/checkout-sessions').json()['code'] == 'billing_not_configured'
    assert flow.subscription()['agreement_status'] == 'none'
    assert flow.client.get('/v1/billing/subscription').status_code == 401
    assert flow.client.post('/v1/billing/webhooks/test-only', json={'amount_minor': 1234}).status_code == 404
    assert not flow.rights()['sync_write']
    monkeypatch.setattr(settings, 'mode', 'self_hosted')
    monkeypatch.setattr(app.state, 'billing', flow.config)
    assert 'subscription' not in flow.client.get('/v1/server-info').json()['capabilities']
    assert flow.rights()['sync_write'] and flow.rights()['status'] == 'self_hosted'
    assert flow.checkout().status_code == flow.call('GET', '/subscription').status_code == 404


def test_quote_idempotency_scope_and_browser_handoff(flow, monkeypatch):
    caps = flow.client.get('/v1/server-info').json()['capabilities']
    assert {'billing_checkout', 'billing_auto_renew'}.issubset(caps)
    plan, = checked(flow.call('GET', '/plans'), 'BillingPlans')['plans']
    assert plan['period_seconds'] == 2592000 and plan['amount_minor'] == 1234
    assert flow.checkout(terms_version='old').json()['code'] == 'billing_terms_changed'
    key = uuid4()
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda k: flow.checkout(key=k), (key, uuid4())))
    first, second = (checked(r, 'CheckoutSession', 201) for r in responses)
    assert first['checkout_id'] == second['checkout_id']
    oid = first['checkout_id']
    assert flow.checkout(key=key).json()['checkout_id'] == oid
    assert flow.checkout('auto_renew', key=key).json()['code'] == 'idempotency_key_reused'
    assert flow.checkout('auto_renew').json()['code'] == 'billing_order_unresolved'
    username = 'test-other-' + uuid4().hex
    other = auth.create_account(username, flow.account[2])
    try:
        # Login once using the other account; resource ownership comes from the bearer.
        monkeypatch.setattr(settings, 'public_origin', str(flow.client.base_url).rstrip('/'))
        other_tokens = tokens_for(flow.client, (other, username, flow.account[2]))
        monkeypatch.setattr(settings, 'public_origin', billing.OFFICIAL_ORIGIN)
        assert flow.client.get('/v1/billing/orders/' + oid, headers=headers(other_tokens)).status_code == 404
        assert flow.client.post('/v1/billing/orders/' + oid + '/close', headers=headers(other_tokens)).status_code == 404
    finally:
        with connect() as conn:
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (other,))
    href = urlsplit(first['url'])
    assert href.scheme == 'https' and href.netloc == 'cloud.viliana.cn' and not href.query
    ticket = href.fragment.removeprefix('ticket=')
    endpoint = href.path + '/handoff'
    with TestClient(app, base_url=billing.OFFICIAL_ORIGIN) as browser:
        assert 'fetch(' in browser.get(href.path).text
        assert browser.post(endpoint, json={'ticket': ticket}, headers={'Origin': 'https://not-weekglass.invalid'}).status_code == 403
        assert browser.post(f'/v1/billing/checkout/{uuid4()}/handoff', json={'ticket': ticket},
                            headers={'Origin': billing.OFFICIAL_ORIGIN}).status_code == 403
        redeem = browser.post(endpoint, json={'ticket': ticket}, headers={'Origin': billing.OFFICIAL_ORIGIN})
        assert redeem.status_code == 200
        assert all(flag in redeem.headers['set-cookie'] for flag in ('HttpOnly', 'Secure', href.path))
        assert '当前未接通在线收银' in browser.get(href.path).text
        assert browser.get('/v1/me/entitlements').status_code == 401
        assert browser.post(endpoint, json={'ticket': ticket}, headers={'Origin': billing.OFFICIAL_ORIGIN}).status_code == 403
        closed = checked(flow.call('POST', f'/orders/{oid}/close'), 'BillingOrder')
        assert closed['status'] == 'closed'
        assert browser.post(endpoint, json={'ticket': second['url'].split('#ticket=')[1]},
                            headers={'Origin': billing.OFFICIAL_ORIGIN}).status_code == 403
    assert flow.checkout(key=key).json() == {'checkout_id': oid, 'url': None, 'expires_at': None}
    assert not flow.rights()['sync_write']


def test_paid_periods_extend_once_and_share_write_gate(flow, monkeypatch):
    with connect() as conn:
        account_row = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (flow.account[0],)).fetchone()
    payload = batch(SimpleNamespace(identity=flow.tokens, account=account_row), [event()])
    assert flow.client.post('/v1/sync/batches', headers=flow.headers, json=payload).json()['code'] == 'subscription_required'
    checkout = checked(flow.checkout(), 'CheckoutSession', 201)
    oid = checkout['checkout_id']
    assert not flow.rights()['sync_write']
    assert flow.claim(oid)['status'] == 'submitting' and flow.claim(oid) is None
    paid = flow.verified('payment_paid', oid)
    flow.apply(replace(paid, amount_minor=1), 'rejected')
    flow.apply(replace(paid, merchant_id='wrong'), 'rejected')
    paid = replace(paid, event_id=uuid4().hex)
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(flow.apply, (paid, paid)))
    flow.apply(replace(paid, event_id=uuid4().hex))
    assert flow.order(oid)['status'] == 'paid'
    first_end = flow.order(oid)['period_end']
    assert flow.rights()['current_period_end'] == first_end
    receipt = checked(flow.client.post('/v1/sync/batches', headers=flow.headers, json=payload), 'Receipt')
    second, _, _ = flow.buy()
    assert second['period_start'] == first_end
    assert flow.checkout().json()['code'] == 'billing_period_already_reserved'
    monkeypatch.setattr('weekglass_server.entitlements.now', lambda: datetime.fromisoformat(second['period_end']))
    rights = flow.rights()
    assert rights['status'] == 'expired' and not rights['sync_read'] and not rights['sync_write']
    assert rights['current_period_end'] == second['period_end'] and rights['export_allowed']
    assert flow.client.post('/v1/sync/batches', headers=flow.headers, json=payload).json() == receipt
    assert flow.client.get('/v1/sync/batches/' + payload['batch_id'], headers=flow.headers).json() == receipt
    assert flow.client.get('/v1/exports/calendar', headers=flow.headers).json()['code'] == 'subscription_required'


def test_agreement_due_guard_cancel_and_inflight_settlement(flow):
    order, agreement_id, _ = flow.buy('auto_renew')
    initial = flow.subscription()
    assert initial['agreement_status'] == 'pending' and not initial['auto_renew']
    assert initial['paid_period_end'] == order['period_end']
    signed = flow.verified('agreement_signed', agreement_id, template_id=flow.config.template_id)
    flow.apply(signed)
    due = now() - timedelta(minutes=1)
    end = now() + timedelta(minutes=5)
    def plan(delivered):
        return billing.plan_renewal(flow.config, agreement_id, due, end, delivered,
                                    'verified-test-delivery' if delivered else None, due)
    slot = plan(None)
    assert slot and billing.claim_renewal(flow.config, slot) is None
    slot = plan(due - timedelta(days=4))
    assert slot and billing.claim_renewal(flow.config, slot) is None
    slot = plan(due - timedelta(days=5))
    assert slot and flow.subscription()['next_charge_at'] == stamp(due)
    with connect() as conn:
        conn.execute('UPDATE auth_accounts SET enabled=false WHERE account_id=%s', (flow.account[0],))
    assert billing.claim_renewal(flow.config, slot) is None
    assert plan(due - timedelta(days=5)) is None
    with connect() as conn:
        conn.execute('UPDATE auth_accounts SET enabled=true WHERE account_id=%s', (flow.account[0],))
    assert plan(due - timedelta(days=5)) == slot
    # A manual order occupies the very same slot; releasing an unsubmitted order is safe.
    manual = checked(flow.checkout(), 'CheckoutSession', 201)['checkout_id']
    assert billing.claim_renewal(flow.config, slot) is None
    assert flow.call('POST', f'/orders/{manual}/close').status_code == 200
    assert plan(due - timedelta(days=5)) == slot
    automatic = billing.claim_renewal(flow.config, slot)
    assert automatic and billing.claim_renewal(flow.config, slot) is None
    assert flow.checkout().json()['code'] == 'billing_order_unresolved'
    cancel = checked(flow.call('POST', '/subscription/cancel'), 'BillingSubscription')
    assert cancel['agreement_status'] == 'canceling' and not cancel['auto_renew']
    assert cancel['in_flight_order']['checkout_id'] == str(automatic['checkout_id'])
    assert flow.call('POST', '/subscription/cancel').json() == cancel
    flow.apply(flow.verified('payment_paid', automatic['checkout_id']))
    assert flow.order(str(automatic['checkout_id']))['status'] == 'refund_pending'
    assert flow.rights()['current_period_end'] == order['period_end']
    flow.apply(flow.verified('agreement_ended', agreement_id, external_id=signed.external_id))
    flow.apply(replace(signed, event_id=uuid4().hex))
    assert flow.subscription()['agreement_status'] == 'canceled'
    assert not billing.claim_renewal(flow.config, slot)


def test_due_guard_preserves_admin_grant_and_limits_prepaid_periods(flow):
    order, agreement_id, _ = flow.buy('auto_renew')
    flow.apply(flow.verified('agreement_signed', agreement_id, template_id=flow.config.template_id))
    grant_end = now() + timedelta(days=35)
    with connect() as conn:
        conn.execute('UPDATE accounts SET grant_until=%s WHERE account_id=%s', (grant_end, flow.account[0]))
    assert flow.subscription()['paid_period_end'] == order['period_end']
    assert flow.rights()['current_period_end'] == stamp(grant_end)
    due = now() - timedelta(minutes=1)
    def plan():
        return billing.plan_renewal(flow.config, agreement_id, due, now() + timedelta(minutes=5),
                                    due - timedelta(days=5), 'verified-test-delivery', due)
    slot = plan()
    second, _, _ = flow.buy()
    assert second['period_start'] == stamp(grant_end)
    with connect() as conn:
        manual = conn.execute('SELECT renewal_id FROM billing_orders WHERE checkout_id=%s', (second['checkout_id'],)).fetchone()
    assert manual['renewal_id'] == slot
    assert plan() is None and billing.claim_renewal(flow.config, slot) is None
    assert flow.checkout().json()['code'] == 'billing_period_already_reserved'


def test_refund_before_payment_and_partial_refund_keep_correct_access(flow):
    oid = checked(flow.checkout(), 'CheckoutSession', 201)['checkout_id']
    flow.claim(oid)
    paid = flow.verified('payment_paid', oid)
    full = flow.config.adapter.result('refund_succeeded', oid, external_id=paid.external_id,
        amount_minor=1234, currency='CNY', merchant_refund_id='merchant-1', provider_refund_id=uuid4().hex)
    flow.apply(full, 'deferred')
    flow.apply(paid)
    assert flow.order(oid)['status'] == 'refunded' and not flow.rights()['sync_write']
    flow.apply(replace(paid, event_id=uuid4().hex))
    assert flow.order(oid)['status'] == 'refunded'
    first, _, payment = flow.buy()
    second, _, _ = flow.buy()
    pending = replace(full, event_id=uuid4().hex, kind='refund_pending', related_id=UUID(first['checkout_id']),
                      external_id=payment.external_id, amount_minor=200, merchant_refund_id='merchant-2', provider_refund_id=uuid4().hex)
    flow.apply(pending)
    assert flow.order(first['checkout_id'])['status'] == 'refund_pending'
    assert flow.rights()['current_period_end'] == second['period_end']
    flow.apply(replace(pending, kind='refund_succeeded', event_id=uuid4().hex))
    assert flow.rights()['current_period_end'] == second['period_end']
    rest = replace(pending, kind='refund_succeeded', event_id=uuid4().hex, amount_minor=1034,
                   merchant_refund_id='merchant-3', provider_refund_id=uuid4().hex)
    flow.apply(replace(rest, amount_minor=1035), 'rejected')
    flow.apply(replace(rest, event_id=uuid4().hex))
    assert flow.order(first['checkout_id'])['status'] == 'refunded'
    moved = flow.order(second['checkout_id'])
    assert moved['period_start'] < second['period_start']
    assert datetime.fromisoformat(moved['period_end']) - datetime.fromisoformat(moved['period_start']) == timedelta(days=30)
    assert flow.rights()['current_period_end'] == moved['period_end']


def test_delete_detaches_finance_and_late_payment_cannot_restore_account(flow):
    order, agreement_id, _ = flow.buy('auto_renew')
    flow.apply(flow.verified('agreement_signed', agreement_id, template_id=flow.config.template_id))
    pending = checked(flow.checkout(), 'CheckoutSession', 201)['checkout_id']
    assert flow.claim(pending)
    response = flow.client.request('DELETE', '/v1/me/account', headers=flow.headers,
                                  json={'current_password': flow.account[2], 'confirmation': flow.account[1]})
    assert response.status_code == 204, response.text
    flow.apply(flow.verified('payment_paid', pending))
    with connect() as conn:
        assert not conn.execute('SELECT 1 FROM accounts WHERE account_id=%s', (flow.account[0],)).fetchone()
        assert conn.execute('SELECT account_id,status FROM billing_orders WHERE checkout_id=%s', (pending,)).fetchone() == {
            'account_id': None, 'status': 'refund_pending'}
        period = conn.execute('SELECT account_id,revoked_at FROM billing_periods WHERE checkout_id=%s', (order['checkout_id'],)).fetchone()
        assert period['account_id'] is None and period['revoked_at']
        assert not conn.execute('SELECT 1 FROM billing_periods WHERE checkout_id=%s', (pending,)).fetchone()
        agreement = conn.execute('SELECT account_id,status FROM billing_agreements WHERE agreement_id=%s', (agreement_id,)).fetchone()
        assert agreement == {'account_id': None, 'status': 'canceling'}
    assert flow.call('GET', '/subscription').status_code == 401
