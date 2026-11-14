"""Browser/ledger test with PostgreSQL and a simulated Waffo SDK response."""
from datetime import timedelta
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
import pytest

from test_auth import headers, tokens_for
from weekglass_server import auth, billing, main
from weekglass_server.protocol import now, stamp
from weekglass_server.settings import settings
from weekglass_server.waffo import BridgeError, WaffoTest
from weekglass_server.waffo_lab import install, make_config, new_order_link

ORIGIN = 'http://127.0.0.1:18081'
URL = 'https://checkout.waffo.ai/test-shop/checkout/cs_550e8400-e29b-41d4-a716-446655440000'


@pytest.fixture
def lab(monkeypatch):
    if os.environ.get('DB_HOST') != '127.0.0.1' or settings.database_url:
        pytest.skip('Waffo lab requires a PostgreSQL server on loopback')
    assert os.environ.get('DB_NAME', '').endswith('_test')
    monkeypatch.setattr(settings, 'mode', 'hosted')
    monkeypatch.setattr(settings, 'public_origin', ORIGIN)
    monkeypatch.setattr(settings, 'alternate_origins', ())
    adapter = WaffoTest('MER_test', 'STO_test', 'PROD_test', Path('unused'))
    calls = []
    completed = {}
    verified = {}

    def sdk(self, operation, **data):
        calls.append((operation, data))
        if operation == 'catalog':
            return {'test_mode': True, 'product_id': 'PROD_test', 'store_id': 'STO_test',
                    'currency': 'CNY', 'amount': '3.00'}
        if operation == 'create_checkout':
            assert data['currency'] == 'CNY' and data['amount'] == '3.00'
            return {'session_id': URL.rsplit('/', 1)[-1], 'checkout_url': URL,
                    'expires_at': stamp(now() + timedelta(minutes=15))}
        if operation == 'query_order':
            return {'order': completed.get(data['external_order_id'])}
        if operation == 'verify_webhook':
            if data['signature'] not in verified:
                raise BridgeError('invalid_webhook')
            return {'payload': verified[data['signature']]}
        raise AssertionError(operation)

    monkeypatch.setattr(WaffoTest, '_call', sdk)
    app = FastAPI(lifespan=main.lifespan)
    app.state.billing = None
    app.include_router(auth.router)
    app.include_router(main.account.router)
    app.include_router(main.billing_routes.router)
    app.add_exception_handler(HTTPException, main.http_error)
    install(app, make_config(adapter))
    with TestClient(app, base_url=ORIGIN, follow_redirects=False) as client:
        yield client, calls, completed, verified


def test_test_cashier_returns_to_its_original_account(lab):
    client, calls, completed, verified = lab
    user = 'waffo-test-' + uuid4().hex
    password = 'test-' + uuid4().hex
    account_id = auth.create_account(user, password)
    tokens = tokens_for(client, (account_id, user, password))
    credentials = headers(tokens)
    plans = client.get('/v1/billing/plans', headers=credentials).json()['plans']
    assert plans[0]['purchase_modes'] == ['single']
    assert plans[0]['amount_minor'] == 300
    checkout = client.post('/v1/billing/checkout-sessions',
                           headers={**credentials, 'Idempotency-Key': str(uuid4())},
                           json={'plan_id': plans[0]['plan_id'], 'purchase_mode': 'single'})
    assert checkout.status_code == 201, checkout.text
    payload = checkout.json()
    link = urlsplit(payload['url'])
    path = link.path
    ticket = parse_qs(link.fragment)['ticket'][0]
    assert client.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 403
    assert client.get(path).status_code == 200
    assert client.post(path + '/handoff', headers={'Origin': 'https://other.invalid'},
                       json={'ticket': ticket}).status_code == 403
    assert client.post(path + '/handoff', headers={'Origin': ORIGIN}, json={'ticket': ticket}).status_code == 200
    assert client.post(path + '/handoff', headers={'Origin': ORIGIN}, json={'ticket': ticket}).status_code == 403
    page = client.get(path)
    assert page.status_code == 200 and '打开测试收银台' in page.text and 'lake-drift' in page.text
    for _ in range(2):
        assert client.post(path + '/provider', headers={'Origin': ORIGIN}).json() == {'url': URL}
    assert [op for op, _ in calls].count('create_checkout') == 1
    assert client.post('/v1/billing/webhooks/waffo-test', headers={'X-Waffo-Signature': 'fake'}, content=b'{}').status_code == 401
    assert client.post(path + '/refresh', headers={'Origin': ORIGIN}).json() == {'status': 'processing'}
    oid = payload['checkout_id']
    payment_id = 'PAY_' + uuid4().hex
    record = {'provider_payment_id': payment_id, 'status': 'succeeded', 'amount': '2.99', 'currency': 'CNY',
              'created_at': stamp(now()), 'refunds': []}
    completed[oid] = {'test_mode': True, 'status': 'completed', 'store_id': 'STO_test', 'product_id': 'PROD_test',
                      'external_order_id': oid, 'currency': 'CNY', 'amount': '3.00', 'payments': [record]}
    assert client.post(path + '/refresh', headers={'Origin': ORIGIN}).status_code == 503
    assert client.get('/v1/billing/orders/' + oid, headers=credentials).json()['status'] == 'processing'
    record['amount'] = '3.00'
    for _ in range(2):
        assert client.post(path + '/refresh', headers={'Origin': ORIGIN}).json() == {'status': 'paid'}
    order = client.get('/v1/billing/orders/' + oid, headers=credentials).json()
    assert order['status'] == 'paid' and order['period_start'] and order['period_end']
    record['refunds'].append({'status': 'succeeded'})
    verified['verified-fixture'] = {'eventType': 'refund.succeeded', 'eventId': 'REF_' + uuid4().hex,
        'storeId': 'STO_test', 'mode': 'test', 'timestamp': stamp(now()),
        'data': {'orderId': 'ORD_test', 'orderStatus': 'completed', 'paymentStatus': 'succeeded',
                 'refundStatus': 'succeeded', 'currency': 'CNY', 'orderMerchantExternalId': oid,
                 'orderMetadata': {'weekglass_product_id': 'PROD_test'}, 'refundedAmount': '3.00',
                 'paymentId': payment_id}}
    for _ in range(2):
        assert client.post('/v1/billing/webhooks/waffo-test',
                           headers={'X-Waffo-Signature': 'verified-fixture'}, content=b'{}').status_code == 204
    assert client.get('/v1/billing/orders/' + oid, headers=credentials).json()['status'] == 'refunded'


def test_sandbox_cannot_open_on_production(monkeypatch):
    monkeypatch.setattr(settings, 'mode', 'hosted')
    monkeypatch.setattr(settings, 'public_origin', billing.OFFICIAL_ORIGIN)
    adapter = WaffoTest('MER_test', 'STO_test', 'PROD_test', Path('unused'))
    with pytest.raises(BridgeError, match='loopback_test_database_required'):
        make_config(adapter)
    with pytest.raises(ValueError, match='isolated'):
        billing.BillingConfig(adapter, (billing.BillingPlan('30d', 'v1', 100),), checkout_enabled=True)


def test_operator_link_can_open_without_login(lab):
    client, _, _, _ = lab
    link = urlsplit(new_order_link(client.app.state.billing))
    assert link.netloc == '127.0.0.1:18081'
    ticket = parse_qs(link.fragment)['ticket'][0]
    assert client.post(link.path + '/handoff', headers={'Origin': ORIGIN}, json={'ticket': ticket}).status_code == 200
    assert '打开测试收银台' in client.get(link.path).text
