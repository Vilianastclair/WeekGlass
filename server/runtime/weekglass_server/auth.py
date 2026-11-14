"""First-party native-app OAuth authorization with PKCE and rotating tokens.

Browser registration and recovery use the same PKCE-bound grant. No payment grant endpoint.
"""
from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import re
import secrets
import threading
from urllib.parse import parse_qs, urlencode, urlsplit
from uuid import UUID, uuid4

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from psycopg import Error as DatabaseError
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from .db import connect
from .settings import settings, request_origin
from .protocol import body as validated_body
from .auth_pages import page, FORM_SCRIPT_SOURCE, HANDOFF_SCRIPT_SOURCE
from .migrations import migrate_auth

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
    if not isinstance(password, str) or not 16 <= len(password) <= 1024:
        raise ValueError('Password must contain 16 to 1024 characters')
    with _password_slots:
        return _hasher.hash(password)


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
    username = username.strip().casefold()
    if not re.fullmatch(r'[a-z0-9][a-z0-9_.@+-]{2,79}', username):
        raise ValueError('Username must contain 3–80 ASCII letters, numbers or _.@+-')
    password_hash = hash_password(password)
    account_id = str(uuid4())
    with connect() as conn:
        conn.execute('INSERT INTO accounts(account_id,dataset_id,sync_epoch) VALUES (%s,%s,%s)',
                     (account_id, str(uuid4()), str(uuid4())))
        conn.execute('INSERT INTO auth_accounts(account_id,username,password_hash) VALUES (%s,%s,%s)',
                     (account_id, username, password_hash))
    return account_id


def lock_account(conn, account_id):
    # Touch the row, not just a lock: concurrent repeatable-read snapshots must
    # observe a serialization conflict when authentication is revoked.
    conn.execute('UPDATE accounts SET commit_seq=commit_seq WHERE account_id=%s', (account_id,))


def reset_password(username: str, password: str):
    """Administrator-only CLI recovery; invalidate every existing login."""
    password_hash = hash_password(password)
    with connect() as conn:
        account = conn.execute('SELECT account_id FROM auth_accounts WHERE username=%s', (username.strip().casefold(),)).fetchone()
        if not account:
            raise ValueError('Account does not exist')
        account_id = account['account_id']
        lock_account(conn, account_id)
        conn.execute('UPDATE auth_accounts SET password_hash=%s WHERE account_id=%s', (password_hash, account_id))
        conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s', (account_id,))
        conn.execute('UPDATE devices SET revoked_at=now() WHERE account_id=%s', (account_id,))
        conn.execute('DELETE FROM auth_codes WHERE account_id=%s', (account_id,))
        conn.execute('DELETE FROM auth_grants WHERE account_id=%s', (account_id,))
        conn.execute('UPDATE auth_accounts SET recovery_hash=NULL WHERE account_id=%s', (account_id,))
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
    origin = request.headers.get('origin')
    # Require exact same-origin browser submission on an explicitly allowed
    # endpoint. An alternate origin is not a cross-origin CSRF exception.
    if origin != request_origin(request):
        fail(403, 'invalid_origin', '请从 WeekGlass 授权页面提交。')


def html_response(csrf, message='', status=200, *, action='login', recovery_key=None, expired=False,
                  handoff_url=None, error_message=None):
    script_source = HANDOFF_SCRIPT_SOURCE if handoff_url else (
        "'none'" if expired or error_message else FORM_SCRIPT_SOURCE)
    return HTMLResponse(page(csrf, message, action=action, registration=settings.registration_enabled,
                             recovery_key=recovery_key, expired=expired, handoff_url=handoff_url,
                             error_message=error_message), status_code=status, headers={
        'Cache-Control': 'no-store', 'Pragma': 'no-cache',
        'Content-Security-Policy': "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src " + script_source + "; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        # no-referrer causes browsers to send Origin:null on form POSTs.
        # same-origin preserves CSRF validation without leaking the PKCE URL to
        # the cross-origin loopback callback (which also uses no-referrer).
        'Referrer-Policy': 'no-referrer' if handoff_url else 'same-origin',
        'X-Content-Type-Options': 'nosniff',
    })


def handoff_response(redirect_uri, code, state):
    # A POST 302 to loopback is blocked by Chromium's form-action 'self'.
    # Render a successful same-origin document first; its fixed hashed script
    # can navigate to this exact checked callback without relaxing form-action.
    callback = checked_redirect(redirect_uri) + '?' + urlencode({'code': code, 'state': state})
    return html_response('', handoff_url=callback)


def browser_error(status, code, headers=None):
    messages = {
        'invalid_origin': '无法确认此登录页面的来源，请重新发起连接。',
        'invalid_server_origin': '此登录入口不可用，请从应用重新连接。',
        'rate_limited': '操作过于频繁，请等待一分钟后重新连接。',
        'database_unavailable': '服务暂时无法完成验证，请稍后重新连接。',
        'account_unavailable': '账号目前不可用，请联系此服务器管理员。',
        'invalid_request': '提交内容无效，请重新打开登录页面。',
        'request_too_large': '提交内容过长，请重新打开登录页面。',
    }
    response = html_response('', status=status,
        error_message=messages.get(code, '这次连接未能完成，请稍后重新连接。'))
    response.headers['X-WeekGlass-Error'] = code if code in messages else 'request_rejected'
    if headers and 'Retry-After' in headers:
        response.headers['Retry-After'] = headers['Retry-After']
    return response


