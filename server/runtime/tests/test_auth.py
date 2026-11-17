"""Real PostgreSQL integration tests. Each test provisions a unique test account."""
import base64
from datetime import timedelta
import hashlib
from html.parser import HTMLParser
import re
import secrets
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from fastapi import HTTPException, Request

from weekglass_server import auth
from weekglass_server.db import connect
from weekglass_server.main import app
from weekglass_server.settings import settings


@pytest.fixture(scope='module')
def running_client():
    import os
    assert os.environ.get('DB_NAME', '').endswith('_test') and not os.environ.get('DATABASE_URL'), 'Integration tests require an explicitly named test database'
    with TestClient(app, base_url=settings.public_origin, follow_redirects=False) as c:
        yield c


@pytest.fixture
def client(running_client):
    running_client.cookies.clear()
    yield running_client
    running_client.cookies.clear()
    # Rate limits use a shared test peer. Remove this test's rate limit buckets,
    # never business data or other tests' accounts.
    with connect() as conn:
        for purpose in ('authorize', 'login-ip', 'token', 'account-browser', 'registration-ip', 'account-management-ip'):
            conn.execute('DELETE FROM auth_rate_limits WHERE bucket=%s', (auth.hashed(purpose+':testclient'),))
        conn.execute('DELETE FROM auth_rate_limits WHERE bucket=%s', (auth.hashed('registration-global:weekglass'),))


@pytest.fixture
def account(client):
    username = 'test-' + uuid4().hex
    password = secrets.token_urlsafe(24)
    account_id = auth.create_account(username, password)
    yield account_id, username, password
    with connect() as conn:
        conn.execute('DELETE FROM accounts WHERE account_id=%s', (account_id,))


def begin(client, device_id=None, *, origin=''):
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    params = {'response_type': 'code', 'client_id': 'weekglass-native',
              'redirect_uri': 'http://127.0.0.1:54321/oauth/callback',
              'code_challenge': challenge, 'code_challenge_method': 'S256',
              'state': secrets.token_urlsafe(32), 'device_id': device_id or str(uuid4())}
    response = client.get(origin + '/v1/auth/authorize', params=params)
    assert response.status_code == 200, response.text
    assert 'no-store' in response.headers['cache-control']
    assert 'HttpOnly' in response.headers['set-cookie']
    csrf = re.search(r'name="csrf" value="([^"]+)"', response.text).group(1)
    return params, verifier, csrf


def _script_sources(scripts):
    return ' '.join("'sha256-" + base64.b64encode(hashlib.sha256(script.encode()).digest()).decode() + "'"
                    for script in scripts)


def test_login_reveal_is_csp_hashed_and_account_scope_is_clear():
    from weekglass_server.auth_pages import FORM_SCRIPT, PASSWORD_SCRIPT
    from weekglass_server.web_theme import THEME_SCRIPT
    response = auth.html_response('synthetic-csrf')
    html = response.body.decode()
    scripts = re.findall(r'<script>(.*?)</script>', html, re.S)
    assert scripts == [THEME_SCRIPT, FORM_SCRIPT]
    assert PASSWORD_SCRIPT in FORM_SCRIPT
    assert html.index(THEME_SCRIPT) < html.index('<style>')
    assert f'script-src {_script_sources(scripts)};' in response.headers['content-security-policy']
    assert "script-src 'unsafe-inline'" not in response.headers['content-security-policy']
    assert "style-src 'unsafe-inline'" in response.headers['content-security-policy']
    assert 'img-src data:;' in response.headers['content-security-policy']
    assert 'type="password"' in html and 'hidden data-password-toggle' in html
    assert 'section-weekglass username' in html
    assert '独立的 WeekGlass 账号' in html and '主网站及学校账号分开' in html
    # Toggling is progressive enhancement; all forms still submit without JS.
    assert 'method="post" action="/v1/auth/authorize"' in html
    assert 'data-auth-form' in html and 'data-submit-status' in html
    assert 'role="status" aria-live="polite" hidden' in html
    assert '服务端源代码' not in html


