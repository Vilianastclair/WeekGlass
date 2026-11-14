"""Local publication/reconstruction prototype; never installs or runs an update.

All network transport and Windows process handover are intentionally outside this
module. Consumers must pin the public key independently of the sync server.
"""
from __future__ import annotations
import argparse
import base64
import bz2
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
from datetime import datetime, timedelta, timezone
import zlib

import bsdiff4
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

MAX_FILE = 256 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_MANIFEST = 4 * 1024 * 1024
MAX_FILES = 5000
PLATFORMS = ('windows-x64', 'android-arm64')
SHA = re.compile(r'^[0-9a-f]{64}$')
RESERVED = re.compile(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', re.I)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def parse_time(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Timezone required')
    return result


def valid_path(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 240:
        raise ValueError('Invalid path')
    parts = value.split('/')
    if ('\\' in value or ':' in value or value.startswith('/') or
        any(c in value for c in '<>"|?*') or any(ord(c) < 32 for c in value) or
        any(p in ('', '.', '..') or p.endswith(('.', ' ')) or RESERVED.match(p) for p in parts)):
        raise ValueError('Unsafe Windows relative path')
    return value


def child(root: Path, relative: str) -> Path:
    relative = valid_path(relative)
    current = root.resolve()
    for piece in PurePosixPath(relative).parts:
        current = current / piece
        if current.is_symlink() or (hasattr(current, 'is_junction') and current.is_junction()):
            raise ValueError('Links/reparse directory not permitted')
    current.resolve().relative_to(root.resolve())
    return current


def inventory(root: Path) -> dict[str, dict]:
    root = root.resolve()
    result, folded = {}, set()
    if not root.is_dir():
        raise ValueError('Input release must be a directory')
    for here, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            p = Path(here) / name
            if p.is_symlink() or (hasattr(p, 'is_junction') and p.is_junction()):
                raise ValueError('Release cannot contain links')
        for name in sorted(files):
            p = Path(here) / name
            relative = valid_path(p.relative_to(root).as_posix())
            if relative.casefold() in folded:
                raise ValueError('Windows case collision')
            folded.add(relative.casefold())
            size = p.stat().st_size
            if size > MAX_FILE:
                raise ValueError('File exceeds prototype memory limit')
            result[relative] = {'sha256': digest(p.read_bytes()), 'size': size}
    if len(result) > MAX_FILES or sum(x['size'] for x in result.values()) > MAX_TOTAL:
        raise ValueError('Release exceeds bounded limits')
    return dict(sorted(result.items()))


def release_inventory(root: Path, platform: str) -> dict[str, dict]:
    """Android can consume an APK directly, without copying installed packages."""
    if platform not in PLATFORMS:
        raise ValueError('Unsupported platform')
    if platform == 'android-arm64' and root.is_file():
        if root.is_symlink() or root.suffix.lower() != '.apk' or not 0 < root.stat().st_size <= MAX_FILE:
            raise ValueError('A bounded regular APK is required')
        return {'weekglass.apk': {'sha256': digest(root.read_bytes()), 'size': root.stat().st_size}}
    result = inventory(root)
    if platform == 'android-arm64' and result and set(result) != {'weekglass.apk'}:
        raise ValueError('Android release must contain only weekglass.apk')
    return result


def release_file(root: Path, relative: str, platform: str) -> Path:
    if platform == 'android-arm64' and root.is_file() and relative == 'weekglass.apk':
        if root.is_symlink():
            raise ValueError('APK cannot be a link')
        return root
    return child(root, relative)


def object_path(store: Path, object_hash: str) -> Path:
    if not SHA.fullmatch(object_hash):
        raise ValueError('Invalid object hash')
    return child(store, f'objects/{object_hash[:2]}/{object_hash}')


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.wg-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def put(store: Path, data: bytes, encoding: str) -> dict:
    h = digest(data)
    path = object_path(store, h)
    if path.exists():
        if digest(path.read_bytes()) != h:
            raise ValueError('Content-addressed object has been corrupted')
    else:
        write_atomic(path, data)
    return {'sha256': h, 'size': len(data), 'encoding': encoding}


def full_object(store: Path, raw: bytes) -> dict:
    packed = zlib.compress(raw, level=9)
    return put(store, packed, 'zlib') if len(packed) < len(raw) else put(store, raw, 'raw')


def envelope(payload: dict, key: Ed25519PrivateKey) -> bytes:
    raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':'), sort_keys=True).encode('utf-8')
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return json.dumps({'format': 1, 'key_id': digest(public),
        'signed': base64.b64encode(raw).decode('ascii'),
        'signature': base64.b64encode(key.sign(raw)).decode('ascii')},
        separators=(',', ':')).encode('utf-8')


