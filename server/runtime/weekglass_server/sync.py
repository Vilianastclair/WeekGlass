from datetime import datetime, timedelta
import asyncio
import hashlib
import time
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import psycopg
from psycopg.types.json import Jsonb
import rfc8785
from fastapi import APIRouter, Depends, Query, Request, Response
from fastapi.responses import StreamingResponse
from starlette.concurrency import run_in_threadpool
from .auth import get_identity
from . import auth
from .billing import billing_capabilities, WAFFO_LIVE_PROVIDER
from .db import connect
from .entitlements import entitlement
from .settings import settings, request_origin
from .protocol import LIMITS, body, compact, cursor, decode_token, encode_token, now, parse_cursor, problem, stamp

router = APIRouter(prefix='/v1')


def account_for(conn, identity, lock=False):
    row = conn.execute('SELECT * FROM accounts WHERE account_id=%s' + (' FOR UPDATE' if lock else ''),
                       (identity['account_id'],)).fetchone()
    if not row:
        problem(401, 'account_unavailable')
    auth.revalidate_identity(conn, identity)
    return row


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
            'capabilities': ['atomic_batches', 'delta_pull', 'snapshot', 'export', 'account_management', 'recovery_key'] +
                            (['registration'] if settings.registration_enabled else []) +
                            flags, 'limits': LIMITS}


@router.get('/me/entitlements')
def entitlements(identity=Depends(get_identity)):
    with connect() as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        return entitlement(conn, account_for(conn, identity))


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
        if not entitlement(conn, account)['sync_write']:
            problem(403, 'subscription_required')
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
        account_for(conn, identity)
        snap = conn.execute('SELECT * FROM snapshots WHERE snapshot_id=%s AND account_id=%s', (snapshot_id, identity['account_id'])).fetchone()
        if not snap:
            problem(410, 'snapshot_expired')
        return snapshot_page(conn, snap, token['after'])


@router.get('/sync/changes')
async def changes(cursor: str = Query(min_length=16, max_length=1024), limit_batches: int = Query(1, ge=1, le=10),
            wait_seconds: int = Query(0, ge=0, le=25), identity=Depends(get_identity)):
    deadline = time.monotonic() + wait_seconds
    def read_page():
        with connect() as conn:
            # Retention pruning must not remove unseen rows between floor check and pull.
            conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            account = account_for(conn, identity)
            seq = parse_cursor(cursor, account)
            # limit_batches is an upper bound; one indivisible batch limits peak memory.
            rows = conn.execute('SELECT seq,batch FROM changes WHERE account_id=%s AND seq>%s ORDER BY seq LIMIT 1',
                                (identity['account_id'], seq)).fetchall()
            more = bool(rows and rows[0]['seq'] < account['commit_seq'])
        return rows, more
    while True:
        rows, more = await run_in_threadpool(read_page)
        if rows or time.monotonic() >= deadline:
            included = [r['batch'] for r in rows]
            return {'changes': included, 'next_cursor': included[-1]['cursor'] if included else cursor,
                    'has_more': more, 'server_time': stamp()}
        await asyncio.sleep(min(0.5, max(0, deadline - time.monotonic())))


@router.post('/sync/ack', status_code=204)
async def ack(request: Request, identity=Depends(get_identity)):
    data = await body(request, 'Ack')
    if data['device_id'] != identity['device_id']:
        problem(403, 'device_mismatch')
    def write():
        with connect() as conn:
            account = account_for(conn, identity)
            seq = parse_cursor(data['cursor'], account)
            conn.execute('''INSERT INTO sync_acks VALUES (%s,%s,%s) ON CONFLICT(account_id,device_id)
                         DO UPDATE SET seq=greatest(sync_acks.seq,EXCLUDED.seq)''', (identity['account_id'], identity['device_id'], seq))
    await run_in_threadpool(write)
    return Response(status_code=204)


@router.get('/exports/calendar')
def export(identity=Depends(get_identity)):
    def stream():
        with connect() as conn:
            conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            account = account_for(conn, identity)
            header = {'format': 'weekglass-json-v1', 'server_id': settings.server_id,
                      'account_id': identity['account_id'], 'dataset_id': str(account['dataset_id']),
                      'boundary_cursor': cursor(account, account['commit_seq']), 'created_at': stamp()}
            yield compact(header)[:-1] + b',"records":['
            with conn.cursor(name='calendar_export') as rows:
                rows.itersize = 5
                rows.execute('SELECT record FROM event_heads WHERE account_id=%s ORDER BY event_id', (identity['account_id'],))
                first = True
                for row in rows:
                    yield (b'' if first else b',') + compact(row['record'])
                    first = False
            yield b']}'
    return StreamingResponse(stream(), media_type='application/json', headers={'Content-Disposition': 'attachment; filename="weekglass-calendar.json"', 'Cache-Control': 'no-store'})