@pytest.mark.parametrize(('action', 'title'), [('login', '登录 WeekGlass'), ('register', '创建 WeekGlass 账号'),
                                             ('recover', '找回密码')])
def test_portal_auth_retains_account_scope_without_source_download(action, title, monkeypatch):
    monkeypatch.setattr(settings, 'registration_enabled', True)
    if action == 'register' and auth.email_signup_uses_address():
        action = 'email_register'
    response = auth.html_response('synthetic-csrf', action=action, portal=True)
    html = response.body.decode()
    assert f'<h1>{title}</h1>' in html
    assert '与 Viliana 主站及学校账号分开' in html
    assert '服务端源代码' not in html and '/v1/source/' not in html


def test_expired_page_has_no_credential_fields_or_automatic_retry():
    from weekglass_server.web_theme import THEME_SCRIPT_SOURCE
    response = auth.html_response('', status=403, expired=True)
    html = response.body.decode()
    assert response.status_code == 403
    assert '授权页面已失效' in html and '回到 WeekGlass 点击重新连接' in html
    assert '<form' not in html and '<input' not in html
    assert 'http-equiv="refresh"' not in html
    assert response.headers['cache-control'] == 'no-store'
    assert response.headers['referrer-policy'] == 'same-origin'
    assert f'script-src {THEME_SCRIPT_SOURCE};' in response.headers['content-security-policy']


class HandoffParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'a' and attrs.get('id') == 'handoff-link':
            self.links.append(attrs)


def callback_from(response):
    assert response.status_code == 200
    assert 'location' not in response.headers
    assert response.headers['content-type'].startswith('text/html')
    assert response.headers['referrer-policy'] == 'no-referrer'
    assert "form-action 'self';" in response.headers['content-security-policy']
    assert '账号验证通过' in response.text
    parser = HandoffParser()
    parser.feed(response.text)
    assert len(parser.links) == 1
    assert parser.links[0]['rel'] == 'noreferrer'
    return parser.links[0]['href']


def test_success_handoff_is_an_escaped_document_with_a_fixed_csp_script():
    from weekglass_server.auth_pages import HANDOFF_SCRIPT
    from weekglass_server.web_theme import THEME_SCRIPT
    code, state = 'c' * 43, 'synthetic-state-<script>"&injected=true</script>'
    response = auth.handoff_response('http://127.0.0.1:54321/oauth/callback', code, state)
    html = response.body.decode()
    assert response.status_code == 200 and 'location' not in response.headers
    assert '<form' not in html and '<input' not in html
    assert '账号验证通过' in html and '以应用中的连接结果为准' in html
    assert '<noscript>' in html and '一分钟内有效' in html
    assert '&amp;state=' in html and state not in html
    parser = HandoffParser()
    parser.feed(html)
    assert len(parser.links) == 1
    target = urlsplit(parser.links[0]['href'])
    assert target.hostname == '127.0.0.1' and target.port == 54321
    assert target.path == '/oauth/callback'
    assert parse_qs(target.query) == {'code': [code], 'state': [state]}
    scripts = re.findall(r'<script>(.*?)</script>', html, re.S)
    assert scripts == [THEME_SCRIPT, HANDOFF_SCRIPT]
    assert code not in HANDOFF_SCRIPT and state not in HANDOFF_SCRIPT
    csp = response.headers['content-security-policy']
    assert f'script-src {_script_sources(scripts)};' in csp
    assert "form-action 'self';" in csp and '127.0.0.1' not in csp
    assert "script-src 'unsafe-inline'" not in csp
    assert response.headers['referrer-policy'] == 'no-referrer'
    assert response.headers['cache-control'] == 'no-store'


