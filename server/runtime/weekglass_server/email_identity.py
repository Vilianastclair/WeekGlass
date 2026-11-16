"""Email enrollment without mail, and post-payment mailbox proof."""
from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from datetime import datetime, timedelta
import hashlib
import hmac
import logging
import math
import re
import secrets
from threading import BoundedSemaphore
from uuid import UUID, uuid4

import anyio
from psycopg.errors import UniqueViolation
from starlette.background import BackgroundTask

from . import auth, billing, email_delivery
from .account import revoke_sessions
from .db import connect
from .settings import settings

_window = timedelta(minutes=10)
_resend_delay = timedelta(seconds=60)
_manage_window = timedelta(minutes=30)
_hour = timedelta(hours=1)
_day = timedelta(days=1)
_max_attempts = 5
_atom = r"[a-z0-9!#$%&'*+/=?^_`{|}~-]+"
_local_part = re.compile(rf'{_atom}(?:\.{_atom})*')
_domain_label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
_domain = re.compile(rf'{_domain_label}(?:\.{_domain_label})+')
_username = re.compile(r'[a-z0-9][a-z0-9_.@+-]{2,79}')
_code_pattern = re.compile(r'[0-9]{6}')
_logger = logging.getLogger(__name__)
_smtp_slots = BoundedSemaphore(2)
_smtp_threads = anyio.CapacityLimiter(2)
_minute_budgets = {'bind': 12, 'verified': 48}
_daily_budgets = {'bind': 50, 'verified': 100}

_public_steps = {
    'email_otp_send': 'email_otp_verify',
    'email_reset_send': 'email_reset_verify',
}
_manage_steps = {
    'email_bind_send': 'email_bind_verify',
    'email_change_old_send': 'email_change_old_verify',
    'email_change_new_send': 'email_change_new_verify',
}
_purposes = {
    'email_otp_verify': 'login',
    'email_reset_verify': 'reset',
    'email_bind_verify': 'bind',
    'email_change_old_verify': 'change_old',
    'email_change_new_verify': 'change_new',
}
_fields = {
    'email_login': {'email', 'password'},
    'email_pending_login': {'email', 'password'},
    'email_register': {'email', 'password', 'confirm_password'},
    'email_otp_send': {'email'},
    'email_reset_send': {'email'},
    'email_reset_finish': {'password', 'confirm_password'},
    'email_manage_begin': {'identity_kind', 'identifier', 'password'},
    'email_manage_connect': set(),
    'email_pending_save': {'email', 'password'},
    'email_bind_send': {'email'},
    'email_change_old_send': set(),
    'email_change_new_send': {'email'},
    'email_resend': set(),
    'email_cancel': set(),
    **{action: {'code'} for action in _purposes},
}
_send_actions = {*_public_steps, *_manage_steps, 'email_resend'}
_management_actions = {'email_manage_begin', 'email_manage_connect', 'email_pending_save', 'email_cancel', 'email_resend',
                       *_manage_steps, *_manage_steps.values()}
_mail_actions = _send_actions | set(_purposes) | {'email_reset_finish'}
_management_entry_steps = {'email_manage_unverified', 'email_manage_unavailable', 'email_change_old_send'}
_generic_send_notice = '如果此邮箱可用于该操作，你会收到验证码。'


def normalize_email(value):
    # WeekGlass uses an ASCII SMTP envelope. Punycode domains are accepted;
    # display names, quoted local parts, and SMTPUTF8 addresses are not.
    email = value.strip()
    if not email.isascii() or len(email) > 254 or email.count('@') != 1:
        return None
    email = email.lower()
    local, domain = email.split('@')
    if len(local) <= 64 and _local_part.fullmatch(local) and _domain.fullmatch(domain):
        return email
    return None


def _mask(email):
    local, domain = email.split('@')
    return (local[0] if len(local) > 1 else '') + '•••@' + domain


