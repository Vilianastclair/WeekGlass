"""First-party native-app OAuth authorization with PKCE and rotating tokens.

Browser registration and recovery use the same PKCE-bound grant. No payment grant endpoint.
"""
from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import math
import re
import secrets
import threading
import unicodedata
from urllib.parse import parse_qs, urlencode, urlsplit
from uuid import UUID, uuid4

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from argon2.low_level import Type, hash_secret_raw
from psycopg import Error as DatabaseError
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from starlette.concurrency import run_in_threadpool

from . import email_delivery
from .db import connect
from .settings import settings, request_origin
from .protocol import body as validated_body
from .auth_pages import page, FORM_SCRIPT_SOURCE, HANDOFF_SCRIPT_SOURCE
from .migrations import migrate_auth
from .web_theme import THEME_SCRIPT_SOURCE

router = APIRouter()
_hasher = PasswordHasher(time_cost=3, memory_cost=32768, parallelism=1)
_password_slots = threading.BoundedSemaphore(1)
_dummy_hash = _hasher.hash(secrets.token_urlsafe(32))
_cookie_name = 'wg_authorization'
_cookie_path = '/v1/auth/authorize'
_authorization_cookie_pattern = re.compile(r'^wg_authorization_[0-9a-f]{64}$')
_max_authorization_cookies = 8
_verifier_pattern = re.compile(r'^[A-Za-z0-9._~-]{43,128}$')
_challenge_pattern = re.compile(r'^[A-Za-z0-9_-]{43}$')
EMAIL_PASSWORD_HELP = '密码须为 8–128 个字符，且至少包含字母、数字、特殊字符中的两类。空白不算特殊字符。'


def fail(status: int, code: str, message: str):
    raise HTTPException(status, detail={'code': code, 'message': message},
                        headers={'Cache-Control': 'no-store'})


def now():
    return datetime.now(timezone.utc)


def stamp(value):
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z') if value else None


def hashed(value: str):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def valid_uuid(value):
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        fail(400, 'invalid_request', '无效的设备标识。')


def hash_password(password: str):
    return _hash_password(password, 16, 1024)


def hash_email_password(password: str):
    if not email_password_valid(password):
        raise ValueError(EMAIL_PASSWORD_HELP)
    return _hash_password(password, 8, 128)


def email_password_valid(password):
    if not isinstance(password, str) or not 8 <= len(password) <= 128:
        return False
    classes = (any(ch.isalpha() for ch in password), any(ch.isdecimal() for ch in password),
               any(unicodedata.category(ch)[0] in ('P', 'S') for ch in password))
    return sum(classes) >= 2


def _hash_password(password, minimum, maximum):
    if not isinstance(password, str) or not minimum <= len(password) <= maximum:
        raise ValueError(f'Password must contain {minimum} to {maximum} characters')
    with _password_slots:
        return _hasher.hash(password)


def password_matches(account, password):
    try:
        with _password_slots:
            matched = _hasher.verify(account['password_hash'] if account else _dummy_hash, password)
    except (VerificationError, InvalidHashError):
        matched = False
    return bool(matched and account and account['enabled'])


def pending_login_key(email, password):
    """Indexed, password-hard lookup for multiple claims to one unverified address."""
    if not email:
        return None
    # Persistent parameters deliberately do not depend on the rotating HMAC
    # secret or on future changes to the general password hasher.
    salt = hashlib.sha256(f'weekglass-pending-login-v1\0{settings.server_id}\0{email}'.encode('ascii')).digest()[:16]
    with _password_slots:
        return hash_secret_raw(password.encode('utf-8'), salt, time_cost=3,
                               memory_cost=32768, parallelism=1, hash_len=32, type=Type.ID, version=19).hex()


