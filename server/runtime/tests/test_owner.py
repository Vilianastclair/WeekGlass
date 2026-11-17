"""WeekGlass owner operations against a dedicated PostgreSQL test database."""
from datetime import timedelta, timezone
import re
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
import psycopg
import pytest
from psycopg import sql

from test_auth import account, client, headers, running_client, tokens_for
from test_console import PASSWORD, attach_web_session, authorize, csrf, owner_submit, sign_in, submit
from test_waffo_runtime import ORIGIN, checkout, official, open_order
from weekglass_server import account as account_service, auth
from weekglass_server import owner as owner_routes
from weekglass_server.db import connect
from weekglass_server.entitlements import set_grant
from weekglass_server.migrations import migrate_account_console, migrate_owner_console
from weekglass_server.protocol import now, stamp
from weekglass_server.settings import settings
from weekglass_server.waffo import BridgeError


@pytest.fixture(autouse=True)
def hosted(monkeypatch):
    monkeypatch.setattr(settings, 'mode', 'hosted')


@pytest.fixture
def operator(client, account):
    aid, username, password = account
    with connect() as conn:
        conn.execute('INSERT INTO web_owner(account_id) VALUES (%s)', (aid,))
    sign_in(client, username, password)
    yield aid, username, password
    with connect() as conn:
        conn.execute('DELETE FROM web_owner_operations WHERE actor_id=%s', (aid,))


def future(days=900):
    china = timezone(timedelta(hours=8))
    return (now().astimezone(china) + timedelta(days=days)).strftime('%Y-%m-%dT%H:%M')


def test_overview_and_pages_require_owner_even_if_path_known(client, account, operator):
    aid, _, _ = operator
    public = TestClient(client.app, base_url=settings.public_origin, follow_redirects=False)
    targets = {'': 'WeekGlass 管理后台', '/users': '云端用户', '/users/new': '创建账号',
               f'/users/{aid}': '服务权益', '/orders': '订单管理', '/audit': '管理审计', '/service': '运行状态'}
    try:
        assert public.get('/account/admin').headers['location'] == '/account/login?next=admin'
        outsider = auth.create_account('other-admin-test-'+uuid4().hex, PASSWORD)
        attach_web_session(public, outsider)
        for suffix, title in targets.items():
            path = '/account/admin' + suffix
            assert public.get(path).status_code == 403
            response = client.get(path)
            assert response.status_code == 200 and title in response.text
            assert 'aria-label="管理后台"' in response.text
        assert public.get('/account/admin/orders/' + str(uuid4())).status_code == 403
        token = csrf(public.get('/account'))
        for _ in range(13):
            denied = owner_submit(public, f'/account/admin/users/{aid}', token, 'change_grant', expected='', until=future())
            assert denied.status_code == 403
        with connect() as conn:
            assert not conn.execute('SELECT 1 FROM auth_rate_limits WHERE bucket=%s',
                (auth.hashed('owner-admin-proof:'+aid),)).fetchone()
        home = client.get('/account/admin')
        assert '/account/admin/users?state=suspended' in home.text
        assert client.get('/account/admin', params={'q': aid}).headers['location'].startswith('/account/admin/users?q=')
    finally:
        public.close()
        if 'outsider' in locals():
            with connect() as conn:
                conn.execute('DELETE FROM accounts WHERE account_id=%s', (outsider,))