@dataclass(frozen=True, slots=True)
class _Flow:
    grant_hash: str
    action: str
    expires_at: datetime
    email: str | None = None
    account_id: UUID | None = None
    credential_version: int | None = None
    code_nonce: str | None = None
    code_hash: str | None = None
    attempts: int = 0
    old_email: str | None = None
    old_code_nonce: str | None = None
    old_code_hash: str | None = None
    manage_expires_at: datetime | None = None


def _flow(conn, grant):
    # The caller holds the authorization grant row lock. Every write and
    # transition below is serialized against other requests from this page.
    row = conn.execute('SELECT * FROM auth_email_flows WHERE grant_hash=%s', (grant['grant_hash'],)).fetchone()
    return _Flow(**row) if row else None


def _save(conn, flow):
    conn.execute('''INSERT INTO auth_email_flows(grant_hash,action,expires_at,email,account_id,
          credential_version,code_nonce,code_hash,attempts,old_email,
          old_code_nonce,old_code_hash,manage_expires_at)
        VALUES (%(grant_hash)s,%(action)s,%(expires_at)s,%(email)s,%(account_id)s,
          %(credential_version)s,%(code_nonce)s,%(code_hash)s,%(attempts)s,%(old_email)s,
          %(old_code_nonce)s,%(old_code_hash)s,%(manage_expires_at)s)
        ON CONFLICT (grant_hash) DO UPDATE SET action=excluded.action,expires_at=excluded.expires_at,
          email=excluded.email,account_id=excluded.account_id,credential_version=excluded.credential_version,
          code_nonce=excluded.code_nonce,code_hash=excluded.code_hash,
          attempts=excluded.attempts,old_email=excluded.old_email,old_code_nonce=excluded.old_code_nonce,
          old_code_hash=excluded.old_code_hash,manage_expires_at=excluded.manage_expires_at''', asdict(flow))


def _digest(domain, *fields):
    # OTPs have just one million values. A keyed, scoped digest prevents
    # offline guessing from a read of PostgreSQL, even if all rows are known.
    data = '\0'.join((domain, *fields)).encode('ascii')
    return hmac.new(settings.signing_key, data, hashlib.sha256).hexdigest()


def _code_digest(flow, code, *, previous=False):
    if previous:
        action, email, nonce = 'email_change_old_verify', flow.old_email, flow.old_code_nonce
    else:
        action, email, nonce = flow.action, flow.email, flow.code_nonce
    return _digest('weekglass-email-code-v1', flow.grant_hash, _purposes[action], email, nonce,
                   str(flow.account_id), str(flow.credential_version), code)


def _matches_code(flow, code):
    return bool(_code_pattern.fullmatch(code) and flow.code_hash and
                hmac.compare_digest(flow.code_hash, _code_digest(flow, code)))


def _resend_bucket(email, *, actual=True):
    domain = 'weekglass-email-resend-v1' if actual else 'weekglass-email-decoy-resend-v1'
    return _digest(domain, email)


def _mailbox_send_bucket(email):
    return _digest('weekglass-email-send-hour-v1', email)


def _account_send_bucket(account_id):
    return _digest('weekglass-paid-account-send-day-v1', str(account_id))


def _delay(conn, email, *, actual):
    row = conn.execute('SELECT reset_at FROM auth_rate_limits WHERE bucket=%s',
                       (_resend_bucket(email, actual=actual),)).fetchone()
    return max(0, math.ceil((row['reset_at'] - auth.now()).total_seconds())) if row else 0


def _take_limit(conn, instant, bucket, limit, window):
    return conn.execute('''INSERT INTO auth_rate_limits(bucket,reset_at,attempts) VALUES (%s,%s,1)
        ON CONFLICT (bucket) DO UPDATE SET
          attempts=CASE WHEN auth_rate_limits.reset_at<=%s THEN 1 ELSE auth_rate_limits.attempts+1 END,
          reset_at=CASE WHEN auth_rate_limits.reset_at<=%s THEN excluded.reset_at ELSE auth_rate_limits.reset_at END
        WHERE auth_rate_limits.reset_at<=%s OR auth_rate_limits.attempts<%s RETURNING bucket''',
        (bucket, instant + window, instant, instant, instant, limit)).fetchone() is not None