def init_schema(conn):
    conn.execute('''
    CREATE TABLE IF NOT EXISTS auth_accounts (
      account_id uuid PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
      username text UNIQUE NOT NULL,
      password_hash text NOT NULL,
      enabled boolean NOT NULL DEFAULT true
    );
    CREATE TABLE IF NOT EXISTS devices (
      account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
      device_id uuid NOT NULL,
      display_name text NOT NULL DEFAULT 'WeekGlass',
      platform text NOT NULL DEFAULT 'windows',
      app_version text NOT NULL DEFAULT '',
      last_seen_at timestamptz NOT NULL DEFAULT now(),
      revoked_at timestamptz,
      PRIMARY KEY(account_id, device_id)
    );
    CREATE TABLE IF NOT EXISTS auth_grants (
      grant_hash text PRIMARY KEY, csrf_hash text NOT NULL,
      redirect_uri text NOT NULL, challenge text NOT NULL, state text NOT NULL,
      device_id uuid NOT NULL, expires_at timestamptz NOT NULL
    );
    CREATE TABLE IF NOT EXISTS auth_families (
      family_id uuid PRIMARY KEY,
      account_id uuid NOT NULL,
      device_id uuid NOT NULL,
      revoked_at timestamptz,
      FOREIGN KEY(account_id,device_id) REFERENCES devices(account_id,device_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS auth_codes (
      code_hash text PRIMARY KEY,
      account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
      device_id uuid NOT NULL, redirect_uri text NOT NULL, challenge text NOT NULL,
      expires_at timestamptz NOT NULL, used_at timestamptz, family_id uuid
    );
    CREATE TABLE IF NOT EXISTS auth_tokens (
      token_hash text PRIMARY KEY,
      family_id uuid NOT NULL REFERENCES auth_families(family_id) ON DELETE CASCADE,
      kind text NOT NULL CHECK(kind IN ('access', 'refresh')),
      expires_at timestamptz NOT NULL, used_at timestamptz
    );
    CREATE TABLE IF NOT EXISTS auth_rate_limits (
      bucket text PRIMARY KEY, reset_at timestamptz NOT NULL, attempts integer NOT NULL
    );
    CREATE INDEX IF NOT EXISTS auth_grants_expiry ON auth_grants(expires_at);
    CREATE INDEX IF NOT EXISTS auth_codes_expiry ON auth_codes(expires_at);
    CREATE INDEX IF NOT EXISTS auth_tokens_family ON auth_tokens(family_id);
    CREATE INDEX IF NOT EXISTS auth_rates_expiry ON auth_rate_limits(reset_at);
    ''')
    migrate_auth(conn)


def create_account(username: str, password: str):
    with connect() as conn:
        return str(insert_account(conn, username, password))


def insert_account(conn, username: str, password: str, *, recovery_hash=None):
    username = username.strip().casefold()
    if not re.fullmatch(r'[a-z0-9][a-z0-9_.@+-]{2,79}', username):
        raise ValueError('Username must contain 3–80 ASCII letters, numbers or _.@+-')
    password_hash = hash_password(password)
    account_id = uuid4()
    conn.execute('INSERT INTO accounts(account_id,dataset_id,sync_epoch) VALUES (%s,%s,%s)',
                 (account_id, uuid4(), uuid4()))
    conn.execute('INSERT INTO auth_accounts(account_id,username,password_hash,recovery_hash) VALUES (%s,%s,%s,%s)',
                 (account_id, username, password_hash, recovery_hash))
    return account_id


def lock_account(conn, account_id):
    # Touch the row, not just a lock: concurrent repeatable-read snapshots must
    # observe a serialization conflict when authentication is revoked.
    conn.execute('UPDATE accounts SET commit_seq=commit_seq WHERE account_id=%s', (account_id,))


def locked_credentials(conn, account_id):
    lock_account(conn, account_id)
    return conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (account_id,)).fetchone()


def reset_password(username: str, password: str):
    """Administrator-only CLI recovery; invalidate every existing login."""
    with connect() as conn:
        account = conn.execute('SELECT account_id FROM auth_accounts WHERE username=%s', (username.strip().casefold(),)).fetchone()
        if not account:
            raise ValueError('Account does not exist')
        account_id = account['account_id']
        account = locked_credentials(conn, account_id)
        if not account:
            raise ValueError('Account does not exist')
        password_hash = (hash_password if account['legacy_login'] else hash_email_password)(password)
        pending_key = pending_login_key(account['pending_email'], password)
        conn.execute('''UPDATE auth_accounts SET password_hash=%s, recovery_hash=NULL,
          verified_email=CASE WHEN legacy_login THEN NULL ELSE verified_email END,
          email_verified_at=CASE WHEN legacy_login THEN NULL ELSE email_verified_at END,
          pending_login_key=%s,credential_version=credential_version+1 WHERE account_id=%s''',
          (password_hash, pending_key, account_id))
        conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s', (account_id,))
        conn.execute('UPDATE devices SET revoked_at=now() WHERE account_id=%s', (account_id,))
        conn.execute('DELETE FROM auth_codes WHERE account_id=%s', (account_id,))
        conn.execute('DELETE FROM auth_grants WHERE account_id=%s', (account_id,))
    return str(account_id)


def rate_limit(request: Request, purpose: str, limit: int, subject: str = ''):
    # The application receives the peer from the trusted edge only; no arbitrary
    # X-Forwarded-For input is consumed here. Buckets contain hashes, not usernames.
    peer = request.client.host if request.client else 'unknown'
    bucket = hashed(purpose + ':' + (subject or peer))
    with connect() as conn:
        conn.execute('DELETE FROM auth_rate_limits WHERE reset_at < now() - interval \'10 minutes\'')
        row = conn.execute('''INSERT INTO auth_rate_limits(bucket,reset_at,attempts)
          VALUES (%s,now()+interval '1 minute',1)
          ON CONFLICT(bucket) DO UPDATE SET
            attempts=CASE WHEN auth_rate_limits.reset_at < now() THEN 1 ELSE auth_rate_limits.attempts+1 END,
            reset_at=CASE WHEN auth_rate_limits.reset_at < now() THEN now()+interval '1 minute' ELSE auth_rate_limits.reset_at END
          RETURNING attempts''', (bucket,)).fetchone()
    if row['attempts'] > limit:
        raise HTTPException(429, detail={'code': 'rate_limited', 'message': '操作过于频繁，请稍后重试。'},
                            headers={'Retry-After': '60', 'Cache-Control': 'no-store'})