def test_owner_can_extend_and_remove_own_gift_while_stale_and_failed_writes_roll_back(client, operator, monkeypatch):
    aid, username, password = operator
    target = f'/account/admin/users/{aid}'
    token = csrf(client.get(target))
    tokens = tokens_for(client, operator)
    assert '设置或延长赠送' in client.get(target).text
    distant = future(1100)
    recovery = account_service.recovery_key()
    for detail in ('误贴恢复码 '+recovery, '误贴密码 '+password):
        blocked = owner_submit(client, target, token, 'change_grant', password, expected='', until=distant, reason=detail)
        assert blocked.status_code == 422 and recovery not in blocked.text and password not in blocked.text
    created = owner_submit(client, target, token, 'change_grant', password, expected='', until=distant,
                           reason='自用长期赠送测试')
    assert created.status_code == 303 and '赠送权益已更新' in client.get(created.headers['location']).text
    with connect() as conn:
        before = conn.execute('SELECT grant_until FROM accounts WHERE account_id=%s', (aid,)).fetchone()['grant_until']
    assert before > now() + timedelta(days=1099)
    rights = client.get('/v1/me/entitlements', headers=headers(tokens)).json()
    assert rights['sync_read'] and rights['sync_write']
    stale = owner_submit(client, target, token, 'change_grant', password, expected='', until=future(1200))
    assert stale.status_code == 409 and '刷新' in stale.text
    assert owner_submit(client, target, token, 'change_grant', password, expected=stamp(before),
                        until='2001-01-01T00:00').status_code == 422
    assert owner_submit(client, target, token, 'change_grant', password, expected=stamp(before),
                        until='9999-12-31T23:59').status_code == 422
    with monkeypatch.context() as fault:
        def unavailable(*_args, **_kwargs):
            raise psycopg.OperationalError('synthetic audit insert failure')
        fault.setattr(owner_routes, '_audit', unavailable)
        stopped = owner_submit(client, target, token, 'change_grant', password, expected=stamp(before), until=future(1200))
        assert stopped.status_code == 503
    with connect() as conn:
        unchanged = conn.execute('SELECT grant_until FROM accounts WHERE account_id=%s', (aid,)).fetchone()['grant_until']
        assert unchanged == before
        logs = conn.execute('SELECT reason,details FROM web_owner_operations WHERE actor_id=%s', (aid,)).fetchall()
        assert len(logs) == 1 and logs[0]['reason'] == '自用长期赠送测试'
        assert logs[0]['details'] == {'before': {'grant_until': None, 'gift_active': False},
                                      'after': {'grant_until': stamp(before), 'gift_active': True}}
    ended = owner_submit(client, target, token, 'revoke_grant', password, expected=stamp(before), reason='<script>测试理由</script>')
    assert ended.status_code == 303
    rights = client.get('/v1/me/entitlements', headers=headers(tokens)).json()
    assert rights['status'] == 'expired' and not rights['sync_read'] and rights['export_allowed']
    audit = client.get('/account/admin/audit', params={'scope': 'account', 'q': aid, 'action': 'revoke_grant'}).text
    assert '取消赠送权益' in audit and '操作前' in audit and '操作后' in audit
    assert '&lt;script&gt;测试理由&lt;/script&gt;' in audit and '<script>测试理由</script>' not in audit
    assert profile_kept(client) and client.get(target).status_code == 200
    delete = client.request('DELETE', '/v1/me/account', headers=headers(tokens),
                            json={'current_password': password, 'confirmation': username})
    assert delete.status_code == 409 and delete.json()['code'] == 'owner_account_protected'
    assert submit(client, '/account/security/delete', token, current_password=password,
                  confirmation=username).status_code == 409


def profile_kept(client):
    return client.get('/account/security').status_code == 200


def test_owner_provisions_and_recovers_account_without_storing_recovery_proof_in_audit(client, operator):
    aid, _, password = operator
    name = 'created-'+uuid4().hex
    token = csrf(client.get('/account/admin/users/new'))
    created = owner_submit(client, '/account/admin/users/new', token, 'create_account', password, username=name)
    assert created.status_code == 200 and created.headers['cache-control'] == 'no-store'
    key = re.search(r'<code class="owner-code">(WG-[^<]+)</code>', created.text).group(1)
    with connect() as conn:
        uid = conn.execute('SELECT account_id FROM auth_accounts WHERE username=%s', (name,)).fetchone()['account_id']
    user = TestClient(client.app, base_url=settings.public_origin, follow_redirects=False)
    try:
        target = f'/account/admin/users/{uid}'
        assert '未开通' in client.get(target).text
        assert owner_submit(client, '/account/admin/users/new', token, 'create_account', password,
                            username=name).status_code == 409
        recovered = authorize(user, 'recover', csrf(user.get('/account/recover')), username=name, recovery_key=key,
                              password=PASSWORD, confirm_password=PASSWORD)
        assert recovered.status_code == 200 and '我已保存，进入控制台' in recovered.text
        assert authorize(user, 'continue', csrf(recovered)).status_code == 303
        assert user.get('/account').status_code == 200
        assert user.get('/account/admin').status_code == 403
        with connect() as conn:
            current = conn.execute('''SELECT credential_version,recovery_generation FROM auth_accounts
              WHERE account_id=%s''', (uid,)).fetchone()
        expected = f'{current["credential_version"]}:{current["recovery_generation"]}'
        token = csrf(client.get(target))
        assert owner_submit(client, target, token, 'issue_recovery', password, confirmation='wrong',
                            expected=expected).status_code == 422
        issued = owner_submit(client, target, token, 'issue_recovery', password, confirmation=name, expected=expected)
        assert issued.status_code == 200 and '替换旧码' in issued.text
        assert owner_submit(client, target, token, 'issue_recovery', password, confirmation=name, expected=expected).status_code == 409
        new_key = re.search(r'<code class="owner-code">(WG-[^<]+)</code>', issued.text).group(1)
        assert new_key != key
        audit = client.get('/account/admin/audit', params={'q': str(uid)}).text
        assert '创建账号' in audit and '签发恢复码' in audit and key not in audit and new_key not in audit
        assert new_key not in client.get(target).text
        with connect() as conn:
            logs = conn.execute('SELECT details FROM web_owner_operations WHERE actor_id=%s AND subject_id=%s', (aid, uid)).fetchall()
            assert len(logs) == 2 and all(new_key not in str(row) and key not in str(row) for row in logs)
    finally:
        user.close()
        with connect() as conn:
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (uid,))