class _Limited(Exception):
    pass


def _take_limits(conn, instant, *limits):
    # Both limits are enforced as a unit. No slot is lost from the other
    # bucket when one quota has already been reached.
    try:
        with conn.transaction():
            for bucket, limit, window in limits:
                if not _take_limit(conn, instant, bucket, limit, window):
                    raise _Limited
    except _Limited:
        return False
    return True


def _reserve_mail_budget(conn, email, account_id, purpose, instant):
    # First verification mail cannot use the budget set aside for users' login,
    # recovery and dual-proof verified address changes.
    pool = 'bind' if purpose == 'bind' else 'verified'
    return _take_limits(conn, instant,
                        (_resend_bucket(email), 1, _resend_delay),
                        (_mailbox_send_bucket(email), 8, _hour),
                        (_account_send_bucket(account_id), 6, _day),
                        (auth.hashed('email-send-budget:' + pool), _minute_budgets[pool], _resend_delay),
                        (auth.hashed('email-send-day-budget:' + pool), _daily_budgets[pool], _day))


def _guess_limits(email):
    return ((_digest('weekglass-email-guess-hour-v1', email), 10, _hour),
            (_digest('weekglass-email-guess-day-v1', email), 24, _day))


def _verify_mailbox_guess(conn, flow, code):
    if not flow.code_hash:
        return False
    limits = _guess_limits(flow.email)
    if not _take_limits(conn, auth.now(), *limits) or not _matches_code(flow, code):
        return False
    # A successful proof does not debit the mailbox's failure allowance.
    # The reservation row locks are held until this verify request commits.
    conn.execute('UPDATE auth_rate_limits SET attempts=attempts-1 WHERE bucket=ANY(%s)',
                 ([bucket for bucket, _, _ in limits],))
    return True


def _expiry(flow=None):
    instant = auth.now() + _window
    return min(instant, flow.manage_expires_at) if flow and flow.manage_expires_at else instant


def _show(csrf, action='login', *, conn=None, grant=None, flow=None, account=None, paid=False, resend_actual=None,
          message='', notice=None, status=200):
    management_only = bool(grant and grant['management_only'])
    email_hint = _mask(flow.email) if flow and flow.email else None
    resend_after = (_delay(conn, flow.email, actual=bool(flow.code_hash) if resend_actual is None else resend_actual)
                    if flow and flow.action in _purposes else None)
    view = flow.action if flow else 'email_manage_begin' if management_only else action
    return auth.html_response(csrf, message, status, action=view,
                              notice=notice, email_hint=email_hint, resend_after=resend_after,
                              email_login_enabled=True, management_only=management_only,
                              pending_email=account['pending_email'] if account else None, email_paid=paid,
                              email_pending_editable=bool(account and account['pending_email']),
                              backup_username=account['username'] if account and not account['legacy_login'] else None)


def _transition(conn, request, grant, cookie, csrf, flow, *, account=None, paid=False, notice=None, resend_actual=None):
    _save(conn, flow)
    response = _show(csrf, conn=conn, grant=grant, flow=flow, account=account, paid=paid, notice=notice, resend_actual=resend_actual)
    auth.renew_authorization(conn, request, response, grant, cookie, flow.expires_at)
    return response


async def _deliver(email, purpose, code):
    # Never queue behind a stalled provider or take one of the shared worker
    # tokens used by health, auth, billing and sync. A user can resend later.
    if not _smtp_slots.acquire(blocking=False):
        _logger.warning('WeekGlass email delivery capacity exhausted')
        return
    try:
        await anyio.to_thread.run_sync(email_delivery.send_code, email, purpose, code, limiter=_smtp_threads)
    except email_delivery.DeliveryError:
        _logger.warning('WeekGlass email challenge delivery failed (%s)', purpose)
    finally:
        _smtp_slots.release()


