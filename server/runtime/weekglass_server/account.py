"""WeekGlass-only account lifecycle; no dependency on the main site's accounts."""
from __future__ import annotations

import hmac
import re
import secrets
from uuid import uuid4

from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import APIRouter, Depends, Request, Response
from psycopg.errors import UniqueViolation
from starlette.concurrency import run_in_threadpool

from . import auth, billing
from .db import connect
from .protocol import body
from .settings import settings

router = APIRouter()


def password_matches(account, password):
    try:
        with auth._password_slots:
            matched = auth._hasher.verify(account['password_hash'] if account else auth._dummy_hash, password)
    except (VerificationError, InvalidHashError):
        matched = False
    return bool(matched and account and account['enabled'])


def recovery_key():
    return 'WG-' + secrets.token_urlsafe(32)


def revoke_sessions(conn, account_id, *, except_device=None, keep_grant=None):
    if except_device:
        conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s AND device_id<>%s',
                     (account_id, except_device))
        conn.execute('UPDATE devices SET revoked_at=now() WHERE account_id=%s AND device_id<>%s',
                     (account_id, except_device))
        conn.execute('DELETE FROM auth_codes WHERE account_id=%s AND device_id<>%s', (account_id, except_device))
    else:
        conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s', (account_id,))
        conn.execute('UPDATE devices SET revoked_at=now() WHERE account_id=%s', (account_id,))
        conn.execute('DELETE FROM auth_codes WHERE account_id=%s', (account_id,))
    conn.execute('DELETE FROM auth_grants WHERE account_id=%s AND grant_hash<>%s', (account_id, keep_grant or ''))


def browser_action(request, action, form):
    expected = {'csrf'} if action == 'continue' else {'csrf', 'username', 'password', 'confirm_password'}
    if action == 'recover':
        expected.add('recovery_key')
    if action not in ('register', 'recover', 'continue') or set(form) != expected:
        auth.fail(400, 'invalid_request', '请求内容无效。')
    if any(len(value) > 1024 for value in form.values()) or len(form['csrf']) > 128:
        auth.fail(400, 'invalid_request', '请求内容过长。')
    auth.rate_limit(request, 'account-browser', 12)
    with connect() as conn:
        grant, cookie_name = auth.authorization_grant(conn, request, form['csrf'])
        if action == 'continue':
            if not grant['account_id']:
                auth.fail(400, 'invalid_request', '请先注册或恢复账号。')
            auth.lock_account(conn, grant['account_id'])
            account = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (grant['account_id'],)).fetchone()
            if not account or not account['enabled']:
                auth.fail(403, 'account_unavailable', '账号不可用。')
            return auth.complete_authorization(conn, grant, cookie_name, account['account_id'])
        if grant['account_id']:
            auth.fail(400, 'invalid_request', '此操作已完成，请重新登录。')
        username = form['username'].strip().casefold()
        if not re.fullmatch(r'[a-z0-9][a-z0-9_.@+-]{2,79}', username):
            return auth.html_response(form['csrf'], '账号需为 3–80 位英文字母、数字或 _.@+-。', 400, action=action)
        if not 16 <= len(form['password']) <= 1024 or form['password'] != form['confirm_password']:
            return auth.html_response(form['csrf'], '请设置至少 16 字符的密码，并确保两次输入一致。', 400, action=action)
        auth.rate_limit(request, 'account-browser-user', 6, username)
        key = recovery_key()
        if action == 'register':
            if not settings.registration_enabled:
                return auth.html_response(form['csrf'], '此服务器未开放注册，请联系管理员。', 403, action=action)
            auth.rate_limit(request, 'registration-ip', 3)
            auth.rate_limit(request, 'registration-global', 30, 'weekglass')
            aid = str(uuid4())
            password_hash = auth.hash_password(form['password'])
            try:
                with conn.transaction():
                    conn.execute('INSERT INTO accounts(account_id,dataset_id,sync_epoch) VALUES (%s,%s,%s)',
                                 (aid, str(uuid4()), str(uuid4())))
                    conn.execute('INSERT INTO auth_accounts(account_id,username,password_hash,recovery_hash) VALUES (%s,%s,%s,%s)',
                                 (aid, username, password_hash, auth.hashed(key)))
            except UniqueViolation:
                return auth.html_response(form['csrf'], '此账号名不可用，请换一个账号名或直接登录。', 409, action=action)
        else:
            account = conn.execute('SELECT * FROM auth_accounts WHERE username=%s', (username,)).fetchone()
            if account:
                auth.lock_account(conn, account['account_id'])
                account = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (account['account_id'],)).fetchone()
            expected_hash = account['recovery_hash'] if account and account['recovery_hash'] else auth.hashed('unavailable')
            valid = hmac.compare_digest(expected_hash, auth.hashed(form['recovery_key'].strip()))
            if not valid or not account or not account['enabled'] or not account['recovery_hash']:
                return auth.html_response(form['csrf'], '账号或恢复码不正确。', 401, action=action)
            aid = account['account_id']
            conn.execute('UPDATE auth_accounts SET password_hash=%s,recovery_hash=%s WHERE account_id=%s',
                         (auth.hash_password(form['password']), auth.hashed(key), aid))
            revoke_sessions(conn, aid, keep_grant=grant['grant_hash'])
        conn.execute('UPDATE auth_grants SET account_id=%s WHERE grant_hash=%s', (aid, grant['grant_hash']))
    return auth.html_response(form['csrf'], recovery_key=key)


