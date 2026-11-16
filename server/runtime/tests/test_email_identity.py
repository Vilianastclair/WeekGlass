"""Exercise the browser email flows on PostgreSQL, never against SMTP."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import re
import secrets
from threading import Event, Lock
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import anyio
from fastapi.testclient import TestClient
from psycopg import sql
import pytest

from test_account import continue_tokens, key_from
from test_auth import account, begin, callback_from, client, code_for, headers, refresh_form, running_client, tokens_for
from weekglass_server import auth, billing, email_delivery, email_identity
from weekglass_server.db import connect
from weekglass_server.main import app
from weekglass_server.migrations import migrate_auth, migrate_email_identity
from weekglass_server.settings import settings


@pytest.fixture
def delivery(client, monkeypatch):
    class FakeMail(list):
        pass

    messages = FakeMail()
    monkeypatch.setattr(settings, 'mode', 'hosted')
    monkeypatch.setattr(settings, 'email_signup_enabled', True)
    monkeypatch.setattr(email_delivery, 'available', lambda: True)
    monkeypatch.setattr(email_delivery, 'send_code', lambda *mail: messages.append(mail))
    orders = []
    merchant = 'email-test-' + uuid4().hex
    product = 'email-test-sku'

    def start_order(account_id, provider=billing.WAFFO_LIVE_PROVIDER):
        checkout, renewal = uuid4(), uuid4()
        with connect() as conn:
            conn.execute("INSERT INTO billing_renewals(renewal_id,account_id,status) VALUES (%s,%s,'skipped')", (renewal, account_id))
            conn.execute('''INSERT INTO billing_orders(checkout_id,account_id,renewal_id,source,purchase_mode,provider,
              merchant_id,app_id,plan_id,terms_version,amount_minor,currency,period_seconds,provider_product_id,status,created_at)
              VALUES(%s,%s,%s,'checkout','single',%s,%s,'test',%s,%s,100,'CNY',2592000,%s,'processing',now())''',
              (checkout, account_id, renewal, provider, merchant, billing.MONTHLY_PLAN_ID, billing.MONTHLY_TERMS, product))
            conn.execute("UPDATE billing_renewals SET status='reserved',order_id=%s WHERE renewal_id=%s", (checkout, renewal))
        order = checkout, renewal, provider
        orders.append(order)
        return order

    def event(order, *, refund=False, amount=100):
        checkout, _, provider = order
        adapter = SimpleNamespace(provider=provider, merchant_id=merchant, app_id='test', product_id=product)
        refund_ids = {'merchant_refund_id': 'refund-' + checkout.hex, 'provider_refund_id': 'remote-' + checkout.hex} if refund else {}
        synthetic = billing.VerifiedEvent(uuid4().hex, 'refund_succeeded' if refund else 'payment_paid', provider,
                                          merchant, 'test', checkout, auth.now(), external_id='paid-' + checkout.hex,
                                          amount_minor=amount, currency='CNY', provider_product_id=product, **refund_ids)
        # Exercise the real settlement transaction. This origin override is
        # only checked inside Python; these tests never contact any provider.
        with monkeypatch.context() as scope:
            if provider == billing.WAFFO_LIVE_PROVIDER:
                scope.setattr(settings, 'public_origin', billing.OFFICIAL_ORIGIN)
            elif provider == billing.WAFFO_TEST_PROVIDER:
                # This fixture only writes to the dedicated *_test database.
                # Test the already-verified sandbox settlement, not transport.
                scope.setattr(billing, 'sandbox_database', lambda origin: True)
            return billing.apply_verified_event(adapter, synthetic)

    def pay(account_id):
        order = start_order(account_id)
        assert event(order) == 'applied'
        return order

    messages.start_order, messages.event, messages.pay = start_order, event, pay
    yield messages
    with connect() as conn:
        # Tests use the testclient peer and synthetic addresses only.
        buckets = [auth.hashed(purpose + ':testclient') for purpose in ('email-send-ip', 'email-browser-ip')]
        buckets += [auth.hashed(prefix + ':' + pool) for prefix in ('email-send-budget', 'email-send-day-budget')
                    for pool in ('bind', 'verified')]
        conn.execute('DELETE FROM auth_rate_limits WHERE bucket=ANY(%s)', (buckets,))
        for checkout, renewal, _ in orders:
            conn.execute('DELETE FROM billing_events WHERE related_id=%s AND merchant_id=%s', (checkout, merchant))
            conn.execute('DELETE FROM billing_refunds WHERE checkout_id=%s', (checkout,))
            conn.execute('DELETE FROM billing_periods WHERE checkout_id=%s', (checkout,))
            conn.execute("UPDATE billing_renewals SET status='skipped',order_id=NULL WHERE renewal_id=%s", (renewal,))
            conn.execute('DELETE FROM billing_orders WHERE checkout_id=%s', (checkout,))
            conn.execute('DELETE FROM billing_renewals WHERE renewal_id=%s', (renewal,))


@pytest.fixture
def address(client):
    names = []

    def create(*, long=False):
        email = (('e' * 27) if long else '') + uuid4().hex + '@' + (('long-name.' * 5) if long else '') + 'example.test'
        names.append(email)
        return email

    yield create
    with connect() as conn:
        accounts = conn.execute('''DELETE FROM accounts WHERE account_id IN
          (SELECT account_id FROM auth_accounts WHERE verified_email=ANY(%s) OR pending_email=ANY(%s)) RETURNING account_id''',
          (names, names)).fetchall()
        for account in accounts:
            conn.execute('DELETE FROM auth_rate_limits WHERE bucket=%s', (email_identity._account_send_bucket(account['account_id']),))
        for email in names:
            buckets = [email_identity._resend_bucket(email), email_identity._resend_bucket(email, actual=False),
                       email_identity._mailbox_send_bucket(email), email_identity._digest('weekglass-pending-signup-hour-v1', email)]
            buckets += [bucket for bucket, _, _ in email_identity._guess_limits(email)]
            conn.execute('DELETE FROM auth_rate_limits WHERE bucket=ANY(%s)', (buckets,))


def post(client, action, csrf, **fields):
    return client.post('/v1/auth/authorize', headers={'Origin': settings.public_origin, 'Accept': 'text/html'},
                       data={'action': action, 'csrf': csrf, **fields})


def action_in(response, action, status=200):
    assert response.status_code == status, response.text
    assert f'name="action" value="{action}"' in response.text
    assert 'id="handoff-link"' not in response.text


def redeem(client, flow, response):
    params, verifier, _ = flow
    query = parse_qs(urlsplit(callback_from(response)).query)
    assert query['state'] == [params['state']]
    reply = client.post('/v1/auth/token', data={
        'grant_type': 'authorization_code', 'client_id': 'weekglass-native', 'code': query['code'][0],
        'code_verifier': verifier, 'redirect_uri': params['redirect_uri'], 'device_id': params['device_id']})
    assert reply.status_code == 200, reply.text
    return reply.json()


def saved_flow(csrf):
    with connect() as conn:
        return conn.execute('''SELECT f.*,g.expires_at AS grant_expiry FROM auth_email_flows f
          JOIN auth_grants g USING(grant_hash) WHERE g.csrf_hash=%s''', (auth.hashed(csrf),)).fetchone()


def lift_cooldown(email):
    # Move just this test address's cooldown to the past instead of sleeping.
    with connect() as conn:
        conn.execute('UPDATE auth_rate_limits SET reset_at=now()-interval \'1 second\' WHERE bucket=%s',
                     (email_identity._resend_bucket(email),))


def sent(delivery, email, purpose):
    actual_target, actual_purpose, code = delivery[-1]
    assert (actual_target, actual_purpose) == (email, purpose)
    assert len(code) == 6 and code.isascii() and code.isdigit()
    return code


def generated_password():
    return 'Wg7-' + secrets.token_urlsafe(24)


@pytest.mark.parametrize(('password', 'valid'), [
    ('Abcdefg1', True), ('1!234567', True), ('中文安全码١٢٣', True), ('abcdefg!', True),
    ('abcdefgh', False), ('12345678', False), ('!@#$%^&*', False), ('abc defg', False),
    ('Abcd123', False), ('x' * 127 + '9', True), ('x' * 128 + '9', False),
])
def test_new_email_password_policy_counts_two_classes_at_8_to_128_characters(password, valid):
    assert auth.email_password_valid(password) is valid


def signup(client, delivery, email, password):
    flow = begin(client)
    count = len(delivery)
    tokens = redeem(client, flow, post(client, 'email_register', flow[2], email=email, password=password, confirm_password=password))
    assert len(delivery) == count
    return tokens


def bind(client, delivery, account, email, *, kind='username', use_pending=False):
    flow = begin(client)
    action_in(post(client, 'email_manage_begin', flow[2], identity_kind=kind, identifier=account[1], password=account[2]),
              'email_bind_send')
    action_in(post(client, 'email_bind_send', flow[2], email='' if use_pending else email), 'email_bind_verify')
    return redeem(client, flow, post(client, 'email_bind_verify', flow[2], code=sent(delivery, email, 'bind')))


def verified_signup(client, delivery, email, password):
    tokens = signup(client, delivery, email, password)
    delivery.pay(tokens['account_id'])
    updated = bind(client, delivery, (tokens['account_id'], email, password), email, kind='email', use_pending=True)
    assert updated['account_id'] == tokens['account_id']
    return tokens


def test_signup_creates_unverified_account_without_smtp_and_uses_normalized_email(client, delivery, address, monkeypatch):
    email = address()
    password = 'Abcd1234'
    monkeypatch.setattr(email_delivery, 'available', lambda: False)
    invalid = begin(client)
    action_in(post(client, 'email_register', invalid[2], email=email, password='abc defg', confirm_password='abc defg'),
              'email_register', 400)
    tokens = signup(client, delivery, '  ' + email.upper() + '  ', password)
    with connect() as conn:
        stored = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (tokens['account_id'],)).fetchone()
    assert stored['pending_email'] == email and stored['verified_email'] is None and stored['email_verified_at'] is None
    assert stored['password_hash'].startswith('$argon2id$') and stored['pending_login_key'] != password
    profile = client.get('/v1/me/account', headers=headers(tokens)).json()
    assert profile['username'] == profile['backup_username'] and profile['username'].startswith('wg-')
    assert profile['pending_email'] == email and 'verified_email' not in profile
    assert profile['email_verified'] is profile['email_verification_required'] is profile['email_verification_available'] is False
    assert profile['account_id'] == tokens['account_id'] and profile['recovery_configured'] is False
    assert not client.get('/v1/me/entitlements', headers=headers(tokens)).json()['sync_write']
    old = begin(client)
    assert post(client, 'email_register_send', old[2], email=email, password=password, confirm_password=password).status_code == 400
    assert not delivery

    password_flow = begin(client)
    second = redeem(client, password_flow, post(client, 'login', password_flow[2], username=email.upper(), password=password))
    assert (tokens['account_id'], tokens['dataset_id'], tokens['sync_epoch']) == (
        second['account_id'], second['dataset_id'], second['sync_epoch'])
    wrong = begin(client)
    action_in(post(client, 'login', wrong[2], username=email, password='wrong'), 'login', 401)


def test_verified_owner_takes_precedence_over_pending_aliases_without_combining_accounts(client, delivery, address):
    email, replacement = address(), address()
    first_password, second_password = generated_password(), generated_password()
    with connect() as conn:
        before = conn.execute('SELECT count(*) AS n FROM accounts').fetchone()['n']
    first = signup(client, delivery, email, first_password)
    second = signup(client, delivery, email, second_password)
    assert first['account_id'] != second['account_id'] and first['dataset_id'] != second['dataset_id']
    duplicate = begin(client)
    action_in(post(client, 'email_register', duplicate[2], email=email, password=first_password,
                   confirm_password=first_password), 'email_register', 409)
    with connect() as conn:
        assert conn.execute('SELECT count(*) AS n FROM accounts').fetchone()['n'] == before + 2
    assert not delivery
    pending = begin(client)
    assert redeem(client, pending, post(client, 'email_login', pending[2], email=email,
                                       password=first_password))['account_id'] == first['account_id']
    delivery.pay(second['account_id'])
    verified = bind(client, delivery, (second['account_id'], email, second_password), email, kind='email', use_pending=True)
    assert verified['account_id'] == second['account_id'] and verified['dataset_id'] == second['dataset_id']
    original = client.get('/v1/me/account', headers=headers(first)).json()
    assert original['pending_email'] == email and not original['email_verified']
    conflict = begin(client)
    action_in(post(client, 'email_login', conflict[2], email=email, password=first_password), 'login', 401)
    first_fallback = tokens_for(client, (first['account_id'], original['backup_username'], first_password))
    assert first_fallback['account_id'] == first['account_id'] and first_fallback['dataset_id'] == first['dataset_id']
    pending_flow = begin(client)
    pending_identity = redeem(client, pending_flow, post(client, 'login', pending_flow[2], username=email, password=first_password))
    assert pending_identity['account_id'] == first['account_id'] and pending_identity['dataset_id'] == first['dataset_id']
    second_flow = begin(client)
    established = redeem(client, second_flow, post(client, 'email_login', second_flow[2], email=email, password=second_password))
    assert established['account_id'] == second['account_id']
    delivery.pay(first['account_id'])
    correction = begin(client)
    action_in(post(client, 'email_manage_begin', correction[2], identity_kind='pending_email', identifier=email,
                   password=first_password), 'email_bind_send')
    action_in(post(client, 'email_bind_send', correction[2], email=replacement), 'email_bind_verify')
    fixed = redeem(client, correction, post(client, 'email_bind_verify', correction[2], code=sent(delivery, replacement, 'bind')))
    assert fixed['account_id'] == first['account_id'] and fixed['dataset_id'] == first['dataset_id']


def test_admin_grant_pending_and_sandbox_payment_never_authorize_mail(client, delivery, address):
    email, replacement, password = address(), address(), generated_password()
    tokens = signup(client, delivery, email, password)
    credentials = lambda: client.get('/v1/me/account', headers=headers(tokens)).json()
    flow = begin(client)
    for send, verify in [('email_otp_send', 'email_otp_verify'), ('email_reset_send', 'email_reset_verify')]:
        test_flow = begin(client)
        action_in(post(client, send, test_flow[2], email=email), verify)
        assert saved_flow(test_flow[2])['code_hash'] is None
    manage = post(client, 'email_manage_begin', flow[2], identity_kind='email', identifier=email, password=password)
    action_in(manage, 'email_pending_save')
    assert 'name="action" value="email_bind_send"' not in manage.text
    assert post(client, 'email_bind_send', flow[2], email=email).status_code == 403

    with connect() as conn:
        conn.execute("UPDATE accounts SET grant_until=now()+interval '3 days' WHERE account_id=%s", (tokens['account_id'],))
    assert client.get('/v1/me/entitlements', headers=headers(tokens)).json()['sync_write']
    assert not credentials()['email_verification_required']
    assert post(client, 'email_bind_send', flow[2], email=email).status_code == 403
    sandbox = delivery.start_order(tokens['account_id'], billing.WAFFO_TEST_PROVIDER)
    assert delivery.event(sandbox) == 'applied' and not credentials()['email_verification_required']
    order = delivery.start_order(tokens['account_id'])
    assert delivery.event(order, amount=1) == 'rejected'
    assert not credentials()['email_verification_required'] and not delivery
    assert delivery.event(order) == 'applied'

    awaiting = credentials()
    assert awaiting['email_verification_required'] and awaiting['email_verification_available'] and not awaiting['email_verified']
    paid_before = client.get('/v1/billing/orders/'+str(order[0]), headers=headers(tokens)).json()
    assert paid_before['status'] == 'paid' and paid_before['period_end'] and not delivery
    action_in(post(client, 'email_bind_send', flow[2], email=replacement), 'email_bind_verify')
    connected = redeem(client, flow, post(client, 'email_bind_verify', flow[2], code=sent(delivery, replacement, 'bind')))
    assert connected['account_id'] == tokens['account_id'] and connected['dataset_id'] == tokens['dataset_id']
    after = credentials()
    assert after['email_verified'] and not after['email_verification_required'] and 'pending_email' not in after
    assert after['verified_email'] == replacement
    assert client.get('/v1/billing/orders/'+str(order[0]), headers=headers(tokens)).json() == paid_before


def test_mail_proofs_are_throttled_contextbound_and_consumed_atomically(client, delivery, address):
    email = address()
    tokens = verified_signup(client, delivery, email, generated_password())
    lift_cooldown(email)
    otp_flow, recovery_flow = begin(client), begin(client)
    action_in(post(client, 'email_otp_send', otp_flow[2], email=email), 'email_otp_verify')
    original_code = sent(delivery, email, 'login')
    with connect() as conn:
        row = conn.execute('SELECT reset_at FROM auth_rate_limits WHERE bucket=%s', (email_identity._resend_bucket(email),)).fetchone()
    assert timedelta(seconds=58) < row['reset_at'] - auth.now() <= timedelta(seconds=60)
    action_in(post(client, 'email_reset_send', recovery_flow[2], email=email.upper()), 'email_reset_verify')
    action_in(post(client, 'email_reset_verify', recovery_flow[2], code=original_code), 'email_reset_verify', 400)
    action_in(post(client, 'email_resend', otp_flow[2]), 'email_otp_verify')
    assert len(delivery) == 2

    wrong = '000000' if original_code != '000000' else '999999'
    for _ in range(5):
        action_in(post(client, 'email_otp_verify', otp_flow[2], code=wrong), 'email_otp_verify', 400)
    state = saved_flow(otp_flow[2])
    assert state['attempts'] == 5
    assert '达到验证次数上限' in post(client, 'email_otp_verify', otp_flow[2], code=original_code).text
    with connect() as conn:
        conn.execute('UPDATE auth_email_flows SET expires_at=now()-interval \'1 second\' WHERE grant_hash=%s', (state['grant_hash'],))
    assert '验证码已过期' in post(client, 'email_otp_verify', otp_flow[2], code=original_code).text
    lift_cooldown(email)
    action_in(post(client, 'email_resend', otp_flow[2]), 'email_otp_verify')
    new_code = sent(delivery, email, 'login')
    assert new_code != original_code and saved_flow(otp_flow[2])['attempts'] == 0
    action_in(post(client, 'email_otp_verify', otp_flow[2], code=original_code), 'email_otp_verify', 400)

    def try_code():
        other = TestClient(app, base_url=settings.public_origin, cookies=client.cookies)
        try:
            return post(other, 'email_otp_verify', otp_flow[2], code=new_code)
        finally:
            other.close()

    with ThreadPoolExecutor(max_workers=2) as workers:
        replies = list(workers.map(lambda _: try_code(), range(2)))
    assert sorted(reply.status_code for reply in replies) == [200, 403]
    renewed = redeem(client, otp_flow, next(reply for reply in replies if reply.status_code == 200))
    assert renewed['account_id'] == tokens['account_id']


def test_password_reset_is_single_use_grant_and_logs_out_every_device(client, delivery, address):
    email, old, single_class = address(), 'existingpassword', '12345678'
    first = verified_signup(client, delivery, email, generated_password())
    # A previously accepted password need not satisfy the new rules to log in.
    with connect() as conn:
        conn.execute('UPDATE auth_accounts SET password_hash=%s WHERE account_id=%s',
                     (auth.hash_password(old), first['account_id']))
    flow = begin(client)
    second = redeem(client, flow, post(client, 'email_login', flow[2], email=email, password=old))
    old_key = client.post('/v1/me/recovery-key', json={'current_password': old}, headers=headers(second)).json()['recovery_key']
    lift_cooldown(email)
    reset = begin(client)
    assert post(client, 'email_reset_finish', reset[2], password=old, confirm_password=old).status_code == 400
    action_in(post(client, 'email_reset_send', reset[2], email=email), 'email_reset_verify')
    code = sent(delivery, email, 'reset')
    action_in(post(client, 'email_reset_verify', reset[2], code=code), 'email_reset_finish')
    grant = saved_flow(reset[2])
    assert not grant['code_hash'] and timedelta(minutes=9, seconds=58) < grant['expires_at'] - auth.now() <= timedelta(minutes=10)
    action_in(post(client, 'email_reset_finish', reset[2], password=single_class, confirm_password=single_class),
              'email_reset_finish', 400)
    new = 'x' * 7 + '9'
    response = post(client, 'email_reset_finish', reset[2], password=new, confirm_password=new)
    action_in(response, 'login')
    assert '密码已重设' in response.text and saved_flow(reset[2]) is None
    assert post(client, 'email_reset_finish', reset[2], password=old, confirm_password=old).status_code == 400
    for token in (first, second):
        assert client.get('/v1/me/account', headers=headers(token)).status_code == 401
        assert client.post('/v1/auth/token', data=refresh_form(token)).status_code == 400
    action_in(post(client, 'login', reset[2], username=email, password=old), 'login', 401)
    renewed = redeem(client, reset, post(client, 'email_login', reset[2], email=email, password=new))
    assert (renewed['account_id'], renewed['dataset_id'], renewed['sync_epoch']) == (
        first['account_id'], first['dataset_id'], first['sync_epoch'])
    assert client.get('/v1/me/account', headers=headers(renewed)).json()['recovery_configured'] is False
    backup = begin(client)
    assert post(client, 'recover', backup[2], username=email, recovery_key=old_key,
                password=old, confirm_password=old).status_code == 401


def test_recovery_responses_do_not_reveal_an_unbound_address(client, delivery, address, caplog, monkeypatch):
    known, unknown = address(), address()
    verified_signup(client, delivery, known, generated_password())
    lift_cooldown(known)
    monkeypatch.setattr(email_delivery, 'send_code', lambda *_: (_ for _ in ()).throw(email_delivery.DeliveryError('do not print this')))
    replies = []
    for email in (known, unknown):
        flow = begin(client)
        reply = post(client, 'email_reset_send', flow[2], email=email)
        action_in(reply, 'email_reset_verify')
        replies.append(reply.text.replace(flow[2], 'csrf').replace(email_identity._mask(email), 'hint'))
    assert replies[0] == replies[1]
    assert 'do not print this' not in caplog.text and known not in caplog.text


def test_eligible_mail_budget_is_atomic_and_separate_from_first_paid_verification(client, delivery, address):
    first, second, unbound = address(), address(), address()
    for email in (first, second):
        verified_signup(client, delivery, email, generated_password())
        lift_cooldown(email)
    password = generated_password()
    pending = signup(client, delivery, unbound, password)
    delivery.pay(pending['account_id'])
    with connect() as conn:
        for limit, used, window in [('email-send-day-budget:bind', 50, timedelta(days=1)),
                                    ('email-send-budget:verified', 47, timedelta(minutes=1)),
                                    ('email-send-day-budget:verified', 99, timedelta(days=1))]:
            conn.execute('''INSERT INTO auth_rate_limits(bucket,reset_at,attempts) VALUES (%s,now()+%s,%s)
                ON CONFLICT(bucket) DO UPDATE SET reset_at=excluded.reset_at,attempts=excluded.attempts''',
                (auth.hashed(limit), window, used))

    assert post(client, 'email_otp_send', uuid4().hex, email=first).status_code == 403
    decoy = begin(client)
    action_in(post(client, 'email_reset_send', decoy[2], email=unbound), 'email_reset_verify')
    registration = begin(client)
    action_in(post(client, 'email_manage_begin', registration[2], identity_kind='email', identifier=unbound,
                   password=password), 'email_bind_send')
    action_in(post(client, 'email_bind_send', registration[2], email=unbound), 'email_bind_verify')
    assert len(delivery) == 2 and saved_flow(registration[2])['code_hash'] is None

    inputs = [(first, begin(client)), (second, begin(client))]

    def try_send(item):
        email, flow = item
        browser = TestClient(app, base_url=settings.public_origin, cookies=client.cookies)
        try:
            return post(browser, 'email_otp_send', flow[2], email=email)
        finally:
            browser.close()

    with ThreadPoolExecutor(max_workers=2) as workers:
        for reply in workers.map(try_send, inputs):
            action_in(reply, 'email_otp_verify')
    assert len(delivery) == 3 and delivery[-1][0] in (first, second)
    minute_key = auth.hashed('email-send-budget:verified')
    with connect() as conn:
        assert conn.execute('SELECT attempts FROM auth_rate_limits WHERE bucket=%s', (minute_key,)).fetchone()['attempts'] == 48
        assert conn.execute('SELECT attempts FROM auth_rate_limits WHERE bucket=%s',
                            (auth.hashed('email-send-day-budget:verified'),)).fetchone()['attempts'] == 100
        conn.execute('UPDATE auth_rate_limits SET reset_at=now()-interval \'1 second\' WHERE bucket=%s', (minute_key,))
    assert sum(bool(saved_flow(flow[2])['code_hash']) for _, flow in inputs) == 1
    blocked_mailbox, blocked = next((email, flow) for email, flow in inputs if not saved_flow(flow[2])['code_hash'])
    lift_cooldown(blocked_mailbox)
    action_in(post(client, 'email_resend', blocked[2]), 'email_otp_verify')
    assert len(delivery) == 3 and saved_flow(blocked[2])['code_hash'] is None


def test_issuance_hour_cap_covers_all_grants_and_purposes_for_one_mailbox(client, delivery, address):
    email = address()
    verified_signup(client, delivery, email, generated_password())
    bucket = email_identity._mailbox_send_bucket(email)
    with connect() as conn:
        conn.execute('UPDATE auth_rate_limits SET attempts=7 WHERE bucket=%s', (bucket,))
    lift_cooldown(email)
    otp = begin(client)
    action_in(post(client, 'email_otp_send', otp[2], email=email), 'email_otp_verify')
    sent(delivery, email, 'login')
    lift_cooldown(email)
    reset = begin(client)
    action_in(post(client, 'email_reset_send', reset[2], email=email.upper()), 'email_reset_verify')
    assert saved_flow(reset[2])['code_hash'] is None and len(delivery) == 2
    with connect() as conn:
        assert conn.execute('SELECT attempts FROM auth_rate_limits WHERE bucket=%s', (bucket,)).fetchone()['attempts'] == 8


def test_guess_hour_and_day_caps_persist_across_grants(client, delivery, address):
    email = address()
    verified_signup(client, delivery, email, generated_password())
    for _ in range(2):
        lift_cooldown(email)
        phase = begin(client)
        action_in(post(client, 'email_otp_send', phase[2], email=email), 'email_otp_verify')
        code = sent(delivery, email, 'login')
        for _ in range(5):
            wrong = '000000' if code != '000000' else '111111'
            action_in(post(client, 'email_otp_verify', phase[2], code=wrong), 'email_otp_verify', 400)

    lift_cooldown(email)
    phase = begin(client)
    action_in(post(client, 'email_otp_send', phase[2], email=email), 'email_otp_verify')
    code = sent(delivery, email, 'login')
    action_in(post(client, 'email_otp_verify', phase[2], code=code), 'email_otp_verify', 400)
    hour, day = [limit[0] for limit in email_identity._guess_limits(email)]
    with connect() as conn:
        limits = {row['bucket']: row['attempts'] for row in conn.execute(
            'SELECT bucket,attempts FROM auth_rate_limits WHERE bucket=ANY(%s)', ([hour, day],)).fetchall()}
        assert limits == {hour: 10, day: 10}
        conn.execute('UPDATE auth_rate_limits SET reset_at=now()-interval \'1 second\' WHERE bucket=%s', (hour,))
        conn.execute('UPDATE auth_rate_limits SET attempts=24 WHERE bucket=%s', (day,))
    action_in(post(client, 'email_otp_verify', phase[2], code=code), 'email_otp_verify', 400)
    with connect() as conn:
        assert conn.execute('SELECT attempts FROM auth_rate_limits WHERE bucket=%s', (hour,)).fetchone()['attempts'] == 10
        conn.execute('UPDATE auth_rate_limits SET reset_at=now()-interval \'1 second\' WHERE bucket=%s', (day,))
    redeem(client, phase, post(client, 'email_otp_verify', phase[2], code=code))


def test_smtp_saturation_does_not_queue_or_block_shared_api_workers(monkeypatch, caplog):
    release, filled = Event(), Event()
    lock = Lock()
    called = []

    def stalled_provider(email, *_):
        with lock:
            called.append(email)
            if len(called) == 2:
                filled.set()
        assert release.wait(10), 'Test did not release the stalled provider'

    async def exercise():
        async with anyio.create_task_group() as tasks:
            try:
                tasks.start_soon(email_identity._deliver, 'one@example.test', 'bind', '123456')
                tasks.start_soon(email_identity._deliver, 'two@example.test', 'reset', '123456')
                with anyio.fail_after(3):
                    while not filled.is_set():
                        await anyio.sleep(0.01)
                    await email_identity._deliver('not-queued@example.test', 'login', '123456')
                    assert anyio.to_thread.current_default_thread_limiter().borrowed_tokens == 0
                    assert await anyio.to_thread.run_sync(lambda: 'api available') == 'api available'
            finally:
                release.set()

    monkeypatch.setattr(email_delivery, 'send_code', stalled_provider)
    anyio.run(exercise)
    assert set(called) == {'one@example.test', 'two@example.test'}
    assert 'delivery capacity exhausted' in caplog.text and 'not-queued@example.test' not in caplog.text


def test_bind_legacy_then_prove_both_mailboxes_and_revoke_every_device(client, delivery, account, address, monkeypatch):
    old, new = address(), address()
    original = tokens_for(client, account)
    key = client.post('/v1/me/recovery-key', json={'current_password': account[2]}, headers=headers(original)).json()['recovery_key']
    flow = begin(client)
    assert post(client, 'email_bind_send', flow[2], email=old).status_code == 400
    action_in(post(client, 'email_manage_begin', flow[2], identity_kind='username', identifier=account[1], password='wrong'),
              'email_manage_begin', 401)
    delivery.pay(account[0])
    bound = bind(client, delivery, account, old)
    assert (bound['account_id'], bound['dataset_id'], bound['sync_epoch']) == (
        original['account_id'], original['dataset_id'], original['sync_epoch'])
    profile = client.get('/v1/me/account', headers=headers(original)).json()
    assert profile['username'] == account[1] and profile['verified_email'] == old and profile['recovery_configured']
    with connect() as conn:
        assert conn.execute('SELECT recovery_hash FROM auth_accounts WHERE account_id=%s', (account[0],)).fetchone()['recovery_hash'] == auth.hashed(key)
    pending = code_for(client, account)

    lift_cooldown(old)
    recovery = begin(client)
    action_in(post(client, 'email_reset_send', recovery[2], email=old), 'email_reset_verify')
    action_in(post(client, 'email_reset_verify', recovery[2], code=sent(delivery, old, 'reset')), 'email_reset_finish')

    lift_cooldown(old)
    change = begin(client)
    action_in(post(client, 'email_manage_begin', change[2], identity_kind='email', identifier=old, password=account[2]),
              'email_change_old_send')
    action_in(post(client, 'email_change_new_send', change[2], email=new), 'email_change_old_send', 400)
    action_in(post(client, 'email_change_old_send', change[2]), 'email_change_old_verify')
    old_code = sent(delivery, old, 'change_old')
    action_in(post(client, 'email_change_old_verify', change[2], code=old_code), 'email_change_new_send')
    action_in(post(client, 'email_change_new_send', change[2], email=old.upper()), 'email_change_new_send', 400)
    monkeypatch.setattr(email_identity.secrets, 'randbelow', lambda limit: int(old_code))
    action_in(post(client, 'email_change_new_send', change[2], email=new), 'email_change_new_verify')
    new_code = sent(delivery, new, 'change_new')
    assert new_code != old_code
    action_in(post(client, 'email_change_new_verify', change[2], code=old_code), 'email_change_new_verify', 400)
    response = post(client, 'email_change_new_verify', change[2], code=new_code)
    action_in(response, 'login')
    assert '邮箱已更换' in response.text
    for token in (original, bound):
        assert client.get('/v1/me/account', headers=headers(token)).status_code == 401
        assert client.post('/v1/auth/token', data=refresh_form(token)).status_code == 400
    assert client.post('/v1/auth/token', data=pending).status_code == 400
    assert post(client, 'email_reset_finish', recovery[2], password='cannot-reset-now', confirm_password='cannot-reset-now').status_code == 400
    action_in(post(client, 'login', change[2], username=old, password=account[2]), 'login', 401)
    renewed = redeem(client, change, post(client, 'email_login', change[2], email=new, password=account[2]))
    assert renewed['account_id'] == account[0]
    native = tokens_for(client, account)
    assert client.get('/v1/me/account', headers=headers(native)).json()['verified_email'] == new


def test_password_change_cancels_unfinished_binding(client, delivery, account, address):
    email = address()
    tokens = tokens_for(client, account)
    delivery.pay(account[0])
    pending = begin(client)
    action_in(post(client, 'email_manage_begin', pending[2], identity_kind='username', identifier=account[1], password=account[2]),
              'email_bind_send')
    action_in(post(client, 'email_bind_send', pending[2], email=email), 'email_bind_verify')
    changed_password = generated_password()
    assert client.post('/v1/me/password', json={'current_password': account[2], 'new_password': changed_password},
                       headers=headers(tokens)).status_code == 204
    assert post(client, 'email_bind_verify', pending[2], code=sent(delivery, email, 'bind')).status_code == 400
    renewed = tokens_for(client, (account[0], account[1], changed_password))
    assert 'verified_email' not in client.get('/v1/me/account', headers=headers(renewed)).json()


def test_legacy_recovery_key_closes_a_compromised_mailbox(client, delivery, account, address):
    tokens = tokens_for(client, account)
    delivery.pay(account[0])
    old_key = client.post('/v1/me/recovery-key', json={'current_password': account[2]}, headers=headers(tokens)).json()['recovery_key']
    email = address()
    compromised = bind(client, delivery, account, email)
    lift_cooldown(email)
    email_login = begin(client)
    action_in(post(client, 'email_otp_send', email_login[2], email=email), 'email_otp_verify')
    pending_code = sent(delivery, email, 'login')

    flow = begin(client)
    new_password = generated_password()
    response = post(client, 'recover', flow[2], username=account[1], recovery_key=old_key,
                    password=new_password, confirm_password=new_password)
    assert key_from(response) != old_key
    recovered = continue_tokens(client, *flow)
    assert recovered['account_id'] == compromised['account_id'] and recovered['dataset_id'] == compromised['dataset_id']
    profile = client.get('/v1/me/account', headers=headers(recovered)).json()
    assert 'verified_email' not in profile and profile['recovery_configured']
    assert client.get('/v1/me/account', headers=headers(compromised)).status_code == 401
    assert post(client, 'email_otp_verify', email_login[2], code=pending_code).status_code == 400


def test_username_that_looks_like_email_keeps_its_distinct_account(client, delivery, address):
    shared, password = address(), generated_password()
    legacy_id = auth.create_account(shared, password)
    try:
        legacy = tokens_for(client, (legacy_id, shared, password))
        created = signup(client, delivery, shared, password)
        assert created['account_id'] != legacy['account_id']
        flow = begin(client)
        result = redeem(client, flow, post(client, 'email_login', flow[2], email=shared, password=password))
        assert result['account_id'] == created['account_id']
        flow = begin(client)
        action_in(post(client, 'email_manage_begin', flow[2], identity_kind='username', identifier=shared, password=password),
                  'email_manage_connect')
        assert str(saved_flow(flow[2])['account_id']) == legacy_id
    finally:
        with connect() as conn:
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (legacy_id,))


def test_email_account_can_reconnect_and_use_recovery_key_without_sender(client, delivery, address, monkeypatch):
    email, original_password, new_password = address(long=True), generated_password(), '中文安全码١٢٣'
    tokens = verified_signup(client, delivery, email, original_password)
    key = client.post('/v1/me/recovery-key', json={'current_password': original_password}, headers=headers(tokens)).json()['recovery_key']

    monkeypatch.setattr(email_delivery, 'available', lambda: False)
    flow = begin(client)
    assert post(client, 'email_otp_send', flow[2], email=email).status_code == 403
    response = post(client, 'recover', flow[2], username=email, recovery_key=key,
                    password=new_password, confirm_password=new_password)
    assert key_from(response) != key
    recovered = continue_tokens(client, *flow)
    assert recovered['account_id'] == tokens['account_id']
    flow = begin(client)
    renewed = redeem(client, flow, post(client, 'email_login', flow[2], email=email, password=new_password))
    profile = client.get('/v1/me/account', headers=headers(renewed)).json()
    assert profile['username'] == email and profile['verified_email'] == email and len(email) > 80
    assert client.request('DELETE', '/v1/me/account', headers=headers(renewed),
                          json={'current_password': new_password, 'confirmation': email}).status_code == 204


def test_self_hosted_stays_username_first_even_if_mail_is_configured(client, delivery, address, monkeypatch):
    email, password = address(), generated_password()
    monkeypatch.setattr(settings, 'mode', 'self_hosted')
    flow = begin(client)
    auth_page = client.get('/v1/auth/authorize', params=flow[0])
    assert 'value="email_login"' not in auth_page.text and 'value="email_register"' not in auth_page.text
    assert 'value="register"' in auth_page.text and 'registration' in client.get('/v1/server-info').json()['capabilities']
    assert post(client, 'email_register', flow[2], email=email, password=password, confirm_password=password).status_code == 403
    assert post(client, 'email_login', flow[2], email=email, password=password).status_code == 403
    for action in ('email_otp_send', 'email_reset_send'):
        assert post(client, action, flow[2], email=email).status_code == 403
    assert client.get('/v1/auth/email').status_code == 404 and not delivery


def test_hosted_registration_policy_is_independent_of_smtp_and_preserves_existing_logins(client, delivery, account,
                                                                                         address, monkeypatch):
    email, password = address(), generated_password()
    monkeypatch.setattr(email_delivery, 'available', lambda: False)
    existing = signup(client, delivery, email, password)
    flow = begin(client)
    registration = {'username': 'new-' + uuid4().hex, 'password': password, 'confirm_password': password}
    action_in(post(client, 'register', flow[2], **registration), 'email_register', 400)
    page = client.get('/v1/auth/authorize', params=flow[0])
    assert 'value="email_register"' in page.text and 'value="register"' not in page.text
    assert 'registration' in client.get('/v1/server-info').json()['capabilities']
    monkeypatch.setattr(settings, 'registration_enabled', False)
    assert 'registration' not in client.get('/v1/server-info').json()['capabilities']
    assert post(client, 'register', flow[2], **registration).status_code == 403
    assert post(client, 'email_register', flow[2], email=email, password=password, confirm_password=password).status_code == 403
    pending = redeem(client, flow, post(client, 'email_login', flow[2], email=email, password=password))
    assert pending['account_id'] == existing['account_id']
    assert tokens_for(client, account)['account_id'] == account[0]
    assert not delivery


def test_standalone_paid_management_requires_credentials_and_never_issues_native_code(client, delivery, address):
    email, replacement, password = address(), address(), generated_password()
    tokens = signup(client, delivery, email, password)
    order = delivery.pay(tokens['account_id'])
    page = client.get('/v1/auth/email')
    assert page.status_code == 200 and 'HttpOnly' in page.headers['set-cookie']
    csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
    assert client.get('/v1/auth/email', params={'checkout_id': str(order[0])}).status_code == 404
    assert post(client, 'email_login', csrf, email=email, password=password).status_code == 400
    assert post(client, 'login', csrf, username='some-user', password=password).status_code == 400
    assert post(client, 'email_bind_send', csrf, email=replacement).status_code == 400
    reauth = post(client, 'email_manage_begin', csrf, identity_kind='email', identifier=email, password=password)
    action_in(reauth, 'email_bind_send')
    assert 'value="email_manage_connect"' not in reauth.text
    action_in(post(client, 'email_bind_send', csrf, email=replacement), 'email_bind_verify')
    completion = post(client, 'email_bind_verify', csrf, code=sent(delivery, replacement, 'bind'))
    assert completion.status_code == 200 and '邮箱已验证' in completion.text and 'id="handoff-link"' not in completion.text
    assert 'name="csrf"' not in completion.text and saved_flow(csrf) is None
    assert client.get('/v1/me/account', headers=headers(tokens)).json()['verified_email'] == replacement


def test_fully_refunded_payment_revokes_unfinished_mail_proof(client, delivery, address):
    email, password = address(), generated_password()
    tokens = signup(client, delivery, email, password)
    order = delivery.pay(tokens['account_id'])
    with connect() as conn:
        conn.execute('''UPDATE billing_periods SET start_at=now()-interval '31 days',end_at=now()-interval '1 day'
          WHERE checkout_id=%s''', (order[0],))
    assert not client.get('/v1/me/entitlements', headers=headers(tokens)).json()['sync_write']
    assert client.get('/v1/me/account', headers=headers(tokens)).json()['email_verification_required']
    flow = begin(client)
    action_in(post(client, 'email_manage_begin', flow[2], identity_kind='email', identifier=email, password=password),
              'email_bind_send')
    action_in(post(client, 'email_bind_send', flow[2], email=''), 'email_bind_verify')
    code = sent(delivery, email, 'bind')
    assert delivery.event(order, refund=True) == 'applied'
    assert post(client, 'email_bind_verify', flow[2], code=code).status_code == 400
    profile = client.get('/v1/me/account', headers=headers(tokens)).json()
    assert not profile['email_verified'] and not profile['email_verification_required'] and profile['pending_email'] == email
    assert not client.get('/v1/me/entitlements', headers=headers(tokens)).json()['sync_write']


def test_pending_alias_edit_and_password_change_use_current_credentials_without_mail(client, delivery, address, monkeypatch):
    email, replacement, password = address(), address(), generated_password()
    tokens = signup(client, delivery, email, password)
    monkeypatch.setattr(email_delivery, 'available', lambda: False)
    phase = begin(client)
    action_in(post(client, 'email_manage_begin', phase[2], identity_kind='email', identifier=email, password=password),
              'email_pending_save')
    action_in(post(client, 'email_pending_save', phase[2], email=replacement, password='incorrect'), 'email_pending_save', 401)
    action_in(post(client, 'email_pending_save', phase[2], email=replacement.upper(), password=password), 'email_pending_save')
    assert not delivery
    connected = redeem(client, phase, post(client, 'email_manage_connect', phase[2]))
    assert connected['dataset_id'] == tokens['dataset_id']
    attempt = begin(client)
    action_in(post(client, 'login', attempt[2], username=email, password=password), 'login', 401)

    assert client.post('/v1/me/password', json={'current_password': password, 'new_password': '12345678'},
                       headers=headers(connected)).status_code == 422
    next_password = '-!123456'
    assert client.post('/v1/me/password', json={'current_password': password, 'new_password': next_password},
                       headers=headers(connected)).status_code == 204
    action_in(post(client, 'login', attempt[2], username=replacement, password=password), 'login', 401)
    changed = redeem(client, attempt, post(client, 'email_login', attempt[2], email=replacement, password=next_password))
    assert changed['account_id'] == tokens['account_id'] and not delivery
    # If an older writer leaves the deterministic index stale, it can still
    # select the candidate, but cannot substitute for the current password.
    with connect() as conn:
        conn.execute('UPDATE auth_accounts SET pending_login_key=%s WHERE account_id=%s',
                     (auth.pending_login_key(replacement, password), tokens['account_id']))
    stale = begin(client)
    action_in(post(client, 'email_pending_login', stale[2], email=replacement, password=password), 'login', 401)


def test_decoy_sends_cannot_cool_down_a_paid_bind_and_paid_budget_survives_alias_rotation(client, delivery, address):
    email, other, password = address(), address(), generated_password()
    tokens = signup(client, delivery, email, password)
    decoy = begin(client)
    action_in(post(client, 'email_reset_send', decoy[2], email=email), 'email_reset_verify')
    assert not delivery
    delivery.pay(tokens['account_id'])
    bucket = email_identity._account_send_bucket(tokens['account_id'])
    with connect() as conn:
        assert not conn.execute('SELECT 1 FROM auth_rate_limits WHERE bucket=%s',
                                (email_identity._resend_bucket(email),)).fetchone()
        conn.execute("INSERT INTO auth_rate_limits(bucket,reset_at,attempts) VALUES (%s,now()+interval '1 day',5)", (bucket,))
    for target in (email, other):
        flow = begin(client)
        action_in(post(client, 'email_manage_begin', flow[2], identity_kind='email', identifier=email, password=password),
                  'email_bind_send')
        action_in(post(client, 'email_bind_send', flow[2], email=target), 'email_bind_verify')
    assert len(delivery) == 1 and delivery[0][:2] == (email, 'bind')
    assert saved_flow(flow[2])['code_hash'] is None
    with connect() as conn:
        assert conn.execute('SELECT attempts FROM auth_rate_limits WHERE bucket=%s', (bucket,)).fetchone()['attempts'] == 6


def test_email_migration_preserves_existing_credential_and_grant(client):
    account_id, dataset_id, epoch = uuid4(), uuid4(), uuid4()
    namespace = sql.Identifier('email_migration_' + uuid4().hex)
    with connect() as conn:
        with conn.transaction(force_rollback=True):
            conn.execute(sql.SQL('CREATE SCHEMA {}').format(namespace))
            conn.execute(sql.SQL('SET LOCAL search_path TO {}').format(namespace))
            conn.execute('''CREATE TABLE schema_migrations (migration_id text PRIMARY KEY);
              INSERT INTO schema_migrations VALUES ('20261106_account_recovery_v1');
              CREATE TABLE accounts (account_id uuid PRIMARY KEY,dataset_id uuid,sync_epoch uuid);
              CREATE TABLE auth_accounts (account_id uuid PRIMARY KEY,username text UNIQUE,password_hash text,
                recovery_hash text,enabled boolean);
              CREATE TABLE auth_grants (grant_hash text PRIMARY KEY,account_id uuid,
                redirect_uri text NOT NULL DEFAULT 'http://127.0.0.1:54321/oauth/callback',
                challenge text NOT NULL DEFAULT 'before',state text NOT NULL DEFAULT 'before');''')
            conn.execute('INSERT INTO accounts VALUES (%s,%s,%s)', (account_id, dataset_id, epoch))
            conn.execute('INSERT INTO auth_accounts VALUES (%s,%s,%s,%s,true)', (account_id, 'old', 'before', 'recovery'))
            conn.execute('INSERT INTO auth_grants(grant_hash,account_id) VALUES (%s,%s)', ('previous-grant', account_id))
            migrate_email_identity(conn)
            conn.execute("INSERT INTO auth_grants(grant_hash,account_id) VALUES ('old-bind',NULL),('old-signup',NULL)")
            conn.execute('''INSERT INTO auth_email_flows(grant_hash,action,expires_at,account_id,credential_version)
              VALUES ('old-bind','email_bind_send',now(),%s,0),('old-signup','email_register_verify',now(),NULL,NULL)''', (account_id,))
            migrate_auth(conn)
            migrate_auth(conn)
            row = conn.execute('SELECT * FROM accounts JOIN auth_accounts USING(account_id)').fetchone()
            assert row['account_id'] == account_id and row['dataset_id'] == dataset_id and row['sync_epoch'] == epoch
            assert row['username'] == 'old' and row['password_hash'] == 'before' and row['recovery_hash'] == 'recovery'
            assert row['legacy_login'] and row['verified_email'] is None and row['pending_email'] is None and row['credential_version'] == 0
            grant = conn.execute('SELECT * FROM auth_grants WHERE grant_hash=%s', ('previous-grant',)).fetchone()
            assert grant['account_id'] == account_id and not grant['management_only'] and not grant['portal']
            assert grant['challenge'] == grant['state'] == 'before'
            assert conn.execute('SELECT count(*) AS n FROM auth_email_flows').fetchone()['n'] == 0