@pytest.mark.parametrize('redirect', [
    'https://attacker.example/oauth/callback',
    'http://localhost:54321/oauth/callback',
    'http://127.0.0.1:80/oauth/callback',
    'http://127.0.0.1:65536/oauth/callback',
    'http://127.0.0.1:54321/other',
    'http://127.0.0.1:54321/oauth/callback?next=https://attacker.example',
    'http://127.0.0.1:54321/oauth/callback#fragment',
    'http://user@127.0.0.1:54321/oauth/callback',
])
def test_success_handoff_rechecks_the_exact_loopback_callback(redirect):
    with pytest.raises(HTTPException) as error:
        auth.handoff_response(redirect, 'c' * 43, 's' * 32)
    assert error.value.status_code == 400


@pytest.mark.parametrize('failure, status, code, retry', [
    (HTTPException(429, detail={'code': 'rate_limited'}, headers={'Retry-After': '60'}),
     429, 'rate_limited', '60'),
    (auth.DatabaseError('synthetic database failure'), 503, 'database_unavailable', '5'),
])
def test_browser_failures_are_closed_html_without_replaying_credentials(monkeypatch, failure, status, code, retry):
    def rejected(request, form):
        raise failure
    monkeypatch.setattr(auth, '_login', rejected)
    # No lifespan/DB is needed: exercise browser routing/error rendering only.
    with_browser = TestClient(app, base_url=settings.public_origin)
    result = with_browser.post('/v1/auth/authorize', data={'password': 'synthetic-secret'},
        headers={'Origin': settings.public_origin, 'Accept': 'text/html'})
    assert result.status_code == status and result.headers['x-weekglass-error'] == code
    assert result.headers['retry-after'] == retry
    assert '<form' not in result.text and '<input' not in result.text
    assert 'synthetic-secret' not in result.text and '不会自动重新提交密码' in result.text


def test_browser_wrong_origin_is_still_rejected_before_credentials(monkeypatch):
    def forbidden(request, form):
        raise AssertionError('cross-origin credentials reached login')
    monkeypatch.setattr(auth, '_login', forbidden)
    with_browser = TestClient(app, base_url=settings.public_origin)
    result = with_browser.post('/v1/auth/authorize', data={'password': 'synthetic-secret'},
        headers={'Origin': 'https://attacker.example', 'Accept': 'text/html'})
    assert result.status_code == 403 and result.headers['x-weekglass-error'] == 'invalid_origin'
    assert '无法确认此登录页面的来源' in result.text
    assert '<form' not in result.text and 'synthetic-secret' not in result.text


def code_for(client, account, device_id=None):
    params, verifier, csrf = begin(client, device_id)
    response = client.post('/v1/auth/authorize', data={'csrf': csrf, 'username': account[1], 'password': account[2]},
                           headers={'Origin': settings.public_origin})
    query = parse_qs(urlsplit(callback_from(response)).query)
    assert query['state'][0] == params['state']
    return {'grant_type': 'authorization_code', 'client_id': 'weekglass-native',
            'redirect_uri': params['redirect_uri'], 'device_id': params['device_id'],
            'code': query['code'][0], 'code_verifier': verifier}


def tokens_for(client, account, device_id=None):
    form = code_for(client, account, device_id)
    response = client.post('/v1/auth/token', data=form)
    assert response.status_code == 200, response.text
    assert response.headers['cache-control'] == 'no-store'
    result = response.json()
    assert result['account_id'] == account[0]
    return result


def headers(tokens):
    return {'Authorization': 'Bearer '+tokens['access_token']}


def refresh_form(tokens):
    return {'grant_type': 'refresh_token', 'client_id': 'weekglass-native',
            'device_id': tokens['device_id'], 'refresh_token': tokens['refresh_token']}