def test_owner_can_exit_one_browser_without_revoking_app_devices_or_itself(client, operator):
    aid, username, password = operator
    tokens = tokens_for(client, operator)
    browser = TestClient(client.app, base_url=settings.public_origin, follow_redirects=False)
    try:
        sign_in(browser, username, password)
        target = f'/account/admin/users/{aid}'
        page = client.get(target)
        assert all(label in page.text for label in ('应用设备', '网页登录', '当前浏览器'))
        token = csrf(page)
        active = client.cookies.get('__Host-wg-account')
        secondary = browser.cookies.get('__Host-wg-account')
        with connect() as conn:
            session = conn.execute('SELECT session_id FROM web_sessions WHERE session_hash=%s',
                                   (auth.hashed(secondary),)).fetchone()['session_id']
            current = conn.execute('SELECT session_id FROM web_sessions WHERE session_hash=%s',
                                   (auth.hashed(active),)).fetchone()['session_id']
        assert token and active not in page.text and auth.hashed(secondary) not in page.text
        assert owner_submit(client, target, token, 'revoke_session', password, session_id=str(current)).status_code == 400
        assert owner_submit(client, target, token, 'revoke_session', password, session_id=str(session)).status_code == 303
        assert browser.get('/account').status_code == 303
        assert client.get('/account/admin').status_code == 200
        assert client.get('/v1/devices', headers=headers(tokens)).status_code == 200
        sign_in(browser, username, password)
        assert owner_submit(client, target, token, 'revoke_devices', password).status_code == 303
        assert browser.get('/account').status_code == 303
        assert client.get('/account/admin').status_code == 200
        assert client.get('/v1/devices', headers=headers(tokens)).status_code == 401
    finally:
        browser.close()


def test_owner_order_uses_channel_evidence_and_gift_never_rewrites_paid_period(official, monkeypatch):
    browser = official.client
    buyer = official.users[0][0]
    oid, path = open_order(official, checkout(official, user=0))
    assert browser.post(path + '/provider', headers={'Origin': ORIGIN}).status_code == 200
    aid = auth.create_account('ops-'+uuid4().hex, PASSWORD)
    with connect() as conn:
        conn.execute('INSERT INTO web_owner(account_id) VALUES (%s)', (aid,))
    try:
        attach_web_session(browser, aid)
        target = f'/account/admin/orders/{oid}'
        order = browser.get(target)
        assert order.status_code == 200 and '核对当前订单' in order.text
        assert '退款及渠道事件' in order.text and '关闭未提交订单' not in order.text
        assert oid in browser.get('/account/admin/orders?state=in_flight').text
        token = csrf(order)
        assert owner_submit(browser, target, token, 'close_order', expected='processing').status_code == 409
        paused = owner_submit(browser, target, token, 'reconcile_order', expected='processing')
        assert paused.status_code == 303 and 'notice=not_due' in paused.headers['location']
        assert not official.adapter.queries
        with connect() as conn:
            conn.execute('''UPDATE billing_orders SET provider_last_check_at=now()-interval '2 minutes',
              provider_next_check_at=now()+interval '1 day' WHERE checkout_id=%s''', (oid,))
        with monkeypatch.context() as fault:
            def unavailable(_row):
                raise BridgeError('synthetic link outage')
            fault.setattr(official.adapter, 'query_events', unavailable)
            unavailable_result = owner_submit(browser, target, token, 'reconcile_order', expected='processing')
            assert unavailable_result.status_code == 303 and 'notice=unavailable' in unavailable_result.headers['location']
        with connect() as conn:
            order_before = conn.execute('SELECT status,paid_at FROM billing_orders WHERE checkout_id=%s', (oid,)).fetchone()
            assert order_before == {'status': 'processing', 'paid_at': None}
            conn.execute('UPDATE billing_orders SET provider_last_check_at=now()-interval \'2 minutes\' WHERE checkout_id=%s', (oid,))
        official.adapter.queried_events[UUID(oid)] = [official.adapter.event('payment_paid', oid)]
        checked = owner_submit(browser, target, token, 'reconcile_order', expected='processing')
        assert checked.status_code == 303 and 'notice=checked' in checked.headers['location']
        assert len(official.adapter.queries) == 1
        assert '已支付' in browser.get(checked.headers['location']).text
        with connect() as conn:
            paid = conn.execute('SELECT * FROM billing_periods WHERE checkout_id=%s', (oid,)).fetchone()
        buyer_page = f'/account/admin/users/{buyer}'
        assert '已购有效或待生效时段' in browser.get(buyer_page).text
        created_gift = owner_submit(browser, buyer_page, token, 'change_grant', expected='', until=future())
        assert created_gift.status_code == 303
        with connect() as conn:
            gift = conn.execute('SELECT grant_until FROM accounts WHERE account_id=%s', (buyer,)).fetchone()['grant_until']
        assert owner_submit(browser, buyer_page, token, 'revoke_grant', expected=stamp(gift)).status_code == 303
        rights = browser.get('/v1/me/entitlements', headers=official.users[0][1]).json()
        assert rights['sync_read'] and rights['current_period_end'] == stamp(paid['end_at'])
        with connect() as conn:
            assert paid == conn.execute('SELECT * FROM billing_periods WHERE checkout_id=%s', (oid,)).fetchone()
        assert owner_submit(browser, target, token, 'reconcile_order', expected='processing').status_code == 409
        # A fresh unsubmitted order can be closed without any provider call.
        fresh = checkout(official, user=0).json()['checkout_id']
        closed = owner_submit(browser, '/account/admin/orders/' + fresh, token, 'close_order', expected='pending')
        assert closed.status_code == 303 and '已关闭' in browser.get(closed.headers['location']).text
        audit = browser.get('/account/admin/audit', params={'scope': 'order', 'q': oid}).text
        assert '渠道暂无响应' in audit and '渠道核对完成' in audit and '已支付' in audit
    finally:
        with connect() as conn:
            conn.execute('DELETE FROM web_owner_operations WHERE actor_id=%s', (aid,))
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (aid,))


