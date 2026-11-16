"""First-party browser flows on the isolated PostgreSQL test database."""
from datetime import timedelta
import re
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit
from uuid import UUID, uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import anyio
import pytest

from test_auth import account, begin, callback_from, client, code_for, headers, running_client, tokens_for
from test_email_identity import address, delivery
from test_sync import batch, event
from test_waffo_runtime import MONTHLY, ANNUAL, ORIGIN, checkout, official
from weekglass_server import admin, auth, calendar_export, console_sessions as sessions
from weekglass_server.db import connect
from weekglass_server.entitlements import set_grant
from weekglass_server.protocol import now, validate
from weekglass_server.settings import settings

PASSWORD = 'Local-fixture-password-123'
SOURCE_URL = '/v1/source/weekglass-cloud-20261116.tar.gz'


def csrf(response):
    assert response.status_code == 200, response.text
    return re.search(r'name="csrf" value="([^"]+)"', response.text).group(1)


def authorize(client, action, token, *, next='', **fields):
    suffix = '?next=' + next if next else ''
    return client.post('/account/authorize' + suffix, headers={'Origin': settings.public_origin},
                       data={'action': action, 'csrf': token, **fields})


def submit(client, path, token, **fields):
    return client.post(path, headers={'Origin': settings.public_origin}, data={'csrf': token, **fields})


def sign_in(client, name, password=PASSWORD, *, next='', expected=303):
    response = authorize(client, 'login', csrf(client.get('/account/login')), next=next, username=name,
                         password=password)
    assert response.status_code == expected, response.text
    return response


def attach_web_session(client, account_id):
    with connect() as conn:
        login = sessions.sign_in(conn, account_id)
    client.cookies.set('__Host-wg-account', login.headers['set-cookie'].split(';', 1)[0].split('=', 1)[1])


@pytest.fixture(autouse=True)
def hosted_console(monkeypatch):
    monkeypatch.setattr(settings, 'mode', 'hosted')


def test_portal_signup_unverified_login_and_paid_verification(client, delivery, address):
    email = address()
    page = client.get('/account/register')
    assert SOURCE_URL in page.text and '用邮箱和密码即可创建账号' in page.text
    assert '邀请码' not in page.text and '验证码' not in page.text
    registered = authorize(client, 'email_register', csrf(page), email=email, password=PASSWORD,
                           confirm_password=PASSWORD)
    assert registered.status_code == 303 and registered.headers['location'] == '/account#plans'
    cookies = registered.headers.get_list('set-cookie')
    assert any(all(item in cookie for item in ('__Host-wg-account=', 'HttpOnly', 'Secure', 'Path=/', 'SameSite=lax'))
               for cookie in cookies)
    assert not delivery
    home = client.get('/account')
    assert home.status_code == 200
    assert all(item in home.text for item in ('未开通', '1.00', '9.99', '365 天', '微信单次支付', SOURCE_URL))
    assert client.get('/v1/me/entitlements').status_code == 401  # cookie is not a bearer token
    assert client.get('/account/admin').status_code == 403
    with connect() as conn:
        user = conn.execute('SELECT account_id,username FROM auth_accounts WHERE pending_email=%s', (email,)).fetchone()
        assert not conn.execute('SELECT 1 FROM web_owner WHERE account_id=%s', (user['account_id'],)).fetchone()
    assert submit(client, '/account/logout', csrf(home)).status_code == 303
    assert client.get('/account/orders').headers['location'] == '/account/login?next=orders'
    assert sign_in(client, email.upper(), next='orders').headers['location'] == '/account/orders'
    assert '还没有订单' in client.get('/account/orders').text

    # The same signed-in flow may correct a typo, but cannot send mail yet.
    proof = authorize(client, 'email_manage_begin', csrf(client.get('/account/email')),
                      identity_kind='session', identifier='', password=PASSWORD)
    assert '更正注册邮箱' in proof.text
    updated_email = address()
    edited = authorize(client, 'email_pending_save', csrf(proof), email=updated_email, password=PASSWORD)
    assert '邮箱已保存，未发送邮件' in edited.text and not delivery
    denied = authorize(client, 'email_bind_send', csrf(edited), email=updated_email)
    assert denied.status_code == 403 and not delivery
    assert submit(client, '/account/logout', csrf(client.get('/account'))).status_code == 303
    assert sign_in(client, user['username'], next='//other.invalid').headers['location'] == '/account'

    delivery.pay(user['account_id'])
    assert '验证邮箱' in client.get('/account').text
    proof = authorize(client, 'email_manage_begin', csrf(client.get('/account/email')),
                      identity_kind='session', identifier='', password=PASSWORD)
    sent = authorize(client, 'email_bind_send', csrf(proof), email=updated_email)
    assert len(delivery) == 1 and delivery[0][0] == updated_email
    verified = authorize(client, 'email_bind_verify', csrf(sent), code=delivery[0][2])
    assert verified.status_code == 200 and '邮箱已验证' in verified.text
    security = client.get('/account/security')
    assert '已验证' in security.text and updated_email in security.text
    assert submit(client, '/account/logout', csrf(security)).status_code == 303
    # Login now finds the verified address in the very same form.
    assert sign_in(client, updated_email, next='security').headers['location'] == '/account/security'


