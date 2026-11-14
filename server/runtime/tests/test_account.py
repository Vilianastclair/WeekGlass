"""Account lifecycle regression tests against the dedicated *_test database."""
import re
import secrets
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import pytest

from weekglass_server import auth
from weekglass_server.db import connect
from weekglass_server.settings import settings
from test_auth import account, begin, callback_from, client, code_for, headers, running_client, tokens_for


def post_browser(client, form):
    return client.post('/v1/auth/authorize', data=form, headers={'Origin': settings.public_origin})


def key_from(response):
    assert response.status_code == 200
    key = re.search(r'<code id="recovery-key">([^<]+)</code>', response.text).group(1)
    assert key.startswith('WG-') and len(key) >= 45
    return key


def continue_tokens(client, params, verifier, csrf):
    response = post_browser(client, {'action': 'continue', 'csrf': csrf})
    assert response.headers['referrer-policy'] == 'no-referrer'
    q = parse_qs(urlsplit(callback_from(response)).query)
    assert q['state'] == [params['state']]
    reply = client.post('/v1/auth/token', data={
        'grant_type': 'authorization_code', 'client_id': 'weekglass-native',
        'code': q['code'][0], 'code_verifier': verifier,
        'redirect_uri': params['redirect_uri'], 'device_id': params['device_id']})
    assert reply.status_code == 200
    return reply.json()


def test_browser_policy_keeps_same_origin_and_rejects_null(client, account):
    params, _, csrf = begin(client)
    page = client.get('/v1/auth/authorize', params=params)
    assert page.headers['referrer-policy'] == 'same-origin'
    assert "form-action 'self'" in page.headers['content-security-policy']
    form = {'csrf': csrf, 'username': account[1], 'password': account[2]}
    for origin in ('null', 'https://viliana.cn'):
        assert client.post('/v1/auth/authorize', data=form, headers={'Origin': origin}).status_code == 403


def test_registration_recovery_key_and_explicit_continuation(client):
    username, password = 'new-' + uuid4().hex, secrets.token_urlsafe(24)
    params, verifier, csrf = begin(client)
    aid = None
    try:
        response = post_browser(client, {'action': 'register', 'csrf': csrf, 'username': username,
                                         'password': password, 'confirm_password': password})
        key = key_from(response)
        assert 'location' not in response.headers
        with connect() as conn:
            row = conn.execute('SELECT account_id,recovery_hash FROM auth_accounts WHERE username=%s', (username,)).fetchone()
            aid = row['account_id']
            assert row['recovery_hash'] == auth.hashed(key) and row['recovery_hash'] != key
        # Reconnecting in the app must not replace the page holding this
        # one-time recovery key, or let an unrelated flow continue the account.
        _, _, other_csrf = begin(client)
        assert post_browser(client, {'action': 'continue', 'csrf': other_csrf}).status_code == 400
        tokens = continue_tokens(client, params, verifier, csrf)
        profile = client.get('/v1/me/account', headers=headers(tokens)).json()
        assert profile['username'] == username and profile['recovery_configured'] is True
        assert profile['usage'] == {'storage_bytes': 0, 'event_count': 0}
        assert post_browser(client, {'action': 'continue', 'csrf': csrf}).status_code == 403
        entitlement = client.get('/v1/me/entitlements', headers=headers(tokens)).json()
        assert entitlement['sync_write'] is (settings.mode == 'self_hosted')
    finally:
        if aid:
            with connect() as conn:
                conn.execute('DELETE FROM accounts WHERE account_id=%s', (aid,))


def test_registration_disabled_validation_and_duplicate_leave_no_orphans(client, account, monkeypatch):
    _, _, csrf = begin(client)
    form = {'action': 'register', 'csrf': csrf, 'username': account[1],
            'password': account[2], 'confirm_password': account[2]}
    assert post_browser(client, dict(form, password='short', confirm_password='short')).status_code == 400
    assert post_browser(client, form).status_code == 409
    with connect() as conn:
        assert conn.execute('SELECT count(*) AS n FROM auth_accounts WHERE username=%s', (account[1],)).fetchone()['n'] == 1
    monkeypatch.setattr(settings, 'registration_enabled', False)
    assert post_browser(client, dict(form, username='blocked-' + uuid4().hex)).status_code == 403


