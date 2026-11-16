"""Public HTTPS account/sync checks using disposable synthetic accounts only.

No passwords, recovery codes, OAuth codes, tokens or account IDs enter reports.
Optional --ssh grants only the freshly created synthetic sync account a one-day
test entitlement, then deletes it. Existing accounts are never selected.
"""
from __future__ import annotations

import argparse
import base64
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import re
import secrets
import shlex
import subprocess
from urllib.parse import parse_qs, urlsplit
from uuid import UUID, uuid4

import httpx

from smoke_http import auth, authorization_callback, batch, check_sync, event, login, require, response, stamp, CheckFailed


def begin(client, origin, *, include_signup_mode=False):
    verifier = secrets.token_urlsafe(48)
    params = {'response_type': 'code', 'client_id': 'weekglass-native',
              'redirect_uri': 'http://127.0.0.1:54321/oauth/callback',
              'code_challenge': base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode(),
              'code_challenge_method': 'S256', 'state': secrets.token_urlsafe(32), 'device_id': str(uuid4())}
    page = response(client.get('/v1/auth/authorize', params=params), 200, 'authorization page')
    require(page.headers.get('referrer-policy') == 'same-origin', 'browser POST origin policy')
    require('Secure' in page.headers.get('set-cookie', '') and 'HttpOnly' in page.headers.get('set-cookie', ''), 'secure grant cookie')
    csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
    context = params, verifier, csrf
    return (context, 'value="email_register"' in page.text) if include_signup_mode else context


def browser(client, origin, form):
    return client.post('/v1/auth/authorize', data=form, headers={'Origin': origin})


def recover_key(reply):
    response(reply, 200, 'recovery key confirmation page')
    match = re.search(r'<code id="recovery-key">([^<]+)</code>', reply.text)
    require(match is not None, 'recovery key shown once')
    return match.group(1)


def finish(client, origin, context, reply=None, *, official_signup=False):
    params, verifier, csrf = context
    if reply is None:
        reply = browser(client, origin, {'action': 'continue', 'csrf': csrf})
    require(reply.headers.get('referrer-policy') == 'no-referrer', 'callback referrer privacy')
    target = urlsplit(authorization_callback(reply, signup=official_signup))
    query = parse_qs(target.query)
    require(query['state'] == [params['state']], 'PKCE state')
    return response(client.post('/v1/auth/token', data={
        'grant_type': 'authorization_code', 'client_id': 'weekglass-native',
        'code': query['code'][0], 'code_verifier': verifier, 'redirect_uri': params['redirect_uri'],
        'device_id': params['device_id']}), 200, 'PKCE redemption').json()


def synthetic_record():
    return {'seed_username': 'smoke-' + uuid4().hex, 'password': 'Wg7-' + secrets.token_urlsafe(32)}


def register(client, origin, record=None):
    if record is None:
        record = synthetic_record()
    username, password = record['seed_username'], record['password']
    record['username'] = username
    context, email_signup = begin(client, origin, include_signup_mode=True)
    if email_signup:
        record['email'] = username + '@example.invalid'
    form = {'action': 'email_register' if email_signup else 'register', 'csrf': context[2],
            **({'email': record['email']} if email_signup else {'username': username}),
            'password': password, 'confirm_password': password}
    for invalid in ('null', 'https://viliana.cn'):
        response(client.post('/v1/auth/authorize', data=form, headers={'Origin': invalid}), 403, 'cross-origin registration refused')
    reply = browser(client, origin, form)
    key = None if email_signup else recover_key(reply)
    tokens = finish(client, origin, context, reply if email_signup else None, official_signup=email_signup)
    aid = tokens['account_id']
    record.update(tokens=tokens, account_id=aid, recovery_key=key)
    if email_signup:
        record['username'] = 'wg-' + UUID(aid).hex
    return record