@router.get('/v1/me/account')
def account_info(identity=Depends(auth.get_identity)):
    with connect() as conn:
        auth.revalidate_identity(conn, identity)
        account = conn.execute('''SELECT a.account_id,a.created_at,u.username,u.recovery_hash IS NOT NULL AS recovery_configured
          FROM accounts a JOIN auth_accounts u USING(account_id) WHERE account_id=%s''', (identity['account_id'],)).fetchone()
        usage = conn.execute('''SELECT coalesce(sum(payload_bytes),0) AS storage_bytes,
          count(*) FILTER (WHERE record->>'deleted_at_utc' IS NULL) AS event_count
          FROM event_heads WHERE account_id=%s''', (identity['account_id'],)).fetchone()
        count = conn.execute('SELECT count(*) AS n FROM devices WHERE account_id=%s AND revoked_at IS NULL',
                             (identity['account_id'],)).fetchone()['n']
    return {'account_id': str(account['account_id']), 'username': account['username'],
            'created_at': auth.stamp(account['created_at']), 'recovery_configured': account['recovery_configured'],
            'active_devices': count, 'usage': usage}


def _account_action(request, identity, data, action):
    auth.rate_limit(request, 'account-management-ip', 12)
    auth.rate_limit(request, 'account-management-user', 6, identity['account_id'])
    with connect() as conn:
        auth.lock_account(conn, identity['account_id'])
        auth.revalidate_identity(conn, identity)
        account = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (identity['account_id'],)).fetchone()
        if not password_matches(account, data['current_password']):
            auth.fail(403, 'incorrect_password', '当前密码不正确。')
        if action == 'password':
            conn.execute('UPDATE auth_accounts SET password_hash=%s WHERE account_id=%s',
                         (auth.hash_password(data['new_password']), identity['account_id']))
            revoke_sessions(conn, identity['account_id'])
        elif action == 'recovery':
            key = recovery_key()
            conn.execute('UPDATE auth_accounts SET recovery_hash=%s WHERE account_id=%s',
                         (auth.hashed(key), identity['account_id']))
            return {'recovery_key': key}
        elif action == 'revoke_others':
            revoke_sessions(conn, identity['account_id'], except_device=identity['device_id'])
        elif action == 'delete':
            if data['confirmation'].strip().casefold() != account['username']:
                auth.fail(400, 'confirmation_required', '请输入当前账号名以确认。')
            billing.detach_account(conn, identity['account_id'])
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (identity['account_id'],))
    return Response(status_code=204)


@router.post('/v1/me/password', status_code=204)
async def change_password(request: Request, identity=Depends(auth.get_identity)):
    data = await body(request, 'ChangePasswordRequest')
    return await run_in_threadpool(_account_action, request, identity, data, 'password')


@router.post('/v1/me/recovery-key')
async def rotate_recovery_key(request: Request, identity=Depends(auth.get_identity)):
    data = await body(request, 'ConfirmPasswordRequest')
    return await run_in_threadpool(_account_action, request, identity, data, 'recovery')


@router.post('/v1/me/sessions/revoke-others', status_code=204)
async def revoke_other_sessions(request: Request, identity=Depends(auth.get_identity)):
    data = await body(request, 'ConfirmPasswordRequest')
    return await run_in_threadpool(_account_action, request, identity, data, 'revoke_others')


@router.delete('/v1/me/account', status_code=204)
async def delete_account(request: Request, identity=Depends(auth.get_identity)):
    data = await body(request, 'DeleteAccountRequest')
    return await run_in_threadpool(_account_action, request, identity, data, 'delete')