def test_authorization_code_single_use_and_no_plaintext_tokens(client, account):
    form = code_for(client, account)
    response = client.post('/v1/auth/token', data=form)
    assert response.status_code == 200
    tokens = response.json()
    assert client.get('/v1/devices', headers=headers(tokens)).status_code == 200
    with connect() as conn:
        assert conn.execute('SELECT token_hash FROM auth_tokens WHERE token_hash=%s', (tokens['access_token'],)).fetchone() is None
        assert conn.execute('SELECT token_hash FROM auth_tokens WHERE token_hash=%s', (auth.hashed(tokens['access_token']),)).fetchone()
    assert client.post('/v1/auth/token', data=form).status_code == 400
    assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401


def test_handoff_code_keeps_one_minute_lifetime_and_consumes_its_grant_once(client, account):
    params, verifier, csrf = begin(client)
    form = {'csrf': csrf, 'username': account[1], 'password': account[2]}
    success = client.post('/v1/auth/authorize', data=form, headers={'Origin': settings.public_origin})
    callback = urlsplit(callback_from(success))
    query = parse_qs(callback.query)
    assert query['state'] == [params['state']]
    with connect() as conn:
        code = conn.execute('SELECT * FROM auth_codes WHERE code_hash=%s',
                            (auth.hashed(query['code'][0]),)).fetchone()
        assert code and 55 < (code['expires_at'] - auth.now()).total_seconds() <= 60
        assert code['used_at'] is None and code['challenge'] == params['code_challenge']
        assert conn.execute('SELECT grant_hash FROM auth_grants WHERE csrf_hash=%s',
                            (auth.hashed(csrf),)).fetchone() is None
    assert_expired_page(client.post('/v1/auth/authorize', data=form,
                                   headers={'Origin': settings.public_origin, 'Accept': 'text/html'}))
    result = client.post('/v1/auth/token', data={'grant_type': 'authorization_code',
        'client_id': 'weekglass-native', 'redirect_uri': params['redirect_uri'],
        'device_id': params['device_id'], 'code': query['code'][0], 'code_verifier': verifier})
    assert result.status_code == 200 and result.json()['account_id'] == account[0]


def test_wrong_pkce_and_callback_cannot_redeem(client, account):
    form = code_for(client, account)
    invalid = dict(form, code_verifier=secrets.token_urlsafe(48))
    assert client.post('/v1/auth/token', data=invalid).status_code == 400
    invalid = dict(form, redirect_uri='http://127.0.0.1:54322/oauth/callback')
    assert client.post('/v1/auth/token', data=invalid).status_code == 400
    assert client.post('/v1/auth/token', data=form).status_code == 200
    params, _, _ = begin(client)
    params['redirect_uri'] = 'https://attacker.example/oauth/callback'
    assert client.get('/v1/auth/authorize', params=params).status_code == 400


def test_login_requires_csrf_origin_and_password(client, account):
    _, _, csrf = begin(client)
    form = {'csrf': csrf, 'username': account[1], 'password': account[2]}
    assert client.post('/v1/auth/authorize', data=form, headers={'Origin':'https://attacker.example'}).status_code == 403
    assert client.post('/v1/auth/authorize', data=dict(form,csrf='wrong'), headers={'Origin':settings.public_origin}).status_code == 403
    wrong = client.post('/v1/auth/authorize', data=dict(form,password='wrong'), headers={'Origin':settings.public_origin})
    assert wrong.status_code == 401
    assert '账号或密码不正确' in wrong.text
    assert client.post('/v1/auth/authorize', data=form, headers={'Origin':settings.public_origin}).status_code == 200