def test_native_signup_handoff_waits_for_the_pkce_exchange(client, delivery, address):
    email = address()
    params, verifier, token = begin(client)
    response = client.post('/v1/auth/authorize', headers={'Origin': settings.public_origin}, data={
        'action': 'email_register', 'csrf': token, 'email': email, 'password': PASSWORD, 'confirm_password': PASSWORD})
    callback = parse_qs(urlsplit(callback_from(response)).query)
    assert callback['signup'] == ['1'] and callback['state'] == [params['state']]
    assert 'href="/account#plans"' not in response.text and not delivery
    proof = {'grant_type': 'authorization_code', 'client_id': 'weekglass-native', 'code': callback['code'][0],
             'code_verifier': verifier, 'redirect_uri': params['redirect_uri'], 'device_id': params['device_id']}
    exchanged = client.post('/v1/auth/token', data=proof)
    assert exchanged.status_code == 200
    rights = client.get('/v1/me/entitlements', headers=headers(exchanged.json())).json()
    assert rights['status'] == 'not_subscribed' and not rights['sync_read'] and not rights['sync_write']
    assert client.post('/v1/auth/token', data=proof).status_code == 400
    assert '选择云同步时长' in client.get('/account#plans').text
    _, _, token = begin(client)
    response = client.post('/v1/auth/authorize', headers={'Origin': settings.public_origin},
                           data={'csrf': token, 'username': email, 'password': PASSWORD})
    assert 'signup' not in parse_qs(urlsplit(callback_from(response)).query)


