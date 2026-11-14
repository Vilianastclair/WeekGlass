"""Account billing API and a one-time, order-only browser handoff."""
from datetime import timedelta
from hashlib import sha256
import base64
import re
import secrets
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from starlette.concurrency import run_in_threadpool

from . import auth, billing
from .db import connect
from .protocol import body, decode_token, encode_token, now, problem, stamp
from .settings import request_origin, settings

router = APIRouter(prefix='/v1/billing')
_cookie = 'wg_billing_order'
_token_pattern = re.compile(r'[A-Za-z0-9_-]{43}')


def _hosted():
    if settings.mode != 'hosted':
        problem(404, 'billing_not_configured')


def _account(conn, identity, lock=False):
    if lock:
        account = billing.lock_account(conn, identity['account_id'])
    else:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        account = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (identity['account_id'],)).fetchone()
    if not account:
        problem(401, 'account_unavailable')
    auth.revalidate_identity(conn, identity)
    return account


def _owned_order(conn, account, checkout_id):
    order = conn.execute('SELECT * FROM billing_orders WHERE checkout_id=%s AND account_id=%s',
                         (checkout_id, account['account_id'])).fetchone()
    if not order:
        problem(404, 'billing_order_not_found')
    return order


@router.get('/plans')
def plans(request: Request, identity=Depends(auth.get_identity)):
    _hosted()
    with connect() as conn:
        account = _account(conn, identity)
    config = request.app.state.billing
    if config and config.scope[0] == billing.WAFFO_LIVE_PROVIDER and request_origin(request) != config.origin:
        return {'plans': []}
    return {'plans': billing.offers(config, account_id=account['account_id'])}


@router.post('/checkout-sessions', status_code=201)
async def checkout(request: Request, identity=Depends(auth.get_identity)):
    _hosted()
    config = request.app.state.billing
    if not billing.checkout_available(config, UUID(identity['account_id'])):
        problem(503, 'billing_not_configured')
    if request_origin(request) != config.origin and config.scope[0] == billing.WAFFO_LIVE_PROVIDER:
        problem(404, 'billing_not_configured')
    keys = request.headers.getlist('idempotency-key')
    try:
        key = UUID(keys[0])
        if len(keys) != 1 or str(key) != keys[0].lower():
            raise ValueError()
    except (IndexError, ValueError):
        problem(422, 'invalid_idempotency_key')
    intent = await body(request, 'Checkout')
    return await run_in_threadpool(_checkout, config, key, intent, identity)


def _checkout(config, key, intent, identity):
    with connect() as conn:
        account = _account(conn, identity, lock=True)
        order = billing.create_checkout(conn, account, config, key, intent)
        return _order_link(conn, order, config)


def _order_link(conn, order, config):
    checkout_id = order['checkout_id']
    instant = now()
    if not _browser_payable(conn, order, config):
        return {'checkout_id': str(checkout_id), 'url': None, 'expires_at': None}
    conn.execute('DELETE FROM billing_checkout_handoffs WHERE checkout_id=%s AND expires_at<=%s',
                 (checkout_id, instant))
    ticket, expires = secrets.token_urlsafe(32), instant + timedelta(minutes=5)
    conn.execute('INSERT INTO billing_checkout_handoffs(ticket_hash,checkout_id,expires_at) VALUES (%s,%s,%s)',
                 (auth.hashed(ticket), checkout_id, expires))
    return {'checkout_id': str(checkout_id), 'url': f'{config.origin}/v1/billing/checkout/{checkout_id}#ticket={ticket}',
            'expires_at': stamp(expires)}


def _browser_payable(conn, order, config):
    return bool(order and billing.same_scope(order, config) and billing.checkout_available(config, order['account_id'])
                and (billing.checkout_payable(conn, order, config) or
                     billing.waffo_checkout_can_resume(order) or
                     config.sandbox_origin and order['status'] in billing.IN_FLIGHT
                     and billing.checkout_quote_available(order, config)))


@router.get('/subscription')
def subscription(request: Request, identity=Depends(auth.get_identity)):
    _hosted()
    with connect() as conn:
        account = _account(conn, identity)
        return billing.subscription_json(conn, account, request.app.state.billing)


@router.post('/subscription/cancel')
def cancel(request: Request, identity=Depends(auth.get_identity)):
    _hosted()
    with connect() as conn:
        account = _account(conn, identity, lock=True)
        billing.stop_renewal(conn, account['account_id'], now())
        return billing.subscription_json(conn, account, request.app.state.billing)


@router.get('/orders')
def orders(identity=Depends(auth.get_identity)):
    _hosted()
    with connect() as conn:
        account = _account(conn, identity)
        rows = conn.execute('''SELECT * FROM billing_orders WHERE account_id=%s
          ORDER BY created_at DESC,checkout_id DESC LIMIT 50''', (account['account_id'],)).fetchall()
        return {'orders': [billing.order_json(conn, row) for row in rows]}


@router.get('/orders/{checkout_id}')
def order(checkout_id: UUID, identity=Depends(auth.get_identity)):
    _hosted()
    with connect() as conn:
        return billing.order_json(conn, _owned_order(conn, _account(conn, identity), checkout_id))


@router.post('/orders/{checkout_id}/close')
def close_order(checkout_id: UUID, identity=Depends(auth.get_identity)):
    _hosted()
    with connect() as conn:
        order = _owned_order(conn, _account(conn, identity, lock=True), checkout_id)
        return billing.order_json(conn, billing.close_unsubmitted(conn, order, now()))


_HANDOFF = '''const ticket = new URLSearchParams(location.hash.slice(1)).get('ticket');
if (ticket) {
  history.replaceState(null, '', location.pathname);
  fetch(location.pathname + '/handoff', {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ticket})
  }).then(response => {
    if (!response.ok) throw new Error();
    location.reload();
  }).catch(() => {
    document.querySelector('p').textContent = '结账链接已失效。请返回 WeekGlass 重新打开订单。';
  });
}'''


