"""Owner-only WeekGlass operations. Account changes and their audit entry commit together."""
from datetime import datetime, timedelta
import re
import secrets
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from psycopg.errors import UniqueViolation
from psycopg.types.json import Jsonb

from . import account, auth, billing, console_pages as shell, console_sessions as sessions, owner_pages as pages, waffo_runtime
from .console import _form_action, _form_data, _go, _profile, _read, _signed_out, _write_identity
from .db import connect
from .entitlements import entitlement, set_grant_until
from .protocol import now, problem, stamp
from .settings import settings

router = APIRouter(prefix='/account/admin', include_in_schema=False)
_PER_PAGE = 24
_USER_SQL = '''SELECT a.account_id,a.grant_until,a.created_at,u.username,u.pending_email,u.verified_email,u.enabled,
  u.legacy_login,u.credential_version,u.recovery_generation,u.recovery_hash IS NOT NULL AS recovery_configured,u.email_verified_at,
  (SELECT count(*) FROM devices d WHERE d.account_id=a.account_id AND d.revoked_at IS NULL) AS active_devices,
  CASE
    WHEN a.grant_until>now() OR EXISTS (
      SELECT 1 FROM billing_periods p WHERE p.account_id=a.account_id AND p.revoked_at IS NULL
        AND p.start_at<=now() AND p.end_at>now()) THEN 'active'
    WHEN a.grant_until<=now() OR EXISTS (
      SELECT 1 FROM billing_periods p WHERE p.account_id=a.account_id AND least(p.end_at,p.revoked_at)<=now()
        AND least(p.end_at,p.revoked_at)>p.start_at) THEN 'expired'
    ELSE 'not_subscribed' END AS service_status
  FROM accounts a JOIN auth_accounts u USING(account_id)'''
_ORDER_SQL = '''SELECT o.checkout_id,o.account_id,o.status,o.created_at,o.paid_at,o.amount_minor,
  o.period_seconds,o.plan_id,o.terms_version,o.provider,o.merchant_id,o.app_id,o.provider_next_check_at,
  o.provider_last_check_at,o.refund_required,p.start_at,p.end_at,p.revoked_at,
  coalesce(u.verified_email,u.pending_email,u.username) AS account_label
  FROM billing_orders o LEFT JOIN auth_accounts u USING(account_id) LEFT JOIN billing_periods p USING(checkout_id)'''
_AUDIT_SQL = '''SELECT x.*,u.username AS actor_name,t.username AS subject_name FROM (
    SELECT action_id,actor_id,subject_id,'account' AS subject_kind,action,NULL::text AS reason,
      '{}'::jsonb AS details,days,occurred_at,true AS legacy FROM web_owner_actions
    UNION ALL
    SELECT action_id,actor_id,subject_id,subject_kind,action,reason,details,
      NULL::smallint AS days,occurred_at,false AS legacy FROM web_owner_operations
  ) x LEFT JOIN auth_accounts u ON u.account_id=x.actor_id
  LEFT JOIN auth_accounts t ON x.subject_kind='account' AND t.account_id=x.subject_id'''
_AUDIT_ORDER = ' ORDER BY x.occurred_at DESC,x.legacy,x.action_id DESC'
_USER_FILTERS = {'state': ('enabled', 'suspended'), 'service': ('active', 'expired', 'not_subscribed'),
                 'email': ('verified', 'unverified', 'no_email')}
_ORDER_FILTERS = {'state': ('unresolved', 'in_flight', *shell._ORDERS)}
_AUDIT_FILTERS = {'action': pages.ACTIONS, 'scope': ('account', 'order')}


def _owner_read(request, build):
    try:
        with connect() as conn:
            identity = _read(conn, request)
            if not identity:
                return _signed_out('admin')
            if not sessions.is_owner(conn, identity['account_id']):
                auth.fail(403, 'owner_required', '只有 WeekGlass 所有者可以进入管理后台。')
            return build(conn, identity, _profile(conn, identity))
    except HTTPException as exc:
        return shell.problem_page('无法打开管理后台', shell.error_message(exc.detail), status=exc.status_code,
                                  href='/account/admin', button='返回后台概览', headers=exc.headers)


