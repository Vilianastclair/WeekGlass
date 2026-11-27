"""Responsive operations views. All changes are explicit same-origin forms."""
from urllib.parse import urlencode

from . import billing
from .console_pages import (_CN as CN, _ORDERS, _STATES, _feedback, _form, _heading, _password, _shell,
                            _status, amount, date, e)
from .protocol import DEVICE_PLATFORM_LABELS, now, stamp

ACTIONS = {
    'suspend': '暂停账号', 'resume': '恢复登录', 'revoke_devices': '退出所有会话', 'revoke_device': '断开应用设备',
    'revoke_session': '退出网页登录', 'change_grant': '设置赠送权益', 'revoke_grant': '取消赠送权益',
    'create_account': '创建账号', 'issue_recovery': '签发恢复码', 'close_order': '关闭未提交订单',
    'reconcile_order': '向渠道核对订单',
}
_NOTICES = {
    'suspend': '账号已暂停，原会话已撤销。', 'resume': '账号已恢复，可重新登录。',
    'revoke_devices': '会话已退出；若为自己的账号，已保留当前浏览器。',
    'revoke_device': '已断开选定的应用设备。', 'revoke_session': '已退出选定的网页登录。',
    'change_grant': '赠送权益已更新，已购时段不变。', 'revoke_grant': '赠送权益已取消，已购时段不变。',
    'close_order': '订单未提交收银台，现已关闭。',
    'checked': '已向 Waffo 核对。未确认付款的订单仍等待渠道结果。',
    'not_due': '渠道正在核对或刚检查过。请查看当前状态，稍后再试。',
    'unavailable': '暂未取得可验证的渠道响应。订单状态未因连接失败而改变。',
    'unverified': '收到未通过验证的渠道结果。只应用了通过验证的事件，请查看当前状态。',
    'no_link': '此订单从未向收银台发出可用链接，已按现有对账规则结束。',
}
_SECTIONS = (('overview', '', '概览'), ('users', '/users', '用户'), ('orders', '/orders', '订单'),
             ('audit', '/audit', '审计'), ('service', '/service', '运行状态'))
_USER_STATES = {'enabled': '可登录', 'suspended': '已暂停'}
_EMAIL_STATES = {'verified': '已验证', 'unverified': '待验证', 'no_email': '未填写'}
_ORDER_STATES = {'unresolved': '未完成', 'in_flight': '渠道待核对', **_ORDERS}
_REFUND_STATES = {'pending': '处理中', 'succeeded': '已退款', 'failed': '失败'}
_EVENT_STATES = {'applied': '已入账', 'deferred': '待处理', 'rejected': '未通过'}
_OUTCOMES = {'requested': '已开始核对', 'not_due': '等待检查窗口', 'unavailable': '渠道暂无响应',
             'unverified': '有渠道结果未通过验证', 'checked': '渠道核对完成', 'no_link': '未发出可用链接'}
_AUDIT_FIELDS = {'enabled': '允许登录', 'devices': '已连接应用设备', 'browsers': '有效网页登录',
                 'grant_until': '赠送到期', 'gift_active': '有效赠送', 'recovery_configured': '已设置恢复码',
                 'recovery_generation': '恢复码版本',
                 'device_id': '设备 ID', 'session_id': '浏览器会话编号', 'order_status': '订单状态',
                 'check_result': '渠道核对'}


def _url(base, filters=None, **extra):
    values = {**(filters or {}), **extra}
    query = urlencode({key: value for key, value in values.items() if value and not (key == 'page' and value == 1)})
    return base + (f'?{query}' if query else '')


def users_url(filters):
    return _url('/account/admin/users', filters)


def _admin(section, title, profile, csrf, body):
    nav = '<nav class="owner-nav" aria-label="管理后台">' + ''.join(
        '<a href="/account/admin' + path + '"' + (' aria-current="page"' if section == key else '') + f'>{label}</a>'
        for key, path, label in _SECTIONS) + '</nav>'
    return _shell(title, nav + body, profile=profile, csrf=csrf, section='admin')


