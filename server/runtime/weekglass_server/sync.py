from datetime import date, datetime, timedelta
import asyncio
import hashlib
import time
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import psycopg
from psycopg.types.json import Jsonb
import rfc8785
from fastapi import APIRouter, Depends, Query, Request, Response
from starlette.concurrency import run_in_threadpool
from .auth import get_identity
from . import auth, calendar_export
from .billing import billing_capabilities, WAFFO_LIVE_PROVIDER
from .db import connect
from .entitlements import allow_sync, entitlement
from .settings import settings, request_origin
from .protocol import LIMITS, body, compact, cursor, decode_token, encode_token, now, parse_cursor, problem, stamp

router = APIRouter(prefix='/v1')
SLEEP_REVISION_PATTERN = r'^(unknown|none|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'


def account_for(conn, identity, lock=False):
    row = conn.execute('SELECT * FROM accounts WHERE account_id=%s' + (' FOR UPDATE' if lock else ''),
                       (identity['account_id'],)).fetchone()
    if not row:
        problem(401, 'account_unavailable')
    auth.revalidate_identity(conn, identity)
    return row


def require_sync(conn, account):
    if not allow_sync(conn, account):
        problem(403, 'subscription_required')


@router.get('/server-info')
def server_info(request: Request):
    origin = request_origin(request)
    config = request.app.state.billing
    flags = billing_capabilities(config)
    if config and config.scope[0] == WAFFO_LIVE_PROVIDER and origin != config.origin:
        flags = ['subscription']
    return {'protocol_version': '1', 'server_id': settings.server_id, 'mode': settings.mode,
            'server_time': stamp(), 'api_base_url': origin + '/v1',
            'authorization_endpoint': origin + '/v1/auth/authorize',
            'token_endpoint': origin + '/v1/auth/token',
            'capabilities': ['atomic_batches', 'delta_pull', 'snapshot', 'export', 'account_management', 'recovery_key', 'sleep_schedule', 'teaching_terms'] +
                            (['registration'] if settings.registration_enabled else []) +
                            flags, 'limits': LIMITS}


@router.get('/me/entitlements')
def entitlements(identity=Depends(get_identity)):
    with connect() as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        rights, _ = entitlement(conn, account_for(conn, identity))
        return rights


def validate_event(event):
    if len(compact(event)) > 131072:
        problem(413, 'event_too_large')
    try:
        ZoneInfo(event['time_zone_id'])
    except (ZoneInfoNotFoundError, ValueError):
        problem(422, 'unknown_time_zone')
    start = event['all_day_start'] if event['is_all_day'] else event['start_utc']
    end = event['all_day_end_exclusive'] if event['is_all_day'] else event['end_utc']
    if datetime.fromisoformat(end.replace('Z', '+00:00')) <= datetime.fromisoformat(start.replace('Z', '+00:00')):
        problem(422, 'invalid_interval')