def test_owner_migration_preserves_old_role_sessions_audit_and_grant(client):
    namespace = sql.Identifier('owner_migration_' + uuid4().hex)
    aid = uuid4()
    expires, grant = now()+timedelta(hours=9), now()+timedelta(days=20)
    with connect() as conn, conn.transaction(force_rollback=True):
        conn.execute(sql.SQL('CREATE SCHEMA {}').format(namespace))
        conn.execute(sql.SQL('SET LOCAL search_path TO {}').format(namespace))
        conn.execute('''CREATE TABLE schema_migrations(migration_id text PRIMARY KEY);
          CREATE TABLE accounts(account_id uuid PRIMARY KEY,grant_until timestamptz);
          CREATE TABLE auth_accounts(account_id uuid PRIMARY KEY,username text NOT NULL);
          CREATE TABLE auth_grants(management_only boolean,redirect_uri text,challenge text,state text);''')
        migrate_account_console(conn)
        conn.execute('INSERT INTO accounts VALUES (%s,%s)', (aid, grant))
        conn.execute('INSERT INTO auth_accounts VALUES (%s,%s)', (aid,'migration-fixture'))
        conn.execute('INSERT INTO web_owner(account_id) VALUES (%s)', (aid,))
        conn.execute('INSERT INTO web_sessions VALUES (%s,%s,0,%s)', ('legacy-session', aid, expires))
        conn.execute('''INSERT INTO web_owner_actions(actor_id,subject_id,action,days)
                     VALUES (%s,%s,'change_grant',366)''', (aid, aid))
        migrate_owner_console(conn)
        migrate_owner_console(conn)
        row = conn.execute('SELECT * FROM web_sessions WHERE session_hash=%s', ('legacy-session',)).fetchone()
        assert row['account_id'] == aid and row['session_id'] and row['expires_at'] == expires
        assert row['created_at'] == expires - timedelta(hours=12)
        assert conn.execute('SELECT account_id FROM web_owner').fetchone()['account_id'] == aid
        assert conn.execute('SELECT grant_until FROM accounts').fetchone()['grant_until'] == grant
        old = conn.execute('SELECT * FROM web_owner_actions').fetchone()
        assert old['days'] == 366 and old['action'] == 'change_grant'
        conn.execute('''INSERT INTO web_owner_operations(actor_id,subject_id,subject_kind,action,reason,details)
                     VALUES (%s,%s,'account','revoke_grant','复查旧镜像兼容','{}')''', (aid, aid))
        # The rollback console keeps reading only names it understands.
        assert conn.execute('SELECT action FROM web_owner_actions ORDER BY action_id DESC').fetchall() == [{'action':'change_grant'}]
        history = conn.execute(owner_routes._AUDIT_SQL + owner_routes._AUDIT_ORDER).fetchall()
        assert [(item['action'], item['legacy']) for item in history] == [('revoke_grant', False), ('change_grant', True)]
        # Old image field lists still insert on the additive schema.
        conn.execute('''INSERT INTO web_sessions(session_hash,account_id,credential_version,expires_at)
                     VALUES (%s,%s,0,%s)''', ('after-rollback', aid, expires))