def _section(title, body, *, cls=''):
    return f'<section class="sheet owner-section {cls}"><h2>{title}</h2>{body}</section>'


def _values(items):
    return '<dl class="identity-list owner-values">' + ''.join(
        f'<dt>{label}</dt><dd>{value}</dd>' for label, value in items) + '</dl>'


def _short_link(path, text):
    return f'<a href="{e(path)}">{e(text)}</a>'


def _button_link(path, text, primary=False):
    return f'<a class="button {"primary" if primary else "secondary"}" href="{e(path)}">{e(text)}</a>'


def _selector(name, label, choices, filters):
    options = '<option value="">全部</option>' + ''.join(
        f'<option value="{e(key)}"' + (' selected' if filters.get(name) == key else '') + f'>{e(value)}</option>'
        for key, value in choices.items())
    return f'<label>{label}<select name="{name}">{options}</select></label>'


def _search(base, filters, placeholder, selectors):
    groups = ''.join(_selector(name, label, choices, filters) for name, label, choices in selectors)
    reset = _short_link(base, '清除筛选') if any(v for key, v in filters.items() if key != 'page') else ''
    return f'''<form class="search owner-search" method="get" action="{base}">
      <label class="search-query">搜索<input name="q" value="{e(filters["q"])}" placeholder="{e(placeholder)}" maxlength="254"></label>
      {groups}<button type="submit" class="button secondary">筛选</button>{reset}</form>'''


def _pages(base, filters, more):
    page = filters['page']
    if page == 1 and not more:
        return ''
    items = ''.join(_short_link(_url(base, filters, page=target), label) for target, enabled, label in
                    ((page-1, page>1, '上一页'), (page+1, more, '下一页')) if enabled)
    return f'<nav class="pagination" aria-label="分页"><span>第 {page} 页</span>{items}</nav>'


def _audit_value(key, value):
    if value is None:
        return '无'
    if type(value) is bool:
        return '是' if value else '否'
    if key == 'grant_until':
        return date(value, time=True)
    if key == 'order_status':
        return _ORDERS.get(value, value)
    if key == 'check_result':
        return _OUTCOMES.get(value, value)
    return value


def _changes(phase, values):
    if not values:
        return ''
    result = ((label, e(_audit_value(key, values[key]))) for key, label in _AUDIT_FIELDS.items() if key in values)
    return f'<div class="audit-diff"><h3>{phase}</h3>{_values(result)}</div>'


def _audit_rows(rows, *, detailed=False):
    body = []
    for row in rows:
        resource = 'orders' if row['subject_kind'] == 'order' else 'users'
        label = row['subject_name'] or str(row['subject_id'])
        subject = (_short_link(f'/account/admin/{resource}/{row["subject_id"]}', label)
                   if row['subject_name'] or row['subject_kind'] == 'order' else e(label))
        caption = f'<strong>{ACTIONS[row["action"]]}</strong><span>{subject}</span>'
        when = f'<time>{date(row["occurred_at"], time=True)}</time>'
        if not detailed:
            body.append(f'<div class="audit-row"><div>{caption}</div>{when}</div>')
            continue
        detail = row['details']
        before = _changes('操作前', detail.get('before', {}))
        after = _changes('操作后', detail.get('after', {}))
        previous = f'<p>赠送期限 {row["days"]} 天</p>' if row['days'] is not None else ''
        actor = e(row['actor_name'] or row['actor_id'])
        reason = e(row['reason'] or '早期记录未保存理由')
        record = f'早期记录 {row["action_id"]}' if row['legacy'] else f'记录 {row["action_id"]}'
        body.append(f'''<article class="owner-audit"><div class="audit-row"><div>{caption}</div>{when}</div>
          <p class="owner-reason">{reason}</p><details><summary>查看变更</summary>
          <p>操作者 {actor}　{record}</p>{previous}
          <div class="audit-pair">{before}{after}</div></details></article>''')
    return ''.join(body) or '<p class="empty-line">还没有符合条件的操作记录。</p>'


