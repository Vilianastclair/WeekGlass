"""First-party hosted account console; the native bearer API is separate."""
import re
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from starlette.concurrency import run_in_threadpool

from . import account, auth, billing, calendar_export, console_pages as pages, console_sessions as sessions
from .db import connect
from .entitlements import allow_sync, entitlement, export_claim, last_service_end
from .protocol import now, problem
from .settings import settings

router = APIRouter(prefix='/account', include_in_schema=False)
_pending_orders_sql = "SELECT * FROM billing_orders WHERE account_id=%s AND status=ANY(%s) ORDER BY created_at DESC"


def _go(target='/account'):
    return RedirectResponse(target, status_code=303)


def _signed_out(section=None):
    return sessions.clear_cookie(_go('/account/login' + (f'?next={section}' if section else '')))


def _profile(conn, identity):
    result = conn.execute('''SELECT a.*,u.username,u.legacy_login,u.pending_email,u.verified_email,
      u.recovery_hash IS NOT NULL AS recovery_configured FROM accounts a JOIN auth_accounts u USING(account_id)
      WHERE a.account_id=%s''', (identity['account_id'],)).fetchone()
    result['is_owner'] = sessions.is_owner(conn, identity['account_id'])
    return result


def _devices(conn, account_id):
    return conn.execute('''SELECT device_id,display_name,platform,last_seen_at FROM devices
      WHERE account_id=%s AND revoked_at IS NULL ORDER BY last_seen_at DESC''', (account_id,)).fetchall()


def _read(conn, request):
    sessions.check_origin(request)
    conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
    return sessions.identity(conn, request)


def _signin_form(request, action):
    sessions.check_origin(request)
    with connect() as conn:
        if sessions.identity(conn, request):
            return _go(sessions.destination(request.query_params.get('next')))
    if action in ('register', 'email_register') and not settings.registration_enabled:
        return pages.problem_page('暂未开放注册', '如已有 WeekGlass 账号，可以直接登录。', status=403,
                                  href='/account/login', button='返回登录')
    if action == 'email_reset_send' and not auth.mail_available():
        return _go('/account/recover')
    auth.rate_limit(request, 'authorize', 30)
    return auth._authorization_page(request, settings.public_origin, '', '', '', uuid4(),
                                    portal=True, action=action,
                                    notice=pages.LOGIN_MESSAGES.get(request.query_params.get('changed')))


@router.get('/login')
def login_page(request: Request):
    return _signin_form(request, 'login')


@router.get('/register')
def register_page(request: Request):
    return _signin_form(request, 'email_register' if auth.email_signup_uses_address() else 'register')


@router.get('/recover')
def recover_page(request: Request):
    return _signin_form(request, 'recover')


@router.get('/recover/email')
def recover_email(request: Request):
    return _signin_form(request, 'email_reset_send')


@router.post('/authorize')
async def authorize(request: Request):
    sessions.check_origin(request)
    return await auth.submit_authorization(request, portal=True)


@router.get('/email')
def email_page(request: Request):
    sessions.check_origin(request)
    with connect() as conn:
        identity = sessions.identity(conn, request)
    if not identity:
        return _signed_out()
    auth.rate_limit(request, 'authorize', 30)
    return auth._authorization_page(request, settings.public_origin, '', '', '', uuid4(), management_only=True,
                                    portal=True, portal_session_hash=identity['session_hash'])


@router.get('')
def home(request: Request):
    config = request.app.state.billing
    with connect() as conn:
        identity = _read(conn, request)
        if not identity:
            return _signed_out()
        profile = _profile(conn, identity)
        aid = profile['account_id']
        rights, claim = entitlement(conn, profile)
        pending = conn.execute(_pending_orders_sql, (aid, list(billing.UNRESOLVED))).fetchone()
        offers = billing.offers(config, account_id=aid)
        devices = conn.execute('SELECT count(*) AS n FROM devices WHERE account_id=%s AND revoked_at IS NULL',
                               (aid,)).fetchone()['n']
        paid_mail = auth.mail_available() and billing.needs_paid_email_verification(conn, aid)
    return pages.overview(profile, identity['csrf'], rights, offers, pending, claim, devices, paid_mail)


