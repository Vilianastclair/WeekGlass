"""Order-only browser checkout and environment-specific Waffo webhooks."""
from datetime import timedelta
from uuid import UUID

from fastapi import APIRouter, Request, Response
from starlette.concurrency import run_in_threadpool

from . import billing, email_delivery, waffo_runtime
from .auth_styles import AUTH_STYLE
from .billing_routes import _checkout_access, _page
from .db import connect
from .protocol import now, problem
from .settings import request_origin
from .waffo import BridgeError

router = APIRouter(prefix='/v1/billing', include_in_schema=False)
_CHECKOUT_STYLE = AUTH_STYLE + '''
.panel button[data-action="refresh"]:not(:first-of-type) {
  min-height:38px;margin-top:8px;background:transparent;border-color:transparent;
  box-shadow:none;color:var(--accent);font-size:13px;
}
.checkout-email-action {
  display:grid;place-items:center;min-height:46px;margin-top:24px;padding:10px 16px;
  border:1px solid var(--edge);border-radius:var(--radius);color:var(--ink);
  background:linear-gradient(180deg,var(--button-top),var(--button-bottom));
  box-shadow:0 5px 12px var(--shade),inset 0 1px 0 #ffffff48;font-weight:550;text-decoration:none;
}
.checkout-email-action:hover{text-decoration:underline}
'''
_VERIFY_EMAIL_ACTION = '<a class="checkout-email-action" href="/v1/auth/email">验证或更换邮箱</a>'
_PORTAL_VERIFY_EMAIL = '<a class="checkout-email-action" href="/account/email">验证邮箱</a>'

_ACTIONS = '''const controls = [...document.querySelectorAll('button')];
const status = document.querySelector('[role=status]');
const refresh = document.querySelector('[data-action="refresh"]');
const test = refresh?.dataset.test === 'yes';
const portal = refresh?.dataset.portal === 'yes';
const messages = {
  paid: test ? '测试付款已确认，本地测试账号已开通云同步。' :
    `付款已确认。${refresh.dataset.periodDays} 天云同步已到账。${portal ? '请返回账号控制台查看。' : '可以关闭此页并返回 WeekGlass。'}`,
  refunded: '退款已确认，对应的云同步权益已撤销。',
  refund_pending: '退款待确认。',
  closed: '此订单已关闭，未开通新的云同步时段。',
  failed: '此订单未付款。',
};
let running = false;
async function act(action) {
  if (running) return false;
  running = true;
  controls.forEach(item => item.disabled = true);
  status.textContent = action === 'provider' ? '正在打开收银台…' : '正在核对付款…';
  try {
    const response = await fetch(location.pathname + '/' + action, {method: 'POST'});
    const result = await response.json();
    if (!response.ok) {
      status.textContent = result.code === 'billing_account_mismatch'
        ? '此订单不属于目前登录的账号。请退出当前账号后重新打开订单。'
        : ['billing_checkout_pending','test_checkout_pending'].includes(result.code)
          ? '收银结果仍在核对，不会重复提交这笔订单。'
          : '暂时无法核对，请稍后再试。';
      return action === 'refresh';
    }
    if (result.url) {
      location.assign(result.url);
      return false;
    }
    const verify = result.status === 'paid' && result.verify_email === true && !test;
    status.textContent = verify
      ? `付款已确认，${refresh.dataset.periodDays} 天云同步已到账。请验证邮箱，以便找回账号。`
      : messages[result.status] || '还没有已确认的付款。若刚完成，请稍候；到账后会自动开通。';
    if (messages[result.status]) {
      document.querySelector('[data-action="provider"]')?.remove();
      if (!test) refresh?.remove();
      const emailAction = document.querySelector('#checkout-email-next');
      if (verify && emailAction) emailAction.replaceWith(emailAction.content.cloneNode(true));
      return false;
    }
    return true;
  } catch {
    status.textContent = '连接中断，请稍后再核对。';
    return action === 'refresh';
  } finally {
    running = false;
    controls.forEach(item => item.disabled = false);
  }
}
controls.forEach(button => button.addEventListener('click', () => act(button.dataset.action)));
window.addEventListener('pageshow', async (event) => {
  if (!refresh) return;
  const returned = refresh.dataset.returned === 'yes';
  if (!returned && !event.persisted && performance.getEntriesByType('navigation')[0]?.type !== 'back_forward') return;
  if (returned) history.replaceState(null, '', location.pathname);
  if (!await act('refresh') || test) return;
  for (const delay of [3000, 6000, 12000, 18000]) {
    await new Promise(resolve => setTimeout(resolve, delay));
    if (!await act('refresh')) break;
  }
});'''


