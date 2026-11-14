"""Live adapter boundary without production credentials, database, or Waffo access."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

import pytest

from weekglass_server.waffo import BridgeError, WaffoLive
from weekglass_server.billing import ANNUAL_PERIOD_SECONDS, MONTHLY_PLAN_ID, MONTHLY_TERMS, PERIOD_SECONDS


MERCHANT = 'MER_' + 'a' * 22
STORE = 'STO_' + 'b' * 22
PRODUCT = 'PROD_' + 'c' * 22
ANNUAL = 'PROD_' + 'f' * 22
PAYMENT = 'PAY_' + 'd' * 22
PROVIDER_ORDER = 'ORD_' + 'e' * 22
CHECKOUT = UUID('6061b32c-ac37-4157-b7a0-16deea07a318')
TIME = datetime(2026, 11, 13, 11, 13, 30, tzinfo=timezone.utc)
SESSION = 'cs_550e8400-e29b-41d4-a716-446655440000'
URL = f'https://pancake.waffo.ai/store/weekglass/checkout/{SESSION}'


@pytest.fixture
def adapter():
    return WaffoLive(MERCHANT, STORE, PRODUCT, Path('synthetic-only'), ANNUAL)


@pytest.fixture
def order(adapter, monkeypatch):
    monkeypatch.setattr('weekglass_server.waffo.now', lambda: TIME)
    return dict(provider=adapter.provider, merchant_id=MERCHANT, app_id=STORE, checkout_id=CHECKOUT,
                amount_minor=100, currency='CNY', source='checkout', purchase_mode='single', paid_at=None,
                plan_id=MONTHLY_PLAN_ID, terms_version=MONTHLY_TERMS, period_seconds=PERIOD_SECONDS,
                provider_product_id=None,  # pre-migration monthly order
                provider_checkout_expires_at=TIME + timedelta(minutes=1))


@pytest.fixture
def result():
    return dict(test_mode=False, status='completed', store_id=STORE, product_id=PRODUCT,
                external_order_id=str(CHECKOUT), provider_order_id=PROVIDER_ORDER,
                currency='CNY', amount='1.00', created_at=TIME.isoformat(), payments=[
                    dict(status='succeeded', provider_payment_id=PAYMENT, amount='1.00', currency='CNY',
                         created_at=TIME.isoformat(), refund_status='none', refunds=[]),
                ])


def stub_query(monkeypatch, result):
    def call(self, operation, **params):
        assert operation == 'query_order' and params == {'external_order_id': str(CHECKOUT)}
        return {'order': result}
    monkeypatch.setattr(WaffoLive, '_call', call)


def test_live_load_uses_only_its_separately_scoped_key_reference(monkeypatch, tmp_path):
    path = tmp_path / 'fixture.pem'
    path.touch()
    for key, value in (('MERCHANT_ID', MERCHANT), ('STORE_ID', STORE), ('PRODUCT_ID', PRODUCT), ('PRIVATE_KEY_FILE', str(path))):
        monkeypatch.setenv('WEEKGLASS_WAFFO_' + key, value)
        monkeypatch.delenv('WEEKGLASS_WAFFO_LIVE_' + key, raising=False)
    with pytest.raises(BridgeError, match='configure_live_merchant_store_and_product'):
        WaffoLive.load()
    for key, value in (('MERCHANT_ID', MERCHANT), ('STORE_ID', STORE), ('PRODUCT_ID', PRODUCT), ('PRIVATE_KEY_FILE', str(path))):
        monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_' + key, value)
    monkeypatch.delenv('WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID', raising=False)
    assert WaffoLive.load() == WaffoLive(MERCHANT, STORE, PRODUCT, path)
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID', PRODUCT)
    assert WaffoLive.load().annual_product_id is None
    monkeypatch.setenv('WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID', ANNUAL)
    assert WaffoLive.load().annual_product_id == ANNUAL


def test_checkout_uses_locked_quote_and_rejects_wrong_scope_or_url(adapter, order, monkeypatch):
    calls = []
    bridge = {'checkout_url': URL, 'session_id': SESSION, 'expires_at': (TIME + timedelta(minutes=15)).isoformat()}

    def call(self, operation, **params):
        calls.append((operation, params))
        return bridge

    monkeypatch.setattr(WaffoLive, '_call', call)
    for wrong in (dict(provider='waffo_pancake_test'), dict(currency='USD'), dict(purchase_mode='auto_renew'),
                  dict(merchant_id='wrong'), dict(amount_minor=True), dict(checkout_id=str(CHECKOUT))):
        with pytest.raises(BridgeError, match='live_order_scope_mismatch'):
            adapter.create_checkout({**order, **wrong})
    assert not calls
    assert adapter.create_checkout(order) == (URL, TIME + timedelta(minutes=15))
    assert calls == [('create_checkout', dict(product_id=PRODUCT, currency='CNY', amount='1.00',
                                              external_order_id=str(CHECKOUT)))]
    bridge['checkout_url'] += '?test=true'
    with pytest.raises(BridgeError, match='live_checkout_response_invalid'):
        adapter.create_checkout(order)


@pytest.mark.parametrize('wrong', [
    dict(test_mode=True), dict(store_id='wrong'), dict(product_id='wrong'), dict(external_order_id=str(UUID(int=1))),
    dict(currency='USD'), dict(amount='1.01'), dict(payments=[]),
])
def test_query_rejects_mismatched_order_or_missing_payment(adapter, order, result, wrong, monkeypatch):
    stub_query(monkeypatch, {**result, **wrong})
    with pytest.raises(BridgeError, match='live_order_response_invalid'):
        adapter.query_events(order)


def test_query_uses_actual_charge_and_never_promotes_absent_or_pending_records(adapter, order, result, monkeypatch):
    stub_query(monkeypatch, None)
    assert adapter.query_events(order) == []
    result['status'] = 'pending'
    result['payments'][0]['status'] = 'pending'
    stub_query(monkeypatch, result)
    assert adapter.query_events(order) == []
    result['status'] = 'completed'
    result['payments'][0].update(status='succeeded', amount='0.99')
    with pytest.raises(BridgeError, match='live_order_response_invalid'):
        adapter.query_events(order)
    result['payments'][0]['amount'] = '1.00'
    event, = adapter.query_events(order)
    assert (event.kind, event.event_id, event.amount_minor, event.external_id, event.occurred_at) == (
        'payment_paid', 'query:paid:' + PAYMENT, 100, PAYMENT, TIME,
    )


def test_canceled_order_closes_only_after_known_cashier_expiry_with_no_succeeded_or_pending_payment(adapter, order, result, monkeypatch):
    result['status'] = 'canceled'
    stub_query(monkeypatch, result)
    for status in ('succeeded', 'pending'):
        result['payments'][0]['status'] = status
        with pytest.raises(BridgeError, match='live_order_response_invalid'):
            adapter.query_events(order)
    result['payments'][0]['status'] = 'canceled'
    assert adapter.query_events(order) == []
    assert adapter.query_events({**order, 'provider_checkout_expires_at': None}) == []
    order['provider_checkout_expires_at'] = TIME
    event, = adapter.query_events(order)
    assert (event.kind, event.event_id, event.external_id, event.amount_minor) == (
        'payment_closed', 'query:closed:' + PROVIDER_ORDER, PROVIDER_ORDER, 100,
    )


def test_query_with_already_refunded_payment_waits_for_verified_ledger_evidence(adapter, order, result, monkeypatch):
    payment = result['payments'][0]
    payment['refund_status'] = 'refunded'
    payment['refunds'] = [dict(status='succeeded', provider_refund_id='RFD_' + label * 22, amount=amount, currency='CNY')
                          for label, amount in [('a', '0.40'), ('b', '0.60')]]
    stub_query(monkeypatch, result)
    assert adapter.query_events(order) == []
    order['verified_refund_amounts'] = {PAYMENT: 40}
    assert adapter.query_events(order) == []
    order['verified_refund_amounts'] = {'other-payment': 100}
    assert adapter.query_events(order) == []
    order['verified_refund_amounts'] = {PAYMENT: 100}
    assert [event.kind for event in adapter.query_events(order)] == ['payment_paid']


def test_annual_checkout_and_query_use_the_order_product_not_the_monthly_default(adapter, order, result, monkeypatch):
    annual = {**order, 'amount_minor': 999, 'period_seconds': ANNUAL_PERIOD_SECONDS, 'provider_product_id': ANNUAL}
    calls = []

    def cashier(self, operation, **params):
        calls.append((operation, params))
        return {'checkout_url': URL, 'session_id': SESSION, 'expires_at': (TIME + timedelta(minutes=15)).isoformat()}

    monkeypatch.setattr(WaffoLive, '_call', cashier)
    assert adapter.create_checkout(annual) == (URL, TIME + timedelta(minutes=15))
    assert calls == [('create_checkout', dict(product_id=ANNUAL, currency='CNY', amount='9.99',
                                              external_order_id=str(CHECKOUT)))]
    with pytest.raises(BridgeError, match='live_order_scope_mismatch'):
        adapter.create_checkout({**annual, 'provider_product_id': None})

    result['amount'] = result['payments'][0]['amount'] = '9.99'
    stub_query(monkeypatch, result)
    with pytest.raises(BridgeError, match='live_order_response_invalid'):
        adapter.query_events(annual)
    result['product_id'] = ANNUAL
    event, = adapter.query_events(annual)
    assert (event.kind, event.amount_minor, event.provider_product_id) == ('payment_paid', 999, ANNUAL)