def push(data, identity):
    if data['device_id'] != identity['device_id']:
        problem(403, 'device_mismatch')
    mutations = data['mutations']
    if len({m['event_id'] for m in mutations}) != len(mutations) or len({m['mutation_id'] for m in mutations}) != len(mutations):
        problem(422, 'duplicate_batch_entity_or_mutation')
    for mutation in mutations:
        if mutation['event'] is not None:
            if mutation['event']['id'] != mutation['event_id']:
                problem(422, 'event_id_mismatch')
            validate_event(mutation['event'])
    try:
        request_hash = hashlib.sha256(rfc8785.dumps(data)).hexdigest()
    except (ValueError, UnicodeError):
        problem(422, 'invalid_canonical_json')
    with connect() as conn:
        account = account_for(conn, identity, lock=True)
        aid = account['account_id']
        if data['dataset_id'] != str(account['dataset_id']) or data['sync_epoch'] != str(account['sync_epoch']):
            problem(410, 'epoch_mismatch')
        previous = conn.execute('SELECT * FROM receipts WHERE account_id=%s AND batch_id=%s', (aid, data['batch_id'])).fetchone()
        if previous:
            if previous['request_hash'] != request_hash:
                problem(409, 'idempotency_key_reused')
            return previous['receipt']
        require_sync(conn, account)
        duplicate = conn.execute('SELECT 1 FROM mutation_ids WHERE account_id=%s AND mutation_id=ANY(%s::uuid[]) LIMIT 1',
                                 (aid, [m['mutation_id'] for m in mutations])).fetchone()
        if duplicate:
            problem(409, 'mutation_id_reused')
        conflicts = []
        existing = {r['event_id']: r for r in conn.execute('SELECT * FROM event_heads WHERE account_id=%s AND event_id=ANY(%s)',
                    (aid, [m['event_id'] for m in mutations])).fetchall()}
        heads = {m['event_id']: existing.get(m['event_id']) for m in mutations}
        for mutation in mutations:
            current = heads[mutation['event_id']]
            revision = str(current['revision']) if current else None
            if revision != mutation['base_revision']:
                conflicts.append({'mutation_id': mutation['mutation_id'], 'event_id': mutation['event_id'],
                                  'reason': 'not_found' if not current else 'already_exists' if mutation['base_revision'] is None else
                                  'deleted' if current['record']['deleted_at_utc'] else 'revision_mismatch',
                                  'current': current['record'] if current else None})
        if conflicts:
            problem(409, 'revision_conflict', conflicts=conflicts)
        seq, committed = account['commit_seq'] + 1, stamp()
        records = [{'id': m['event_id'], 'revision': str(seq), 'deleted_at_utc': committed if m['operation'] == 'delete' else None,
                    'event': m['event']} for m in mutations]
        size_change = sum(len(compact(r)) - (heads[r['id']]['payload_bytes'] if heads[r['id']] else 0) for r in records)
        used = conn.execute('SELECT coalesce(sum(payload_bytes),0) AS n,count(*) AS c FROM event_heads WHERE account_id=%s', (aid,)).fetchone()
        if used['n'] + size_change > settings.storage_bytes or used['c'] + sum(h is None for h in heads.values()) > 50000:
            problem(507, 'storage_quota_exceeded')
        operations = conn.execute('SELECT count(*) AS n FROM mutation_ids WHERE account_id=%s', (aid,)).fetchone()['n']
        if operations + len(mutations) > 250000:
            problem(507, 'metadata_quota_exceeded')
        expired = conn.execute("DELETE FROM changes WHERE account_id=%s AND created_at < now()-interval '90 days' RETURNING seq", (aid,)).fetchall()
        if expired:
            conn.execute('UPDATE accounts SET retention_floor=greatest(retention_floor,%s) WHERE account_id=%s', (max(r['seq'] for r in expired), aid))
        change = {'batch_id': data['batch_id'], 'origin_device_id': data['device_id'], 'committed_at': committed,
                  'cursor': cursor(account, seq), 'records': records}
        change_size = len(compact(change))
        history = conn.execute('SELECT coalesce(sum(payload_bytes),0) AS n FROM changes WHERE account_id=%s', (aid,)).fetchone()['n']
        if history + change_size > settings.max_history_bytes:
            problem(507, 'history_quota_exceeded')
        receipt = {'batch_id': data['batch_id'], 'request_sha256': request_hash, 'commit_cursor': cursor(account, seq),
                   'committed_at': committed, 'results': [{'mutation_id': m['mutation_id'], 'event_id': m['event_id'], 'revision': str(seq)} for m in mutations]}
        conn.cursor().executemany('''INSERT INTO event_heads VALUES (%s,%s,%s,%s,%s) ON CONFLICT(account_id,event_id)
              DO UPDATE SET revision=EXCLUDED.revision,record=EXCLUDED.record,payload_bytes=EXCLUDED.payload_bytes''',
                         [(aid, record['id'], seq, Jsonb(record), len(compact(record))) for record in records])
        conn.execute('INSERT INTO receipts VALUES (%s,%s,%s,%s)', (aid, data['batch_id'], request_hash, Jsonb(receipt)))
        conn.cursor().executemany('INSERT INTO mutation_ids VALUES (%s,%s,%s)',
                                 [(aid, mutation['mutation_id'], data['batch_id']) for mutation in mutations])
        conn.execute('INSERT INTO changes(account_id,seq,batch,payload_bytes) VALUES (%s,%s,%s,%s)', (aid, seq, Jsonb(change), change_size))
        conn.execute('UPDATE accounts SET commit_seq=%s WHERE account_id=%s', (seq, aid))
        return receipt


