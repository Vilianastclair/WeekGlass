"""Stream one authorized, consistent calendar boundary as WeekGlass JSON."""
from threading import BoundedSemaphore

import anyio
from fastapi import HTTPException
from fastapi.responses import StreamingResponse

from .db import connect
from .protocol import compact, cursor, stamp
from .settings import settings


# Slow downloads must not fill the database pool used by login and payments.
_downloads = BoundedSemaphore(2)


class _CalendarResponse(StreamingResponse):
    def __init__(self, source, first, size, filename):
        self.source = source

        def content():
            yield first
            yield from source

        super().__init__(content(), media_type='application/json', headers={
            'Content-Disposition': f'attachment; filename="{filename}"',
            'Content-Length': str(size), 'Content-Encoding': 'identity', 'Cache-Control': 'no-store',
        })

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            # ASGI cancellation can interrupt iteration while the PostgreSQL
            # cursor is still open. Always release it and the connection slot.
            try:
                with anyio.CancelScope(shield=True):
                    await anyio.to_thread.run_sync(self.source.close)
            finally:
                _downloads.release()


def download(select_boundary, *, transferred=None, filename='weekglass-calendar.json'):
    def fragments():
        with connect() as conn:
            conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            account, created_at = select_boundary(conn)
            aid = account['account_id']
            header = {'format': 'weekglass-json-v1', 'server_id': settings.server_id,
                      'account_id': str(aid), 'dataset_id': str(account['dataset_id']),
                      'boundary_cursor': cursor(account, account['commit_seq']), 'created_at': stamp(created_at)}
            prefix = compact(header)[:-1] + b',"records":['
            totals = conn.execute('''SELECT COALESCE(sum(payload_bytes),0) AS size, count(*) AS records
              FROM event_heads WHERE account_id=%s''', (aid,)).fetchone()
            length = len(prefix) + totals['size'] + max(0, totals['records'] - 1) + 2
            yield prefix, length
            with conn.cursor(name='calendar_export') as rows:
                rows.itersize = 8
                rows.execute('SELECT record FROM event_heads WHERE account_id=%s ORDER BY event_id', (aid,))
                first = True
                for row in rows:
                    yield (b'' if first else b',') + compact(row['record'])
                    first = False
        # Store delivery before the final bytes can reach the browser. A
        # failed transfer alone never consumes the allowance; the browser
        # checks length and confirms separately after saving the file.
        if transferred:
            transferred()
        yield b']}'

    source = fragments()
    # Access checks and any response-status errors must happen before ASGI
    # sends the headers. A truncated body then fails the advertised length.
    if not _downloads.acquire(blocking=False):
        raise HTTPException(429, detail={'code': 'export_busy', 'retry_after_seconds': 5}, headers={'Retry-After': '5'})
    try:
        first, size = next(source)
        return _CalendarResponse(source, first, size, filename)
    except BaseException:
        try:
            source.close()
        finally:
            _downloads.release()
        raise
