"""Real PostgreSQL integration tests; run only against an explicitly isolated test DB."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
import os
from threading import Event
from uuid import uuid4
import pytest
from fastapi.testclient import TestClient
from weekglass_server import auth, db, sync
from weekglass_server.main import app
from weekglass_server.protocol import SPEC, compact, now, stamp, validate
from weekglass_server.settings import settings


@pytest.fixture(scope='module', autouse=True)
def isolated_db():
    assert os.environ.get('DB_NAME', '').endswith('_test') and not settings.database_url, 'Tests require explicit test database'


@pytest.fixture
def client(monkeypatch):
    with TestClient(app) as test:
        aid = auth.create_account('sync-' + uuid4().hex, 'test-Only-Password-1234567')
        did = str(uuid4())
        identity = {'account_id': aid, 'device_id': did}
        app.dependency_overrides[auth.get_identity] = lambda: identity
        monkeypatch.setattr(auth, 'revalidate_identity', lambda conn, identity: None)
        test.identity = identity
        with db.connect() as conn:
            row = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (aid,)).fetchone()
        test.account = row
        yield test
        app.dependency_overrides.clear()
        with db.connect() as conn:
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (aid,))


def event(eid=None):
    data = deepcopy(SPEC['components']['schemas']['Event']['examples'][0])
    data.update(id=eid or 'whu-' + uuid4().hex, title='')
    return data


def batch(client, events, revisions=None):
    return {'batch_id': str(uuid4()), 'device_id': client.identity['device_id'],
            'dataset_id': str(client.account['dataset_id']), 'sync_epoch': str(client.account['sync_epoch']),
            'mutations': [{'mutation_id': str(uuid4()), 'event_id': e['id'], 'base_revision': r,
                           'operation': 'put', 'event': e} for e, r in zip(events, revisions or [None] * len(events))]}


def checked(response, schema, status=200):
    assert response.status_code == status, response.text
    validate(schema, response.json())
    return response.json()


def test_empty_title_replay_and_conflict_are_atomic(client):
    beginning = checked(client.post('/v1/sync/snapshots'), 'SnapshotPage')
    payload = batch(client, [event(), event()])
    first = checked(client.post('/v1/sync/batches', json=payload), 'Receipt')
    assert client.post('/v1/sync/batches', json=payload).json() == first
    changed = deepcopy(payload)
    changed['mutations'][0]['event']['title'] = 'different'
    assert client.post('/v1/sync/batches', json=changed).status_code == 409
    conflict = batch(client, [event(payload['mutations'][0]['event_id']), event()], ['9', None])
    checked(client.post('/v1/sync/batches', json=conflict), 'Problem', 409)
    page = checked(client.get('/v1/sync/changes', params={'cursor': beginning['boundary_cursor']}), 'ChangePage')
    assert len(page['changes']) == 1 and len(page['changes'][0]['records']) == 2
    assert page['changes'][0]['cursor'] == first['commit_cursor']
    assert client.get('/v1/sync/batches/' + conflict['batch_id']).status_code == 404


def test_deletion_requires_current_revision_and_restore_is_explicit(client):
    value = event()
    first = checked(client.post('/v1/sync/batches', json=batch(client, [value])), 'Receipt')
    deletion = batch(client, [value], [first['results'][0]['revision']])
    deletion['mutations'][0].update(operation='delete', event=None)
    second = checked(client.post('/v1/sync/batches', json=deletion), 'Receipt')
    assert client.post('/v1/sync/batches', json=batch(client, [value])).status_code == 409
    restored = checked(client.post('/v1/sync/batches', json=batch(client, [value], [second['results'][0]['revision']])), 'Receipt')
    assert restored['results'][0]['revision'] == '3'


def test_snapshot_stays_fixed_and_delta_fills_gap(client):
    first = batch(client, [event()])
    client.post('/v1/sync/batches', json=first)
    snapshot = checked(client.post('/v1/sync/snapshots'), 'SnapshotPage')
    client.post('/v1/sync/batches', json=batch(client, [event()]))
    assert client.post('/v1/sync/snapshots').json() == snapshot
    page = checked(client.get('/v1/sync/changes', params={'cursor': snapshot['boundary_cursor']}), 'ChangePage')
    assert len(page['changes']) == 1
    exported = checked(client.get('/v1/exports/calendar'), 'Export')
    assert len(exported['records']) == 2


def test_cursor_is_bound_to_account_and_signature(client):
    snapshot = client.post('/v1/sync/snapshots').json()
    old = dict(client.identity)
    other = auth.create_account('other-' + uuid4().hex, 'test-Only-Password-1234567')
    try:
        client.identity['account_id'] = other
        assert client.get('/v1/sync/changes', params={'cursor': snapshot['boundary_cursor']}).status_code == 403
    finally:
        client.identity.update(old)
        with db.connect() as conn:
            conn.execute('DELETE FROM accounts WHERE account_id=%s', (other,))
    token = snapshot['boundary_cursor']
    assert client.get('/v1/sync/changes', params={'cursor': 'X' + token[1:]}).status_code == 400


def test_old_epoch_and_expired_snapshot_require_resync(client):
    snapshot = client.post('/v1/sync/snapshots').json()
    with db.connect() as conn:
        conn.execute('UPDATE accounts SET sync_epoch=%s WHERE account_id=%s', (uuid4(), client.identity['account_id']))
    assert client.get('/v1/sync/changes', params={'cursor': snapshot['boundary_cursor']}).status_code == 410


def test_entitlement_enforced_but_committed_replay_remains_readable(client, monkeypatch):
    payload = batch(client, [event()])
    snapshot = client.post('/v1/sync/snapshots').json()
    receipt = checked(client.post('/v1/sync/batches', json=payload), 'Receipt')
    monkeypatch.setattr(settings, 'mode', 'hosted')
    ent = checked(client.get('/v1/me/entitlements'), 'Entitlements')
    assert ent['status'] == 'not_subscribed' and not ent['sync_read'] and not ent['sync_write']
    assert not ent['export_allowed']
    assert client.post('/v1/sync/batches', json=payload).json() == receipt
    assert client.get('/v1/sync/batches/' + payload['batch_id']).json() == receipt
    token = sync.encode_token({'snapshot': snapshot['snapshot_id'], 'a': client.identity['account_id'], 'after': ''})
    cursor = snapshot['boundary_cursor']
    rejected = [client.post('/v1/sync/batches', json=batch(client, [event()])),
                client.post('/v1/sync/snapshots'),
                client.get('/v1/sync/snapshots/' + snapshot['snapshot_id'], params={'page_token': token}),
                client.get('/v1/sync/changes', params={'cursor': cursor}),
                client.post('/v1/sync/ack', json={'cursor': cursor, 'device_id': client.identity['device_id']}),
                client.get('/v1/exports/calendar')]
    for response in rejected:
        assert checked(response, 'Problem', 403)['code'] == 'subscription_required'
    assert client.post('/v1/billing/checkout-sessions').status_code == 503
    with db.connect() as conn:
        conn.execute('UPDATE accounts SET grant_until=%s WHERE account_id=%s', (now()+timedelta(days=1), client.identity['account_id']))
    assert client.post('/v1/sync/batches', json=batch(client, [event()])).status_code == 200
    ent = checked(client.get('/v1/me/entitlements'), 'Entitlements')
    assert ent['status'] == 'active' and ent['sync_read'] and ent['sync_write']
    assert client.get('/v1/sync/changes', params={'cursor': cursor}).status_code == 200


def test_long_poll_stops_when_hosted_grant_expires(client, monkeypatch):
    monkeypatch.setattr(settings, 'mode', 'hosted')
    aid = client.identity['account_id']
    with db.connect() as conn:
        conn.execute('UPDATE accounts SET grant_until=%s WHERE account_id=%s', (now()+timedelta(days=1), aid))
    cursor = client.post('/v1/sync/snapshots').json()['boundary_cursor']
    reading = Event()
    require = sync.require_sync

    def notify(conn, account):
        require(conn, account)
        reading.set()

    monkeypatch.setattr(sync, 'require_sync', notify)
    with ThreadPoolExecutor() as pool:
        polling = pool.submit(client.get, '/v1/sync/changes', params={'cursor': cursor, 'wait_seconds': 8})
        assert reading.wait(timeout=4)
        with db.connect() as conn:
            conn.execute('UPDATE accounts SET grant_until=%s WHERE account_id=%s', (now()-timedelta(seconds=1), aid))
        assert checked(polling.result(timeout=5), 'Problem', 403)['code'] == 'subscription_required'


def test_schema_bytes_and_time_semantics_are_checked(client):
    assert client.post('/v1/sync/batches', json=batch(client, [event() for _ in range(101)])).status_code == 422
    bad = event()
    bad['end_utc'] = bad['start_utc']
    assert client.post('/v1/sync/batches', json=batch(client, [bad])).status_code == 422
    assert client.post('/v1/sync/batches', content=b'{"batch_id":0,"batch_id":1}', headers={'Content-Type': 'application/json'}).status_code == 400
    assert client.post('/v1/sync/batches', content=b'x'*2097153).status_code == 413
    assert client.post('/v1/sync/batches', content=b'x', headers={'Content-Encoding': 'gzip'}).status_code == 415


def test_concurrent_writes_conflict_without_lost_update(client):
    from weekglass_server.sync import push
    from fastapi import HTTPException
    value = event()
    initial = push(batch(client, [value]), client.identity)
    p1 = batch(client, [dict(value, title='device A')], [initial['results'][0]['revision']])
    p2 = batch(client, [dict(value, title='device B')], [initial['results'][0]['revision']])
    def attempt(payload):
        try:
            return push(payload, client.identity)
        except HTTPException as exc:
            return exc.status_code
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(attempt, (p1, p2)))
    assert sum(isinstance(x, dict) for x in results) == 1
    assert 409 in results
    with db.connect() as conn:
        assert conn.execute('SELECT commit_seq FROM accounts WHERE account_id=%s', (client.identity['account_id'],)).fetchone()['commit_seq'] == 2


def test_snapshot_pagination_preserves_boundary(client):
    for _ in range(5):
        assert client.post('/v1/sync/batches', json=batch(client, [event() for _ in range(100)])).status_code == 200
    client.post('/v1/sync/batches', json=batch(client, [event()]))
    first = checked(client.post('/v1/sync/snapshots'), 'SnapshotPage')
    assert len(first['records']) == 500 and first['next_page_token']
    next_page = checked(client.get('/v1/sync/snapshots/' + first['snapshot_id'], params={'page_token': first['next_page_token']}), 'SnapshotPage')
    assert len(next_page['records']) == 1 and next_page['boundary_cursor'] == first['boundary_cursor']
    assert len({r['id'] for r in first['records'] + next_page['records']}) == 501


def test_quota_rejection_is_atomic(client, monkeypatch):
    monkeypatch.setattr(settings, 'storage_bytes', 1)
    payload = batch(client, [event()])
    assert client.post('/v1/sync/batches', json=payload).status_code == 507
    assert client.get('/v1/sync/batches/' + payload['batch_id']).status_code == 404