@router.post('/sync/batches')
async def batches(request: Request, identity=Depends(get_identity)):
    data = await body(request, 'BatchRequest')
    return await run_in_threadpool(push, data, identity)


@router.get('/sync/batches/{batch_id}')
def get_receipt(batch_id: UUID, identity=Depends(get_identity)):
    with connect() as conn:
        account_for(conn, identity)
        row = conn.execute('SELECT receipt FROM receipts WHERE account_id=%s AND batch_id=%s', (identity['account_id'], batch_id)).fetchone()
        if not row:
            problem(404, 'receipt_not_found')
        return row['receipt']


def snapshot_page(conn, snap, after=''):
    account = conn.execute('SELECT * FROM accounts WHERE account_id=%s', (snap['account_id'],)).fetchone()
    if snap['expires_at'] <= now():
        problem(410, 'snapshot_expired')
    if snap['sync_epoch'] != account['sync_epoch']:
        problem(410, 'epoch_mismatch')
    result = {'snapshot_id': str(snap['snapshot_id']), 'dataset_id': str(snap['dataset_id']),
              'sync_epoch': str(snap['sync_epoch']), 'boundary_cursor': cursor(account, snap['boundary']),
              'expires_at': stamp(snap['expires_at']), 'records': [], 'next_page_token': None}
    total, last, more = len(compact(result)) + 1200, after, False
    with conn.cursor(name='snapshot_page') as stream:
        stream.itersize = 16
        stream.execute('SELECT event_id,record FROM snapshot_records WHERE snapshot_id=%s AND event_id>%s ORDER BY event_id LIMIT 501',
                       (snap['snapshot_id'], after))
        for row in stream:
            size = len(compact(row['record'])) + 1
            if len(result['records']) == 500 or total + size > 2097152:
                more = True
                break
            result['records'].append(row['record'])
            total += size
            last = row['event_id']
    if more:
        result['next_page_token'] = encode_token({'snapshot': str(snap['snapshot_id']), 'a': str(snap['account_id']), 'after': last})
    return result


@router.post('/sync/snapshots')
def create_snapshot(identity=Depends(get_identity)):
    for attempt in range(3):
        try:
            with connect() as conn:
                conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
                account = account_for(conn, identity, lock=True)
                require_sync(conn, account)
                conn.execute('DELETE FROM snapshots WHERE account_id=%s AND (expires_at<=now() OR sync_epoch<>%s)',
                             (account['account_id'], account['sync_epoch']))
                snap = conn.execute('SELECT * FROM snapshots WHERE account_id=%s', (account['account_id'],)).fetchone()
                if not snap:
                    sid = uuid4()
                    snap = conn.execute('INSERT INTO snapshots VALUES (%s,%s,%s,%s,%s,%s) RETURNING *',
                        (sid, account['account_id'], account['dataset_id'], account['sync_epoch'], account['commit_seq'], now()+timedelta(minutes=15))).fetchone()
                    conn.execute('INSERT INTO snapshot_records SELECT %s,event_id,record FROM event_heads WHERE account_id=%s', (sid, account['account_id']))
                return snapshot_page(conn, snap)
        except psycopg.errors.SerializationFailure:
            if attempt == 2:
                problem(503, 'snapshot_retry_required')