def test_owner_controls_are_scoped_and_revoke_pending_device_codes(client, account, monkeypatch):
    owner, owner_name, owner_password = account
    username = 'console-' + uuid4().hex
    uid = auth.create_account(username, PASSWORD)
    target = f'/account/admin/users/{uid}'
    unfinished = TestClient(client.app, base_url=settings.public_origin, follow_redirects=False)
    try:
        sign_in(client, username)
        unauthorized = csrf(client.get('/account'))
        assert client.get('/account/admin').status_code == 403
        assert submit(client, target, unauthorized, action='change_grant', current_password=PASSWORD, days='30').status_code == 403
        tokens = tokens_for(client, (uid, username, PASSWORD))
        did = tokens['device_id']
        flow = csrf(unfinished.get('/account/login'))
        pending = authorize(unfinished, 'email_manage_begin', flow, identity_kind='unified',
                            identifier=username, password=PASSWORD)
        assert 'value="email_manage_connect"' in pending.text
        with connect() as conn:
            assert set_grant(conn, uid, 0, now())['grant_until'] is None
            set_grant(conn, uid, 1, now())
            row = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (uid,)).fetchone()
        data = batch(SimpleNamespace(identity=tokens, account=row), [event()])
        data['mutations'][0]['event']['title'] = 'private synthetic calendar title'
        assert client.post('/v1/sync/batches', headers=headers(tokens), json=data).status_code == 200
        proof = code_for(client, (uid, username, PASSWORD), device_id=did)
        remembered_cookie = client.cookies.get('__Host-wg-account')
        client.cookies.clear()

        monkeypatch.setattr('sys.argv', ['admin', 'set-owner', owner])
        admin.main()
        sign_in(client, owner_name, owner_password)
        home = client.get('/account/admin', params={'q': username})
        assert username in home.text and 'private synthetic calendar title' not in home.text
        detail = client.get(target)
        assert detail.status_code == 200 and did in detail.text and 'private synthetic calendar title' not in detail.text
        token = csrf(detail)
        evil = client.post(target, headers={'Origin': 'https://viliana.cn'},
                           data={'csrf': token, 'action': 'suspend', 'current_password': owner_password})
        assert evil.status_code == 403
        assert submit(client, target, 'bad csrf', action='suspend', current_password=owner_password).status_code == 403
        assert submit(client, target, token, action='suspend', current_password='wrong').status_code == 403
        assert submit(client, target, token, action='revoke_device', current_password=owner_password,
                      device_id=str(uuid4())).status_code == 404
        assert submit(client, target, token, action='revoke_device', current_password=owner_password,
                      device_id=did).status_code == 303
        assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401
        assert client.post('/v1/auth/token', data=proof).status_code == 400
        assert submit(client, target, token, action='revoke_devices', current_password=owner_password).status_code == 303
        assert authorize(unfinished, 'email_manage_connect', flow).status_code == 400
        assert unfinished.get('/account').status_code == 303
        # A fresh proof using the same password still works.
        sign_in(unfinished, username)
        remembered_cookie = unfinished.cookies.get('__Host-wg-account')
        assert submit(client, target, token, action='change_grant', current_password=owner_password, days='0').status_code == 303
        assert '已到期' in client.get(target).text
        assert submit(client, target, token, action='suspend', current_password=owner_password).status_code == 303
        with TestClient(client.app, base_url=settings.public_origin, follow_redirects=False) as other:
            other.cookies.set('__Host-wg-account', remembered_cookie)
            assert other.get('/account').headers['location'] == '/account/login'
            sign_in(other, username, expected=401)
        assert submit(client, target, token, action='resume', current_password=owner_password).status_code == 303
        assert submit(client, f'/account/admin/users/{owner}', token, action='suspend', current_password=owner_password).status_code == 400
        monkeypatch.setattr('sys.argv', ['admin', 'clear-owner'])
        admin.main()
        assert client.get('/account/admin').status_code == 403
    finally:
        unfinished.close()
        with connect() as conn:
            conn.execute('DELETE FROM web_owner_actions WHERE actor_id=%s OR subject_id=%s', (owner, uid))
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (uid,))


def test_revoke_sessions_invalidates_pending_proof_but_keeps_current_web_session(client, account):
    uid, username, password = account
    sign_in(client, username, password)
    device = tokens_for(client, account)
    with TestClient(client.app, base_url=settings.public_origin, follow_redirects=False) as unfinished, \
         TestClient(client.app, base_url=settings.public_origin, follow_redirects=False) as other:
        sign_in(other, username, password)
        pending = authorize(unfinished, 'email_manage_begin', csrf(unfinished.get('/account/login')),
                            identity_kind='unified', identifier=username, password=password)
        token = csrf(pending)
        assert 'value="email_manage_connect"' in pending.text
        reply = submit(client, '/account/security/revoke', csrf(client.get('/account/security')),
                       current_password=password)
        assert reply.status_code == 303 and '其他网页登录' in client.get(reply.headers['location']).text
        assert client.get('/account').status_code == 200
        assert client.get('/v1/devices', headers=headers(device)).status_code == 401
        assert other.get('/account').headers['location'] == '/account/login'
        replay = authorize(unfinished, 'email_manage_connect', token)
        assert replay.status_code == 400 and '重新验证当前密码' in replay.text
        assert unfinished.get('/account').status_code == 303
        sign_in(unfinished, username, password)
        assert unfinished.get('/account').status_code == 200