def overview(profile, csrf, metrics, inbox, audit):
    headline = _heading('运营概览', 'WeekGlass 管理后台', '从待处理的订单出发，或查看账号、服务和设备。')
    indicators = (
        ('云端账号', metrics['accounts'], f'近 7 天新增 {metrics["new_accounts"]}', '/account/admin/users'),
        ('已开通同步', metrics['active'], '包含已购和赠送时段', '/account/admin/users?state=enabled&service=active'),
        ('应用设备', metrics['devices'], '当前未断开的客户端', '/account/admin/users'),
        ('暂停账号', metrics['suspended'], '登录已停用', '/account/admin/users?state=suspended'),
    )
    cards = ''.join(f'''<a class="sheet owner-kpi" href="{e(path)}"><span>{label}</span>
      <strong>{count}</strong><small>{detail}</small></a>''' for label, count, detail, path in indicators)
    tasks = []
    for key, state, title, detail in (
        ('processing', 'processing', '支付待核对', '查看渠道尚未确认的订单'),
        ('pending', 'pending', '待支付订单', '可关闭尚未送出收银台的订单'),
        ('refund_pending', 'refund_pending', '退款待确认', '查看渠道退款记录'),
    ):
        if inbox[key]:
            link = '/account/admin/orders?state=in_flight' if key == 'processing' else f'/account/admin/orders?state={state}'
            tasks.append(f'''<a class="owner-task" href="{link}"><div><strong>{title}</strong><p>{detail}</p></div>
              {_status(str(inbox[key])+' 笔', 'warning')}</a>''')
    tasks = ''.join(tasks) or '<p class="empty-line">暂时没有待处理的订单。</p>'
    work = _section('订单待办', tasks + _button_link('/account/admin/orders', '查看订单'))
    log = _section('最近操作', _audit_rows(audit) + _button_link('/account/admin/audit', '打开审计'))
    return _admin('overview', 'WeekGlass 管理后台', profile, csrf,
                  headline + f'<div class="owner-kpis">{cards}</div><div class="owner-grid">{work}{log}</div>')


def users(profile, csrf, rows, filters, more):
    start = '/account/admin/users'
    search = _search(start, filters, '用户名、邮箱或账号 ID',
                     (('state', '账号状态', _USER_STATES), ('service', '云同步', {k: _STATES[k] for k in
                      ('active', 'expired', 'not_subscribed')}), ('email', '邮箱验证', _EMAIL_STATES)))
    people = []
    for row in rows:
        uri = _url(f'/account/admin/users/{row["account_id"]}', filters)
        title = row['verified_email'] or row['pending_email'] or row['username']
        label = _USER_STATES['enabled' if row['enabled'] else 'suspended']
        people.append(f'''<article class="owner-row"><div><strong>{_short_link(uri, title)}</strong>
          <p>{date(row['created_at'])} 注册　{row['active_devices']} 台设备</p></div>
          <div class="owner-badges">{_status(label, "success" if row["enabled"] else "warning")}
          {_status(_STATES[row["service_status"]])}</div>{_button_link(uri,'管理')}</article>''')
    results = ''.join(people) or '<p class="empty-line">未找到匹配的账号。</p>'
    return _admin('users', 'WeekGlass 云端用户', profile, csrf,
        '<div class="owner-head">' + _heading('账号管理', '云端用户', '查找账号，管理赠送权益、登录和会话。')
        + _button_link('/account/admin/users/new', '创建账号', True) + '</div>'
        + f'<section class="sheet owner-section">{search}{results}{_pages(start, filters, more)}</section>')