def mount_routes(app):
    if not getattr(app.state, 'waffo_routes_mounted', False):
        app.include_router(router)
        app.state.waffo_routes_mounted = True


def show_paid_email_action(conn, order, config):
    return (
        order['status'] == 'paid'
        and config.scope[0] == billing.WAFFO_LIVE_PROVIDER
        and email_delivery.available()
        and billing.needs_paid_email_verification(conn, order['account_id'])
    )


def order_page(order, config, returned=False, *, verify_email=False, portal=False, account_label=None):
    status = order['status']
    is_test = bool(config.sandbox_origin)
    days = order['period_seconds'] // 86400
    may_pay = ((status == 'pending' and billing.checkout_quote_available(order, config))
               or (billing.waffo_checkout_can_resume(order) and billing.checkout_available(config, order['account_id']))
               or (is_test and status in billing.IN_FLIGHT and billing.checkout_quote_available(order, config)))
    label = '打开测试收银台' if is_test else '打开微信收银台'
    pay = f'<button data-action="provider">{label}</button>' if may_pay else ''
    should_refresh = status in (*billing.IN_FLIGHT, 'pending') or (is_test and status in ('paid', 'refund_pending'))
    hidden = ' hidden' if status == 'pending' and not is_test else ''
    refresh_label = '核对测试付款' if is_test else '查看付款结果'
    test_flag, returned_flag = ('yes' if is_test else 'no'), ('yes' if returned else 'no')
    refresh = (f'<button data-action="refresh" data-test="{test_flag}" data-returned="{returned_flag}"'
               f' data-period-days="{days}" data-portal="{"yes" if portal else "no"}"{hidden}>'
               f'{refresh_label}</button>') if should_refresh else ''
    if is_test:
        title = 'WeekGlass 测试订单'
        message = {'pending': '测试订单，不会扣款。', 'submitting': '收银会话正在核对。',
                   'processing': '付款后回到这里核对结果。', 'paid': '测试付款已确认。',
                   'refunded': '测试退款已确认。', 'refund_pending': '测试退款待确认。',
                   'closed': '测试订单已关闭。', 'failed': '测试订单未付款。'}[status]
    else:
        amount = order['amount_minor']
        title = 'WeekGlass 云同步'
        paid_message = (f'付款已确认。{days} 天云同步已到账。' +
                        ('请返回账号控制台查看。' if portal else '可以关闭此页并返回 WeekGlass。'))
        message = {'pending': f'¥{amount // 100}.{amount % 100:02} / {days} 天。单次购买，不会自动续费。'
                              if may_pay else '暂未开放购买。此订单未付款。',
                   'submitting': '收银台正在准备，稍后可查看付款结果。',
                   'processing': '付款结果待确认；到账后会自动开通。',
                   'paid': paid_message,
                   'refunded': '退款已确认，对应的云同步权益已撤销。', 'refund_pending': '退款待确认。',
                   'closed': '此订单已关闭，未开通新的云同步时段。', 'failed': '此订单未付款。'}[status]
    verify_link = _PORTAL_VERIFY_EMAIL if portal else _VERIFY_EMAIL_ACTION
    if verify_email and not is_test and status == 'paid':
        message = f'付款已确认，{days} 天云同步已到账。请验证邮箱，以便找回账号。'
        email_action = verify_link
    elif refresh and not is_test:
        email_action = f'<template id="checkout-email-next">{verify_link}</template>'
    else:
        email_action = ''
    back = '<p><a href="/account/orders">返回账号订单</a></p>' if portal else ''
    return _page(title, message, actions=pay + refresh + email_action + back, style=_CHECKOUT_STYLE,
                 script=_ACTIONS if pay or refresh else '', referrer_policy='same-origin', account_label=account_label)


def _config(request, provider=None):
    config = request.app.state.billing
    if not (config and config.scope[0] in (billing.WAFFO_TEST_PROVIDER, billing.WAFFO_LIVE_PROVIDER)
            and (provider is None or config.scope[0] == provider)
            and (not config.sandbox_origin or billing.sandbox_database(config.origin))
            and request_origin(request) == config.origin):
        problem(404, 'billing_not_configured')
    return config


def _browser_config(request):
    config = _config(request)
    if request.headers.getlist('origin') != [config.origin]:
        problem(403, 'billing_handoff_invalid')
    return config


def _order(conn, request, checkout_id, config):
    order = conn.execute('SELECT * FROM billing_orders WHERE checkout_id=%s AND account_id IS NOT NULL',
                         (checkout_id,)).fetchone()
    access = _checkout_access(conn, request, checkout_id, order)
    if access == 'mismatch':
        problem(403, 'billing_account_mismatch')
    if not access:
        problem(403, 'billing_handoff_invalid')
    if not order or not billing.same_scope(order, config) or not billing._enabled(conn, order):
        problem(404, 'billing_order_not_found')
    return order