def test_one_expired_export_retries_the_same_boundary_and_renews_its_allowance(client, account):
    uid, username, password = account
    sign_in(client, username, password)
    tokens = tokens_for(client, account)

    def export_request(path, *, status=200, hostile=False):
        home = client.get('/account')
        export_csrf = csrf(home)
        response = client.post('/account/calendar/' + path,
            headers={'Origin': 'https://viliana.cn' if hostile else settings.public_origin, 'X-WeekGlass-CSRF': export_csrf})
        assert response.status_code == status, response.text
        return response

    assert export_request('prepare', status=403).json()['code'] == 'export_not_available'
    with connect() as conn:
        set_grant(conn, uid, 7, now())
        row = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (uid,)).fetchone()
    event_one = event()
    event_one['title'] = '一周 🗓️'
    first = batch(SimpleNamespace(account=row, identity=tokens), [event_one])
    assert client.post('/v1/sync/batches', json=first, headers=headers(tokens)).status_code == 200
    assert client.get('/account/calendar/download').status_code == 200
    assert export_request('prepare', status=409).json()['code'] == 'export_use_active_download'
    with connect() as conn:
        set_grant(conn, uid, 0, now() - timedelta(seconds=1))
    assert export_request('prepare', status=403, hostile=True).json()['code'] == 'invalid_origin'
    home = client.get('/account')
    assert all(item in home.text for item in ('已到期', '文件下载后请妥善保存', '申请个人信息副本'))
    claim = export_request('prepare').json()['export_id']
    assert export_request(claim + '/complete', status=409).json()['code'] == 'export_not_transferred'
    downloaded = export_request(claim + '/download')
    assert downloaded.headers['content-disposition'] == 'attachment; filename="weekglass-calendar.json"'
    assert int(downloaded.headers['content-length']) == len(downloaded.content)
    assert downloaded.json()['records'][0]['event']['title'] == '一周 🗓️'
    validate('Export', downloaded.json())
    # Simulated failure to save: no completion request. Same ID, same bytes.
    assert export_request('prepare').json()['export_id'] == claim
    assert export_request(claim + '/download').content == downloaded.content
    assert export_request(claim + '/complete', status=204).content == b''
    assert export_request(claim + '/complete', status=204).content == b''  # lost ack response
    assert export_request('prepare', status=409).json()['code'] == 'export_already_completed'
    assert export_request(claim + '/download', status=409).json()['code'] == 'export_already_completed'
    assert not client.get('/v1/me/entitlements', headers=headers(tokens)).json()['export_allowed']
    assert '请保留你保存的文件' in client.get('/account').text

    with connect() as conn:
        set_grant(conn, uid, 7, now())
    assert client.post('/v1/sync/batches', json=batch(SimpleNamespace(account=row, identity=tokens), [event()]),
                       headers=headers(tokens)).status_code == 200
    with connect() as conn:
        set_grant(conn, uid, 0, now())
    renewed = export_request('prepare').json()['export_id']
    assert claim != renewed and len(export_request(renewed + '/download').json()['records']) == 2


def test_portal_places_one_account_scoped_single_payment_and_reads_result(official):
    browser = official.client
    attach_web_session(browser, official.users[0][0])
    page = browser.get('/account')
    assert all(f'value="{plan.plan_id}"' in page.text for plan in (MONTHLY, ANNUAL))
    token = csrf(page)
    data = {'plan_id': ANNUAL.plan_id, 'terms_version': ANNUAL.terms_version, 'idempotency_key': str(uuid4())}
    payment = submit(browser, '/account/checkout', token, **data)
    assert payment.status_code == 303 and payment.headers['location'].startswith('/v1/billing/checkout/')
    assert submit(browser, '/account/checkout', token, **data).headers['location'] == payment.headers['location']
    path = payment.headers['location']
    oid = UUID(path.split('/')[-1])
    with connect() as conn:
        order = conn.execute('SELECT * FROM billing_orders WHERE checkout_id=%s', (oid,)).fetchone()
        assert order['amount_minor'] == 999 and order['period_seconds'] == 365 * 86400
        assert order['purchase_mode'] == 'single' and order['agreement_id'] is None
    assert '打开微信收银台' in browser.get(path).text
    assert '订单所属账号' in browser.get(path).text
    assert '365 天云同步' in browser.get('/account/orders').text
    with TestClient(browser.app, base_url=ORIGIN, follow_redirects=False) as other:
        attach_web_session(other, official.users[1][0])
        assert '打开微信收银台' not in other.get(path).text
        assert other.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 403
        bad = submit(other, '/account/orders/' + str(oid) + '/close', csrf(other.get('/account')))
        assert bad.status_code == 404
    assert submit(browser, '/account/orders/' + str(oid) + '/close', token).headers['location'] == '/account/orders?notice=closed'
    assert '已关闭' in browser.get('/account/orders?notice=closed').text