def _action(target, csrf, action, label, *, data=None, fields='', primary=False):
    reason = ('<label class="field">操作理由<input name="reason" required minlength="3" maxlength="240" '
              'placeholder="填写工单或原因，勿填密码或恢复码"></label>')
    return _form(e(target), csrf, label, fields=fields + reason + _password(text='所有者密码'),
                 data={'action': action, **(data or {})}, kind='button primary' if primary else 'button secondary')


def _operation(label, explanation, form):
    return f'<details class="setting owner-operation"><summary>{label}</summary><p>{explanation}</p>{form}</details>'


def recovery_state(version, generation):
    return f'{version}:{generation}'


def new_user(profile, csrf):
    fields = ('<label class="field">用户名<input name="username" required minlength="3" maxlength="80" '
              'spellcheck="false" autocapitalize="none"></label>')
    create = _action('/account/admin/users/new', csrf, 'create_account', '创建并生成恢复码', fields=fields, primary=True)
    return _admin('users', '创建 WeekGlass 账号', profile, csrf,
        _short_link('/account/admin/users', '返回用户列表') + _heading('账号管理', '创建账号',
        '创建一个普通用户。把用户名和一次性恢复码交给本人，由本人设置密码。') + _section('账号资料', create))


def recovery(profile, csrf, aid, username, key, *, new=False):
    copy = ('将用户名与恢复码安全地交给本人；请对方通过「找回密码」设置自己的密码。' if new else
            '新恢复码替换旧码。确认对方身份后，通过安全渠道交给本人；对方使用恢复码后会设置新密码。')
    fields = _values((('用户名', f'<code>{e(username)}</code>'), ('一次性恢复码', f'<code class="owner-code">{e(key)}</code>')))
    body = fields + f'<p class="owner-secret-note">此恢复码只显示这一次。</p>' + _button_link(
        f'/account/admin/users/{aid}', '返回用户详情', True)
    return _admin('users', '交付恢复码', profile, csrf, _heading('账号恢复', '交付恢复码', copy) + _section('账号凭据', body))


def _grant_controls(target, csrf, row):
    old = row['grant_until']
    active = old and old > now()
    data = {'expected': stamp(old) if old else ''}
    current = old.astimezone(CN).strftime('%Y-%m-%dT%H:%M') if active else ''
    fields = f'<label class="field">到期日期和时间（北京时间）<input name="until" type="datetime-local" value="{current}" required></label>'
    set_form = _action(target, csrf, 'change_grant', '保存赠送期限', fields=fields, data=data, primary=True)
    actions = _operation('设置或延长赠送', '按指定时间到期，不收款。已购买的时段仍按原日期生效。', set_form)
    if active:
        actions += _operation('立即取消赠送', '赠送立即到期；已支付时段不变。没有已生效的付费时段时，云同步会暂停。',
                              _action(target, csrf, 'revoke_grant', '取消赠送', data=data))
    return actions


def _devices(target, csrf, devices):
    result = []
    for dev in devices:
        connected = not dev['revoked_at']
        status = _status('已连接', 'success') if connected else _status('已断开')
        title = e(dev['display_name'])
        meta = DEVICE_PLATFORM_LABELS.get(dev['platform'], '其他设备') + (
            f' {e(dev["app_version"])}' if dev['app_version'] else '')
        when = '上次登记 ' + date(dev['last_seen_at'], time=True)
        if not connected:
            when += '，断开于 ' + date(dev['revoked_at'], time=True)
        form = (_operation('断开此设备', '设备须重新登录才能继续同步；本机已保存的日历不会删除。',
                           _action(target, csrf, 'revoke_device', '确认断开', data={'device_id': dev['device_id']}))
                if connected else '')
        result.append(f'<article class="owner-session"><div><strong>{title}</strong>{status}</div><p>{meta}　{when}</p>{form}</article>')
    caption = '<p>最多显示最近 30 个设备。</p>' if len(devices) == 30 else ''
    return (''.join(result) or '<p class="empty-line">没有设备连接记录。</p>') + caption


