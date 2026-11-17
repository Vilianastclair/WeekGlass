"""WeekGlass-only account lifecycle; no dependency on the main site's accounts."""
from __future__ import annotations

import hmac
import re
import secrets
from uuid import uuid4

from fastapi import APIRouter, Depends, Request, Response
from psycopg.errors import UniqueViolation
from starlette.concurrency import run_in_threadpool

from . import auth, billing
from .db import connect
from .protocol import body, problem
from .settings import settings

router = APIRouter()
_username_pattern = re.compile(r'[a-z0-9][a-z0-9_.@+-]{2,79}')


def visible_username(account):
    # Older native clients show and ask users to confirm the username field.
    # An unverified email is never the device's only sign-in handle.
    return (account['username'] if account['legacy_login'] else
            account['verified_email'] or account['username'])


def recovery_key():
    return 'WG-' + secrets.token_urlsafe(32)


def revoke_sessions(conn, account_id, *, except_device=None, keep_grant=None, keep_web_session=None,
                    credentials_changed=False):
    # Invalidate unconsumed password/mailbox proof as well as issued tokens.
    # Such proofs can live on an email flow, not on auth_grants.account_id.
    # The caller holds the account lock and may have advanced this generation
    # already while updating credentials.
    if not credentials_changed:
        conn.execute('UPDATE auth_accounts SET credential_version=credential_version+1 WHERE account_id=%s',
                     (account_id,))
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
    conn.execute('DELETE FROM web_sessions WHERE account_id=%s AND session_hash<>%s',
                 (account_id, keep_web_session or ''))
    if keep_web_session:
        conn.execute('''UPDATE web_sessions s SET credential_version=u.credential_version FROM auth_accounts u
          WHERE s.session_hash=%s AND s.account_id=%s AND u.account_id=s.account_id''',
                     (keep_web_session, account_id))


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
        if action == 'continue':
            grant, _ = auth.authorization_grant(conn, request, form['csrf'], lock=False)
            auth.require_login_grant(grant)
            if not grant['account_id']:
                auth.fail(400, 'invalid_request', '请先注册或恢复账号。')
            # Revocation takes the account lock before deleting pending grants.
            # Continue follows that same lock order and rechecks the grant.
            account = auth.locked_credentials(conn, grant['account_id'])
            grant, cookie_name = auth.authorization_grant(conn, request, form['csrf'])
            if not account or not account['enabled']:
                auth.fail(403, 'account_unavailable', '账号不可用。')
            return auth.complete_authorization(conn, grant, cookie_name, account['account_id'])
        grant, _ = auth.authorization_grant(conn, request, form['csrf'])
        auth.require_login_grant(grant)
        if grant['account_id']:
            auth.fail(400, 'invalid_request', '此操作已完成，请重新登录。')
        username = form['username'].strip().casefold()
        from .email_identity import normalize_email
        email_login_enabled = auth.email_signup_uses_address() or auth.has_email_logins(conn)
        email = normalize_email(form['username']) if action == 'recover' and email_login_enabled else None
        valid_username = bool(_username_pattern.fullmatch(username))
        password = form['password']

        def rejected(message, status=400):
            return auth.html_response(form['csrf'], message, status, action=action,
                                      email_login_enabled=email_login_enabled, portal=grant['portal'])

        if action == 'register':
            if not settings.registration_enabled:
                return rejected('此服务器暂未开放注册，请联系管理员。', 403)
            if auth.email_signup_uses_address():
                return auth.html_response(form['csrf'], '请使用邮箱注册 WeekGlass 账号。', 400,
                                          action='email_register', email_login_enabled=True, portal=grant['portal'])
        if not valid_username and not email:
            return rejected('请输入 WeekGlass 账号或已验证邮箱。' if action == 'recover' and email_login_enabled else
                            '账号需为 3–80 位英文字母、数字或 _.@+-。')
        minimum = 8 if action == 'recover' and email_login_enabled else 16
        if password != form['confirm_password'] or not minimum <= len(password) <= 1024:
            return rejected(f'请设置至少 {minimum} 字符的密码，并确保两次输入一致。')
        auth.rate_limit(request, 'account-browser-user', 6, email or username)
        key = recovery_key()
        if action == 'register':
            auth.rate_limit(request, 'registration-ip', 3)
            auth.rate_limit(request, 'registration-global', 30, 'weekglass')
            aid = str(uuid4())
            password_hash = auth.hash_password(password)
            try:
                with conn.transaction():
                    conn.execute('INSERT INTO accounts(account_id,dataset_id,sync_epoch) VALUES (%s,%s,%s)',
                                 (aid, str(uuid4()), str(uuid4())))
                    conn.execute('INSERT INTO auth_accounts(account_id,username,password_hash,recovery_hash) VALUES (%s,%s,%s,%s)',
                                 (aid, username, password_hash, auth.hashed(key)))
            except UniqueViolation:
                return rejected('此账号名不可用，请换一个账号名或直接登录。', 409)
        else:
            # An address can be shared by pending accounts, or look like an
            # existing username. The saved key, not the string, proves which
            # account can recover.
            key_hash = auth.hashed(form['recovery_key'].strip())
            account = conn.execute('''SELECT account_id FROM auth_accounts WHERE recovery_hash=%s
              AND (username=%s OR verified_email=%s OR pending_email=%s)''',
              (key_hash, username if valid_username else None, email, email)).fetchone()
            if account:
                account = auth.locked_credentials(conn, account['account_id'])
            if (not account or not account['enabled'] or not account['recovery_hash'] or
                    not hmac.compare_digest(account['recovery_hash'], key_hash) or
                    not (account['username'] == username or
                         (email and email in (account['verified_email'], account['pending_email'])))):
                return rejected('账号或恢复码不正确。', 401)
            if account['legacy_login'] and len(password) < 16:
                return rejected('请设置至少 16 字符的密码，并确保两次输入一致。')
            if not account['legacy_login'] and not auth.email_password_valid(password):
                return rejected(auth.EMAIL_PASSWORD_HELP)
            password_hash = (auth.hash_password if account['legacy_login'] else auth.hash_email_password)(password)
            pending_key = auth.pending_login_key(account['pending_email'], password)
            aid = account['account_id']
            # A compromised legacy password could have authorized binding an
            # attacker's mailbox. The saved key restores the original account
            # without leaving that mailbox able to sign in or reset again.
            try:
                with conn.transaction():
                    conn.execute('''UPDATE auth_accounts SET password_hash=%s,recovery_hash=%s,
                      verified_email=CASE WHEN legacy_login THEN NULL ELSE verified_email END,
                      email_verified_at=CASE WHEN legacy_login THEN NULL ELSE email_verified_at END,
                      pending_login_key=%s,credential_version=credential_version+1 WHERE account_id=%s''',
                      (password_hash, auth.hashed(key), pending_key, aid))
            except UniqueViolation:
                return rejected('此密码无法用于该账号，请输入其他密码。', 409)
            revoke_sessions(conn, aid, keep_grant=grant['grant_hash'], credentials_changed=True)
        conn.execute('UPDATE auth_grants SET account_id=%s WHERE grant_hash=%s', (aid, grant['grant_hash']))
    return auth.html_response(form['csrf'], recovery_key=key, portal=grant['portal'])


