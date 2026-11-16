"""Hosted browser sessions. Native API tokens never enter this cookie."""
from datetime import timedelta
import hashlib
import hmac
import re
import secrets

from fastapi.responses import RedirectResponse

from . import auth
from .settings import request_origin, settings

_SESSION_LIFETIME = timedelta(hours=12)
_token_pattern = re.compile(r'[A-Za-z0-9_-]{43}')
DESTINATIONS = {'plans': '/account#plans', 'calendar': '/account#calendar',
                'orders': '/account/orders', 'security': '/account/security', 'admin': '/account/admin'}


def destination(section):
    return DESTINATIONS.get(section, '/account')


def check_origin(request):
    if settings.mode != 'hosted' or request_origin(request) != settings.public_origin:
        auth.fail(404, 'account_console_unavailable', '此入口未提供官方云账号控制台。')


def _cookie():
    return '__Host-wg-account' if settings.public_origin.startswith('https://') else 'wg-account'


def _csrf(token):
    return hmac.new(settings.signing_key, ('weekglass-console-csrf-v1:' + token).encode('ascii'),
                    hashlib.sha256).hexdigest()


def identity(conn, request, *, lock=False):
    if settings.mode != 'hosted' or request_origin(request) != settings.public_origin:
        return None
    token = request.cookies.get(_cookie(), '')
    if not _token_pattern.fullmatch(token):
        return None
    session_hash = auth.hashed(token)

    def find():
        return conn.execute('''SELECT s.session_hash,s.account_id,u.credential_version
          FROM web_sessions s JOIN auth_accounts u USING(account_id)
          WHERE s.session_hash=%s AND s.expires_at>now() AND u.enabled
            AND u.credential_version=s.credential_version''', (session_hash,)).fetchone()

    row = find()
    if row and lock:
        auth.lock_account(conn, row['account_id'])
        row = find()
    return {**row, 'csrf': _csrf(token)} if row else None


def require_csrf(identity, value):
    if not identity or not isinstance(value, str) or not hmac.compare_digest(identity['csrf'], value):
        auth.fail(403, 'invalid_csrf', '页面已失效，请刷新后重试。')


def sign_in(conn, account_id, *, target='/account', response=None):
    token = secrets.token_urlsafe(32)
    conn.execute('DELETE FROM web_sessions WHERE expires_at<=now()')
    result = conn.execute('''INSERT INTO web_sessions(session_hash,account_id,credential_version,expires_at)
      SELECT %s,account_id,credential_version,%s FROM auth_accounts WHERE account_id=%s AND enabled
      RETURNING account_id''', (auth.hashed(token), auth.now()+_SESSION_LIFETIME, account_id)).fetchone()
    if not result:
        auth.fail(403, 'account_unavailable', '账号不可用。')
    response = response or RedirectResponse(target, status_code=303)
    response.set_cookie(_cookie(), token, max_age=int(_SESSION_LIFETIME.total_seconds()),
                        httponly=True, secure=settings.public_origin.startswith('https://'), samesite='lax', path='/')
    return response


def clear_cookie(response):
    response.delete_cookie(_cookie(), path='/', httponly=True, samesite='lax',
                           secure=settings.public_origin.startswith('https://'))
    return response


def refresh_credential(conn, grant, account_id):
    if grant['portal_session_hash']:
        conn.execute('''UPDATE web_sessions s SET credential_version=u.credential_version FROM auth_accounts u
          WHERE s.session_hash=%s AND s.account_id=%s AND u.account_id=s.account_id''',
                     (grant['portal_session_hash'], account_id))


def is_owner(conn, account_id, *, lock=False):
    return bool(conn.execute('SELECT 1 FROM web_owner WHERE account_id=%s' + (' FOR SHARE' if lock else ''),
                             (account_id,)).fetchone())