def _browsers(target, csrf, browsers, current):
    result = []
    for row in browsers:
        own = row['session_id'] == current
        short = str(row['session_id']).split('-', 1)[0]
        title = '当前浏览器' if own else f'网页登录 {short}'
        state = _status('此会话', 'success') if own else ''
        form = ('' if own else _operation('退出此网页登录', '只退出这一个网页登录；应用设备和其他浏览器不受影响。',
                 _action(target, csrf, 'revoke_session', '确认退出', data={'session_id': row['session_id']})))
        result.append(f'''<article class="owner-session"><div><strong>{title}</strong>{state}</div>
          <p>{date(row['created_at'], time=True)} 登录，有效至 {date(row['expires_at'], time=True)}</p>{form}</article>''')
    caption = '<p>最多显示最近 30 个有效会话。</p>' if len(browsers) == 30 else ''
    return (''.join(result) or '<p class="empty-line">没有有效的网页登录。</p>') + caption


def user(profile, identity, row, rights, claim, devices, browsers, usage, orders, filters, notice):
    uid, csrf = row['account_id'], identity['csrf']
    own = uid == identity['account_id']
    name = row['verified_email'] or row['pending_email'] or row['username']
    target = _url(f'/account/admin/users/{uid}', filters)
    base = _short_link(users_url(filters), '返回用户列表') + _heading(
        '账号详情', name, f'{date(row["created_at"])} 注册' + ('　当前所有者' if own else ''))
    email_state = 'verified' if row['verified_email'] else 'unverified' if row['pending_email'] else 'no_email'
    profile_rows = [('用户名', f'<code>{e(row["username"])}</code>'),
                    ('账号 ID', f'<code>{uid}</code>'), ('登录许可', '可登录' if row['enabled'] else '已暂停'),
                    ('邮箱状态', _EMAIL_STATES[email_state]), ('验证时间', date(row['email_verified_at'], time=True)),
                    ('恢复码', '已设置' if row['recovery_configured'] else '未设置'),
                    ('日程用量', f'{usage["events"]} 项，{usage["storage_bytes"]/1048576:.2f} MiB'),
                    ('最近云端上传', date(usage['last_upload'], time=True))]
    account_section = _section('账号与用量', _values(profile_rows))
    if rights['status'] == 'active':
        end_label = '连续服务到期'
    else:
        end_label = '服务结束时间'
    gift = row['grant_until']
    gift_active = gift and gift > now()
    allowance = ('已完成' if claim and claim['completed_at'] else '可自助导出' if
                 rights['status'] == 'expired' and rights['export_allowed'] else '无到期导出待处理')
    periods = rights['paid_periods']
    covered = ''.join(f'''<li>{date(p['start_at'], time=True)} 至 {date(p['end_at'], time=True)}
        {_short_link('/account/admin/orders/'+str(p['checkout_id']), '查看订单')}</li>''' for p in periods)
    services = _values((('云同步权益', _STATES[rights['status']]), (end_label, date(rights['current_period_end'], time=True)),
                        ('赠送权益', ('有效至 ' if gift_active else '已结束于 ') + date(gift, time=True) if gift else '未设置'),
                        ('到期导出', allowance)))
    services += '<h3>已购有效或待生效时段</h3>' + (f'<ul class="owner-periods">{covered}</ul>' if covered else
                                                     '<p>没有有效或待生效的付费时段。</p>')
    services += _grant_controls(target, csrf, row)
    permissions = _operation('退出其他登录' if own else '退出所有登录',
        '断开全部应用设备与其他网页登录，保留此浏览器。' if own else '断开应用设备并退出全部网页登录，不会删除数据。',
        _action(target, csrf, 'revoke_devices', '退出其他登录' if own else '退出所有登录'))
    if not own:
        action = 'suspend' if row['enabled'] else 'resume'
        permissions += _operation(ACTIONS[action], '暂停会退出所有会话，不退款、不删除日程。' if row['enabled'] else
            '恢复后可以重新登录，已撤销的会话不会恢复。', _action(target, csrf, action, ACTIONS[action],
            data={'expected': int(row['enabled'])}))
        if row['enabled']:
            proof = '<label class="field">输入用户名以确认<input name="confirmation" required maxlength="80"></label>'
            permissions += _operation('签发新恢复码', '替换当前恢复码。只有核实账号本人身份后才操作。',
                _action(target, csrf, 'issue_recovery', '生成新恢复码', fields=proof,
                        data={'expected': recovery_state(row['credential_version'], row['recovery_generation'])}))
    else:
        permissions += '<p>' + _short_link('/account/security', '打开自己的安全设置') + '</p>'
    return _admin('users', 'WeekGlass 用户详情', profile, csrf, base + _feedback(_NOTICES.get(notice)) +
        f'<div class="owner-grid">{account_section}{_section("服务权益", services)}</div>'
        f'<div class="owner-grid">{_section("应用设备", _devices(target, csrf, devices))}'
        f'{_section("网页登录", _browsers(target, csrf, browsers, identity["session_id"]))}</div>'
        + _section('登录与恢复', permissions)
        + _section('最近订单', _order_rows(orders) + _button_link(f'/account/admin/orders?q={uid}', '查看该账号订单'))
        + _section('操作历史', _button_link(f'/account/admin/audit?scope=account&q={uid}', '查看账号审计')))