def _filters(request, choices):
    raw = request.query_params
    result = {'q': raw.get('q', '').strip().lower()[:254]}
    result.update({key: raw[key] if raw.get(key) in values else '' for key, values in choices.items()})
    p = raw.get('page', '1')
    result['page'] = max(1, min(int(p), 100000)) if p.isascii() and p.isdecimal() and len(p) <= 6 else 1
    return result


def _paginated(conn, sql, args, filters):
    page = filters['page']
    records = conn.execute(sql + ' LIMIT %s OFFSET %s', (*args, _PER_PAGE+1, (page-1)*_PER_PAGE)).fetchall()
    return records[:_PER_PAGE], len(records) > _PER_PAGE


def _inbox(conn):
    # Match the same statuses and links used by the order list.
    return conn.execute('''SELECT count(*) FILTER (WHERE status IN ('submitting','processing')) AS processing,
      count(*) FILTER (WHERE status='pending') AS pending,
      count(*) FILTER (WHERE status='refund_pending') AS refund_pending
      FROM billing_orders''').fetchone()


@router.get('')
def overview(request: Request):
    def build(conn, identity, profile):
        if request.query_params.get('q') or request.query_params.get('page'):
            return _go(pages.users_url(_filters(request, _USER_FILTERS)))
        metrics = conn.execute('''SELECT count(*) AS accounts,count(*) FILTER (WHERE NOT enabled) AS suspended,
          count(*) FILTER (WHERE created_at>=now()-interval '7 days') AS new_accounts,
          count(*) FILTER (WHERE enabled AND service_status='active') AS active
          FROM (''' + _USER_SQL + ') AS state').fetchone()
        metrics['devices'] = conn.execute('SELECT count(*) AS n FROM devices WHERE revoked_at IS NULL').fetchone()['n']
        audit = conn.execute(_AUDIT_SQL + _AUDIT_ORDER + ' LIMIT 6').fetchall()
        return pages.overview(profile, identity['csrf'], metrics, _inbox(conn), audit)
    return _owner_read(request, build)


@router.get('/users')
def users(request: Request):
    def build(conn, identity, profile):
        f = _filters(request, _USER_FILTERS)
        q = f['q']
        rows, more = _paginated(conn, 'SELECT * FROM (' + _USER_SQL + ''') s
          WHERE (%s='' OR strpos(username,%s)>0 OR strpos(coalesce(verified_email,''),%s)>0
                       OR strpos(coalesce(pending_email,''),%s)>0 OR strpos(account_id::text,%s)>0)
            AND (%s='' OR enabled=(%s='enabled'))
            AND (%s='' OR service_status=%s)
            AND (%s='' OR (CASE WHEN verified_email IS NOT NULL THEN 'verified'
              WHEN pending_email IS NOT NULL THEN 'unverified' ELSE 'no_email' END)=%s)
          ORDER BY created_at DESC,account_id DESC''',
          (q, q, q, q, q, f['state'], f['state'], f['service'], f['service'], f['email'], f['email']), f)
        return pages.users(profile, identity['csrf'], rows, f, more)
    return _owner_read(request, build)


@router.get('/users/new')
def new_user(request: Request):
    return _owner_read(request, lambda c, i, p: pages.new_user(p, i['csrf']))