@router.get('/orders')
def orders(request: Request):
    with connect() as conn:
        identity = _read(conn, request)
        if not identity:
            return _signed_out('orders')
        profile = _profile(conn, identity)
        config = request.app.state.billing
        rows = conn.execute('''SELECT * FROM billing_orders WHERE account_id=%s
          ORDER BY created_at DESC,checkout_id DESC LIMIT 50''', (identity['account_id'],)).fetchall()
        result = [(billing.order_json(conn, row), _cashier_available(row, config)) for row in rows]
    return pages.orders(profile, identity['csrf'], result, pages.ORDER_MESSAGES.get(request.query_params.get('notice')))


def _cashier_available(order, config):
    if not config or not billing.same_scope(order, config):
        return False
    if config.scope[0] not in (billing.WAFFO_LIVE_PROVIDER, billing.WAFFO_TEST_PROVIDER):
        return False
    return order['status'] in billing.IN_FLIGHT or (order['status'] == 'pending' and
        billing.checkout_available(config, order['account_id']) and billing.checkout_quote_available(order, config))


def _form_data(form, required):
    if set(form) != {'csrf', *required} or any(len(value) > 1024 for value in form.values()):
        auth.fail(400, 'invalid_request', '提交内容不完整。请从控制台重新操作。')


def _write_identity(conn, request, csrf):
    auth.checked_origin(request)
    identity = sessions.identity(conn, request, lock=True)
    if not identity:
        auth.fail(401, 'unauthenticated', '请先登录 WeekGlass 账号。')
    sessions.require_csrf(identity, csrf)
    return identity


async def _form_action(request, fn, *args, back='/account'):
    sessions.check_origin(request)
    try:
        form = await auth.form_body(request)
        return await run_in_threadpool(fn, request, form, *args)
    except HTTPException as exc:
        if exc.status_code == 401 and exc.detail.get('code') == 'unauthenticated':
            return _signed_out()
        return pages.problem_page('未能完成操作', pages.error_message(exc.detail), href=back,
                                  status=exc.status_code, headers=exc.headers)


@router.post('/logout')
async def logout(request: Request):
    return await _form_action(request, _logout)


def _logout(request, form):
    _form_data(form, ())
    with connect() as conn:
        identity = _write_identity(conn, request, form['csrf'])
        conn.execute('DELETE FROM web_sessions WHERE session_hash=%s', (identity['session_hash'],))
    return _signed_out()


@router.post('/checkout')
async def checkout(request: Request):
    return await _form_action(request, _checkout, back='/account#plans')


def _checkout(request, form):
    _form_data(form, ('plan_id', 'terms_version', 'idempotency_key'))
    try:
        key = UUID(form['idempotency_key'])
    except ValueError:
        problem(422, 'invalid_idempotency_key')
    auth.rate_limit(request, 'console-checkout', 18)
    with connect() as conn:
        identity = _write_identity(conn, request, form['csrf'])
        aid = identity['account_id']
        config = request.app.state.billing
        if not billing.checkout_available(config, aid) or config.scope[0] not in (
                billing.WAFFO_LIVE_PROVIDER, billing.WAFFO_TEST_PROVIDER):
            problem(503, 'billing_not_configured')
        cloud_account = billing.lock_account(conn, aid)
        order = billing.create_checkout(conn, cloud_account, config, key,
           {'plan_id': form['plan_id'], 'terms_version': form['terms_version'], 'purchase_mode': 'single'})
        if _cashier_available(order, config):
            return _go(f"/v1/billing/checkout/{order['checkout_id']}")
    return _go('/account/orders')