def checked_redirect(value: str):
    try:
        parsed = urlsplit(value)
        valid = (parsed.scheme == 'http' and parsed.hostname == '127.0.0.1'
                 and parsed.username is None and parsed.password is None
                 and parsed.port is not None and 1024 <= parsed.port <= 65535
                 and parsed.path == '/oauth/callback' and not parsed.query and not parsed.fragment
                 and value == f'http://127.0.0.1:{parsed.port}/oauth/callback')
    except ValueError:
        valid = False
    if not valid:
        fail(400, 'invalid_request', '只允许应用在本机监听的授权回调地址。')
    return value


def checked_origin(request: Request):
    # Require exact same-origin browser submission on an explicitly allowed
    # endpoint. An alternate origin is not a cross-origin CSRF exception.
    if request.headers.getlist('origin') != [request_origin(request)]:
        fail(403, 'invalid_origin', '请从 WeekGlass 授权页面提交。')


def email_signup_uses_address():
    return settings.mode == 'hosted' and settings.email_signup_enabled


def mail_available():
    return settings.mode == 'hosted' and email_delivery.available()


def html_response(csrf, message='', status=200, *, action='login', recovery_key=None, expired=False,
                  handoff_url=None, error_message=None, email_login_enabled=False, email_hint=None,
                  notice=None, resend_after=None, pending_email=None, email_paid=False, email_pending_editable=False,
                  management_only=False, management_done=False, backup_username=None, portal=False,
                  portal_bound=False):
    script_sources = [THEME_SCRIPT_SOURCE]
    if handoff_url:
        script_sources.append(HANDOFF_SCRIPT_SOURCE)
    elif not (expired or error_message or management_done):
        script_sources.append(FORM_SCRIPT_SOURCE)
    mail_enabled = mail_available()
    email_signup_enabled = email_signup_uses_address()
    manage = settings.mode == 'hosted' and (email_signup_enabled or mail_enabled or email_login_enabled or management_only)
    return HTMLResponse(page(csrf, message, action=action, registration=settings.registration_enabled,
                             recovery_key=recovery_key, expired=expired, handoff_url=handoff_url,
                             error_message=error_message, email_enabled=mail_enabled,
                             email_login_enabled=email_login_enabled or email_signup_enabled, email_hint=email_hint,
                             notice=notice, resend_after=resend_after, email_signup_enabled=email_signup_enabled,
                             email_manage_enabled=manage, pending_email=pending_email, email_paid=email_paid,
                             email_pending_editable=email_pending_editable, management_only=management_only,
                             management_done=management_done, backup_username=backup_username,
                             portal=portal, portal_bound=portal_bound),
                        status_code=status, headers={
        'Cache-Control': 'no-store', 'Pragma': 'no-cache',
        'Content-Security-Policy': "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src " + ' '.join(script_sources) + "; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        # no-referrer causes browsers to send Origin:null on form POSTs.
        # same-origin preserves CSRF validation without leaking the PKCE URL to
        # the cross-origin loopback callback (which also uses no-referrer).
        'Referrer-Policy': 'no-referrer' if handoff_url else 'same-origin',
        'X-Content-Type-Options': 'nosniff',
    })


def handoff_response(redirect_uri, code, state, *, signup_console=False):
    # A POST 302 to loopback is blocked by Chromium's form-action 'self'.
    # Render a successful same-origin document first; its fixed hashed script
    # can navigate to this exact checked callback without relaxing form-action.
    fields = {'code': code, 'state': state}
    if signup_console:
        fields['signup'] = '1'
    callback = checked_redirect(redirect_uri) + '?' + urlencode(fields)
    return html_response('', handoff_url=callback)


def browser_error(status, code, headers=None, *, portal=False):
    messages = {
        'invalid_origin': '无法确认此登录页面的来源，请重新发起连接。',
        'invalid_server_origin': '此登录入口不可用，请从应用重新连接。',
        'rate_limited': '操作过于频繁，请等待一分钟后重新连接。',
        'database_unavailable': '服务暂时无法完成验证，请稍后重新连接。',
        'account_unavailable': '账号目前不可用，请联系此服务器管理员。',
        'email_not_configured': '此服务器未开启邮件验证。请使用密码登录。',
        'invalid_request': '提交内容无效，请重新打开登录页面。',
        'request_too_large': '提交内容过长，请重新打开登录页面。',
    }
    response = html_response('', status=status,
        error_message=messages.get(code, '这次登录未能完成，请稍后重试。'), portal=portal)
    response.headers['X-WeekGlass-Error'] = code if code in messages else 'request_rejected'
    if headers and 'Retry-After' in headers:
        response.headers['Retry-After'] = headers['Retry-After']
    return response