def _order_rows(rows, filters=None):
    body = []
    for row in rows:
        path = _url('/account/admin/orders/' + str(row['checkout_id']), filters)
        retained = row['account_label'] or '账号已解除关联'
        status = row['status']
        badge = _status(_ORDERS[status], 'success' if status == 'paid' else 'warning' if status in billing.UNRESOLVED else 'neutral')
        body.append(f'''<article class="owner-row"><div><strong>{_short_link(path, str(row['period_seconds']//86400) + ' 天云同步')}</strong>
          <p>{e(retained)}　{date(row['created_at'],time=True)}</p><code class="order-id">{row['checkout_id']}</code></div>
          <div class="owner-badges"><strong>¥{amount(row['amount_minor'])}</strong>{badge}</div>{_button_link(path,'详情')}</article>''')
    return ''.join(body) or '<p class="empty-line">没有匹配的订单。</p>'


def orders(profile, csrf, rows, filters, more):
    target = '/account/admin/orders'
    body = _heading('付款与售后', '订单管理', '核对渠道结果，查看入账和退款记录。')
    search = _search(target, filters, '订单号、账号 ID 或邮箱', (('state', '订单状态', _ORDER_STATES),))
    return _admin('orders', 'WeekGlass 订单管理', profile, csrf, body +
        f'<section class="sheet owner-section">{search}{_order_rows(rows, filters)}{_pages(target, filters, more)}</section>')