@router.post('/orders/{checkout_id}/close')
async def close_order(checkout_id: UUID, request: Request):
    return await _form_action(request, _close_order, checkout_id, back='/account/orders')


def _close_order(request, form, checkout_id):
    _form_data(form, ())
    with connect() as conn:
        identity = _write_identity(conn, request, form['csrf'])
        row = conn.execute('SELECT * FROM billing_orders WHERE account_id=%s AND checkout_id=%s FOR UPDATE',
                           (identity['account_id'], checkout_id)).fetchone()
        if not row:
            problem(404, 'billing_order_not_found')
        billing.close_unsubmitted(conn, row, now())
    return _go('/account/orders?notice=closed')


@router.get('/security')
def security(request: Request):
    with connect() as conn:
        identity = _read(conn, request)
        if not identity:
            return _signed_out('security')
        profile = _profile(conn, identity)
        devices = _devices(conn, identity['account_id'])
        paid = billing.has_confirmed_waffo_payment(conn, identity['account_id'])
    return pages.security(profile, identity['csrf'], devices, paid, auth.mail_available(),
                          pages.SECURITY_MESSAGES.get(request.query_params.get('notice')))


@router.post('/security/{action}')
async def security_action(action: str, request: Request):
    return await _form_action(request, _security_action, action, back='/account/security')


def _security_action(request, form, action):
    required = {'password': ('new_password', 'confirm_password'), 'recovery': (), 'revoke': (),
                'delete': ('confirmation',), 'device': ('device_id',)}
    if action not in required:
        problem(404, 'not_found')
    _form_data(form, ('current_password', *required[action]))
    auth.rate_limit(request, 'account-management-ip', 12)
    with connect() as conn:
        identity = _write_identity(conn, request, form['csrf'])
        aid = identity['account_id']
        auth.rate_limit(request, 'account-management-user', 6, str(aid))
        credentials = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (aid,)).fetchone()
        if not auth.password_matches(credentials, form['current_password']):
            auth.fail(403, 'incorrect_password', '当前密码不正确。')
        if action == 'password':
            if form['new_password'] != form['confirm_password']:
                auth.fail(422, 'password_mismatch', '两次输入的新密码不一致。')
            account.update_password(conn, credentials, form['new_password'])
            return sessions.clear_cookie(_go('/account/login?changed=1'))
        if action == 'recovery':
            return pages.recovery_key(_profile(conn, identity), identity['csrf'], account.rotate_recovery(conn, aid))
        if action == 'revoke':
            account.revoke_sessions(conn, aid, keep_web_session=identity['session_hash'])
            return _go('/account/security?notice=revoked')
        if action == 'device':
            auth.disconnect_device(conn, aid, auth.valid_uuid(form['device_id']))
            return _go('/account/security?notice=device')
        if form['confirmation'].strip().casefold() != account.visible_username(credentials):
            auth.fail(400, 'confirmation_required', '请输入安全设置所示的账号确认文字。')
        account.delete_account_data(conn, credentials)
    return sessions.clear_cookie(_go('/account/login?changed=deleted'))


@router.get('/calendar/download')
def calendar_download(request: Request):
    sessions.check_origin(request)

    def select(conn):
        identity = sessions.identity(conn, request)
        if not identity:
            problem(401, 'unauthenticated')
        cloud_account = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (identity['account_id'],)).fetchone()
        if not allow_sync(conn, cloud_account):
            problem(403, 'subscription_required')
        return cloud_account, now()

    try:
        return calendar_export.download(select)
    except HTTPException as exc:
        if exc.status_code == 401:
            return _signed_out('calendar')
        return pages.problem_page('无法下载日程', pages.error_message(exc.detail), status=exc.status_code,
                                  href='/account#calendar', headers=exc.headers)


def _boundary(account_row):
    return account_row['dataset_id'], account_row['sync_epoch'], account_row['commit_seq']


def _matches_boundary(claim, account_row):
    return (claim['dataset_id'], claim['sync_epoch'], claim['boundary']) == _boundary(account_row)