def _issue(conn, request, grant, cookie, csrf, flow, *, eligible):
    instant = auth.now()
    purpose = _purposes[flow.action]
    send = eligible and _reserve_mail_budget(conn, flow.email, flow.account_id, purpose, instant)

    def waiting(*, actual):
        if flow.code_nonce:
            return _show(csrf, conn=conn, grant=grant, flow=flow, notice=_generic_send_notice, resend_actual=actual)
        return _transition(conn, request, grant, cookie, csrf, flow, notice=_generic_send_notice, resend_actual=actual)

    if not send:
        # Only admitted real mail can reserve the actual inbox cooldown. A
        # free user probing an address cannot interfere with a paid user.
        # When a resend cannot issue a replacement, retain any real code.
        if flow.code_hash or (eligible and _delay(conn, flow.email, actual=True)):
            return waiting(actual=True)
        if not _take_limit(conn, instant, _resend_bucket(flow.email, actual=False), 1, _resend_delay):
            return waiting(actual=False)

    value = secrets.randbelow(1_000_000)
    code = f'{value:06d}'
    while _matches_code(flow, code) or (flow.old_code_hash and
            hmac.compare_digest(flow.old_code_hash, _code_digest(flow, code, previous=True))):
        # Changing the address requires a different code even in the rare
        # event that the RNG initially picks the code accepted for the old one.
        value = (value + 1) % 1_000_000
        code = f'{value:06d}'
    flow = replace(flow, expires_at=_expiry(flow), code_nonce=secrets.token_urlsafe(16), code_hash=None, attempts=0)
    if send:
        flow = replace(flow, code_hash=_code_digest(flow, code))
    response = _transition(conn, request, grant, cookie, csrf, flow, notice=_generic_send_notice)
    if send:
        # No SMTP inside the transaction. Send after the indistinguishable
        # HTML response so the recipient's existence doesn't affect latency.
        response.background = BackgroundTask(_deliver, flow.email, purpose, code)
    return response


def _email_available(conn, email):
    return not conn.execute('SELECT 1 FROM auth_accounts WHERE verified_email=%s', (email,)).fetchone()


def _register(conn, grant, cookie, csrf, form):
    if not auth.email_signup_uses_address() or not settings.registration_enabled:
        return _show(csrf, message='此服务器未开放注册，请联系管理员。', status=403)
    email = normalize_email(form['email'])
    if not email:
        return _show(csrf, 'email_register', message='请输入有效的邮箱地址。', status=400)
    if not _valid_new_password(form):
        return _invalid_password(csrf, 'email_register')
    if not _take_limits(conn, auth.now(),
                        (_digest('weekglass-pending-signup-hour-v1', email), 6, _hour),
                        (auth.hashed('registration-global:weekglass'), 30, _resend_delay)):
        response = _show(csrf, 'email_register', message='操作过于频繁，请稍后重试。', status=429)
        response.headers['Retry-After'] = '60'
        return response

    def unavailable():
        return _show(csrf, 'email_register', message='无法使用此邮箱和密码创建账号。请登录，或改用其他邮箱或密码。', status=409)

    if not _email_available(conn, email):
        return unavailable()
    account_id = uuid4()
    pending_key = auth.pending_login_key(email, form['password'])
    password_hash = auth.hash_email_password(form['password'])
    try:
        with conn.transaction():
            conn.execute('INSERT INTO accounts(account_id,dataset_id,sync_epoch) VALUES (%s,%s,%s)',
                         (account_id, uuid4(), uuid4()))
            conn.execute('''INSERT INTO auth_accounts(account_id,username,password_hash,legacy_login,pending_email,pending_login_key)
              VALUES (%s,%s,%s,false,%s,%s)''', (account_id, 'wg-' + account_id.hex, password_hash, email, pending_key))
    except UniqueViolation:
        # Provisional addresses do not reserve the mailbox, but email and
        # password together must distinguish one provisional account.
        return unavailable()
    return auth.complete_authorization(conn, grant, cookie, account_id)