def build(target: Path, bases: list[Path], store: Path, key: Ed25519PrivateKey,
          version: str, build_number: int, platform: str = 'windows-x64',
          channel: str = 'stable', now: datetime | None = None) -> tuple[bytes, dict]:
    if len(bases) > 3:
        raise ValueError('Only the most recent three bases may be patched')
    if type(build_number) is not int or build_number < 1 or not version or platform not in PLATFORMS or channel not in ('stable', 'preview'):
        raise ValueError('Invalid release identity')
    for release in [target, *bases]:
        if store.resolve().is_relative_to(release.resolve()):
            raise ValueError('Object store must be outside every input release')
    now = now or utcnow()
    records = release_inventory(target, platform)
    if not records:
        raise ValueError('A release cannot be empty')
    old = [(p, release_inventory(p, platform)) for p in bases]
    files = []
    for name, record in records.items():
        raw = release_file(target, name, platform).read_bytes()
        if len(raw) != record['size'] or digest(raw) != record['sha256']:
            raise ValueError('Target changed during publication')
        full = put(store, raw, 'raw') if platform == 'android-arm64' else full_object(store, raw)
        entry = {'path': name, **record, 'full': full, 'patches': []}
        seen = set()
        for base, index in old:
            source = index.get(name)
            if source is None or source['sha256'] == record['sha256'] or source['sha256'] in seen:
                continue
            seen.add(source['sha256'])
            previous = release_file(base, name, platform).read_bytes()
            if len(previous) != source['size'] or digest(previous) != source['sha256']:
                raise ValueError('Base changed during publication')
            patch = bsdiff4.diff(previous, raw)
            # BSDIFF4 already compresses its three streams with bzip2. Do not
            # apply transport gzip again. Full is always retained for fallback.
            if len(patch) < entry['full']['size']:
                entry['patches'].append({**put(store, patch, 'bsdiff4'),
                    'base_sha256': source['sha256'], 'base_size': source['size']})
        files.append(entry)
    payload = {'schema': 1, 'product': 'weekglass', 'platform': platform,
        'channel': channel, 'version': version, 'build': build_number,
        'min_updater': 1, 'generated_at': timestamp(now),
        'expires_at': timestamp(now + timedelta(days=30)), 'files': files}
    signed = envelope(payload, key)
    return signed, payload


def verify(data: bytes, public: Ed25519PublicKey, platform: str = 'windows-x64',
           channel: str = 'stable', floor: int = 0, now: datetime | None = None) -> dict:
    if platform not in PLATFORMS or channel not in ('stable', 'preview'):
        raise ValueError('Unsupported platform/channel')
    if len(data) > MAX_MANIFEST:
        raise ValueError('Manifest too large')
    outer = json.loads(data)
    public_bytes = public.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    if outer.get('format') != 1 or outer.get('key_id') != digest(public_bytes):
        raise ValueError('Untrusted signing identity')
    raw = base64.b64decode(outer['signed'], validate=True)
    public.verify(base64.b64decode(outer['signature'], validate=True), raw)
    payload = json.loads(raw)
    now = now or utcnow()
    if (payload['schema'] != 1 or payload['product'] != 'weekglass' or
        payload['platform'] != platform or payload['channel'] != channel or
        type(payload['build']) is not int or payload['build'] < max(1, floor) or
        payload['min_updater'] != 1 or not isinstance(payload.get('version'), str) or not payload['version']):
        raise ValueError('Incompatible platform/channel/build or rollback')
    if not parse_time(payload['generated_at']) <= now + timedelta(minutes=5):
        raise ValueError('Future metadata/clock error')
    if not now < parse_time(payload['expires_at']) <= parse_time(payload['generated_at']) + timedelta(days=31):
        raise ValueError('Expired or excessive validity')
    files = payload['files']
    if not isinstance(files, list) or not files or len(files) > MAX_FILES:
        raise ValueError('Invalid file count')
    seen, total = set(), 0
    for entry in files:
        name = valid_path(entry['path'])
        folded = name.casefold()
        if folded in seen or any(folded.startswith(x + '/') or x.startswith(folded + '/') for x in seen):
            raise ValueError('Conflicting paths')
        seen.add(folded)
        if type(entry['size']) is not int or not 0 <= entry['size'] <= MAX_FILE or not SHA.fullmatch(entry['sha256']):
            raise ValueError('Invalid file size/hash')
        total += entry['size']
        if len(entry['patches']) > 3:
            raise ValueError('Too many delta bases')
        for item in [entry['full'], *entry['patches']]:
            if not SHA.fullmatch(item['sha256']) or type(item['size']) is not int or not 0 <= item['size'] <= MAX_FILE:
                raise ValueError('Invalid object descriptor')
        if entry['full']['encoding'] not in ('raw', 'zlib'):
            raise ValueError('Unknown full encoding')
        for patch in entry['patches']:
            if (patch['encoding'] != 'bsdiff4' or not SHA.fullmatch(patch['base_sha256']) or
                    type(patch['base_size']) is not int or not 0 <= patch['base_size'] <= MAX_FILE):
                raise ValueError('Invalid patch descriptor')
    if platform == 'android-arm64' and (len(files) != 1 or files[0]['path'] != 'weekglass.apk' or
            files[0]['full']['encoding'] != 'raw' or files[0]['full']['sha256'] != files[0]['sha256'] or
            files[0]['full']['size'] != files[0]['size'] or files[0]['size'] <= 0):
        raise ValueError('Android manifest must identify one complete raw APK')
    if total > MAX_TOTAL:
        raise ValueError('Release too large')
    return payload