def finish_page(client, account, page, *, origin=None):
    """Redeem exactly the page's PKCE flow, never another tab's device/state."""
    origin = origin or settings.public_origin
    params, verifier, csrf = page
    response = client.post(origin + '/v1/auth/authorize',
        data={'csrf': csrf, 'username': account[1], 'password': account[2]},
        headers={'Origin': origin})
    query = parse_qs(urlsplit(callback_from(response)).query)
    assert query['state'] == [params['state']]
    form = {'grant_type': 'authorization_code', 'client_id': 'weekglass-native',
            'redirect_uri': params['redirect_uri'], 'device_id': params['device_id'],
            'code': query['code'][0], 'code_verifier': verifier}
    # Selecting the wrong page's PKCE secret must still fail.
    rejected = client.post(origin + '/v1/auth/token',
                           data=dict(form, code_verifier=secrets.token_urlsafe(48)))
    assert rejected.status_code == 400
    result = client.post(origin + '/v1/auth/token', data=form)
    assert result.status_code == 200, result.text
    assert result.json()['device_id'] == params['device_id']
    assert result.json()['account_id'] == account[0]
    return result.json()


def assert_expired_page(response):
    assert response.status_code == 403
    assert response.headers['content-type'].startswith('text/html')
    assert response.headers['x-weekglass-error'] == 'invalid_csrf'
    assert '授权页面已失效' in response.text
    assert '回到 WeekGlass 点击重新连接' in response.text
    assert '<form' not in response.text and '<input' not in response.text
    assert 'location' not in response.headers
    assert response.headers['cache-control'] == 'no-store'


@pytest.mark.parametrize('first_to_finish', [0, 1])
@pytest.mark.parametrize('reload_same_page', [False, True])
def test_multiple_pages_survive_reload_back_and_either_completion_order(
        client, account, first_to_finish, reload_same_page):
    first = begin(client)
    if reload_same_page:
        response = client.get('/v1/auth/authorize', params=first[0])
        assert response.status_code == 200
        csrf = re.search(r'name="csrf" value="([^"]+)"', response.text).group(1)
        second = first[0], first[1], csrf
    else:
        second = begin(client)
    assert first[2] != second[2]
    pages = first, second
    assert len(client.cookies) == 2
    # An incorrect password must leave the older page usable even after a new
    # page is opened; this is the old fixed-cookie overwrite regression.
    wrong = client.post('/v1/auth/authorize',
        data={'csrf': first[2], 'username': account[1], 'password': 'wrong'},
        headers={'Origin': settings.public_origin})
    assert wrong.status_code == 401 and '账号或密码不正确' in wrong.text
    assert re.search(r'name="csrf" value="([^"]+)"', wrong.text).group(1) == first[2]
    finish_page(client, account, pages[first_to_finish])
    assert len(client.cookies) == 1
    finish_page(client, account, pages[1 - first_to_finish])
    assert len(client.cookies) == 0
    # Back/replay after consumption is different: never issue another code.
    replay = client.post('/v1/auth/authorize',
        data={'csrf': first[2], 'username': account[1], 'password': account[2]},
        headers={'Origin': settings.public_origin})
    assert_expired_page(replay)
    assert account[2] not in replay.text


def test_grant_cookie_and_csrf_must_match_and_replay_stays_rejected(client, account):
    first, second = begin(client), begin(client)
    first_name = auth.authorization_cookie_name(first[2], settings.public_origin)
    second_name = auth.authorization_cookie_name(second[2], settings.public_origin)
    first_cookie = next(cookie for cookie in client.cookies.jar if cookie.name == first_name)
    token = first_cookie.value
    other_token = client.cookies.get(second_name)
    form = {'csrf': first[2], 'username': account[1], 'password': account[2]}
    client.cookies.delete(first_name)
    assert_expired_page(client.post('/v1/auth/authorize', data=form,
                                    headers={'Origin': settings.public_origin}))
    client.cookies.set(first_name, other_token, domain=first_cookie.domain, path=first_cookie.path)
    assert_expired_page(client.post('/v1/auth/authorize', data=form,
                                    headers={'Origin': settings.public_origin}))
    client.cookies.set(first_name, token, domain=first_cookie.domain, path=first_cookie.path)
    finish_page(client, account, first)
    # Even restoring the correct old cookie cannot resurrect a consumed grant.
    client.cookies.set(first_name, token, domain=first_cookie.domain, path=first_cookie.path)
    assert_expired_page(client.post('/v1/auth/authorize', data=form,
                                    headers={'Origin': settings.public_origin}))
    finish_page(client, account, second)