def test_native_order_ticket_cannot_override_the_signed_in_account(official):
    browser = official.client
    first = checkout(official)
    assert first.status_code == 201
    parts = urlsplit(first.json()['url'])
    path = parts.path
    ticket = parse_qs(parts.fragment)['ticket'][0]
    origin = {'Origin': ORIGIN}
    assert browser.post(path + '/handoff', json={'ticket': ticket}, headers=origin).status_code == 200
    original = browser.get(path)
    assert original.status_code == 200 and '订单所属账号' in original.text
    next_ticket = parse_qs(urlsplit(checkout(official).json()['url']).fragment)['ticket'][0]
    attach_web_session(browser, official.users[1][0])
    mismatch = browser.get(path)
    assert mismatch.status_code == 403 and '账号与订单不匹配' in mismatch.text and '打开微信收银台' not in mismatch.text
    for action in ('provider', 'refresh'):
        denied = browser.post(path + '/' + action, headers=origin)
        assert denied.status_code == 403 and denied.json()['code'] == 'billing_account_mismatch'
    denied = browser.post(path + '/handoff', json={'ticket': next_ticket}, headers=origin)
    assert denied.status_code == 403 and denied.json()['code'] == 'billing_account_mismatch'
    assert official.adapter.calls == 0
    assert submit(browser, '/account/logout', csrf(browser.get('/account'))).status_code == 303
    assert browser.get(path).status_code == 200   # A's existing order-only cookie still works
    assert browser.post(path + '/handoff', json={'ticket': next_ticket}, headers=origin).status_code == 200
    assert browser.post(path + '/provider', headers=origin).status_code == 200
    assert official.adapter.calls == 1


def test_export_reserves_capacity_until_the_stream_ends_or_disconnects(client, account):
    aid = account[0]

    def read(conn):
        row = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (aid,)).fetchone()
        return row, now()

    sent_first, transferred = [], []
    first = calendar_export.download(read, transferred=lambda: transferred.append('first'))
    second = calendar_export.download(read, transferred=lambda: transferred.append('second'))
    with pytest.raises(HTTPException) as denied:
        calendar_export.download(read)
    assert denied.value.status_code == 429 and denied.value.headers['Retry-After'] == '5'
    # Even when both exports hold a PostgreSQL cursor, ordinary routes work.
    assert client.get('/healthz').status_code == 200

    async def exercise():
        prefix_sent = anyio.Event()

        async def receive():
            await prefix_sent.wait()
            return {'type': 'http.disconnect'}

        async def slow_send(message):
            if message['type'] == 'http.response.body':
                sent_first.append(message['body'])
                prefix_sent.set()
                await anyio.sleep_forever()

        await first({'type': 'http', 'asgi': {'spec_version': '2.3'}}, receive, slow_send)
        assert sent_first and not transferred
        # A disconnected export releases the cursor and its capacity slot.
        retry = await anyio.to_thread.run_sync(calendar_export.download, read)
        chunks = []

        async def send(message):
            if message['type'] == 'http.response.body':
                chunks.append(message['body'])

        scope = {'type': 'http', 'asgi': {'spec_version': '2.4'}}
        await retry(scope, receive, send)
        await second(scope, receive, send)
        assert chunks.count(b']}') == 2 and transferred == ['second']

    anyio.run(exercise)