def cleanup(ssh, record):
    if not ssh:
        return False
    seed = record.get('seed_username', record.get('username', ''))
    email, aid = record.get('email'), record.get('account_id')
    require(re.fullmatch(r'smoke-[a-f0-9]{32}', seed) is not None
            and email in (None, seed + '@example.invalid'), 'synthetic cleanup scope')
    # Identify this run even if registration committed before token redemption
    # was interrupted. A provisional email alone cannot identify an account.
    source = '''from weekglass_server import auth
from weekglass_server.db import connect
import json, sys
seed, email, aid, password = json.loads(sys.stdin.readline())
with connect() as conn:
    if aid:
        conn.execute("""DELETE FROM accounts a USING auth_accounts u WHERE a.account_id=u.account_id AND a.account_id=%s
          AND (u.username=%s OR u.pending_email=%s)""", (aid, seed, email))
    elif email:
        conn.execute("""DELETE FROM accounts a USING auth_accounts u WHERE a.account_id=u.account_id
          AND u.pending_email=%s AND u.pending_login_key=%s""", (email, auth.pending_login_key(email, password)))
    else:
        conn.execute("DELETE FROM accounts a USING auth_accounts u WHERE a.account_id=u.account_id AND u.username=%s", (seed,))
'''
    payload = json.dumps((seed, email, aid, record['password'] if email and not aid else None)) + '\n'
    subprocess.run(['ssh', '-o', 'BatchMode=yes', ssh,
                    'docker exec -i weekglass-api-1 python -c ' + shlex.quote(source)], input=payload.encode(),
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return True


def lifecycle(origin, alternate, ssh):
    record = synthetic_record()
    checks = []
    try:
        with httpx.Client(base_url=origin, timeout=40, follow_redirects=False, trust_env=False) as client, \
             httpx.Client(base_url=alternate, timeout=40, follow_redirects=False, trust_env=False) as other:
            register(client, origin, record)
            current = record['tokens']
            checks += ['same_origin_browser_policy', 'null_and_foreign_origin_refused', 'public_registration', 'same_origin_handoff_document', 'PKCE_redemption']
            profile = response(client.get('/v1/me/account', headers=auth(current)), 200, 'account profile').json()
            email = record.get('email')
            require(profile['username'] == record['username'] and profile['recovery_configured'] is (not email), 'independent account identity')
            if email:
                require(profile.get('pending_email') == email and not profile['email_verified'], 'signup is not mail verification')
                portal = response(client.get('/account#plans'), 200, 'official console signup')
                require('选择云同步时长' in portal.text, 'show plans after signup')
                checks += ['signup_without_email_proof', 'browser_console_plans']
            else:
                checks.append('recovery_key_confirmation')
            entitlement = response(client.get('/v1/me/entitlements', headers=auth(current)), 200, 'entitlements').json()
            free = entitlement['mode'] == 'self_hosted'
            require(entitlement['sync_read'] is free and entitlement['sync_write'] is free, 'registration cannot grant hosted sync')
            checks.append('hosted_subscription_guard')
            device = {'device_id': current['device_id'], 'display_name': 'Synthetic Windows device', 'platform': 'windows', 'app_version': 'qa'}
            response(client.patch('/v1/devices/' + current['device_id'], json=device, headers=auth(current)), 200, 'device metadata')
            second = login(other, email or record['username'], record['password'], alternate)
            require(second['account_id'] == current['account_id'], 'alternate origin same account')
            response(client.post('/v1/me/sessions/revoke-others', json={'current_password': record['password']}, headers=auth(current)), 204, 'revoke other sessions')
            response(other.get('/v1/devices', headers=auth(second)), 401, 'revoked alternate device')
            response(client.get('/v1/devices', headers=auth(current)), 200, 'current device retained')
            checks += ['device_metadata', 'alternate_origin_login', 'revoke_other_sessions']
            def new_recovery_key():
                return response(client.post('/v1/me/recovery-key', json={'current_password': record['password']},
                                            headers=auth(current)), 200, 'rotate recovery key').json()['recovery_key']
            old_key = record['recovery_key'] or new_recovery_key()
            key = new_recovery_key()
            context = begin(client, origin)
            password = 'Wg7-' + secrets.token_urlsafe(32)
            form = {'action': 'recover', 'csrf': context[2], 'username': email or record['username'],
                    'password': password, 'confirm_password': password, 'recovery_key': old_key}
            response(browser(client, origin, form), 401, 'old recovery key rejected')
            form['recovery_key'] = key
            new_key = recover_key(browser(client, origin, form))
            require(new_key != key, 'recovery key consumed and rotated')
            record['password'] = password
            response(client.get('/v1/devices', headers=auth(current)), 401, 'recovery revokes existing access')
            current = finish(client, origin, context)
            checks += ['recovery_key_rotation', 'old_recovery_key_refused', 'password_recovery', 'recovery_revokes_sessions']
            changed = 'Wg7-' + secrets.token_urlsafe(32)
            response(client.post('/v1/me/password', json={'current_password': password, 'new_password': changed}, headers=auth(current)), 204, 'password change')
            record['password'] = changed
            response(client.get('/v1/devices', headers=auth(current)), 401, 'password change revokes session')
            current = login(client, record['username'], changed, origin)
            exported = response(client.get('/v1/exports/calendar', headers=auth(current)),
                                200 if free else 403, 'calendar export entitlement')
            if not free:
                require(exported.json().get('code') == 'subscription_required', 'no calendar API without hosted service')
            checks += ['password_change', 'calendar_export_entitlement']
            response(client.post('/v1/auth/revoke', json={'refresh_token': current['refresh_token'], 'device_id': current['device_id']}), 204, 'logout')
            response(client.get('/v1/me/account', headers=auth(current)), 401, 'logout invalidates access')
            current = login(client, record['username'], changed, origin)
            response(client.request('DELETE', '/v1/me/account', json={'current_password': changed, 'confirmation': 'wrong-name'}, headers=auth(current)), 400, 'delete requires username confirmation')
            response(client.request('DELETE', '/v1/me/account', json={'current_password': changed, 'confirmation': record['username']}, headers=auth(current)), 204, 'delete synthetic account')
            response(client.get('/v1/me/account', headers=auth(current)), 401, 'deleted account inaccessible')
            checks += ['logout', 'deletion_confirmation', 'account_deletion']
        return {'checks': checks, 'passed': len(checks), 'synthetic_account_deleted': True}
    finally:
        if record and ssh:
            cleanup(ssh, record)


def transfer(client, tokens):
    baseline = response(client.post('/v1/sync/snapshots', headers=auth(tokens)), 200, 'transfer baseline').json()
    values = [event('transfer-' + uuid4().hex) for _ in range(50)]
    for value in values:
        value['notes'] = 'Synthetic calendar transfer verification. ' * 20
    payload = batch(tokens, [(value['id'], None, value) for value in values])
    write = response(client.post('/v1/sync/batches', json=payload, headers=auth(tokens)), 200, 'initial transfer batch')
    receipt = write.json()
    initial = response(client.get('/v1/sync/changes', params={'cursor': baseline['boundary_cursor']}, headers=auth(tokens)), 200, 'initial delta').json()
    # Catch up every full batch before measuring one new edit.
    while initial['has_more']:
        initial = response(client.get('/v1/sync/changes', params={'cursor': initial['next_cursor']}, headers=auth(tokens)), 200, 'initial delta catch-up').json()
    edit = deepcopy(values[0]); edit['title'] = 'One changed event'; edit['version'] = 2
    change = batch(tokens, [(edit['id'], receipt['results'][0]['revision'], edit)])
    written = response(client.post('/v1/sync/batches', json=change, headers=auth(tokens)), 200, 'single event edit')
    duplicate = response(client.post('/v1/sync/batches', json=change, headers=auth(tokens)), 200, 'identical retry')
    require(written.json() == duplicate.json(), 'retry preserves receipt')
    delta = response(client.get('/v1/sync/changes', params={'cursor': initial['next_cursor']}, headers=auth(tokens)), 200, 'single event delta')
    result = delta.json()
    require(len(result['changes']) == 1 and len(result['changes'][0]['records']) == 1, 'only changed entity transferred')
    idle = response(client.get('/v1/sync/changes', params={'cursor': result['next_cursor']}, headers=auth(tokens)), 200, 'idle delta')
    require(idle.json()['changes'] == [] and idle.json()['next_cursor'] == result['next_cursor'], 'idle contains no calendar')
    full = response(client.get('/v1/exports/calendar', headers=auth(tokens)), 200, 'full export comparison')
    require(len(delta.content) < len(full.content) / 10, 'single edit is materially smaller than full calendar')
    require(delta.headers.get('content-encoding') == 'gzip', 'delta response gzip')
    return {'event_count': 50, 'single_edit_records': 1, 'idle_records': 0,
            'initial_upload_bytes': len(write.request.content), 'single_edit_upload_bytes': len(written.request.content),
            'single_delta_decoded_bytes': len(delta.content), 'single_delta_wire_bytes': delta.num_bytes_downloaded,
            'idle_decoded_bytes': len(idle.content), 'full_export_decoded_bytes': len(full.content),
            'response_compression': 'gzip', 'idempotent_retry_added_changes': 0}


def sync_checks(origin, ssh):
    require(bool(ssh), 'sync smoke needs authorized SSH for synthetic entitlement')
    record = synthetic_record()
    try:
        with httpx.Client(base_url=origin, timeout=40, follow_redirects=False, trust_env=False) as client:
            register(client, origin, record)
            subprocess.run(['ssh', '-o', 'BatchMode=yes', ssh, 'docker', 'exec', 'weekglass-api-1',
                            'python', '-m', 'weekglass_server.admin', 'grant', record['account_id'], '--days', '1'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            synced = check_sync(origin, record['username'], record['password'], origin)
            measured = transfer(client, record['tokens'])
            response(client.request('DELETE', '/v1/me/account', json={'current_password': record['password'], 'confirmation': record['username']}, headers=auth(record['tokens'])), 204, 'remove synthetic sync account')
            return {'integration': synced, 'transfer': measured, 'synthetic_account_deleted': True}
    finally:
        if record:
            cleanup(ssh, record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://cloud.viliana.cn')
    parser.add_argument('--alternate', default='https://cloud.viliana.cn:8443')
    parser.add_argument('--ssh')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = {'started_at': stamp(), 'transport': 'Real HTTPS, independent disposable accounts, no personal data'}
    try:
        result['account'] = lifecycle(args.origin, args.alternate, args.ssh)
        if args.ssh:
            result['sync'] = sync_checks(args.origin, args.ssh)
        result['success'] = True
    except CheckFailed as error:
        result.update(success=False, error=str(error))
    except Exception as error:
        result.update(success=False, error_type=type(error).__name__)
    result['finished_at'] = stamp()
    if args.report:
        args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['success'] else 1)


if __name__ == '__main__':
    main()