@router.get('/sync/snapshots/{snapshot_id}')
def read_snapshot(snapshot_id: UUID, page_token: str = Query(min_length=16, max_length=1024), identity=Depends(get_identity)):
    token = decode_token(page_token)
    if token.get('snapshot') != str(snapshot_id) or token.get('a') != identity['account_id'] or not isinstance(token.get('after'), str):
        problem(403, 'snapshot_scope_mismatch')
    with connect() as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        account = account_for(conn, identity)
        require_sync(conn, account)
        snap = conn.execute('SELECT * FROM snapshots WHERE snapshot_id=%s AND account_id=%s', (snapshot_id, identity['account_id'])).fetchone()
        if not snap:
            problem(410, 'snapshot_expired')
        return snapshot_page(conn, snap, token['after'])


@router.get('/sync/changes')
async def changes(request: Request, cursor: str = Query(min_length=16, max_length=1024), limit_batches: int = Query(1, ge=1, le=10),
            wait_seconds: int = Query(0, ge=0, le=25), sleep_revision: str | None = Query(None, pattern=SLEEP_REVISION_PATTERN),
            term_revision: str | None = Query(None, pattern=SLEEP_REVISION_PATTERN), identity=Depends(get_identity)):
    deadline = time.monotonic() + wait_seconds
    def read_page():
        with connect() as conn:
            # Retention pruning must not remove unseen rows between floor check and pull.
            conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            account = account_for(conn, identity)
            require_sync(conn, account)
            seq = parse_cursor(cursor, account)
            # limit_batches is an upper bound; one indivisible batch limits peak memory.
            rows = conn.execute('SELECT seq,batch FROM changes WHERE account_id=%s AND seq>%s ORDER BY seq LIMIT 1',
                                (identity['account_id'], seq)).fetchall()
            more = bool(rows and rows[0]['seq'] < account['commit_seq'])
            sleep = account_sleep_schedule(account) if sleep_revision is not None else None
            send_sleep = sleep_revision is not None and sleep_revision != (sleep['revision'] if sleep else 'none')
            terms = read_terms(conn, account, term_revision) if term_revision is not None else None
        return rows, more, send_sleep, sleep, terms
    while True:
        if await request.is_disconnected():
            return Response(status_code=204)
        rows, more, send_sleep, sleep, terms = await run_in_threadpool(read_page)
        if rows or send_sleep or terms is not None or time.monotonic() >= deadline:
            included = [r['batch'] for r in rows]
            page = {'changes': included, 'next_cursor': included[-1]['cursor'] if included else cursor,
                    'has_more': more, 'server_time': stamp()}
            if terms is not None:
                page['teaching_terms'] = terms
            if send_sleep:
                page['sleep_schedule'] = sleep
            return page
        await asyncio.sleep(min(0.5, max(0, deadline - time.monotonic())))


def read_terms(conn, account, known='unknown'):
    row = conn.execute('SELECT revision,CASE WHEN revision::text <> %s THEN entries END AS entries '
                       'FROM teaching_term_sets WHERE account_id=%s AND epoch=%s',
                       (known, account['account_id'], account['sync_epoch'])).fetchone()
    if not row:
        return None if known == 'none' else {'revision': 'none', 'entries': {}}
    return None if row['entries'] is None else {'revision': str(row['revision']), 'entries': row['entries']}