def _begin_public(conn, request, grant, cookie, csrf, action, form):
    email = normalize_email(form['email'])
    if not email:
        return _show(csrf, action, message='请输入有效的邮箱地址。', status=400)
    row = conn.execute('SELECT account_id FROM auth_accounts WHERE verified_email=%s', (email,)).fetchone()
    account = auth.locked_credentials(conn, row['account_id']) if row else None
    if (not account or not account['enabled'] or account['verified_email'] != email or
            not billing.has_confirmed_waffo_payment(conn, account['account_id'])):
        account = None
    flow = _Flow(grant['grant_hash'], _public_steps[action], _expiry(), email=email,
                 account_id=account['account_id'] if account else None,
                 credential_version=account['credential_version'] if account else None)
    return _issue(conn, request, grant, cookie, csrf, flow, eligible=account is not None)


def _password_login(conn, email, username, password, *, pending_only=False):
    if email:
        row = (None if pending_only else conn.execute(
            'SELECT account_id FROM auth_accounts WHERE verified_email=%s', (email,)).fetchone())
        if not row:
            key = auth.pending_login_key(email, password)
            pending = conn.execute('''SELECT account_id FROM auth_accounts WHERE pending_login_key=%s AND pending_email=%s''',
                                   (key, email)).fetchone()
            account = auth.locked_credentials(conn, pending['account_id']) if pending else None
            if (account and account['enabled'] and account['pending_email'] == email
                    and hmac.compare_digest(account['pending_login_key'], key) and auth.password_matches(account, password)):
                return account
            return None
    else:
        row = conn.execute('SELECT account_id FROM auth_accounts WHERE username=%s', (username,)).fetchone() if username else None
    account = auth.locked_credentials(conn, row['account_id']) if row else None
    if account and ((email and account['verified_email'] != email) or
                    (username and account['username'] != username)):
        account = None
    return account if auth.password_matches(account, password) else None


def _begin_manage(conn, request, grant, cookie, csrf, form):
    kind = form['identity_kind']
    email = normalize_email(form['identifier']) if kind in ('email', 'pending_email') else None
    username = form['identifier'].strip().casefold() if kind == 'username' else None
    account = _password_login(conn, email, username if username and _username.fullmatch(username) else None,
                              form['password'], pending_only=kind == 'pending_email')
    if not account:
        return _show(csrf, 'email_manage_begin', grant=grant, message='账号或密码不正确。', status=401)
    verified = account['verified_email']
    paid = billing.has_confirmed_waffo_payment(conn, account['account_id'])
    action = ('email_change_old_send' if paid and auth.mail_available() else 'email_manage_unavailable') if verified else 'email_manage_unverified'
    flow = _Flow(grant['grant_hash'], action, _expiry(), email=verified or account['pending_email'],
                 account_id=account['account_id'], credential_version=account['credential_version'],
                 old_email=verified, manage_expires_at=auth.now() + _manage_window)
    return _transition(conn, request, grant, cookie, csrf, flow, account=account, paid=paid)


def _bound_account(conn, flow):
    account = auth.locked_credentials(conn, flow.account_id) if flow.account_id else None
    expected_email = flow.old_email if flow.manage_expires_at else flow.email
    if (account and account['enabled'] and account['credential_version'] == flow.credential_version
            and account['verified_email'] == expected_email
            and (not flow.manage_expires_at or flow.manage_expires_at > auth.now())):
        return account
    return None


def _end_flow(conn, grant, csrf, *, message):
    conn.execute('DELETE FROM auth_email_flows WHERE grant_hash=%s', (grant['grant_hash'],))
    return _show(csrf, grant=grant, message=message, status=400)


def _continue_manage(conn, grant, cookie, csrf, flow):
    if not _bound_account(conn, flow):
        return _end_flow(conn, grant, csrf, message='账号安全信息已变更，请重新验证当前密码。')
    if grant['management_only']:
        return auth.complete_management(conn, grant, cookie, '本次未更改邮箱。')
    return auth.complete_authorization(conn, grant, cookie, flow.account_id)