def plan(payload: dict, base: Path) -> list[dict]:
    available = release_inventory(base, payload['platform'])
    by_hash = {entry['sha256']: (path, entry['size']) for path, entry in available.items()}
    result = []
    for entry in payload['files']:
        if entry['sha256'] in by_hash:
            result.append({'file': entry, 'kind': 'reuse', 'source': by_hash[entry['sha256']][0]})
            continue
        choices = [(entry['full']['size'], entry['full'], None)]
        for patch in entry['patches']:
            source = by_hash.get(patch['base_sha256'])
            if source and source[1] == patch['base_size']:
                choices.append((patch['size'], patch, source[0]))
        _, obj, source = min(choices, key=lambda item: item[0])
        result.append({'file': entry, 'kind': obj['encoding'], 'object': obj, 'source': source})
    return result


def get_object(store: Path, descriptor: dict) -> bytes:
    path = object_path(store, descriptor['sha256'])
    if path.stat().st_size != descriptor['size']:
        raise ValueError('Object length mismatch')
    data = path.read_bytes()
    if digest(data) != descriptor['sha256']:
        raise ValueError('Object hash mismatch')
    return data


def decode(data: bytes, expected_size: int) -> bytes:
    stream = zlib.decompressobj()
    result = stream.decompress(data, expected_size + 1)
    if len(result) != expected_size or not stream.eof or stream.unused_data or stream.unconsumed_tail:
        raise ValueError('Invalid compressed object or expansion limit')
    return result


def validate_patch(data: bytes, expected_size: int) -> None:
    """Bound all BSDIFF bzip2 streams before the native patcher allocates them."""
    def number(raw: bytes) -> int:
        value = int.from_bytes(raw[:7] + bytes([raw[7] & 127]), 'little')
        return -value if raw[7] & 128 else value

    if len(data) < 32 or data[:8] != b'BSDIFF40':
        raise ValueError('Invalid patch header')
    control_length, diff_length, target_length = [number(data[i:i + 8]) for i in (8, 16, 24)]
    if (control_length < 0 or diff_length < 0 or target_length != expected_size or
            32 + control_length + diff_length > len(data)):
        raise ValueError('Patch target size or stream length mismatch')

    def unpack(block: bytes, limit: int) -> bytes:
        decoder = bz2.BZ2Decompressor()
        result = decoder.decompress(block, max_length=limit + 1)
        if len(result) > limit or not decoder.eof or decoder.unused_data:
            raise ValueError('Patch stream expansion limit or trailing data')
        return result

    control_end, diff_end = 32 + control_length, 32 + control_length + diff_length
    controls = unpack(data[32:control_end], min(8 * 1024 * 1024, (expected_size + 1) * 24))
    diff = unpack(data[control_end:diff_end], expected_size)
    extra = unpack(data[diff_end:], expected_size)
    if len(controls) % 24:
        raise ValueError('Invalid patch control stream')
    output_size = used_diff = used_extra = 0
    for offset in range(0, len(controls), 24):
        x, y = number(controls[offset:offset + 8]), number(controls[offset + 8:offset + 16])
        if x < 0 or y < 0:
            raise ValueError('Negative patch control length')
        output_size += x + y
        used_diff += x
        used_extra += y
        if output_size > expected_size or used_diff > len(diff) or used_extra > len(extra):
            raise ValueError('Patch control exceeds bounded streams')
    if output_size != expected_size or used_diff != len(diff) or used_extra != len(extra):
        raise ValueError('Patch control output mismatch')