@router.put('/sync/teaching-terms')
async def write_teaching_term(request: Request, identity=Depends(get_identity)):
    data = await body(request, 'TeachingTermWrite')
    key, calendar = data['key'], data['calendar']
    monday = date.fromisoformat(calendar['first_monday'])
    year = int(key.split(':')[2].split('-')[0])
    if monday.weekday() or not year <= monday.year <= year + 1:
        problem(422, 'invalid_teaching_calendar')

    def write():
        with connect() as conn:
            account = account_for(conn, identity, lock=True)
            if data['dataset_id'] != str(account['dataset_id']) or data['sync_epoch'] != str(account['sync_epoch']):
                problem(410, 'epoch_mismatch')
            require_sync(conn, account)
            current = read_terms(conn, account)
            head = current['entries'].get(key)
            if head and head['revision'] == data['write_id'] and head['calendar'] != calendar:
                problem(409, 'idempotency_key_reused')
            if head and head['calendar'] == calendar:
                return current
            if (head['revision'] if head else None) != data['base_revision']:
                problem(409, 'teaching_term_conflict', teaching_terms=current)
            if not head and len(current['entries']) >= 256:
                problem(507, 'teaching_term_quota_exceeded')
            current['entries'][key] = {'revision': data['write_id'], 'calendar': calendar}
            current['revision'] = str(uuid4())
            conn.execute('INSERT INTO teaching_term_sets(account_id,epoch,revision,entries) VALUES (%s,%s,%s,%s) '
                         'ON CONFLICT(account_id) DO UPDATE SET epoch=EXCLUDED.epoch,revision=EXCLUDED.revision,entries=EXCLUDED.entries',
                         (account['account_id'], account['sync_epoch'], current['revision'], Jsonb(current['entries'])))
            return current

    return await run_in_threadpool(write)


def account_sleep_schedule(account):
    # After a dataset reset the old value cannot be mistaken for its new baseline.
    return account['sleep_schedule'] if account['sleep_schedule_epoch'] == account['sync_epoch'] else None


@router.put('/sync/sleep-schedule')
async def write_sleep_schedule(request: Request, identity=Depends(get_identity)):
    data = await body(request, 'SleepScheduleWrite')
    incoming = data['schedule']
    schedule = {'enabled': incoming['enabled'], 'sleep_minute': int(incoming['sleep_minute']),
                'wake_minute': int(incoming['wake_minute'])}
    interval = (schedule['sleep_minute'] - schedule['wake_minute']) % 1440
    if interval == 0 or (schedule['enabled'] and interval < 15):
        problem(422, 'invalid_sleep_schedule')

    def write():
        with connect() as conn:
            account = account_for(conn, identity, lock=True)
            if data['dataset_id'] != str(account['dataset_id']) or data['sync_epoch'] != str(account['sync_epoch']):
                problem(410, 'epoch_mismatch')
            require_sync(conn, account)
            current = account_sleep_schedule(account)
            if current and current['write_id'] == data['write_id']:
                if current['schedule'] != schedule:
                    problem(409, 'idempotency_key_reused')
                return current
            if (current['revision'] if current else None) != data['base_revision']:
                problem(409, 'sleep_schedule_conflict', sleep_schedule=current)
            updated = {'revision': str(uuid4()), 'write_id': data['write_id'], 'schedule': schedule}
            conn.execute('UPDATE accounts SET sleep_schedule=%s, sleep_schedule_epoch=%s WHERE account_id=%s',
                         (Jsonb(updated), account['sync_epoch'], account['account_id']))
            return updated

    return await run_in_threadpool(write)


@router.post('/sync/ack', status_code=204)
async def ack(request: Request, identity=Depends(get_identity)):
    data = await body(request, 'Ack')
    if data['device_id'] != identity['device_id']:
        problem(403, 'device_mismatch')
    def write():
        with connect() as conn:
            account = account_for(conn, identity, lock=True)
            require_sync(conn, account)
            seq = parse_cursor(data['cursor'], account)
            conn.execute('''INSERT INTO sync_acks VALUES (%s,%s,%s) ON CONFLICT(account_id,device_id)
                         DO UPDATE SET seq=greatest(sync_acks.seq,EXCLUDED.seq)''', (identity['account_id'], identity['device_id'], seq))
    await run_in_threadpool(write)
    return Response(status_code=204)


@router.get('/exports/calendar')
def export(identity=Depends(get_identity)):
    def select(conn):
        account = account_for(conn, identity)
        require_sync(conn, account)
        return account, now()
    # Inactive subscribers use an acknowledged claim in the web console.
    return calendar_export.download(select)