def _edit_pending(conn, request, grant, cookie, csrf, flow, form):
    account = _bound_account(conn, flow)
    if not account or not account['pending_email']:
        return _end_flow(conn, grant, csrf, message='此账号没有可修改的待验证邮箱，请重新验证。')
    paid = billing.has_confirmed_waffo_payment(conn, flow.account_id)

    def rejected(message, status=400):
        return _show(csrf, conn=conn, grant=grant, flow=flow, account=account, paid=paid, message=message, status=status)

    if not auth.password_matches(account, form['password']):
        return rejected('当前密码不正确。', 401)
    email = normalize_email(form['email'])
    if not email:
        return rejected('请输入有效的邮箱地址。')
    if email != account['pending_email']:
        if not _email_available(conn, email):
            return rejected('此邮箱暂不可用，请改用其他邮箱。', 409)
        pending_key = auth.pending_login_key(email, form['password'])
        try:
            with conn.transaction():
                account = conn.execute('''UPDATE auth_accounts SET pending_email=%s,pending_login_key=%s,
                   credential_version=credential_version+1 WHERE account_id=%s RETURNING *''',
                   (email, pending_key, flow.account_id)).fetchone()
        except UniqueViolation:
            return rejected('此邮箱暂不可用，请改用其他邮箱。', 409)
    updated = replace(flow, email=email, credential_version=account['credential_version'], expires_at=_expiry(flow))
    return _transition(conn, request, grant, cookie, csrf, updated, account=account, paid=paid,
                       notice='邮箱已保存，未发送邮件。')


def _manage_send(conn, request, grant, cookie, csrf, flow, action, form):
    account = _bound_account(conn, flow)
    if not account:
        return _end_flow(conn, grant, csrf, message='账号安全信息已变更，请重新验证当前密码。')
    if not billing.has_confirmed_waffo_payment(conn, flow.account_id):
        return _show(csrf, conn=conn, grant=grant, flow=flow, account=account,
                     message='付款确认后可以验证邮箱。', status=403)
    if action == 'email_change_old_send':
        email = flow.old_email
    elif action == 'email_bind_send' and not form['email'].strip():
        email = account['pending_email']
    else:
        email = normalize_email(form['email'])
    if not email or (action == 'email_change_new_send' and email == flow.old_email):
        return _show(csrf, conn=conn, grant=grant, flow=flow, account=account, paid=True,
                     message='请输入不同于当前邮箱的有效邮箱地址。' if flow.old_email else '请输入有效的邮箱地址。', status=400)
    target = replace(flow, action=_manage_steps[action], email=email, expires_at=_expiry(flow))
    eligible = action == 'email_change_old_send' or _email_available(conn, email)
    return _issue(conn, request, grant, cookie, csrf, target, eligible=eligible)


def _resend(conn, request, grant, cookie, csrf, flow):
    account = _bound_account(conn, flow)
    paid = account is not None and billing.has_confirmed_waffo_payment(conn, flow.account_id)
    if flow.manage_expires_at and not paid:
        return _end_flow(conn, grant, csrf, message='验证流程已失效，请重新验证身份及付款状态。')
    needs_free_email = flow.action in ('email_bind_verify', 'email_change_new_verify')
    eligible = paid and (not needs_free_email or _email_available(conn, flow.email))
    return _issue(conn, request, grant, cookie, csrf, flow, eligible=eligible)


def _changed_login(conn, request, grant, cookie, csrf, account_id, notice):
    revoke_sessions(conn, account_id, keep_grant=grant['grant_hash'])
    if grant['management_only']:
        return auth.complete_management(conn, grant, cookie, notice)
    conn.execute('DELETE FROM auth_email_flows WHERE grant_hash=%s', (grant['grant_hash'],))
    response = _show(csrf, notice=notice)
    auth.renew_authorization(conn, request, response, grant, cookie, _expiry())
    return response