@router.get('/users/{account_id}')
def user(request: Request, account_id: UUID):
    def build(conn, identity, profile):
        row = conn.execute(_USER_SQL + ' WHERE a.account_id=%s', (account_id,)).fetchone()
        if not row:
            problem(404, 'not_found')
        rights, claim = entitlement(conn, row)
        rights['paid_periods'] = conn.execute('''SELECT checkout_id,start_at,end_at FROM billing_periods
          WHERE account_id=%s AND revoked_at IS NULL AND end_at>now()
          ORDER BY start_at,end_at LIMIT 12''', (account_id,)).fetchall()
        devices = conn.execute('''SELECT device_id,display_name,platform,app_version,last_seen_at,revoked_at
          FROM devices WHERE account_id=%s ORDER BY (revoked_at IS NULL) DESC,last_seen_at DESC LIMIT 30''',
          (account_id,)).fetchall()
        browsers = conn.execute('''SELECT s.session_id,s.created_at,s.expires_at FROM web_sessions s
          WHERE s.account_id=%s AND s.credential_version=%s AND s.expires_at>now()
          ORDER BY (s.session_id=%s) DESC,s.created_at DESC LIMIT 30''',
          (account_id, row['credential_version'], identity['session_id'])).fetchall()
        usage = conn.execute('''SELECT coalesce(sum(payload_bytes),0) AS storage_bytes,
          count(*) FILTER (WHERE record->>'deleted_at_utc' IS NULL) AS events FROM event_heads WHERE account_id=%s''',
          (account_id,)).fetchone()
        usage['last_upload'] = conn.execute('''SELECT max(created_at) AS time FROM changes
          WHERE account_id=%s''', (account_id,)).fetchone()['time']
        orders = conn.execute(_ORDER_SQL + ' WHERE o.account_id=%s ORDER BY o.created_at DESC,o.checkout_id DESC LIMIT 6',
                              (account_id,)).fetchall()
        return pages.user(profile, identity, row, rights, claim, devices, browsers, usage, orders,
                          _filters(request, _USER_FILTERS), request.query_params.get('notice'))
    return _owner_read(request, build)


def _prove_owner(conn, request, form):
    # Only the confirmed owner can consume that owner's password-proof budget.
    auth.checked_origin(request)
    current = sessions.identity(conn, request)
    if not current:
        auth.fail(401, 'unauthenticated', '请先登录 WeekGlass 账号。')
    sessions.require_csrf(current, form['csrf'])
    if not sessions.is_owner(conn, current['account_id']):
        auth.fail(403, 'owner_required', '只有 WeekGlass 所有者可以执行此操作。')
    auth.rate_limit(request, 'owner-admin-proof', 12, str(current['account_id']))
    sessions.lock_owner_changes(conn)
    identity = _write_identity(conn, request, form['csrf'])
    aid = identity['account_id']
    if not sessions.is_owner(conn, aid, lock=True):
        auth.fail(403, 'owner_required', '只有 WeekGlass 所有者可以执行此操作。')
    credentials = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (aid,)).fetchone()
    if not auth.password_matches(credentials, form['current_password']):
        auth.fail(403, 'incorrect_password', '所有者密码不正确。')
    return identity


def _reason(form, extras):
    _form_data(form, ('action', 'current_password', 'reason', *extras))
    reason = form['reason'].strip()
    if not 3 <= len(reason) <= 240 or any(ord(c) < 32 for c in reason):
        auth.fail(422, 'invalid_owner_reason', '请输入 3 至 240 字的理由，不填写密码或恢复码。')
    password = form['current_password']
    if re.search(r'(?i:WG-)[A-Za-z0-9_-]{43}', reason) or password and password in reason:
        auth.fail(422, 'owner_reason_contains_secret', '理由不能包含密码或恢复码。请改填工单编号或原因。')
    return reason


def _audit(conn, identity, action, subject, reason, before, after, *, kind='account'):
    return conn.execute('''INSERT INTO web_owner_operations(actor_id,subject_kind,subject_id,action,reason,details)
      VALUES (%s,%s,%s,%s,%s,%s) RETURNING action_id''', (identity['account_id'], kind, subject, action, reason,
        Jsonb({'before': before, 'after': after}))).fetchone()['action_id']


def _check(expected, actual):
    if expected != actual:
        auth.fail(409, 'owner_stale_state', '记录已更新。请返回详情刷新后，再确认此次操作。')


def _grant_end(raw, instant):
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}', raw):
        auth.fail(422, 'invalid_grant_end', '请选择有效的到期日期和时间。')
    try:
        end = datetime.fromisoformat(raw).replace(tzinfo=pages.CN)
        end + timedelta(seconds=billing.ANNUAL_PERIOD_SECONDS)
        if end > instant:
            return end
    except (ValueError, OverflowError):
        pass
    auth.fail(422, 'invalid_grant_end', '到期时间须晚于现在，并在系统日历的有效范围内。')


@router.post('/users/new')
async def create_user(request: Request):
    return await _form_action(request, _create_user, back='/account/admin/users/new')