def authorization_cookie_name(csrf, origin):
    # Cookies are shared across tabs and ports. A separate, origin-bound name
    # keeps each page paired with its own independent HttpOnly grant secret.
    # The name is only a selector: both secrets are still checked in the DB.
    return _cookie_name + '_' + hashed(origin + '\n' + csrf)


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
    # trims them again. All cookies also expire after ten minutes.
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
    grant, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    with connect() as conn:
        conn.execute('DELETE FROM auth_grants WHERE expires_at < now()')
        obsolete_cookies = obsolete_authorization_cookies(conn, request)
        conn.execute('DELETE FROM auth_codes WHERE expires_at < now() - interval \'1 day\'')
        conn.execute('DELETE FROM auth_tokens WHERE expires_at < now()')
        conn.execute('DELETE FROM auth_families f WHERE NOT EXISTS (SELECT 1 FROM auth_tokens t WHERE t.family_id=f.family_id)')
        conn.execute('''INSERT INTO auth_grants(grant_hash,csrf_hash,redirect_uri,challenge,state,device_id,expires_at)
          VALUES (%s,%s,%s,%s,%s,%s,%s)''',
                     (hashed(grant), hashed(csrf), redirect, q['code_challenge'], q['state'], device_id, now()+timedelta(minutes=10)))
    response = html_response(csrf)
    for name in obsolete_cookies:
        response.delete_cookie(name, path=_cookie_path)
    response.set_cookie(authorization_cookie_name(csrf, origin), grant, max_age=600, httponly=True,
                        secure=origin.startswith('https://'), samesite='lax', path=_cookie_path)
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
    try:
        checked_origin(request)
        form = await form_body(request)
        return await run_in_threadpool(_login, request, form)
    except HTTPException as exc:
        if exc.status_code == 403 and isinstance(exc.detail, dict) and exc.detail.get('code') == 'invalid_csrf':
            # Browser-only error view; never resubmit credentials or renew a
            # grant whose cookie/CSRF pair is missing, expired or consumed.
            response = html_response('', status=403, expired=True)
            response.headers['X-WeekGlass-Error'] = 'invalid_csrf'
            return response
        if 'text/html' in request.headers.get('accept', ''):
            code = exc.detail.get('code', 'request_rejected') if isinstance(exc.detail, dict) else 'request_rejected'
            return browser_error(exc.status_code, code, exc.headers)
        raise
    except DatabaseError:
        if 'text/html' in request.headers.get('accept', ''):
            return browser_error(503, 'database_unavailable', {'Retry-After': '5'})
        raise


def _login(request: Request, form: dict):
    form = dict(form)
    action = form.pop('action', 'login')
    if action != 'login':
        from .account import browser_action
        return browser_action(request, action, form)
    if set(form) != {'csrf', 'username', 'password'} or len(form['csrf']) > 128 or len(form['username']) > 80 or len(form['password']) > 1024:
        fail(400, 'invalid_request', '登录内容无效。')
    rate_limit(request, 'login-ip', 12)
    username = form['username'].strip().casefold()
    rate_limit(request, 'login-user', 6, username or '<empty>')
    with connect() as conn:
        grant, cookie_name = authorization_grant(conn, request, form['csrf'])
        account = conn.execute('SELECT * FROM auth_accounts WHERE username=%s', (username,)).fetchone()
        if account:
            lock_account(conn, account['account_id'])
            account = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (account['account_id'],)).fetchone()
        try:
            with _password_slots:
                matched = _hasher.verify(account['password_hash'] if account else _dummy_hash, form['password'])
        except (VerificationError, InvalidHashError):
            matched = False
        if not matched or not account or not account['enabled']:
            return html_response(form['csrf'], '账号或密码不正确。', 401)
        return complete_authorization(conn, grant, cookie_name, account['account_id'])


def authorization_grant(conn, request, csrf):
    cookie_name = authorization_cookie_name(csrf, request_origin(request))
    if cookie_name not in request.cookies:
        # A page opened just before deployment can still finish with its
        # original cookie, but only if its original CSRF matches that grant.
        cookie_name = _cookie_name
    grant_token = request.cookies.get(cookie_name, '')
    grant = conn.execute('SELECT * FROM auth_grants WHERE grant_hash=%s FOR UPDATE', (hashed(grant_token),)).fetchone()
    if not grant or grant['expires_at'] <= now() or not hmac.compare_digest(grant['csrf_hash'], hashed(csrf)):
        fail(403, 'invalid_csrf', '授权页面已失效，请从应用重新连接。')
    return grant, cookie_name


def complete_authorization(conn, grant, cookie_name, account_id):
    code = secrets.token_urlsafe(32)
    response = handoff_response(grant['redirect_uri'], code, grant['state'])
    conn.execute('''INSERT INTO auth_codes(code_hash,account_id,device_id,redirect_uri,challenge,expires_at)
      VALUES(%s,%s,%s,%s,%s,%s)''', (hashed(code), account_id, grant['device_id'],
        grant['redirect_uri'], grant['challenge'], now()+timedelta(seconds=60)))
    conn.execute('DELETE FROM auth_grants WHERE grant_hash=%s', (grant['grant_hash'],))
    response.delete_cookie(cookie_name, path=_cookie_path)
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
        row = conn.execute('UPDATE devices SET revoked_at=COALESCE(revoked_at,now()) WHERE account_id=%s AND device_id=%s RETURNING device_id', (identity['account_id'],device_id)).fetchone()
        if not row:
            fail(404, 'not_found', '设备不存在。')
        conn.execute('UPDATE auth_families SET revoked_at=now() WHERE account_id=%s AND device_id=%s', (identity['account_id'],device_id))
    return Response(status_code=204)