def _browser_origin(request):
    _hosted()
    config = request.app.state.billing
    if request_origin(request) != (config.origin if config else billing.OFFICIAL_ORIGIN):
        problem(404, 'billing_not_configured')


def _page(title, message, *, script='', actions='', style='', referrer_policy='no-referrer'):
    js_policy = ("'sha256-" + base64.b64encode(sha256(script.encode()).digest()).decode() + "'") if script else "'none'"
    css_policy = ("'sha256-" + base64.b64encode(sha256(style.encode()).digest()).decode() + "'") if style else "'none'"
    return HTMLResponse(f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} · WeekGlass</title>
      {'<style>' + style + '</style>' if style else ''}</head>
      <body><main class="panel"><h1>{title}</h1><p role="status">{message}</p>{actions}</main>
      {'<script>' + script + '</script>' if script else ''}</body></html>''',
      headers={'Content-Security-Policy': f"default-src 'none'; script-src {js_policy}; style-src {css_policy}; "
               "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
               'Referrer-Policy': referrer_policy})


def _session(request, checkout_id):
    value = request.cookies.get(_cookie)
    if not value:
        return False
    try:
        data = decode_token(value)
        return (data.get('kind') == 'billing_order' and data.get('checkout_id') == str(checkout_id)
                and data.get('expires', 0) > now().timestamp())
    except HTTPException:
        return False


@router.get('/checkout/{checkout_id}', include_in_schema=False)
def browser(request: Request, checkout_id: UUID):
    _browser_origin(request)
    if _session(request, checkout_id):
        with connect() as conn:
            row = conn.execute('SELECT * FROM billing_orders WHERE checkout_id=%s AND account_id IS NOT NULL',
                               (checkout_id,)).fetchone()
        if row:
            status = row['status']
            config = request.app.state.billing
            if (config and config.scope[0] in (billing.WAFFO_TEST_PROVIDER, billing.WAFFO_LIVE_PROVIDER)
                    and billing.same_scope(row, config)):
                from .waffo_routes import order_page
                return order_page(row, config, request.query_params.get('returned') == '1')
            message = {'paid': '付款已确认。请返回 WeekGlass 刷新权益。',
                       'pending': '订单已保留，当前未接通在线收银。请返回 WeekGlass 查看订单。',
                       'closed': '此订单已关闭。请返回 WeekGlass。', 'failed': '订单未付款。请返回 WeekGlass。',
                       'refund_pending': '退款结果待确认。请返回 WeekGlass 查看订单。',
                       'refunded': '退款已确认。请返回 WeekGlass 查看订单。'}.get(
                           status, '付款结果待确认。请返回 WeekGlass 查看订单。')
            # Readback is deliberately passive; only a real adapter can implement cashier submission.
            return _page('WeekGlass 订单', message, script=_HANDOFF)
    if not billing.checkout_available(request.app.state.billing):
        problem(503, 'billing_not_configured')
    config = request.app.state.billing
    if config.scope[0] in (billing.WAFFO_TEST_PROVIDER, billing.WAFFO_LIVE_PROVIDER):
        from .auth_styles import AUTH_STYLE
        if config.sandbox_origin:
            return _page('正在核对测试订单', '请从 WeekGlass 打开有效的测试结账链接。', script=_HANDOFF,
                         style=AUTH_STYLE, referrer_policy='same-origin')
        return _page('正在打开订单', '请从 WeekGlass 打开有效的结账链接。', script=_HANDOFF,
                     style=AUTH_STYLE, referrer_policy='same-origin')
    return _page('正在核对订单', '请从 WeekGlass 打开有效的结账链接。', script=_HANDOFF)


@router.post('/checkout/{checkout_id}/handoff', include_in_schema=False)
async def redeem(request: Request, checkout_id: UUID):
    _browser_origin(request)
    if request.headers.get('origin') != request_origin(request):
        problem(403, 'invalid_origin')
    config = request.app.state.billing
    if not billing.checkout_available(config):
        problem(503, 'billing_not_configured')
    data = await body(request, 'CheckoutHandoff')
    return await run_in_threadpool(_redeem, checkout_id, config, data['ticket'])


def _redeem(checkout_id, config, ticket):
    if not _token_pattern.fullmatch(ticket):
        problem(403, 'billing_handoff_invalid')
    with connect() as conn:
        account, order = billing._lock_target(conn, 'billing_orders', 'checkout_id', checkout_id)
        instant = now()
        if not billing._enabled(conn, account) or not _browser_payable(conn, order, config):
            problem(403, 'billing_handoff_invalid')
        row = conn.execute('''UPDATE billing_checkout_handoffs SET consumed_at=%s
          WHERE checkout_id=%s AND ticket_hash=%s AND expires_at>%s AND consumed_at IS NULL RETURNING checkout_id''',
          (instant, checkout_id, auth.hashed(ticket), instant)).fetchone()
        if not row:
            problem(403, 'billing_handoff_invalid')
    response = JSONResponse({'checkout_id': str(checkout_id)})
    duration = timedelta(minutes=45 if config.scope[0] == billing.WAFFO_LIVE_PROVIDER else
                         30 if config.sandbox_origin else 15)
    response.set_cookie(_cookie, encode_token({'kind': 'billing_order', 'checkout_id': str(checkout_id),
                                                'expires': int((instant + duration).timestamp())}),
                        secure=config.sandbox_origin is None, httponly=True, samesite='strict' if config.sandbox_origin else 'lax',
                        max_age=int(duration.total_seconds()),
                        path=f'/v1/billing/checkout/{checkout_id}')
    return response