def authorization_cookie_name(csrf, origin):
    # Cookies are shared across tabs and ports. A separate, origin-bound name
    # keeps each page paired with its own independent HttpOnly grant secret.
    # The name is only a selector: both secrets are still checked in the DB.
    return _cookie_name + '_' + hashed(origin + '\n' + csrf)


def _cookie_scope(portal):
    return '/account' if portal else _cookie_path


def _set_authorization_cookie(response, origin, name, token, max_age, *, portal=False):
    response.set_cookie(name, token, max_age=max_age, httponly=True, secure=origin.startswith('https://'),
                        samesite='lax', path=_cookie_scope(portal))


def renew_authorization(conn, request, response, grant, cookie_name, until):
    conn.execute('UPDATE auth_grants SET expires_at=%s WHERE grant_hash=%s', (until, grant['grant_hash']))
    _set_authorization_cookie(response, request_origin(request), cookie_name, request.cookies[cookie_name],
                              max(1, math.ceil((until - now()).total_seconds())), portal=grant['portal'])


def has_email_logins(conn):
    return bool(conn.execute('''SELECT 1 FROM auth_accounts WHERE enabled AND
        (verified_email IS NOT NULL OR pending_email IS NOT NULL) LIMIT 1''').fetchone())


def obsolete_authorization_cookies(conn, request):
    cookies = {name: hashed(value) for name, value in request.cookies.items()
               if _authorization_cookie_pattern.fullmatch(name)}
    if not cookies:
        return []
    rows = conn.execute('''SELECT grant_hash,expires_at FROM auth_grants
      WHERE grant_hash=ANY(%s) AND expires_at > now()''', (list(cookies.values()),)).fetchall()
    expiries = {row['grant_hash']: row['expires_at'] for row in rows}
    active = [name for name, digest in cookies.items() if digest in expiries]
    active.sort(key=lambda name: expiries[cookies[name]], reverse=True)
    keep = set(active[:_max_authorization_cookies - 1])
    # Expired/consumed cookies and the oldest surplus pages are discarded.
    # Concurrent responses may temporarily exceed this bound; the next GET
    # trims them again. Cookies expire with their current form step.
    return [name for name in cookies if name not in keep]


@router.get('/v1/auth/authorize')
def authorize(request: Request):
    origin = request_origin(request)
    rate_limit(request, 'authorize', 30)
    q = request.query_params
    required = {'response_type', 'client_id', 'redirect_uri', 'code_challenge',
                'code_challenge_method', 'state', 'device_id'}
    if set(q) != required or any(len(q.getlist(k)) != 1 for k in q):
        fail(400, 'invalid_request', '授权参数不完整。')
    if q['response_type'] != 'code' or q['client_id'] != 'weekglass-native' or q['code_challenge_method'] != 'S256':
        fail(400, 'invalid_request', '不支持此授权方式。')
    redirect = checked_redirect(q['redirect_uri'])
    if not _challenge_pattern.fullmatch(q['code_challenge']) or not 32 <= len(q['state']) <= 512:
        fail(400, 'invalid_request', '授权校验参数无效。')
    device_id = valid_uuid(q['device_id'])
    return _authorization_page(request, origin, redirect, q['code_challenge'], q['state'], device_id)


@router.get('/v1/auth/email', include_in_schema=False)
def manage_email(request: Request):
    origin = request_origin(request)
    if settings.mode != 'hosted' or request.query_params:
        fail(404, 'invalid_request', '邮箱管理入口不可用。')
    rate_limit(request, 'authorize', 30)
    # No ticket, bearer credentials or OAuth callback are accepted here. The
    # checkout page only points here; the owner must prove their password.
    return _authorization_page(request, origin, '', '', '', uuid4(), management_only=True)


def _authorization_page(request, origin, redirect, challenge, state, device_id, *, management_only=False,
                        portal=False, portal_session_hash=None, action='login', notice=None):
    grant, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    with connect() as conn:
        conn.execute('DELETE FROM auth_grants WHERE expires_at < now()')
        obsolete_cookies = obsolete_authorization_cookies(conn, request)
        conn.execute('DELETE FROM auth_codes WHERE expires_at < now() - interval \'1 day\'')
        conn.execute('DELETE FROM auth_tokens WHERE expires_at < now()')
        conn.execute('DELETE FROM auth_families f WHERE NOT EXISTS (SELECT 1 FROM auth_tokens t WHERE t.family_id=f.family_id)')
        conn.execute('''INSERT INTO auth_grants(grant_hash,csrf_hash,redirect_uri,challenge,state,device_id,expires_at,
          management_only,portal,portal_session_hash) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)''',
                     (hashed(grant), hashed(csrf), redirect, challenge, state, device_id, now()+timedelta(minutes=10),
                      management_only, portal, portal_session_hash))
        email_login_enabled = email_signup_uses_address() or has_email_logins(conn)
    response = html_response(csrf, email_login_enabled=email_login_enabled, management_only=management_only,
                             action='email_manage_begin' if management_only else action,
                             portal=portal, portal_bound=bool(portal_session_hash), notice=notice)
    for name in obsolete_cookies:
        response.delete_cookie(name, path=_cookie_scope(portal))
    _set_authorization_cookie(response, origin, authorization_cookie_name(csrf, origin), grant, 600, portal=portal)
    return response