def test_expired_grant_is_a_closed_browser_page(client, account):
    _, _, csrf = begin(client)
    with connect() as conn:
        conn.execute("UPDATE auth_grants SET expires_at=now()-interval '1 second' WHERE csrf_hash=%s",
                     (auth.hashed(csrf),))
    response = client.post('/v1/auth/authorize',
        data={'csrf': csrf, 'username': account[1], 'password': account[2]},
        headers={'Origin': settings.public_origin})
    assert_expired_page(response)
    assert account[1] not in response.text and account[2] not in response.text


def test_cookie_scope_and_pending_page_limit(client, account):
    pages = [begin(client) for _ in range(10)]
    assert len(client.cookies) == 8
    for cookie in client.cookies.jar:
        assert cookie.path == '/v1/auth/authorize'
        assert cookie.secure is settings.public_origin.startswith('https://')
        assert cookie.domain_specified is False
        assert cookie.get_nonstandard_attr('HttpOnly') is None
        assert cookie.has_nonstandard_attr('HttpOnly')
        assert cookie.get_nonstandard_attr('SameSite') == 'lax'
        assert cookie.expires is not None
    oldest = client.post('/v1/auth/authorize',
        data={'csrf': pages[0][2], 'username': account[1], 'password': account[2]},
        headers={'Origin': settings.public_origin})
    assert_expired_page(oldest)
    # Recent pages are retained in issue order, not arbitrary cookie order.
    finish_page(client, account, pages[2])
    finish_page(client, account, pages[-1])


def test_same_host_alternate_port_pages_are_isolated(client, account, monkeypatch):
    parsed = urlsplit(settings.public_origin)
    alternate = f'{parsed.scheme}://{parsed.hostname}:8443'
    assert alternate != settings.public_origin
    monkeypatch.setattr(settings, 'alternate_origins', (alternate,))
    first = begin(client)
    second = begin(client, origin=alternate)
    assert len(client.cookies) == 2
    form = {'csrf': first[2], 'username': account[1], 'password': account[2]}
    crossed = client.post(alternate + '/v1/auth/authorize', data=form,
                          headers={'Origin': settings.public_origin})
    assert crossed.status_code == 403 and crossed.json()['code'] == 'invalid_origin'
    # Both ports receive the same cookie jar, but a page's selector is bound
    # to its issuing origin even if a forged POST claims the target origin.
    assert_expired_page(client.post(alternate + '/v1/auth/authorize', data=form,
                                    headers={'Origin': alternate}))
    finish_page(client, account, first)
    finish_page(client, account, second, origin=alternate)


def test_predeployment_page_can_finish_without_erasing_new_page(client, account):
    legacy = begin(client)
    name = auth.authorization_cookie_name(legacy[2], settings.public_origin)
    cookie = next(cookie for cookie in client.cookies.jar if cookie.name == name)
    # Emulate a still-valid page/cookie issued by the previous server version.
    client.cookies.delete(name)
    client.cookies.set('wg_authorization', cookie.value, domain=cookie.domain, path=cookie.path)
    current = begin(client)
    finish_page(client, account, legacy)
    assert len(client.cookies) == 1
    finish_page(client, account, current)


def test_refresh_rotation_and_replay_revokes_family(client, account):
    old = tokens_for(client, account)
    response = client.post('/v1/auth/token', data=refresh_form(old))
    assert response.status_code == 200
    current = response.json()
    assert old['refresh_token'] != current['refresh_token']
    assert client.get('/v1/devices', headers=headers(current)).status_code == 200
    assert client.post('/v1/auth/token', data=refresh_form(old)).status_code == 400
    assert client.get('/v1/devices', headers=headers(current)).status_code == 401
    assert client.post('/v1/auth/token', data=refresh_form(current)).status_code == 400