def order(profile, csrf, row, refunds, events, filters, may_check, notice):
    oid = row['checkout_id']
    status = row['status']
    target = _url(f'/account/admin/orders/{oid}', filters)
    path_back = _url('/account/admin/orders', filters)
    owner = _short_link(f'/account/admin/users/{row["account_id"]}', row['account_label'] or str(row['account_id'])) if row['account_id'] else '账号已解除关联'
    interval = date(row['start_at'], time=True) + ' 至 ' + date(row['end_at'], time=True) if row['end_at'] else '未获得时段'
    if row['revoked_at']:
        interval += '，已撤销'
    data = _values((('订单号', f'<code>{oid}</code>'), ('所属账号', owner), ('金额', '¥'+amount(row['amount_minor'])),
        ('状态', _status(_ORDERS[status], 'success' if status == 'paid' else 'warning')),
        ('已购时段', interval), ('创建时间', date(row['created_at'], time=True)), ('付款确认', date(row['paid_at'], time=True)),
        ('上次渠道核对', date(row['provider_last_check_at'], time=True)), ('计划再次核对',
         date(row['provider_next_check_at'], time=True) if status in billing.IN_FLIGHT else '无')))
    changes = ''
    if may_check:
        changes += _operation('向渠道核对', '通过 Waffo 查单，只认可通过验证的渠道结果。遇到请求失败时不关闭订单。',
            _action(target, csrf, 'reconcile_order', '核对当前订单', data={'expected': status}, primary=True))
    if status == 'pending':
        changes += _operation('关闭未提交订单', '此操作只关闭尚未提交到收银台的订单。处理中或已付款的订单不会关闭。',
            _action(target, csrf, 'close_order', '确认关闭', data={'expected': status}))
    if row['refund_required']:
        changes += '<p class="owner-reason">此订单需要退款核对。只显示渠道验证的退款结果。</p>'
    refund = ''.join(f'<p>{_REFUND_STATES.get(item["status"], "未知")} {item["number"]} 笔，¥{amount(item["amount"])}</p>'
                     for item in refunds) or '<p>没有退款记录。</p>'
    verified = ''.join(f'<p>{_EVENT_STATES.get(item["status"], "未知")} {item["number"]} 条</p>' for item in events)
    audit_link = _button_link(f'/account/admin/audit?scope=order&q={oid}', '查看订单审计')
    return _admin('orders', 'WeekGlass 订单详情', profile, csrf, _short_link(path_back, '返回订单列表') +
        _heading('订单详情', str(row['period_seconds']//86400)+' 天云同步', '订单入账与已购时段') + _feedback(_NOTICES.get(notice)) +
        f'<div class="owner-grid">{_section("账本记录", data+changes)}{_section("退款及渠道事件", refund+verified+audit_link)}</div>')


def audit(profile, csrf, rows, filters, more):
    path = '/account/admin/audit'
    search = _search(path, filters, '账号、订单 ID 或操作理由',
        (('action', '操作', ACTIONS), ('scope', '对象', {'account': '账号', 'order': '订单'})))
    body = _heading('操作记录', '管理审计', '按对象和操作追溯变更，查看处理理由与前后状态。')
    return _admin('audit', 'WeekGlass 管理审计', profile, csrf, body +
        f'<div class="sheet owner-section">{search}{_audit_rows(rows, detailed=True)}{_pages(path, filters, more)}</div>')


def service(profile, csrf, version, settings, config, smtp, offers, inbox, last, migrations):
    intake = config and config.scope[0] == billing.WAFFO_LIVE_PROVIDER
    live = '<p>支付事件接收已配置。网络或渠道的实时状态以订单核对结果为准。</p>' if intake else ''
    offer_names = '、'.join(f'{offer["period_seconds"]//86400} 天 ¥{amount(offer["amount_minor"])}' for offer in offers)
    body = _heading('服务检查', '运行状态', '读取实际生效的运行设置和通道状态。')
    availability = _values((('数据库', _status('可连接', 'success')), ('API 版本', e(version)),
        ('部署模式', '官方托管'), ('用户可自助注册', '是' if settings.registration_enabled else '否'),
        ('邮件验证通道', '已配置' if smtp else '未配置'),
        ('每账号设备数', str(settings.max_devices)), ('云端日程用量上限', f'{settings.storage_bytes//1048576} MiB')))
    payment = _values((('微信单次购买', e(offer_names) if offer_names else '暂停新购或未配置'),
        ('支付事件', '已启用' if intake else '未启用'), ('待核对订单', str(inbox['processing'])),
        ('最近核对', date(last, time=True)))) + live + _button_link('/account/admin/orders?state=in_flight', '查看待核对订单')
    ledger = ''.join(f'<div class="audit-row"><code>{e(row["migration_id"])}</code><time>{date(row["applied_at"],time=True)}</time></div>'
                     for row in migrations)
    return _admin('service', 'WeekGlass 运行状态', profile, csrf, body +
        f'<div class="owner-grid">{_section("账号与数据库", availability)}{_section("收款与核对", payment)}</div>'
        + _section('最近应用的数据库迁移', ledger))
