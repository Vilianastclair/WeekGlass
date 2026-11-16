"""Rendered account pages with progressive, same-origin forms."""
from datetime import datetime, timedelta, timezone
from html import escape
from urllib.parse import urlencode
from uuid import uuid4

from fastapi.responses import HTMLResponse

from . import billing, waffo_runtime
from .account import visible_username
from .auth_styles import AUTH_BRAND, CLOUD_SOURCE_URL

_MARK = AUTH_BRAND.split('src="', 1)[1].split('"', 1)[0]
_CN = timezone(timedelta(hours=8))
_ICONS = {
    'cloud': '<path d="M6 17a4 4 0 01-.4-8 6 6 0 0111.2 1.1A3.5 3.5 0 0118 17H6z"/>',
    'arrow': '<path d="M5 12h13m-5-5 5 5-5 5"/>',
    'clock': '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>',
    'calendar': '<rect x="4" y="6" width="16" height="15" rx="2"/><path d="M8 3v5m8-5v5M4 11h16m-12 4h2m4 0h2m-8 3h2"/>',
    'device': '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4"/>',
    'shield': '<path d="M12 3l7 3v5c0 4-3 7-7 9-4-2-7-5-7-9V6l7-3z"/><path d="m9 12 2 2 4-4"/>',
    'check': '<path d="m5 12 4 4 10-10"/>',
    'download': '<path d="M12 3v12m-5-5 5 5 5-5M5 18v3h14v-3"/>',
    'search': '<circle cx="10.5" cy="10.5" r="5.5"/><path d="m15 15 4 4"/>',
}
_HEADER = {
    'Content-Security-Policy': "default-src 'none'; style-src 'self'; script-src 'self'; img-src data:; "
                               "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    'Referrer-Policy': 'same-origin', 'Cache-Control': 'no-store',
}
_STATES = {'not_subscribed': '未开通', 'active': '已开通', 'expired': '已到期', 'self_hosted': '自托管'}
_ORDERS = {'pending': '待付款', 'submitting': '准备收银台', 'processing': '等待确认', 'paid': '已支付',
           'closed': '已关闭', 'failed': '未支付', 'refund_pending': '退款处理中', 'refunded': '已退款'}
_TIERS = ((billing.MONTHLY_PLAN_ID, 30, waffo_runtime.MONTHLY_PRICE_MINOR),
          ('cloud-365d', 365, waffo_runtime.ANNUAL_PRICE_MINOR))

LOGIN_MESSAGES = {'1': '密码已更新。请使用新密码登录。', 'email': '邮箱已更换。请用新邮箱重新登录。',
                  'deleted': 'WeekGlass 云账号已删除。本机日历不受影响。'}
ORDER_MESSAGES = {'closed': '未付款订单已关闭。'}
SECURITY_MESSAGES = {'revoked': '其他网页登录和应用设备已退出。', 'device': '该设备已断开云同步。'}
ADMIN_MESSAGES = {'suspend': '账号已暂停，原会话已撤销。', 'resume': '账号已恢复，可重新登录。',
                  'revoke_devices': '已撤销该账号的会话和设备。', 'revoke_device': '设备已断开云同步。',
                  'change_grant': '限时授权已更新。'}
_ADMIN_ACTIONS = {'suspend': '暂停账号', 'resume': '恢复账号', 'revoke_devices': '撤销会话',
                  'revoke_device': '断开设备', 'change_grant': '更新限时授权'}
_ERRORS = {
    'invalid_csrf': '页面已失效，请返回后重新操作。',
    'subscription_required': '云同步已暂停。请在控制台开通权益，或查看到期导出资格。',
    'billing_order_not_found': '找不到此订单。',
    'billing_order_unresolved': '还有一笔订单未结清。请先在订单页面核对此订单。',
    'billing_order_processing': '支付结果仍在核对，暂时不能关闭订单。',
    'billing_order_not_open': '该订单已完成，不能关闭。',
    'billing_period_already_reserved': '已经提前购买了下一期。你可以在订单页面查看。',
    'billing_terms_changed': '报价已更新，请返回方案页面后重新选择。',
    'billing_not_configured': '当前暂不能购买，请稍后再试。',
    'billing_plan_unavailable': '该方案暂未开放，请选择其他方案。',
    'invalid_changepasswordrequest': '新密码不符合此账号的密码要求，请按页面提示重试。',
    'rate_limited': '操作过于频繁，请稍后重试。',
    'export_busy': '当前下载较多，请过几秒再试。',
    'not_found': '找不到此项记录。',
}