def test_device_metadata_revoke_and_account_isolation(client, account):
    first = tokens_for(client, account)
    second = tokens_for(client, account)
    devices = client.get('/v1/devices', headers=headers(first)).json()['devices']
    assert {x['device_id'] for x in devices} == {first['device_id'], second['device_id']}
    data = {'device_id':second['device_id'],'display_name':'我的笔记本','platform':'windows','app_version':'0.15.0'}
    assert client.patch('/v1/devices/'+second['device_id'], json=data, headers=headers(first)).json()['display_name'] == '我的笔记本'
    unknown = str(uuid4())
    assert client.delete('/v1/devices/'+unknown, headers=headers(first)).status_code == 404
    assert client.delete('/v1/devices/'+second['device_id'], headers=headers(first)).status_code == 204
    assert client.get('/v1/devices', headers=headers(second)).status_code == 401
    assert client.get('/v1/devices', headers=headers(first)).status_code == 200


def test_refresh_revoke_and_access_expiry(client, account):
    tokens = tokens_for(client, account)
    assert client.post('/v1/auth/revoke', json={'refresh_token':tokens['refresh_token'],'device_id':str(uuid4())}).status_code == 204
    assert client.get('/v1/devices', headers=headers(tokens)).status_code == 200
    with connect() as conn:
        conn.execute('UPDATE auth_tokens SET expires_at=now()-interval \'1 second\' WHERE token_hash=%s', (auth.hashed(tokens['access_token']),))
    assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401
    assert client.post('/v1/auth/revoke', json={'refresh_token':tokens['refresh_token'],'device_id':tokens['device_id']}).status_code == 204
    assert client.post('/v1/auth/token', data=refresh_form(tokens)).status_code == 400


def test_expired_code_and_disabled_account(client, account):
    form = code_for(client, account)
    with connect() as conn:
        conn.execute('UPDATE auth_codes SET expires_at=now()-interval \'1 second\' WHERE code_hash=%s', (auth.hashed(form['code']),))
    assert client.post('/v1/auth/token', data=form).status_code == 400
    tokens = tokens_for(client, account)
    with connect() as conn:
        conn.execute('UPDATE auth_accounts SET enabled=false WHERE account_id=%s', (account[0],))
    assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401
    assert client.post('/v1/auth/token', data=refresh_form(tokens)).status_code == 400


def test_other_account_cannot_read_or_revoke_device(client, account):
    first = tokens_for(client, account)
    username, password = 'test-'+uuid4().hex, secrets.token_urlsafe(24)
    other_id = auth.create_account(username, password)
    try:
        other = tokens_for(client, (other_id, username, password))
        devices = client.get('/v1/devices', headers=headers(first)).json()['devices']
        assert other['device_id'] not in {d['device_id'] for d in devices}
        assert client.delete('/v1/devices/'+other['device_id'], headers=headers(first)).status_code == 404
        assert client.get('/v1/devices', headers=headers(other)).status_code == 200
    finally:
        with connect() as conn:
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (other_id,))


def test_identity_revalidated_after_revocation(client, account):
    tokens = tokens_for(client, account)
    request = Request({'type':'http', 'headers': [(b'authorization', headers(tokens)['Authorization'].encode())]})
    identity = auth.get_identity(request)
    assert 'token_hash' in identity and identity['token_hash'] != tokens['access_token']
    assert client.delete('/v1/devices/'+tokens['device_id'], headers=headers(tokens)).status_code == 204
    with pytest.raises(HTTPException) as error:
        with connect() as conn:
            auth.revalidate_identity(conn, identity)
    assert error.value.status_code == 401