def _create_user(request, form):
    reason = _reason(form, ('username',))
    if form['action'] != 'create_account':
        problem(400, 'invalid_request')
    username = form['username'].strip().casefold()
    try:
        with connect() as conn:
            identity = _prove_owner(conn, request, form)
            key = account.recovery_key()
            aid = auth.insert_account(conn, username, secrets.token_urlsafe(32), recovery_hash=auth.hashed(key))
            _audit(conn, identity, 'create_account', aid, reason, {}, {'enabled': True, 'recovery_configured': True})
            profile = _profile(conn, identity)
    except ValueError:
        auth.fail(422, 'invalid_username', '用户名需为 3 至 80 位英文字母、数字或 _.@+-。')
    except UniqueViolation:
        auth.fail(409, 'username_exists', '该用户名已被使用。')
    return pages.recovery(profile, identity['csrf'], aid, username, key, new=True)


@router.post('/users/{account_id}')
async def update_user(request: Request, account_id: UUID):
    return await _form_action(request, _update_user, account_id, back=f'/account/admin/users/{account_id}')


def _session_counts(conn, aid):
    return conn.execute('''SELECT
      (SELECT count(*) FROM devices WHERE account_id=%s AND revoked_at IS NULL) AS devices,
      (SELECT count(*) FROM web_sessions s JOIN auth_accounts u USING(account_id)
        WHERE s.account_id=%s AND s.credential_version=u.credential_version AND s.expires_at>now()) AS browsers''',
      (aid, aid)).fetchone()


def _update_user(request, form, aid):
    action = form.get('action')
    extras = {'suspend': ('expected',), 'resume': ('expected',), 'revoke_devices': (), 'revoke_device': ('device_id',),
              'revoke_session': ('session_id',), 'change_grant': ('expected', 'until'), 'revoke_grant': ('expected',),
              'issue_recovery': ('expected', 'confirmation')}
    if action not in extras:
        problem(400, 'invalid_request')
    reason = _reason(form, extras[action])
    with connect() as conn:
        identity = _prove_owner(conn, request, form)
        own = aid == identity['account_id']
        cloud = conn.execute('SELECT * FROM accounts WHERE account_id=%s FOR UPDATE', (aid,)).fetchone()
        if not cloud:
            problem(404, 'not_found')
        credentials = conn.execute('SELECT * FROM auth_accounts WHERE account_id=%s', (aid,)).fetchone()
        before, after = {}, {}
        if action in ('suspend', 'resume'):
            if own:
                auth.fail(400, 'owner_self_change', '不能暂停或禁用唯一所有者。')
            enabled = credentials['enabled']
            _check(form['expected'], str(int(enabled)))
            if enabled == (action == 'resume'):
                auth.fail(409, 'owner_stale_state', '账号状态已改变，请刷新详情后重试。')
            before = {**_session_counts(conn, aid), 'enabled': enabled}
            auth.lock_account(conn, aid)
            conn.execute('''UPDATE auth_accounts SET enabled=%s,credential_version=credential_version+1
              WHERE account_id=%s''', (not enabled, aid))
            if enabled:
                account.revoke_sessions(conn, aid, credentials_changed=True)
            after = {**_session_counts(conn, aid), 'enabled': not enabled}
        elif action == 'revoke_devices':
            before = _session_counts(conn, aid)
            auth.lock_account(conn, aid)
            account.revoke_sessions(conn, aid, keep_web_session=identity['session_hash'] if own else None)
            after = _session_counts(conn, aid)
        elif action == 'revoke_device':
            did = auth.valid_uuid(form['device_id'])
            active = conn.execute('''SELECT 1 FROM devices WHERE account_id=%s AND device_id=%s AND revoked_at IS NULL''',
                                  (aid, did)).fetchone()
            if not active:
                auth.fail(404, 'not_found', '设备已断开或不属于此账号。请刷新详情。')
            before = _session_counts(conn, aid)
            auth.lock_account(conn, aid)
            auth.disconnect_device(conn, aid, did)
            after = {**_session_counts(conn, aid), 'device_id': did}
        elif action == 'revoke_session':
            sid = auth.valid_uuid(form['session_id'])
            if str(identity['session_id']) == sid:
                auth.fail(400, 'owner_self_change', '当前浏览器会话须通过右上角退出。')
            before = _session_counts(conn, aid)
            deleted = conn.execute('''DELETE FROM web_sessions WHERE account_id=%s AND session_id=%s
              AND expires_at>now() AND credential_version=%s RETURNING session_id''',
              (aid, sid, credentials['credential_version'])).fetchone()
            if not deleted:
                auth.fail(404, 'not_found', '网页登录已退出、已到期或不属于此账号。请刷新详情。')
            after = {**_session_counts(conn, aid), 'session_id': sid}
        elif action in ('change_grant', 'revoke_grant'):
            old = cloud['grant_until']
            _check(form['expected'], stamp(old) if old else '')
            instant = now()
            if action == 'revoke_grant' and (not old or old <= instant):
                auth.fail(409, 'owner_stale_state', '此账号没有有效的赠送期限，请刷新详情。')
            end = _grant_end(form['until'], instant) if action == 'change_grant' else None
            new = set_grant_until(conn, aid, end, instant)['grant_until']
            before = {'grant_until': stamp(old) if old else None, 'gift_active': bool(old and old > instant)}
            after = {'grant_until': stamp(new), 'gift_active': bool(end)}
        else:  # issue_recovery
            if own:
                auth.fail(400, 'owner_self_change', '请在自己的安全设置中生成恢复码。')
            if not credentials['enabled']:
                auth.fail(409, 'account_unavailable', '暂停的账号需先恢复登录，再签发恢复码。')
            if form['confirmation'].strip().casefold() != credentials['username']:
                auth.fail(422, 'confirmation_required', '请输入该账号的用户名以确认。')
            generation = credentials['recovery_generation']
            before = {'recovery_configured': bool(credentials['recovery_hash']), 'recovery_generation': generation}
            _check(form['expected'], pages.recovery_state(credentials['credential_version'], generation))
            key = account.rotate_recovery(conn, aid)
            after = {'recovery_configured': True, 'recovery_generation': generation+1}
            recovery = pages.recovery(_profile(conn, identity), identity['csrf'], aid, credentials['username'], key)
        _audit(conn, identity, action, aid, reason, before, after)
    if action == 'issue_recovery':
        return recovery
    return _go(pages._url(f'/account/admin/users/{aid}', _filters(request, _USER_FILTERS), notice=action))