@router.get('/v1/me/account')
def account_info(identity=Depends(auth.get_identity)):
    with connect() as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        auth.revalidate_identity(conn, identity)
        account = conn.execute('''SELECT a.account_id,a.created_at,u.username,u.legacy_login,u.verified_email,u.pending_email,
          u.recovery_hash IS NOT NULL AS recovery_configured
          FROM accounts a JOIN auth_accounts u USING(account_id) WHERE account_id=%s''', (identity['account_id'],)).fetchone()
        usage = conn.execute('''SELECT coalesce(sum(payload_bytes),0) AS storage_bytes,
          count(*) FILTER (WHERE record->>'deleted_at_utc' IS NULL) AS event_count
          FROM event_heads WHERE account_id=%s''', (identity['account_id'],)).fetchone()
        count = conn.execute('SELECT count(*) AS n FROM devices WHERE account_id=%s AND revoked_at IS NULL',
                             (identity['account_id'],)).fetchone()['n']
        verification_required = billing.needs_paid_email_verification(conn, identity['account_id'])
    result = {'account_id': str(account['account_id']), 'username': visible_username(account),
              'created_at': auth.stamp(account['created_at']), 'recovery_configured': account['recovery_configured'],
              'active_devices': count, 'usage': usage}
    if account['verified_email']:
        result['verified_email'] = account['verified_email']
    if account['pending_email']:
        result['pending_email'] = account['pending_email']
    if not account['legacy_login']:
        result['backup_username'] = account['username']
    result.update(email_verified=bool(account['verified_email']), email_verification_required=verification_required,
                  email_verification_available=verification_required and auth.mail_available())
    return result


def update_password(conn, account, password):
    try:
        password_hash = (auth.hash_password if account['legacy_login'] else auth.hash_email_password)(password)
        pending_key = auth.pending_login_key(account['pending_email'], password)
        with conn.transaction():
            conn.execute('''UPDATE auth_accounts SET password_hash=%s,pending_login_key=%s,
              credential_version=credential_version+1 WHERE account_id=%s''',
                         (password_hash, pending_key, account['account_id']))
    except (ValueError, UniqueViolation):
        problem(422, 'invalid_changepasswordrequest')
    revoke_sessions(conn, account['account_id'], credentials_changed=True)


def rotate_recovery(conn, account_id):
    key = recovery_key()
    conn.execute('''UPDATE auth_accounts SET recovery_hash=%s,recovery_generation=recovery_generation+1
      WHERE account_id=%s''', (auth.hashed(key), account_id))
    return key


def delete_account_data(conn, account):
    from .console_sessions import is_owner
    if is_owner(conn, account['account_id']):
        auth.fail(409, 'owner_account_protected', '当前账号是唯一所有者，请先由运维转移所有者权限。')
    billing.detach_account(conn, account['account_id'])
    conn.execute('DELETE FROM accounts WHERE account_id=%s', (account['account_id'],))


def _account_action(request, identity, data, action):
    auth.rate_limit(request, 'account-management-ip', 12)
    auth.rate_limit(request, 'account-management-user', 6, identity['account_id'])
    with connect() as conn:
        auth.lock_account(conn, identity['account_id'])
        auth.revalidate_identity(conn, identity)
        account = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (identity['account_id'],)).fetchone()
        if not auth.password_matches(account, data['current_password']):
            auth.fail(403, 'incorrect_password', '当前密码不正确。')
        if action == 'password':
            update_password(conn, account, data['new_password'])
        elif action == 'recovery':
            return {'recovery_key': rotate_recovery(conn, identity['account_id'])}
        elif action == 'revoke_others':
            revoke_sessions(conn, identity['account_id'], except_device=identity['device_id'])
        elif action == 'delete':
            if account['legacy_login'] and len(data['confirmation']) > 80:
                problem(422, 'invalid_deleteaccountrequest')
            if data['confirmation'].strip().casefold() != visible_username(account):
                auth.fail(400, 'confirmation_required', '请输入当前账号名或已验证邮箱以确认。')
            delete_account_data(conn, account)
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