async def form_body(request: Request):
    if request.headers.get('content-type', '').split(';')[0] != 'application/x-www-form-urlencoded':
        fail(400, 'invalid_request', '请求必须使用表单编码。')
    raw = await request.body()
    if len(raw) > 16384:
        fail(413, 'request_too_large', '请求内容过大。')
    try:
        fields = parse_qs(raw.decode('utf-8'), keep_blank_values=True, strict_parsing=True, max_num_fields=15, errors='strict')
        if any(len(v) != 1 for v in fields.values()):
            raise ValueError()
        return {k: v[0] for k, v in fields.items()}
    except (ValueError, UnicodeError):
        fail(400, 'invalid_request', '表单编码无效。')


@router.post('/v1/auth/authorize', include_in_schema=False)
async def login(request: Request):
    return await submit_authorization(request)


async def submit_authorization(request, *, portal=False):
    request.state.account_portal = portal
    try:
        checked_origin(request)
        form = await form_body(request)
        return await run_in_threadpool(_login, request, form)
    except HTTPException as exc:
        if exc.status_code == 403 and isinstance(exc.detail, dict) and exc.detail.get('code') == 'invalid_csrf':
            # Browser-only error view; never resubmit credentials or renew a
            # grant whose cookie/CSRF pair is missing, expired or consumed.
            response = html_response('', status=403, expired=True, portal=portal)
            response.headers['X-WeekGlass-Error'] = 'invalid_csrf'
            return response
        if portal or 'text/html' in request.headers.get('accept', ''):
            code = exc.detail.get('code', 'request_rejected') if isinstance(exc.detail, dict) else 'request_rejected'
            return browser_error(exc.status_code, code, exc.headers, portal=portal)
        raise
    except DatabaseError:
        if portal or 'text/html' in request.headers.get('accept', ''):
            return browser_error(503, 'database_unavailable', {'Retry-After': '5'}, portal=portal)
        raise


def _login(request: Request, form: dict):
    form = dict(form)
    action = form.pop('action', 'login')
    if action.startswith('email_'):
        from .email_identity import browser_action
        return browser_action(request, action, form)
    if action != 'login':
        from .account import browser_action
        return browser_action(request, action, form)
    hosted = settings.mode == 'hosted'
    if (set(form) != {'csrf', 'username', 'password'} or len(form['csrf']) > 128
            or len(form['username']) > (254 if hosted else 80) or len(form['password']) > 1024):
        fail(400, 'invalid_request', '登录内容无效。')
    rate_limit(request, 'login-ip', 12)
    username = form['username'].strip().casefold()
    from .email_identity import normalize_email, password_identity
    email = normalize_email(form['username']) if hosted else None
    rate_limit(request, 'login-email' if email else 'login-user', 6, email or username or '<empty>')
    with connect() as conn:
        grant, cookie_name = authorization_grant(conn, request, form['csrf'])
        require_login_grant(grant)
        if grant['account_id']:
            fail(400, 'invalid_request', '请继续之前的操作，或重新发起连接。')
        account = password_identity(conn, username, email, form['password'])
        if not account:
            return html_response(form['csrf'], '账号、邮箱或密码不正确。' if hosted else '账号或密码不正确。', 401,
                                 email_login_enabled=has_email_logins(conn), portal=grant['portal'])
        return complete_authorization(conn, grant, cookie_name, account['account_id'])


def authorization_grant(conn, request, csrf, *, lock=True):
    origin = request_origin(request)
    cookie_name = authorization_cookie_name(csrf, origin)
    if cookie_name not in request.cookies and not getattr(request.state, 'account_portal', False):
        # A page opened just before deployment can still finish with its
        # original cookie, but only if its original CSRF matches that grant.
        cookie_name = _cookie_name
    grant_token = request.cookies.get(cookie_name, '')
    query = 'SELECT * FROM auth_grants WHERE grant_hash=%s FOR UPDATE' if lock else 'SELECT * FROM auth_grants WHERE grant_hash=%s'
    grant = conn.execute(query, (hashed(grant_token),)).fetchone()
    if (not grant or grant['expires_at'] <= now() or not hmac.compare_digest(grant['csrf_hash'], hashed(csrf))
            or grant['portal'] != getattr(request.state, 'account_portal', False)):
        fail(403, 'invalid_csrf', '授权页面已失效，请从应用重新连接。')
    if grant['portal']:
        from .console_sessions import destination
        grant['portal_target'] = destination(request.query_params.get('next'))
    primary = urlsplit(settings.public_origin)
    source = urlsplit(origin)
    grant['console_cookie_origin'] = (source.scheme, source.hostname) == (primary.scheme, primary.hostname)
    if grant['portal_session_hash']:
        from .console_sessions import identity
        session = identity(conn, request, lock=lock)
        if not session or session['session_hash'] != grant['portal_session_hash']:
            fail(403, 'invalid_csrf', '账号会话已结束，请重新登录。')
        grant['portal_account_id'] = session['account_id']
    return grant, cookie_name