def _verify(conn, request, grant, cookie, csrf, flow, code):
    def rejected(message, *, updated=flow):
        return _show(csrf, conn=conn, grant=grant, flow=updated, message=message, status=400)

    if flow.expires_at <= auth.now():
        return rejected('验证码已过期，请重新发送。')
    if flow.attempts >= _max_attempts:
        return rejected('已达到验证次数上限，请重新发送验证码。')
    if not _verify_mailbox_guess(conn, flow, code.strip()):
        # Return the response normally so the transaction commits the failure.
        updated = replace(flow, attempts=flow.attempts + 1)
        _save(conn, updated)
        return rejected('已达到验证次数上限，请重新发送验证码。' if updated.attempts == _max_attempts else
                        '验证码未通过。请检查验证码，或稍后重试。', updated=updated)
    account = _bound_account(conn, flow)
    if not account or not billing.has_confirmed_waffo_payment(conn, flow.account_id):
        return _end_flow(conn, grant, csrf, message='验证流程已失效，请重新操作。')
    if flow.expires_at <= auth.now():
        return rejected('验证码已过期，请重新发送。')
    if flow.action == 'email_otp_verify':
        return auth.complete_authorization(conn, grant, cookie, flow.account_id)
    if flow.action == 'email_reset_verify':
        # Single-use replacement grant lives server-side behind the same
        # cookie/CSRF/PKCE grant and rechecks this exact credential generation.
        updated = replace(flow, action='email_reset_finish', expires_at=_expiry(), code_nonce=None, code_hash=None, attempts=0)
        return _transition(conn, request, grant, cookie, csrf, updated)
    if flow.action == 'email_change_old_verify':
        updated = replace(flow, action='email_change_new_send', expires_at=_expiry(flow),
                          old_code_nonce=flow.code_nonce, old_code_hash=flow.code_hash,
                          code_nonce=None, code_hash=None, attempts=0)
        return _transition(conn, request, grant, cookie, csrf, updated)

    try:
        with conn.transaction():
            conn.execute('''UPDATE auth_accounts SET verified_email=%s,email_verified_at=now(),
              pending_email=NULL,pending_login_key=NULL,
              credential_version=credential_version+1 WHERE account_id=%s''', (flow.email, flow.account_id))
    except UniqueViolation:
        return _end_flow(conn, grant, csrf, message='此邮箱已用于其他 WeekGlass 账号，请换一个邮箱。')
    if flow.action == 'email_bind_verify':
        if grant['management_only']:
            return auth.complete_management(conn, grant, cookie, '邮箱已验证，可以使用邮箱登录或找回密码。')
        return auth.complete_authorization(conn, grant, cookie, flow.account_id)
    return _changed_login(conn, request, grant, cookie, csrf, flow.account_id, '邮箱已更换，所有设备已退出。请用新邮箱重新登录。')


def _valid_new_password(form):
    return form['password'] == form['confirm_password'] and auth.email_password_valid(form['password'])


def _invalid_password(csrf, action):
    return _show(csrf, action, message=auth.EMAIL_PASSWORD_HELP + '两次输入须一致。', status=400)


def _finish_reset(conn, request, grant, cookie, csrf, flow, form):
    if (not _bound_account(conn, flow) or flow.expires_at <= auth.now() or
            not billing.has_confirmed_waffo_payment(conn, flow.account_id)):
        return _end_flow(conn, grant, csrf, message='重置权限已失效，请重新验证邮箱。')
    if not _valid_new_password(form):
        return _invalid_password(csrf, flow.action)
    # Someone who knew the old password may have created a recovery key.
    conn.execute('''UPDATE auth_accounts SET password_hash=%s,recovery_hash=NULL,credential_version=credential_version+1
      WHERE account_id=%s''', (auth.hash_email_password(form['password']), flow.account_id))
    return _changed_login(conn, request, grant, cookie, csrf, flow.account_id, '密码已重设，所有设备已退出。请用新密码重新登录。')


