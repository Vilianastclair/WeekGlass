from contextlib import asynccontextmanager, suppress
import asyncio
import anyio
import psycopg
from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.gzip import GZipMiddleware
from uuid import uuid4
from . import account, auth, billing_routes, console, db, owner, sync, waffo_routes, waffo_runtime
from .settings import settings


@asynccontextmanager
async def lifespan(app):
    anyio.to_thread.current_default_thread_limiter().total_tokens = 4
    db.init_schema()
    with db.connect() as conn:
        auth.init_schema(conn)
    live = await anyio.to_thread.run_sync(waffo_runtime.configured)
    if not live:
        yield
        return
    app.state.billing = live
    reconcile = asyncio.create_task(waffo_runtime.reconcile_loop(live))
    try:
        yield
    finally:
        reconcile.cancel()
        with suppress(asyncio.CancelledError):
            await reconcile
        app.state.billing = None


app = FastAPI(title='WeekGlass sync service', version='0.1.1', lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)
app.state.settings = settings
# Checkout stays off until the approved live catalog and configuration are verified.
app.state.billing = None
app.include_router(auth.router)
app.include_router(account.router)
app.include_router(console.router)
app.include_router(owner.router)
app.include_router(sync.router)
app.include_router(billing_routes.router)
waffo_routes.mount_routes(app)
app.add_middleware(GZipMiddleware, minimum_size=1000)


class BodyLimitMiddleware:
    """Bound streamed/chunked request bodies before any endpoint reads them."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        original_send = send
        async def safe_send(message):
            if message['type'] == 'http.response.start':
                response_headers = list(message.get('headers', []))
                present = {key.lower() for key, _ in response_headers}
                if b'cache-control' not in present:
                    response_headers.append((b'cache-control', b'no-store'))
                if b'x-content-type-options' not in present:
                    response_headers.append((b'x-content-type-options', b'nosniff'))
                message = dict(message, headers=response_headers)
            await original_send(message)
        send = safe_send
        async def rejected(status, code):
            response = JSONResponse({'type': 'about:blank', 'title': code.replace('_', ' '), 'status': status,
                       'code': code, 'request_id': str(uuid4())}, status_code=status, media_type='application/problem+json')
            await response(scope, receive, send)
        headers = dict(scope['headers'])
        if headers.get(b'content-encoding', b'identity') != b'identity':
            return await rejected(415, 'compressed_requests_unsupported')
        body = bytearray()
        while True:
            message = await receive()
            if message['type'] == 'http.disconnect':
                return
            body.extend(message.get('body', b''))
            if len(body) > 2097152:
                return await rejected(413, 'request_too_large')
            if not message.get('more_body'):
                break
        sent = False
        async def buffered():
            nonlocal sent
            if not sent:
                sent = True
                return {'type': 'http.request', 'body': bytes(body), 'more_body': False}
            return await receive()
        await self.app(scope, buffered, send)


app.add_middleware(BodyLimitMiddleware)


@app.exception_handler(HTTPException)
async def http_error(request, exc):
    data = exc.detail if isinstance(exc.detail, dict) else {'code': 'request_rejected'}
    code = data.get('code', 'request_rejected')
    response = {'type': 'about:blank', 'title': code.replace('_', ' '), 'status': exc.status_code,
                'code': code, 'request_id': str(uuid4())}
    for key in ('conflicts', 'sleep_schedule', 'retry_after_seconds'):
        if key in data:
            response[key] = data[key]
    return JSONResponse(response, status_code=exc.status_code, media_type='application/problem+json', headers=exc.headers)


@app.exception_handler(RequestValidationError)
async def validation_error(request, exc):
    return await http_error(request, HTTPException(422, detail={'code': 'invalid_request'}))


@app.exception_handler(psycopg.Error)
async def database_error(request, exc):
    return await http_error(request, HTTPException(503, detail={'code': 'database_unavailable'}, headers={'Retry-After': '5'}))


@app.get('/healthz')
def health():
    with db.connect() as conn:
        conn.execute('SELECT 1')
    return {'status': 'ok', 'service': 'weekglass', 'version': '0.1.1'}