@router.get('/orders')
def orders(request: Request):
    def build(conn, identity, profile):
        f = _filters(request, _ORDER_FILTERS)
        q = f['q']
        matches = (list(billing.UNRESOLVED) if f['state'] == 'unresolved' else
                   list(billing.IN_FLIGHT) if f['state'] == 'in_flight' else [f['state']])
        rows, more = _paginated(conn, 'SELECT * FROM (' + _ORDER_SQL + ''') o
          WHERE (%s='' OR strpos(checkout_id::text,%s)>0 OR strpos(coalesce(account_id::text,''),%s)>0
                       OR strpos(coalesce(account_label,''),%s)>0)
            AND (%s='' OR status=ANY(%s))
          ORDER BY created_at DESC,checkout_id DESC''', (q, q, q, q, f['state'], matches), f)
        return pages.orders(profile, identity['csrf'], rows, f, more)
    return _owner_read(request, build)


def _can_reconcile(config, row):
    return bool(config and config.scope[0] == billing.WAFFO_LIVE_PROVIDER and billing.same_scope(row, config)
                and row['status'] in billing.IN_FLIGHT and row['provider_next_check_at'])


@router.get('/orders/{checkout_id}')
def order(request: Request, checkout_id: UUID):
    def build(conn, identity, profile):
        row = conn.execute(_ORDER_SQL + ' WHERE o.checkout_id=%s', (checkout_id,)).fetchone()
        if not row:
            problem(404, 'billing_order_not_found')
        refunds = conn.execute('''SELECT status,count(*) AS number,sum(amount_minor) AS amount
          FROM billing_refunds WHERE checkout_id=%s GROUP BY status ORDER BY status''', (checkout_id,)).fetchall()
        events = conn.execute('''SELECT status,max(processed_at) AS latest,count(*) AS number FROM billing_events
          WHERE (provider,merchant_id,app_id)=(%s,%s,%s) AND related_id=%s GROUP BY status ORDER BY status''',
          (row['provider'], row['merchant_id'], row['app_id'], checkout_id)).fetchall()
        return pages.order(profile, identity['csrf'], row, refunds, events, _filters(request, _ORDER_FILTERS),
                           _can_reconcile(request.app.state.billing, row), request.query_params.get('notice'))
    return _owner_read(request, build)


