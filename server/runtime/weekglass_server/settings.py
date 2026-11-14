from dataclasses import dataclass
import os
from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID


@dataclass
class Settings:
    database_url: str
    public_origin: str
    server_id: str
    mode: str
    signing_key: bytes
    alternate_origins: tuple[str, ...] = ()
    storage_bytes: int = 64 * 1024 * 1024
    max_devices: int = 10
    max_history_bytes: int = 128 * 1024 * 1024
    registration_enabled: bool = True


def validated_origin(value):
    origin = value.strip().rstrip('/')
    url = urlparse(origin)
    if url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ('127.0.0.1', 'localhost', '::1')):
        raise RuntimeError('HTTPS required outside loopback')
    if not url.hostname or url.path or url.query or url.fragment or url.username or url.password:
        raise RuntimeError('Public origin must be an origin only')
    # Parse the port too: reject malformed/out-of-range operator configuration.
    _ = url.port
    return origin.lower()


def load():
    origin = validated_origin(os.environ.get('WEEKGLASS_PUBLIC_ORIGIN', 'http://127.0.0.1:18081'))
    alternates = tuple(dict.fromkeys(validated_origin(value) for value in
                       os.environ.get('WEEKGLASS_ALTERNATE_ORIGINS', '').split(',') if value.strip()))
    server_id = str(UUID(os.environ['WEEKGLASS_SERVER_ID']))
    mode = os.environ.get('WEEKGLASS_MODE', 'self_hosted')
    if mode not in ('hosted', 'self_hosted'):
        raise RuntimeError('Invalid service mode')
    key = Path(os.environ['AUTH_SIGNING_KEY_FILE']).read_bytes().strip()
    if len(key) < 32:
        raise RuntimeError('Signing secret must contain at least 32 bytes')
    return Settings(os.environ.get('DATABASE_URL', ''), origin, server_id, mode, key,
                    alternate_origins=alternates,
                    registration_enabled=os.environ.get('WEEKGLASS_REGISTRATION_ENABLED', 'true').lower() == 'true')


def request_origin(request):
    """Select an explicitly configured origin; never reflect an arbitrary Host."""
    candidate = f'{request.url.scheme}://{request.headers.get("host", "")}'.lower()
    if candidate not in (settings.public_origin, *settings.alternate_origins):
        from fastapi import HTTPException
        raise HTTPException(400, detail={'code': 'invalid_server_origin'})
    return candidate


settings = load()