def test_old_refresh_cannot_logout_a_new_login(client, account):
    old = tokens_for(client, account)
    current = tokens_for(client, account, old['device_id'])
    assert client.get('/v1/devices', headers=headers(old)).status_code == 401
    assert client.post('/v1/auth/revoke', json={'refresh_token':old['refresh_token'],'device_id':old['device_id']}).status_code == 204
    assert client.get('/v1/devices', headers=headers(current)).status_code == 200
    assert client.post('/v1/auth/revoke', json={'refresh_token':current['refresh_token'],'device_id':current['device_id']}).status_code == 204
    assert client.get('/v1/devices', headers=headers(current)).status_code == 401


def test_password_reset_revokes_tokens_and_pending_codes(client, account):
    tokens = tokens_for(client, account)
    pending = code_for(client, account)
    new_password = secrets.token_urlsafe(24)
    assert auth.reset_password(account[1], new_password) == account[0]
    assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401
    assert client.post('/v1/auth/token', data=refresh_form(tokens)).status_code == 400
    assert client.post('/v1/auth/token', data=pending).status_code == 400
    updated = tokens_for(client, (account[0],account[1],new_password), tokens['device_id'])
    assert client.get('/v1/devices', headers=headers(updated)).status_code == 200


def test_auth_json_rejects_ambiguous_or_invalid_unicode(client):
    duplicate = '{"device_id":"a","device_id":"b","refresh_token":"'+'x'*40+'"}'
    invalid_unicode = '{"device_id":"11111111-1111-4111-8111-111111111111","refresh_token":"\\ud800"}'
    for raw in (duplicate, invalid_unicode):
        response = client.post('/v1/auth/revoke', content=raw, headers={'Content-Type':'application/json'})
        assert response.status_code == 400


def test_discovery_uses_only_configured_request_origin(client, monkeypatch):
    alternate = 'https://legacy-sync.example:8443'
    monkeypatch.setattr(settings, 'alternate_origins', (alternate,))
    for origin in (settings.public_origin, alternate):
        response = client.get(origin + '/v1/server-info')
        assert response.status_code == 200
        info = response.json()
        assert info['server_id'] == settings.server_id
        assert info['api_base_url'] == origin + '/v1'
        assert info['authorization_endpoint'] == origin + '/v1/auth/authorize'
        assert info['token_endpoint'] == origin + '/v1/auth/token'
    assert client.get('/v1/server-info', headers={'Host': 'attacker.example'}).status_code == 400
    response = client.get('/v1/server-info', headers={'X-Forwarded-Host': 'attacker.example'})
    assert response.json()['api_base_url'] == settings.public_origin + '/v1'


def test_alternate_origin_pkce_still_requires_same_origin(client, account, monkeypatch):
    alternate = 'https://legacy-sync.example:8443'
    monkeypatch.setattr(settings, 'alternate_origins', (alternate,))
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    params = {'response_type': 'code', 'client_id': 'weekglass-native',
              'redirect_uri': 'http://127.0.0.1:54321/oauth/callback',
              'code_challenge': challenge, 'code_challenge_method': 'S256',
              'state': secrets.token_urlsafe(32), 'device_id': str(uuid4())}
    page = client.get(alternate + '/v1/auth/authorize', params=params)
    assert page.status_code == 200
    csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
    form = {'csrf': csrf, 'username': account[1], 'password': account[2]}
    for rejected in ('https://attacker.example', settings.public_origin, 'null'):
        assert client.post(alternate + '/v1/auth/authorize', data=form,
                           headers={'Origin': rejected}).status_code == 403
    response = client.post(alternate + '/v1/auth/authorize', data=form, headers={'Origin': alternate})
    query = parse_qs(urlsplit(callback_from(response)).query)
    assert query['state'][0] == params['state']
    token = client.post(alternate + '/v1/auth/token', data={
        'grant_type': 'authorization_code', 'client_id': 'weekglass-native',
        'redirect_uri': params['redirect_uri'], 'device_id': params['device_id'],
        'code': query['code'][0], 'code_verifier': verifier})
    assert token.status_code == 200
    assert client.get('/v1/devices', headers=headers(token.json())).status_code == 200