@router.post('/orders/{checkout_id}')
async def update_order(request: Request, checkout_id: UUID):
    return await _form_action(request, _update_order, checkout_id, back=f'/account/admin/orders/{checkout_id}')


def _update_order(request, form, oid):
    action = form.get('action')
    if action not in ('close_order', 'reconcile_order'):
        problem(400, 'invalid_request')
    reason = _reason(form, ('expected',))
    config = request.app.state.billing
    with connect() as conn:
        identity = _prove_owner(conn, request, form)
        if action == 'close_order':
            _, row = billing._lock_target(conn, 'billing_orders', 'checkout_id', oid)
        else:
            row = conn.execute('SELECT * FROM billing_orders WHERE checkout_id=%s', (oid,)).fetchone()
        if not row:
            problem(404, 'billing_order_not_found')
        old = row['status']
        _check(form['expected'], old)
        if action == 'close_order':
            if old != 'pending':
                problem(409, 'billing_order_not_open')
            billing.close_unsubmitted(conn, row, now())
            result = 'close_order'
            entry = {'order_status': row['status']}
        else:
            if not _can_reconcile(config, row):
                auth.fail(409, 'order_check_unavailable', '此订单当前不能通过已配置的渠道核对。')
            entry = {'check_result': 'requested'}
        log_id = _audit(conn, identity, action, oid, reason, {'order_status': old}, entry, kind='order')
    if action == 'reconcile_order':
        # Release the owner and database locks before external I/O. The shared
        # Waffo lease serializes this action against background/browser checks.
        result = waffo_runtime.reconcile_for_operator(config, oid)
        with connect() as conn:
            current = conn.execute('SELECT status FROM billing_orders WHERE checkout_id=%s', (oid,)).fetchone()
            conn.execute('''UPDATE web_owner_operations SET details=jsonb_set(details,'{after}',%s)
              WHERE action_id=%s''', (Jsonb({'check_result': result, 'order_status': current['status']}), log_id))
    return _go(pages._url(f'/account/admin/orders/{oid}', _filters(request, _ORDER_FILTERS), notice=result))


@router.get('/audit')
def audit(request: Request):
    def build(conn, identity, profile):
        f = _filters(request, _AUDIT_FILTERS)
        q = f['q']
        rows, more = _paginated(conn, _AUDIT_SQL + '''
          WHERE (%s='' OR strpos(x.subject_id::text,%s)>0 OR strpos(x.actor_id::text,%s)>0
                   OR strpos(coalesce(u.username,''),%s)>0 OR strpos(coalesce(t.username,''),%s)>0
                   OR strpos(lower(coalesce(x.reason,'')),%s)>0)
            AND (%s='' OR x.action=%s) AND (%s='' OR x.subject_kind=%s)''' + _AUDIT_ORDER,
          (q, q, q, q, q, q, f['action'], f['action'], f['scope'], f['scope']), f)
        return pages.audit(profile, identity['csrf'], rows, f, more)
    return _owner_read(request, build)


@router.get('/service')
def service(request: Request):
    def build(conn, identity, profile):
        config = request.app.state.billing
        migrations = conn.execute('''SELECT migration_id,applied_at FROM schema_migrations
          ORDER BY applied_at DESC,migration_id DESC LIMIT 6''').fetchall()
        last = conn.execute('SELECT max(provider_last_check_at) AS time FROM billing_orders').fetchone()['time']
        return pages.service(profile, identity['csrf'], request.app.version, settings, config,
                             auth.mail_available(), billing.offers(config), _inbox(conn), last, migrations)
    return _owner_read(request, build)