def e(value):
    return escape(str(value), quote=True)


def icon(name, klass='icon'):
    return (f'<svg class="{klass}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + _ICONS[name] + '</svg>')


def date(value, *, time=False):
    if not value:
        return '—'
    if isinstance(value, str):
        value = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return value.astimezone(_CN).strftime('%Y-%m-%d %H:%M' if time else '%Y-%m-%d')


def amount(minor):
    return f'{minor // 100}.{minor % 100:02d}'


def _hidden(name, value):
    return f'<input type="hidden" name="{name}" value="{e(value)}">'


def _form(path, csrf, button, *, fields='', kind='button secondary', data=None):
    extra = ''.join(_hidden(name, value) for name, value in (data or {}).items())
    return (f'<form method="post" action="{path}">{_hidden("csrf", csrf)}{extra}{fields}'
            f'<button class="{kind}" type="submit">{button}</button></form>')


def _password(name='current_password', text='当前密码', *, new=False, min_length=1, max_length=1024):
    attr = 'new-password' if new else 'current-password'
    return (f'<label class="field">{text}<input name="{name}" type="password" autocomplete="{attr}" '
            f'required minlength="{min_length}" maxlength="{max_length}"></label>')


def _status(text, kind='neutral'):
    return f'<span class="status {kind}"><i></i>{e(text)}</span>'


def _feedback(message):
    return f'<p class="notice" role="status">{e(message)}</p>' if message else ''


def error_message(detail):
    return detail.get('message') or _ERRORS.get(detail.get('code'), '请返回上一页后重试。')


def _shell(title, content, *, profile=None, csrf=None, section=None, script=False, status=200, headers=None):
    links = ''
    logout = ''
    if profile:
        items = [('home', '/account', '概览'), ('orders', '/account/orders', '订单'),
                 ('security', '/account/security', '安全')]
        if profile['is_owner']:
            items.append(('admin', '/account/admin', '所有者'))
        links = '<nav class="nav-links" aria-label="账号导航">' + ''.join(
            f'<a href="{href}"' + (' aria-current="page"' if key == section else '') + f'>{label}</a>'
            for key, href, label in items) + '</nav>'
        logout = _form('/account/logout', csrf, '退出', kind='nav-logout')
    js = '<script src="/account/assets/calendar.js" defer></script>' if script else ''
    return HTMLResponse(f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1"><title>{e(title)}</title>
      <link rel="stylesheet" href="/account/assets/console.css">{js}</head><body>
      <a class="skip" href="#content">跳至主要内容</a><div class="wrap">
      <header class="top"><a class="brand" href="/account"><img src="{_MARK}" alt="" width="34" height="34">
      <span>WeekGlass<small>账号控制台</small></span></a>{links}{logout}</header>
      <main id="content">{content}</main>
      <footer><span>WeekGlass</span><nav aria-label="服务链接"><a href="/">云同步首页</a><a href="/terms">服务条款</a><a href="/privacy">隐私说明</a><a href="{CLOUD_SOURCE_URL}">服务端源代码</a></nav></footer>
      </div></body></html>''', status_code=status, headers={**_HEADER, **(headers or {})})


def _heading(kicker, title, description):
    return (f'<header class="page-head"><p class="eyebrow">{e(kicker)}</p>'
            f'<h1>{e(title)}</h1><p>{e(description)}</p></header>')


def problem_page(title, message, *, href='/account', button='返回账号控制台', status=400, headers=None):
    return _shell(title, f'<section class="sheet compact-sheet">{_heading("WeekGlass", title, message)}'
                  f'<a class="button primary" href="{href}">{button}</a></section>', status=status, headers=headers)


def _plan(tier, offer, csrf, blocked, is_active):
    plan_id, days, price = tier
    annual = days == 365
    copy = '一整年在 Windows 与 Android 之间同步日程。' if annual else '开通 30 天跨设备同步，适合先用一个月。'
    name = '年版' if annual else '月版'
    description = '低于连续购买 12 个 30 天方案的价格' if annual else '到期后再决定是否续购'
    flag = '<span class="plan-flag">更划算</span>' if annual else ''
    if offer and not blocked:
        purchase = _form('/account/checkout', csrf, ('续购' if is_active else '选择') + f' {days} 天' + icon('arrow'),
                         kind='button primary', data={'plan_id': plan_id, 'terms_version': offer['terms_version'],
                                                      'idempotency_key': uuid4()})
    elif blocked:
        purchase = '<a class="button secondary" href="/account/orders">先处理现有订单</a>'
    else:
        purchase = '<span class="button unavailable" aria-disabled="true">暂不可购买</span>'
    return f'''<article class="plan {'annual' if annual else 'monthly'}"><div class="plan-top">
        <span class="plan-glyph">{icon('calendar' if annual else 'clock')}</span>{flag}</div>
        <h3>{name}<span>{days} 天</span></h3>
        <div class="price"><span class="currency">¥</span><strong>{amount(price)}</strong><span class="once">单次付款</span></div>
        <p>{copy}</p><div class="plan-detail">{icon('check')}{description}</div>{purchase}</article>'''


def _calendar(rights, claim, csrf):
    if rights['sync_read']:
        content = ('<p>下载云端日程的 WeekGlass JSON 文件。导出不会改变任何云端日程。</p>'
                   f'<a class="button secondary" href="/account/calendar/download">{icon("download")}下载日程</a>')
    elif rights['export_allowed']:
        content = f'''<div data-export data-csrf="{e(csrf)}">
          <p data-export-intro>到期后可导出一次。下载中断可以重试，文件下载后请妥善保存。</p>
          <button class="button secondary" type="button" data-prepare>{icon('download')}导出云端日程</button>
          <a class="button secondary" data-save download="weekglass-calendar.json" hidden>再次保存同一文件</a>
          <button class="button primary" type="button" data-confirm hidden>重试确认</button>
          <p data-export-status role="status" aria-live="polite"></p>
          <noscript><p>请启用浏览器脚本以检查文件是否完整。导出机会尚未使用。</p></noscript>
        </div>'''
    elif claim and claim['completed_at']:
        content = (f'<p>此期的日程已于 {date(claim["completed_at"])} 导出。请保留你保存的文件。'
                   '续购重新开通同步后，下次到期还可导出一次。</p>')
    else:
        content = '<p>开通过云同步后，可以在这里下载日程。</p>'
    if rights['status'] == 'expired':
        content += '<p class="privacy-copy"><a href="/privacy">了解如何申请个人信息副本</a></p>'
    return f'''<section class="sheet mini" id="calendar"><span class="mini-icon">{icon('download')}</span>
        <h2>日程与导出</h2>{content}</section>'''


def overview(profile, csrf, rights, offers, pending, claim, devices, paid_mail):
    status = rights['status']
    active = status == 'active'
    until = rights['current_period_end']
    description = ('已开通的设备可以同步。到期不自动续费。' if active else
                   '云端日程仍保留。续购后可以继续在设备间同步。' if status == 'expired' else
                   '开通后，即可在 Windows 和 Android 之间同步日程。')
    end_label = '有效期至' if active else '已到期于'
    date_line = f'<dl><dt>{end_label}</dt><dd>{date(until)}</dd></dl>' if until else ''
    access_type = '限时授权' if active and not rights['plan_id'] else '官方云同步'
    plan_link = '续购云同步' if active else '查看同步方案'
    help_mail = ('<p class="notice">付款已确认。<a href="/account/email">验证邮箱</a>，以便以后找回账号。</p>'
                 if paid_mail else '')
    matched = {offer['plan_id']: offer for offer in offers if 'single' in offer['purchase_modes']}
    pending_hint = ('<p class="notice">有一笔订单待处理。<a href="/account/orders">查看订单</a></p>'
                    if pending else '')
    plans = ''.join(_plan(tier, matched.get(tier[0]), csrf,
                   pending and pending['plan_id'] != tier[0], active) for tier in _TIERS)
    content = f'''<section class="hero"><div class="hero-main"><div class="hero-orbits" aria-hidden="true"></div>
        <div class="hero-copy"><p class="eyebrow">官方云服务</p><h1>WeekGlass 云同步</h1><p>{description}</p>
        <a class="button primary" href="#plans">{plan_link}{icon('arrow')}</a></div></div>
        <div class="hero-status sheet"><p class="eyebrow">当前状态</p><div class="status-line">
        <span class="round-cloud">{icon('cloud')}</span><h2>{_STATES[status]}</h2></div>
        {date_line}<dl><dt>{access_type}</dt><dd>{devices} 台已连接设备</dd></dl>
        {'' if active else '<span class="hero-tag">本地日历照常使用</span>'}</div></section>
        {help_mail}<section id="plans" class="section"><div class="section-head"><div><p class="eyebrow">同步方案</p>
        <h2>选择云同步时长</h2></div><p>微信单次支付，到期不扣款</p></div>{pending_hint}
        <div class="plan-grid">{plans}</div><p class="terms-note">同步服务仅适用于官方云。购买前请查看<a href="/terms">服务条款</a>。</p></section>
        <div class="bottom-grid">{_calendar(rights, claim, csrf)}<section class="sheet mini"><span class="mini-icon">{icon('shield')}</span>
        <h2>账号与安全</h2><p class="wrap-text">{e(profile['verified_email'] or profile['pending_email'] or profile['username'])}</p>
        <a class="button secondary" href="/account/security">管理邮箱和设备{icon('arrow')}</a></section></div>'''
    return _shell('WeekGlass 云同步', content, profile=profile, csrf=csrf, section='home', script=rights['export_allowed'] and not active)


def orders(profile, csrf, rows, notice):
    body = []
    for order, cashier in rows:
        status = order['status']
        oid = order['checkout_id']
        state = _status(_ORDERS[status], 'success' if status == 'paid' else 'warning' if status in billing.UNRESOLVED else 'neutral')
        open_label = '继续支付' if status == 'pending' or order.get('can_resume_checkout') else '查看付款结果'
        controls = (f'<a class="button secondary small" href="/v1/billing/checkout/{oid}">{open_label}</a>' if cashier else '')
        if status == 'pending':
            controls += _form(f'/account/orders/{oid}/close', csrf, '关闭未支付订单', kind='button secondary small')
        days = order['period_seconds'] // 86400
        interval = f'<p>有效期 {date(order["period_start"])} 至 {date(order["period_end"])}</p>' if order['period_end'] else ''
        body.append(f'''<article class="order"><div><h2>{days} 天云同步</h2><p>下单时间 {date(order['created_at'], time=True)}</p>
                    {interval}<code class="order-id">订单号 {oid}</code></div><div class="order-side">
                    <strong>¥{amount(order['amount_minor'])}</strong>{state}<div class="row-actions">{controls}</div></div></article>''')
    if not body:
        body.append('<div class="empty"><h2>还没有订单</h2><p>通过微信付款后，可以在这里查看到账情况和权益时段。</p>'
                    '<a class="button primary" href="/account#plans">查看方案</a></div>')
    content = _heading('微信单次购买', '订单', '查看订单状态、付款结果和已购买的有效期。') + _feedback(notice)
    return _shell('WeekGlass 订单', content + '<section class="sheet list">' + ''.join(body) + '</section>',
                  profile=profile, csrf=csrf, section='orders')


def _detail(title, explanation, form, *, danger=False):
    return (f'<details class="setting{" danger" if danger else ""}"><summary>{title}</summary>'
            f'<p>{explanation}</p>{form}</details>')


def _management_hint(profile, paid, mail):
    if profile['verified_email']:
        badge = _status('已验证', 'success')
        detail = '更换邮箱时需要验证原地址和新地址。' if paid and mail else '当前仍可使用此邮箱和密码登录。'
        label = '更换邮箱' if paid and mail else None
    elif profile['pending_email']:
        badge = _status('未验证', 'warning')
        detail = '验证后可用邮箱找回密码。' if paid and mail else '付款确认后可验证。填错的地址现在就能更正，不会发送验证码。'
        label = '验证邮箱' if paid and mail else '更正邮箱'
    else:
        badge = _status('未绑定', 'neutral')
        detail = '绑定并验证邮箱后可用它找回密码。' if paid and mail else '付款确认后可以绑定邮箱。'
        label = '绑定邮箱' if paid and mail else None
    link = f'<a class="button secondary" href="/account/email">{label}</a>' if label else ''
    return badge, detail, link


def _device_rows(devices, path, csrf, *, admin=False, may_disconnect=True):
    rows = []
    for dev in devices:
        data = {'device_id': dev['device_id']}
        if admin:
            data['action'] = 'revoke_device'
        controls = (f'<details class="device-action"><summary>断开</summary>'
                    + _form(path, csrf, '确认断开', data=data, fields=_password()) + '</details>') if may_disconnect else ''
        rows.append(f'''<div class="device-row"><div><strong>{e(dev['display_name'])}</strong>
          <p>{'Android' if dev['platform'] == 'android' else 'Windows'}　上次连接 {date(dev['last_seen_at'], time=True)}</p></div>
          {controls}</div>''')
    return ''.join(rows) or '<p class="empty-line">还没有已连接的设备。</p>'


def security(profile, csrf, devices, paid, mail, notice):
    badge, detail, email_link = _management_hint(profile, paid, mail)
    aid = profile['account_id']
    handle = visible_username(profile)
    address = profile['verified_email'] or profile['pending_email'] or '未填写邮箱'
    available = '已设置' if profile['recovery_configured'] else '未设置'
    rules = '原账号至少使用 16 个字符。' if profile['legacy_login'] else '8 至 128 个字符，字母、数字、特殊字符至少包含两类。'
    minimum, maximum = (16, 1024) if profile['legacy_login'] else (8, 128)
    pw = (_password() + _password('new_password', '新密码', new=True, min_length=minimum, max_length=maximum)
          + _password('confirm_password', '再次输入新密码', new=True, min_length=minimum, max_length=maximum))
    sensitive = [
        _detail('更改密码', rules + '改密后，其他设备和网页登录都会退出。',
                _form('/account/security/password', csrf, '更改密码', fields=pw, kind='button primary')),
        _detail('生成恢复码', '恢复码可以重设密码。生成新恢复码会替换旧恢复码，请立即保存。',
                _form('/account/security/recovery', csrf, '生成恢复码', fields=_password())),
        _detail('退出其他登录', '断开全部 WeekGlass 应用设备和其他网页登录，保留此浏览器。',
                _form('/account/security/revoke', csrf, '退出其他登录', fields=_password())),
    ]
    connected = _device_rows(devices, '/account/security/device', csrf)
    deletion = _detail('删除云账号', '这会永久删除云端日程、设备和登录信息；本机已保存的日历不受影响。',
        _form('/account/security/delete', csrf, '永久删除云账号', kind='button destructive',
              fields=_password() + f'<label class="field">输入 <code>{e(handle)}</code> 确认'
                                    '<input name="confirmation" autocomplete="off" required maxlength="254"></label>'), danger=True)
    content = _heading('账号管理', '安全设置', '管理登录邮箱、设备和恢复方式。') + _feedback(notice) + f'''
      <div class="bottom-grid settings-grid"><section class="sheet mini"><span class="mini-icon">{icon('shield')}</span>
      <h2>邮箱和账号</h2><div class="inline-meta"><strong class="wrap-text">{e(address)}</strong>{badge}</div>
      <p>{detail}</p>{email_link}<dl class="identity-list"><dt>账号标识</dt><dd><code>{e(profile['username'])}</code></dd>
      <dt>账号 ID</dt><dd><code>{aid}</code></dd><dt>恢复码</dt><dd>{available}</dd></dl></section>
      <section class="sheet mini"><span class="mini-icon">{icon('device')}</span><h2>已连接设备</h2>{connected}</section></div>
      <section class="sheet section settings-list"><h2>密码和会话</h2>{''.join(sensitive)}</section>
      <section class="sheet section settings-list"><h2>账号数据</h2>{deletion}</section>'''
    return _shell('WeekGlass 安全设置', content, profile=profile, csrf=csrf, section='security')


def recovery_key(profile, csrf, key):
    return _shell('保存恢复码', f'''<section class="sheet compact-sheet">{_heading('恢复账号', '保存恢复码', '此恢复码只显示一次。请保存在密码管理器或其他安全位置。')}
      <code class="recovery-key">{e(key)}</code><a href="/account/security" class="button primary">我已保存</a></section>''',
      profile=profile, csrf=csrf, section='security')


def _user_label(row):
    return row['verified_email'] or row['pending_email'] or row['username']


def admin(profile, csrf, rows, audit, query, page, next_page):
    content = _heading('所有者控制台', '云端用户', '查看账号和设备状态，管理登录权限与限时授权。')
    content += f'''<section class="sheet list admin-list"><form class="search" method="get" action="/account/admin">
      <label><span>查找用户</span><input name="q" value="{e(query)}" placeholder="账号、邮箱或 ID" maxlength="254"></label>
      <button type="submit" class="button secondary">{icon('search')}搜索</button></form>'''
    for row in rows:
        href = f"/account/admin/users/{row['account_id']}"
        state = _status('可登录', 'success') if row['enabled'] else _status('已暂停', 'warning')
        content += (f'<article class="admin-row"><div><a href="{href}" class="user-link">{e(_user_label(row))}</a>'
                    f'<p>{date(row["created_at"])} 注册　{row["active_devices"]} 台设备</p></div>{state}'
                    f'<a class="button secondary small" href="{href}">管理</a></article>')
    if not rows:
        content += '<p class="empty-line">未找到符合条件的用户。</p>'
    if page > 1 or next_page:
        nav = ''.join(f'<a href="/account/admin?{e(urlencode({"q": query, "page": p}))}">{label}</a>'
                      for p, label, exists in ((page-1, '上一页', page > 1), (page+1, '下一页', next_page)) if exists)
        content += f'<nav class="pagination" aria-label="页码">{nav}</nav>'
    content += '</section><section class="sheet section settings-list"><h2>最近操作</h2>'
    for item in audit:
        subject = str(item['subject_id']) if not item['username'] else item['username']
        info = f'（{item["days"]} 天）' if item['days'] is not None else ''
        content += (f'<div class="audit-row"><span>{_ADMIN_ACTIONS[item["action"]]}{info} {e(subject)}</span>'
                    f'<time>{date(item["occurred_at"], time=True)}</time></div>')
    content += '</section>' if audit else '<p class="empty-line">还没有管理操作。</p></section>'
    return _shell('WeekGlass 云端用户', content, profile=profile, csrf=csrf, section='admin')


def admin_user(profile, csrf, row, rights, devices, notice):
    uid = row['account_id']
    state = _status('可登录', 'success') if row['enabled'] else _status('已暂停', 'warning')
    back = '<a class="back" href="/account/admin">返回用户列表</a>'
    content = back + _heading('账号详情', _user_label(row), f'{date(row["created_at"])} 注册') + _feedback(notice)
    content += f'''<section class="sheet mini"><div class="inline-meta"><h2>服务状态</h2>{state}</div>
      <dl class="identity-list"><dt>账号 ID</dt><dd><code>{uid}</code></dd><dt>云同步</dt><dd>{_STATES[rights['status']]}</dd>
      <dt>当前权益到期</dt><dd>{date(rights['current_period_end'])}</dd><dt>限时授权截止</dt><dd>{date(row['grant_until'])}</dd>
      <dt>已连接设备</dt><dd>{row['active_devices']}</dd></dl></section>'''
    target = f'/account/admin/users/{uid}'
    can_manage = uid != profile['account_id']
    content += ('<section class="sheet mini section"><h2>已连接设备</h2>'
                + _device_rows(devices, target, csrf, admin=True, may_disconnect=can_manage) + '</section>')
    if can_manage:
        action = 'suspend' if row['enabled'] else 'resume'
        account_help = '暂停将撤销所有登录和链接。本机数据和云端日程都会保留。' if row['enabled'] else '恢复后，用户可以重新登录。'
        manage = [_detail(_ADMIN_ACTIONS[action], account_help, _form(target, csrf, _ADMIN_ACTIONS[action],
                          fields=_password(), data={'action': action})),
                  _detail('撤销会话', '退出该账号的网页登录，并断开所有应用设备。',
                          _form(target, csrf, '撤销会话', fields=_password(), data={'action': 'revoke_devices'})),
                  _detail('设置限时授权', '从现在起授权 1 至 366 天，填写 0 移除授权。不会改动订单或已购买的时段。',
                          _form(target, csrf, '保存授权', fields=(
                              '<label class="field">授权天数<input name="days" type="number" min="0" max="366" required></label>'
                              + _password()), data={'action': 'change_grant'}))]
        content += '<section class="sheet section settings-list"><h2>管理账号</h2>' + ''.join(manage) + '</section>'
    return _shell('WeekGlass 用户详情', content, profile=profile, csrf=csrf, section='admin')