def reconstruct(manifest: bytes, public: Ed25519PublicKey, base: Path,
                store: Path, destination: Path, floor: int = 0,
                platform: str = 'windows-x64', channel: str = 'stable') -> dict:
    payload = verify(manifest, public, platform, channel, floor)
    base, destination = base.resolve(), destination.absolute()
    if destination.exists():
        raise ValueError('Destination must be a fresh release directory')
    # Never write into a live/base installation, including a nested directory.
    try:
        destination.resolve().relative_to(base)
    except ValueError:
        pass
    else:
        raise ValueError('Destination cannot be within the base release')
    operations = plan(payload, base)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix='.wg-staging-', dir=destination.parent)).resolve()
    try:
        for op in operations:
            entry = op['file']
            if op['kind'] == 'reuse':
                raw = release_file(base, op['source'], platform).read_bytes()
            else:
                data = get_object(store, op['object'])
                if op['kind'] == 'zlib':
                    raw = decode(data, entry['size'])
                elif op['kind'] == 'raw':
                    raw = data
                else:
                    source = release_file(base, op['source'], platform).read_bytes()
                    if digest(source) != op['object']['base_sha256']:
                        raise ValueError('Base changed during staging; replan with full file')
                    validate_patch(data, entry['size'])
                    raw = bsdiff4.patch(source, data)
            if len(raw) != entry['size'] or digest(raw) != entry['sha256']:
                raise ValueError('Reconstructed target mismatch')
            out = child(temp, entry['path'])
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(raw)
        # New directory holds only signed target files: removed old files do not
        # leak into the new version. No executing files/user databases are edited.
        os.rename(temp, destination)
    finally:
        if temp.exists():
            shutil.rmtree(temp)
    objects = {op['object']['sha256']: op['object']['size'] for op in operations if 'object' in op}
    return {'files': len(operations), 'reused': sum(op['kind'] == 'reuse' for op in operations),
        'patched': sum(op['kind'] == 'bsdiff4' for op in operations),
        'full': sum(op['kind'] in ('raw', 'zlib') for op in operations),
        'object_bytes': sum(objects.values()), 'manifest_bytes': len(manifest),
        'download_bytes': sum(objects.values()) + len(manifest)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    publish = sub.add_parser('build')
    publish.add_argument('--target', type=Path, required=True)
    publish.add_argument('--base', type=Path, action='append', default=[])
    publish.add_argument('--store', type=Path, required=True)
    publish.add_argument('--private-key', type=Path, required=True)
    publish.add_argument('--manifest', type=Path, required=True)
    publish.add_argument('--version', required=True)
    publish.add_argument('--build', type=int, required=True)
    apply = sub.add_parser('reconstruct')
    for name in ['manifest', 'public-key', 'base', 'store', 'destination']:
        apply.add_argument('--' + name, type=Path, required=True)
    apply.add_argument('--floor', type=int, required=True)
    args = parser.parse_args()
    if args.command == 'build':
        import getpass
        password = getpass.getpass('Signing-key passphrase: ').encode('utf-8')
        key = serialization.load_pem_private_key(args.private_key.read_bytes(), password=password)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError('Ed25519 key required')
        data, _ = build(args.target, args.base, args.store, key, args.version, args.build)
        write_atomic(args.manifest, data)
    else:
        key = serialization.load_pem_public_key(args.public_key.read_bytes())
        if not isinstance(key, Ed25519PublicKey):
            raise ValueError('Ed25519 key required')
        print(json.dumps(reconstruct(args.manifest.read_bytes(), key, args.base, args.store,
                                     args.destination, floor=args.floor), indent=2))

if __name__ == '__main__':
    main()