def _expired_service_end(conn, account_row):
    instant = now()
    if allow_sync(conn, account_row, instant=instant):
        problem(409, 'export_use_active_download')
    ended_at = last_service_end(conn, account_row, instant)
    if not ended_at:
        problem(403, 'export_not_available')
    return ended_at


def _export_csrf(request):
    sessions.check_origin(request)
    auth.checked_origin(request)
    csrf = request.headers.getlist('x-weekglass-csrf')
    if len(csrf) != 1 or not re.fullmatch(r'[0-9a-f]{64}', csrf[0]):
        problem(403, 'invalid_csrf')
    return csrf[0]


@router.post('/calendar/prepare')
def export_prepare(request: Request):
    csrf = _export_csrf(request)
    with connect() as conn:
        identity = _write_identity(conn, request, csrf)
        cloud_account = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (identity['account_id'],)).fetchone()
        aid = cloud_account['account_id']
        ended_at = _expired_service_end(conn, cloud_account)
        claim = export_claim(conn, aid, ended_at)
        if claim:
            if claim['completed_at']:
                problem(409, 'export_already_completed')
            if not _matches_boundary(claim, cloud_account):
                problem(409, 'export_boundary_changed')
            return {'export_id': str(claim['export_id'])}
        export_id = uuid4()
        conn.execute('''INSERT INTO calendar_export_claims(account_id,ended_at,export_id,dataset_id,sync_epoch,boundary)
          VALUES (%s,%s,%s,%s,%s,%s)''', (aid, ended_at, export_id, *_boundary(cloud_account)))
    return {'export_id': str(export_id)}


@router.post('/calendar/{export_id}/download')
def export_download(export_id: UUID, request: Request):
    csrf = _export_csrf(request)

    def select(conn):
        identity = sessions.identity(conn, request)
        if not identity:
            problem(401, 'unauthenticated')
        sessions.require_csrf(identity, csrf)
        cloud_account = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (identity['account_id'],)).fetchone()
        ended_at = _expired_service_end(conn, cloud_account)
        claim = export_claim(conn, cloud_account['account_id'], ended_at)
        if not claim or claim['export_id'] != export_id or not _matches_boundary(claim, cloud_account):
            problem(404, 'export_not_found')
        if claim['completed_at']:
            problem(409, 'export_already_completed')
        return cloud_account, claim['created_at']

    def transferred():
        with connect() as conn:
            conn.execute('''UPDATE calendar_export_claims SET delivered_at=now()
              WHERE export_id=%s AND delivered_at IS NULL''', (export_id,))

    return calendar_export.download(select, transferred=transferred)


@router.post('/calendar/{export_id}/complete', status_code=204)
def export_complete(export_id: UUID, request: Request):
    csrf = _export_csrf(request)
    with connect() as conn:
        identity = _write_identity(conn, request, csrf)
        claim = conn.execute('''SELECT delivered_at,completed_at FROM calendar_export_claims
          WHERE account_id=%s AND export_id=%s''', (identity['account_id'], export_id)).fetchone()
        if not claim:
            problem(404, 'export_not_found')
        if not claim['delivered_at']:
            problem(409, 'export_not_transferred')
        if not claim['completed_at']:
            conn.execute('UPDATE calendar_export_claims SET completed_at=now() WHERE export_id=%s', (export_id,))
    return Response(status_code=204)


@router.get('/assets/console.css')
def css(request: Request):
    sessions.check_origin(request)
    from .console_style import CSS
    return Response(CSS, media_type='text/css', headers={'Cache-Control': 'public, max-age=300'})


@router.get('/assets/calendar.js')
def calendar_script(request: Request):
    sessions.check_origin(request)
    from .console_style import CALENDAR_JS
    return Response(CALENDAR_JS, media_type='text/javascript', headers={'Cache-Control': 'public, max-age=300'})
