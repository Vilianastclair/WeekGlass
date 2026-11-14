import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path
from uuid import uuid4
from jsonschema import Draft202012Validator, FormatChecker
from fastapi import HTTPException, Request
from .settings import settings

SPEC = json.loads((Path(__file__).resolve().parents[2] / 'contracts/sync-v1.openapi.json').read_text(encoding='utf-8'))
LIMITS = {name: value['const'] for name, value in SPEC['components']['schemas']['Limits']['properties'].items()}


def now():
    return datetime.now(timezone.utc)


def stamp(dt=None):
    return (dt or now()).astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')


def problem(status, code, **extra):
    raise HTTPException(status, detail={'type': 'about:blank', 'title': code.replace('_', ' '),
          'status': status, 'code': code, 'request_id': str(uuid4()), **extra})


def validate(name, value):
    schema = {'$ref': f'#/components/schemas/{name}', 'components': SPEC['components']}
    if next(Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(value), None):
        problem(422, 'invalid_' + name.lower())


def unique_pairs(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError('Duplicate JSON key')
        out[k] = v
    return out


async def body(request: Request, schema):
    if request.headers.get('content-encoding', 'identity') != 'identity':
        problem(415, 'compressed_requests_unsupported')
    raw = await request.body()
    if len(raw) > 2097152:
        problem(413, 'request_too_large')
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        compact(value)
    except (ValueError, UnicodeError, RecursionError):
        problem(400, 'invalid_json')
    validate(schema, value)
    return value


def encode_token(payload):
    raw = compact(payload)
    sig = hmac.new(settings.signing_key, raw, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(raw + sig).rstrip(b'=').decode('ascii')


def decode_token(token):
    try:
        if len(token) > 1024:
            raise ValueError()
        wire = base64.b64decode(token + '=' * (-len(token) % 4), altchars=b'-_', validate=True)
        raw, sig = wire[:-32], wire[-32:]
        if not hmac.compare_digest(hmac.new(settings.signing_key, raw, hashlib.sha256).digest(), sig):
            raise ValueError()
        return json.loads(raw)
    except (ValueError, TypeError, UnicodeError):
        problem(400, 'invalid_cursor')


def cursor(account, seq):
    return encode_token({'s': settings.server_id, 'a': str(account['account_id']),
        'd': str(account['dataset_id']), 'e': str(account['sync_epoch']), 'n': seq})


def parse_cursor(token, account):
    p = decode_token(token)
    for k, expected in [('s', settings.server_id), ('a', str(account['account_id'])), ('d', str(account['dataset_id']))]:
        if p.get(k) != expected:
            problem(403, 'cursor_scope_mismatch')
    if p.get('e') != str(account['sync_epoch']):
        problem(410, 'epoch_mismatch')
    seq = p.get('n')
    if type(seq) is not int or seq < 0 or seq > account['commit_seq']:
        problem(400, 'invalid_cursor')
    if seq < account['retention_floor']:
        problem(410, 'cursor_expired')
    return seq