def complete_authorization(conn, grant, cookie_name, account_id, *, signup=False):
    require_login_grant(grant)
    if grant['portal']:
        from .console_sessions import sign_in
        response = sign_in(conn, account_id, target='/account#plans' if signup else grant['portal_target'])
        response.delete_cookie(cookie_name, path=_cookie_scope(True))
        conn.execute('DELETE FROM auth_grants WHERE grant_hash=%s', (grant['grant_hash'],))
        return response
    code = secrets.token_urlsafe(32)
    signup_console = signup and settings.mode == 'hosted' and grant['console_cookie_origin']
    response = handoff_response(grant['redirect_uri'], code, grant['state'], signup_console=signup_console)
    if signup_console:
        from .console_sessions import sign_in
        sign_in(conn, account_id, response=response)
    conn.execute('''INSERT INTO auth_codes(code_hash,account_id,device_id,redirect_uri,challenge,expires_at)
      VALUES(%s,%s,%s,%s,%s,%s)''', (hashed(code), account_id, grant['device_id'],
        grant['redirect_uri'], grant['challenge'], now()+timedelta(seconds=60)))
    conn.execute('DELETE FROM auth_grants WHERE grant_hash=%s', (grant['grant_hash'],))
    response.delete_cookie(cookie_name, path=_cookie_path)
    return response


def require_login_grant(grant):
    if grant['management_only']:
        fail(400, 'invalid_request', '邮箱管理页面不能发起设备连接。')


def complete_management(conn, grant, cookie_name, notice):
    response = html_response('', management_only=True, management_done=True, notice=notice, portal=grant['portal'])
    conn.execute('DELETE FROM auth_grants WHERE grant_hash=%s', (grant['grant_hash'],))
    response.delete_cookie(cookie_name, path=_cookie_scope(grant['portal']))
    return response


def issue_tokens(conn, account_id, device_id, family_id):
    access, refresh = secrets.token_urlsafe(48), secrets.token_urlsafe(48)
    instant = now()
    conn.execute('UPDATE devices SET last_seen_at=now() WHERE account_id=%s AND device_id=%s', (account_id, device_id))
    conn.cursor().executemany('INSERT INTO auth_tokens(token_hash,family_id,kind,expires_at) VALUES(%s,%s,%s,%s)', [
        (hashed(access), family_id, 'access', instant+timedelta(seconds=900)),
        (hashed(refresh), family_id, 'refresh', instant+timedelta(days=30)),
    ])
    account = conn.execute('SELECT dataset_id,sync_epoch FROM accounts WHERE account_id=%s', (account_id,)).fetchone()
    return {'token_type': 'Bearer', 'access_token': access, 'expires_in': 900,
            'refresh_token': refresh, 'refresh_expires_in': 2592000,
            'server_id': str(settings.server_id), 'account_id': str(account_id),
            'dataset_id': str(account['dataset_id']), 'device_id': str(device_id), 'sync_epoch': str(account['sync_epoch'])}


@router.post('/v1/auth/token')
async def token(request: Request):
    form = await form_body(request)
    result = await run_in_threadpool(_token, request, form)
    return JSONResponse(result, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})