def browser_action(request, action, form):
    if (action not in _fields or set(form) != _fields[action] | {'csrf'} or len(form['csrf']) > 128
            or any(len(value) > 1024 for value in form.values())
            or (action == 'email_manage_begin' and form['identity_kind'] not in ('email', 'pending_email', 'username'))):
        auth.fail(400, 'invalid_request', '请求内容无效。')
    if action in _mail_actions and not auth.mail_available():
        auth.fail(403, 'email_not_configured', '此服务器未开启邮件验证。')
    if action in _management_actions and settings.mode != 'hosted':
        auth.fail(403, 'email_not_configured', '此服务器未开启邮箱管理。')

    if action in ('email_login', 'email_pending_login', 'email_manage_begin'):
        auth.rate_limit(request, 'login-ip', 12)
        by_username = form.get('identity_kind') == 'username'
        value = form.get('email', form.get('identifier', ''))
        subject = value.strip().casefold() if by_username else normalize_email(value)
        auth.rate_limit(request, 'login-user' if by_username else 'login-email', 6, subject or '<empty>')
    elif action in _send_actions:
        auth.rate_limit(request, 'email-send-ip', 8)
    elif action == 'email_register':
        auth.rate_limit(request, 'registration-ip', 3)
    else:
        auth.rate_limit(request, 'email-browser-ip', 30)

    csrf = form['csrf']
    with connect() as conn:
        grant, cookie = auth.authorization_grant(conn, request, csrf)
        if action not in _management_actions:
            auth.require_native_grant(grant)
        if grant['account_id']:
            auth.fail(400, 'invalid_request', '请继续之前的操作，或重新发起连接。')
        if action in ('email_login', 'email_pending_login'):
            if not auth.email_signup_uses_address() and not auth.has_email_logins(conn):
                auth.fail(403, 'email_not_configured', '此服务器未开启邮件验证。')
            account = _password_login(conn, normalize_email(form['email']), None, form['password'],
                                      pending_only=action == 'email_pending_login')
            if not account:
                return _show(csrf, action, message='邮箱或密码不正确。', status=401)
            return auth.complete_authorization(conn, grant, cookie, account['account_id'])

        flow = _flow(conn, grant)
        if action == 'email_cancel':
            conn.execute('DELETE FROM auth_email_flows WHERE grant_hash=%s', (grant['grant_hash'],))
            return _show(csrf, grant=grant)
        if flow and flow.manage_expires_at and flow.manage_expires_at <= auth.now():
            return _end_flow(conn, grant, csrf, message='管理操作已过期，请重新验证当前密码。')
        if not flow:
            if action == 'email_register':
                return _register(conn, grant, cookie, csrf, form)
            if action in _public_steps:
                return _begin_public(conn, request, grant, cookie, csrf, action, form)
            if action == 'email_manage_begin':
                return _begin_manage(conn, request, grant, cookie, csrf, form)
            return _show(csrf, grant=grant, message='验证流程尚未开始或已结束，请重新操作。', status=400)
        if action == 'email_manage_connect' and flow.action in _management_entry_steps:
            return _continue_manage(conn, grant, cookie, csrf, flow)
        if flow.action == 'email_manage_unverified':
            if action == 'email_pending_save':
                return _edit_pending(conn, request, grant, cookie, csrf, flow, form)
            if action == 'email_bind_send':
                return _manage_send(conn, request, grant, cookie, csrf, flow, action, form)
        if action == 'email_resend' and flow.action in _purposes:
            return _resend(conn, request, grant, cookie, csrf, flow)
        if flow.action != action:
            account = _bound_account(conn, flow) if flow.action in _management_entry_steps else None
            paid = account and billing.has_confirmed_waffo_payment(conn, flow.account_id)
            return _show(csrf, conn=conn, grant=grant, flow=flow, account=account, paid=bool(paid),
                         message='请完成当前步骤，或返回登录后重新操作。', status=400)
        if action in _manage_steps:
            return _manage_send(conn, request, grant, cookie, csrf, flow, action, form)
        if action in _purposes:
            return _verify(conn, request, grant, cookie, csrf, flow, form['code'])
        return _finish_reset(conn, request, grant, cookie, csrf, flow, form)