def test_recovery_rotates_key_revokes_all_devices_and_preserves_calendar(client, account):
    first = tokens_for(client, account)
    second = tokens_for(client, account)
    response = client.post('/v1/me/recovery-key', json={'current_password': account[2]}, headers=headers(first))
    assert response.status_code == 200
    old_key = response.json()['recovery_key']
    params, verifier, csrf = begin(client)
    password = secrets.token_urlsafe(24)
    form = {'action': 'recover', 'csrf': csrf, 'username': account[1], 'recovery_key': old_key,
            'password': password, 'confirm_password': password}
    assert post_browser(client, dict(form, recovery_key='wrong')).status_code == 401
    new_key = key_from(post_browser(client, form))
    assert new_key != old_key
    for tokens in (first, second):
        assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401
    begin(client)
    recovered = continue_tokens(client, params, verifier, csrf)
    assert recovered['account_id'] == first['account_id'] and recovered['dataset_id'] == first['dataset_id']
    _, _, next_csrf = begin(client)
    assert post_browser(client, dict(form, csrf=next_csrf)).status_code == 401
    with connect() as conn:
        stored = conn.execute('SELECT recovery_hash FROM auth_accounts WHERE account_id=%s', (account[0],)).fetchone()
        assert stored['recovery_hash'] == auth.hashed(new_key)


def test_password_change_reauthenticates_and_invalidates_pending_codes(client, account):
    old = tokens_for(client, account)
    pending = code_for(client, account)
    new_password = secrets.token_urlsafe(24)
    endpoint = '/v1/me/password'
    assert client.post(endpoint, json={'current_password': 'wrong', 'new_password': new_password}, headers=headers(old)).status_code == 403
    assert client.get('/v1/me/account', headers=headers(old)).status_code == 200
    assert client.post(endpoint, json={'current_password': account[2], 'new_password': 'short'}, headers=headers(old)).status_code == 422
    assert client.post(endpoint, json={'current_password': account[2], 'new_password': new_password}, headers=headers(old)).status_code == 204
    assert client.get('/v1/me/account', headers=headers(old)).status_code == 401
    assert client.post('/v1/auth/token', data=pending).status_code == 400
    renewed = tokens_for(client, (account[0], account[1], new_password))
    assert client.get('/v1/me/account', headers=headers(renewed)).status_code == 200


def test_revoke_other_sessions_keeps_current_device(client, account):
    first, second = tokens_for(client, account), tokens_for(client, account)
    response = client.post('/v1/me/sessions/revoke-others', json={'current_password': account[2]}, headers=headers(first))
    assert response.status_code == 204
    assert client.get('/v1/me/account', headers=headers(first)).status_code == 200
    assert client.get('/v1/me/account', headers=headers(second)).status_code == 401


def test_account_deletion_requires_password_and_username_then_cascades(client, account):
    tokens = tokens_for(client, account)
    endpoint = '/v1/me/account'
    def delete(password, confirmation):
        return client.request('DELETE', endpoint, json={'current_password': password, 'confirmation': confirmation}, headers=headers(tokens))
    assert delete('wrong', account[1]).status_code == 403
    assert delete(account[2], 'incorrect-name').status_code == 400
    assert delete(account[2], account[1]).status_code == 204
    assert client.get(endpoint, headers=headers(tokens)).status_code == 401
    with connect() as conn:
        for table in ('accounts', 'auth_accounts', 'devices', 'auth_codes', 'auth_families'):
            assert conn.execute(f'SELECT count(*) AS n FROM {table} WHERE account_id=%s', (account[0],)).fetchone()['n'] == 0


def test_recovery_rotation_cannot_be_called_with_cookie_only(client, account):
    begin(client)
    assert client.post('/v1/me/recovery-key', json={'current_password': account[2]}).status_code == 401