@router.post('/checkout/{checkout_id}/provider')
def provider_checkout(request: Request, checkout_id: UUID):
    config = _browser_config(request)
    pending = 'test_checkout_pending' if config.sandbox_origin else 'billing_checkout_pending'
    with connect() as conn:
        order = _order(conn, request, checkout_id, config)
        if not billing.checkout_available(config, order['account_id']):
            problem(503, 'billing_not_configured')
        if ((billing.waffo_checkout_can_resume(order)
             or config.sandbox_origin and order['status'] == 'processing' and order['provider_checkout_url']
             and order['provider_checkout_expires_at'] > now() and billing.checkout_quote_available(order, config))
                and billing._enabled(conn, order)):
            return {'url': order['provider_checkout_url']}
        if order['status'] == 'pending' and not billing.checkout_quote_available(order, config):
            problem(503, 'billing_not_configured')
    claimed = billing.claim_checkout(config, checkout_id)
    if not claimed:
        problem(409, pending)
    try:
        url, expires = config.adapter.create_checkout(claimed)
    except BridgeError as exc:
        if not config.sandbox_origin and str(exc).startswith('checkout_preflight_'):
            # The adapter guarantees no write was attempted; this slot may be reused.
            with connect() as conn:
                _, order = billing._lock_target(conn, 'billing_orders', 'checkout_id', checkout_id)
                if order['status'] == 'submitting':
                    billing._close_order(conn, order, 'failed')
            problem(503, 'billing_provider_unavailable')
        # Otherwise keep the stable order number for read-only reconciliation.
        problem(503, pending)
    with connect() as conn:
        account, order = billing._lock_target(conn, 'billing_orders', 'checkout_id', checkout_id)
        if not billing._enabled(conn, account) or order['status'] != 'submitting':
            problem(409, pending)
        if config.sandbox_origin:
            conn.execute('''UPDATE billing_orders SET status='processing',provider_checkout_url=%s,
              provider_checkout_expires_at=%s WHERE checkout_id=%s''', (url, expires, checkout_id))
        else:
            conn.execute('''UPDATE billing_orders SET status='processing',provider_checkout_url=%s,
              provider_checkout_expires_at=%s,provider_next_check_at=%s WHERE checkout_id=%s''',
              (url, expires, now() + timedelta(seconds=15), checkout_id))
    return {'url': url}


@router.post('/checkout/{checkout_id}/refresh')
def refresh(request: Request, checkout_id: UUID):
    config = _browser_config(request)
    with connect() as conn:
        order = _order(conn, request, checkout_id, config)
    if config.sandbox_origin:
        if order['status'] in (*billing.IN_FLIGHT, 'paid', 'refund_pending'):
            try:
                events = config.adapter.query_events(order)
            except BridgeError:
                problem(503, 'test_payment_unavailable')
            for event in events:
                if billing.apply_verified_event(config.adapter, event) != 'applied':
                    problem(409, 'test_payment_unverified')
    elif order['status'] in billing.IN_FLIGHT:
        waffo_runtime.reconcile_one(config, checkout_id)
    with connect() as conn:
        fresh = _order(conn, request, checkout_id, config)
        result = {'status': fresh['status']}
        if show_paid_email_action(conn, fresh, config):
            result['verify_email'] = True
        return result


@router.post('/webhooks/waffo-test', status_code=204)
async def sandbox_webhook(request: Request):
    return await _webhook(request, billing.WAFFO_TEST_PROVIDER)


@router.post('/webhooks/waffo', status_code=204)
async def live_webhook(request: Request):
    return await _webhook(request, billing.WAFFO_LIVE_PROVIDER)


async def _webhook(request, provider):
    config = _config(request, provider)
    raw = await request.body()
    if len(raw) > 65536:
        problem(413, 'request_too_large')
    if len(request.headers.getlist('x-waffo-signature')) != 1:
        problem(401, 'invalid_payment_signature')
    try:
        event = await run_in_threadpool(config.adapter.verify_event, request.headers, raw)
    except ValueError:
        problem(401, 'invalid_payment_signature')
    except BridgeError as exc:
        if str(exc) == 'sdk_unavailable':
            problem(503, 'billing_provider_unavailable')
        problem(401, 'invalid_payment_signature')
    if event is not None:
        result = await run_in_threadpool(billing.apply_verified_event, config.adapter, event)
        if result == 'rejected':
            problem(422, 'billing_payment_unverified')
    return Response(status_code=204)