def _token(request, form):
    rate_limit(request, 'token', 60)
    if form.get('client_id') != 'weekglass-native':
        fail(400, 'invalid_grant', '授权无效，请重新登录。')
    device_id = valid_uuid(form.get('device_id'))
    if form.get('grant_type') == 'authorization_code':
        if set(form) != {'grant_type', 'client_id', 'code', 'redirect_uri', 'code_verifier', 'device_id'} or not _verifier_pattern.fullmatch(form['code_verifier']) or not 16 <= len(form['code']) <= 512:
            fail(400, 'invalid_request', '授权参数无效。')
        checked_redirect(form['redirect_uri'])
        challenge = base64.urlsafe_b64encode(hashlib.sha256(form['code_verifier'].encode()).digest()).rstrip(b'=').decode()
        result = None
        with connect() as conn:
            owner = conn.execute('SELECT account_id FROM auth_codes WHERE code_hash=%s', (hashed(form['code']),)).fetchone()
            if owner:
                lock_account(conn, owner['account_id'])
            row = conn.execute('SELECT * FROM auth_codes WHERE code_hash=%s FOR UPDATE', (hashed(form['code']),)).fetchone()
            if row and row['used_at'] is not None:
                conn.execute('UPDATE auth_families SET revoked_at=now() WHERE family_id=%s', (row['family_id'],))
            elif row and row['expires_at'] > now() and str(row['device_id']) == device_id and row['redirect_uri'] == form['redirect_uri'] and hmac.compare_digest(row['challenge'], challenge):
                enabled = conn.execute('SELECT enabled FROM auth_accounts WHERE account_id=%s', (row['account_id'],)).fetchone()
                if enabled and enabled['enabled']:
                    current = conn.execute('SELECT device_id FROM devices WHERE account_id=%s AND device_id=%s AND revoked_at IS NULL', (row['account_id'],device_id)).fetchone()
                    count = conn.execute('SELECT count(*) AS total FROM devices WHERE account_id=%s AND revoked_at IS NULL', (row['account_id'],)).fetchone()['total']
                    if current is None and count >= settings.max_devices:
                        fail(403, 'device_limit', '设备数量已达上限，请先撤销旧设备。')
                    conn.execute('''INSERT INTO devices(account_id,device_id) VALUES(%s,%s)
                      ON CONFLICT(account_id,device_id) DO UPDATE SET revoked_at=NULL,last_seen_at=now()''', (row['account_id'], device_id))
                    conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s AND device_id=%s', (row['account_id'], device_id))
                    family_id = str(uuid4())
                    conn.execute('INSERT INTO auth_families(family_id,account_id,device_id) VALUES(%s,%s,%s)', (family_id, row['account_id'], device_id))
                    conn.execute('UPDATE auth_codes SET used_at=now(),family_id=%s WHERE code_hash=%s', (family_id, hashed(form['code'])))
                    result = issue_tokens(conn, row['account_id'], device_id, family_id)
        if result is None:
            fail(400, 'invalid_grant', '授权无效或已使用，请重新登录。')
        return result
    if form.get('grant_type') == 'refresh_token':
        if set(form) != {'grant_type', 'client_id', 'refresh_token', 'device_id'} or not 32 <= len(form['refresh_token']) <= 1024:
            fail(400, 'invalid_request', '刷新参数无效。')
        result = None
        with connect() as conn:
            owner = conn.execute('SELECT f.account_id FROM auth_tokens t JOIN auth_families f USING(family_id) WHERE t.token_hash=%s', (hashed(form['refresh_token']),)).fetchone()
            if owner:
                lock_account(conn, owner['account_id'])
            row = conn.execute('''SELECT t.*,f.account_id,f.device_id,f.revoked_at AS family_revoked,
                d.revoked_at AS device_revoked,a.enabled
              FROM auth_tokens t JOIN auth_families f USING(family_id)
              JOIN devices d ON d.account_id=f.account_id AND d.device_id=f.device_id
              JOIN auth_accounts a ON a.account_id=f.account_id
              WHERE t.token_hash=%s AND t.kind='refresh' FOR UPDATE OF t,f,d''', (hashed(form['refresh_token']),)).fetchone()
            if row and row['used_at'] is not None:
                conn.execute('UPDATE auth_families SET revoked_at=now() WHERE family_id=%s', (row['family_id'],))
            elif row and row['expires_at'] > now() and str(row['device_id']) == device_id and not row['family_revoked'] and not row['device_revoked'] and row['enabled']:
                conn.execute('UPDATE auth_tokens SET used_at=now() WHERE token_hash=%s', (hashed(form['refresh_token']),))
                result = issue_tokens(conn, row['account_id'], device_id, row['family_id'])
        if result is None:
            fail(400, 'invalid_grant', '登录已失效，请重新连接。')
        return result
    fail(400, 'invalid_grant', '不支持此授权方式。')


def get_identity(request: Request):
    header = request.headers.get('authorization', '')
    if not header.startswith('Bearer ') or not 32 <= len(header[7:]) <= 1024:
        fail(401, 'unauthenticated', '请先连接账号。')
    with connect() as conn:
        row = conn.execute('''SELECT f.account_id,f.device_id FROM auth_tokens t
          JOIN auth_families f USING(family_id)
          JOIN devices d ON d.account_id=f.account_id AND d.device_id=f.device_id
          JOIN auth_accounts a ON a.account_id=f.account_id
          WHERE t.token_hash=%s AND t.kind='access' AND t.expires_at>now()
            AND f.revoked_at IS NULL AND d.revoked_at IS NULL AND a.enabled''', (hashed(header[7:]),)).fetchone()
    if not row:
        fail(401, 'unauthenticated', '登录已失效，请重新连接。')
    return {'account_id': str(row['account_id']), 'device_id': str(row['device_id']), 'token_hash': hashed(header[7:])}


def revalidate_identity(conn, identity):
    """Call after taking the account lock, closing revoke-versus-write races."""
    token_hash = identity.get('token_hash')
    if not token_hash:
        fail(401, 'unauthenticated', '登录已失效，请重新连接。')
    row = conn.execute('''SELECT 1 FROM auth_tokens t JOIN auth_families f USING(family_id)
        JOIN devices d ON d.account_id=f.account_id AND d.device_id=f.device_id
        JOIN auth_accounts a ON a.account_id=f.account_id
        WHERE t.token_hash=%s AND t.kind='access' AND t.expires_at>now()
          AND f.account_id=%s AND f.device_id=%s AND f.revoked_at IS NULL
          AND d.revoked_at IS NULL AND a.enabled''',
        (token_hash,identity['account_id'],identity['device_id'])).fetchone()
    if not row:
        fail(401, 'unauthenticated', '登录已失效，请重新连接。')


require_identity = get_identity


@router.post('/v1/auth/revoke', status_code=204)
async def revoke(request: Request):
    body = await validated_body(request, 'RevokeRequest')
    if not isinstance(body, dict) or set(body) != {'refresh_token', 'device_id'} or not isinstance(body['refresh_token'], str) or not 32 <= len(body['refresh_token']) <= 1024:
        fail(400, 'invalid_request', '无效的撤销参数。')
    device_id = valid_uuid(body['device_id'])
    return await run_in_threadpool(_revoke_token, device_id, body['refresh_token'])


def _revoke_token(device_id, refresh_token):
    with connect() as conn:
        owner = conn.execute('''SELECT f.family_id,f.account_id FROM auth_tokens t
          JOIN auth_families f USING(family_id) WHERE t.token_hash=%s AND t.kind='refresh' AND f.device_id=%s''',
                           (hashed(refresh_token), device_id)).fetchone()
        row = None
        if owner:
            lock_account(conn, owner['account_id'])
            row = conn.execute('''SELECT f.family_id,f.account_id FROM auth_tokens t
                JOIN auth_families f USING(family_id)
                WHERE t.token_hash=%s AND t.kind='refresh' AND f.device_id=%s
                AND t.used_at IS NULL AND t.expires_at>now() AND f.revoked_at IS NULL''',
                (hashed(refresh_token),device_id)).fetchone()
        if row:
            conn.execute('UPDATE devices SET revoked_at=now() WHERE account_id=%s AND device_id=%s', (row['account_id'], device_id))
            conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s AND device_id=%s', (row['account_id'], device_id))
    return Response(status_code=204, headers={'Cache-Control': 'no-store'})


def device_json(row):
    return {'device_id': str(row['device_id']), 'display_name': row['display_name'],
            'platform': row['platform'], 'app_version': row['app_version'],
            'last_seen_at': stamp(row['last_seen_at']), 'revoked_at': stamp(row['revoked_at'])}


@router.get('/v1/devices')
def list_devices(identity=Depends(get_identity)):
    with connect() as conn:
        revalidate_identity(conn, identity)
        rows = conn.execute('SELECT * FROM devices WHERE account_id=%s ORDER BY last_seen_at DESC', (identity['account_id'],)).fetchall()
    return {'devices': [device_json(row) for row in rows]}


@router.patch('/v1/devices/{device_id}')
async def update_device(device_id: str, request: Request, identity=Depends(get_identity)):
    device_id = valid_uuid(device_id)
    body = await validated_body(request, 'DeviceInput')
    if not isinstance(body, dict) or set(body) != {'device_id','display_name','platform','app_version'}:
        fail(400, 'invalid_request', '设备信息不完整。')
    if body['device_id'] != device_id or not isinstance(body['display_name'], str) or not 1 <= len(body['display_name']) <= 80 or body['platform'] not in ('windows','android') or not isinstance(body['app_version'], str) or len(body['app_version']) > 40:
        fail(400, 'invalid_request', '设备信息无效。')
    return await run_in_threadpool(_update_device, device_id, body, identity)


def _update_device(device_id, body, identity):
    with connect() as conn:
        lock_account(conn, identity['account_id'])
        revalidate_identity(conn, identity)
        row = conn.execute('''UPDATE devices SET display_name=%s,platform=%s,app_version=%s,last_seen_at=now()
          WHERE account_id=%s AND device_id=%s RETURNING *''', (body['display_name'],body['platform'],body['app_version'],identity['account_id'],device_id)).fetchone()
    if not row:
        fail(404, 'not_found', '设备不存在。')
    return device_json(row)


@router.delete('/v1/devices/{device_id}', status_code=204)
def revoke_device(device_id: str, identity=Depends(get_identity)):
    device_id = valid_uuid(device_id)
    with connect() as conn:
        lock_account(conn, identity['account_id'])
        revalidate_identity(conn, identity)
        disconnect_device(conn, identity['account_id'], device_id)
    return Response(status_code=204)


def disconnect_device(conn, account_id, device_id):
    """Disconnect one device while the caller holds its account lock."""
    row = conn.execute('''UPDATE devices SET revoked_at=COALESCE(revoked_at,now())
      WHERE account_id=%s AND device_id=%s RETURNING device_id''', (account_id, device_id)).fetchone()
    if not row:
        fail(404, 'not_found', '设备不存在。')
    conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s AND device_id=%s',
                 (account_id, device_id))
    conn.execute('DELETE FROM auth_codes WHERE account_id=%s AND device_id=%s', (account_id, device_id))
