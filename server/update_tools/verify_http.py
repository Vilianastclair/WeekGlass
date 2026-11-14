"""Verify signed public channels and reconstruct selected releases with minimal GETs.

Only the verification report is written. Reconstructed bytes are checked in
memory; no installed application, user database, or backup copy is created.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

import bsdiff4
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

import build_publication as publication
import weekglass_updates as wg

PUBLIC_ORIGIN = 'https://cloud.viliana.cn/updates/v1/'
COMPATIBILITY_ORIGIN = 'https://cloud.viliana.cn:8443/updates/v1/'


class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        old, new = urllib.parse.urlsplit(request.full_url), urllib.parse.urlsplit(new_url)
        if (new.scheme, new.netloc) != (old.scheme, old.netloc):
            raise ValueError('Update download redirected outside the pinned origin')
        return super().redirect_request(request, fp, code, message, headers, new_url)


def fetch(origin, name, limit, headers=None, method='GET'):
    url = urllib.parse.urljoin(origin, wg.valid_path(name))
    request = urllib.request.Request(url, headers={'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache', **(headers or {})}, method=method)
    opener = urllib.request.build_opener(SameOriginRedirect())
    try:
        response = opener.open(request, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code == 304 or (method == 'HEAD' and error.code == 404):
            result = b'', error.headers, error.code
            error.close()
            return result
        raise
    with response:
        if response.headers.get('Content-Encoding', 'identity') != 'identity':
            raise ValueError('Update bytes must not be transformed by transport')
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError('HTTP update response exceeds its signed bound')
        return data, response.headers, response.status


def verify_availability(store, public, origin=PUBLIC_ORIGIN, platforms=wg.PLATFORMS, channel='stable'):
    _, index = publication.verify_release(store, public, platforms, channel)
    def check_file(pair):
        name, item = pair
        _, headers, status = fetch(origin, name, 0, method='HEAD')
        if status != 200 or int(headers.get('Content-Length', '-1')) != item['size']:
            raise ValueError('Referenced public file failed HTTP HEAD: ' + name)
    with ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(check_file, index.items()))
    return {'head_200_files': len(index), 'head_200_objects': sum(name.startswith('objects/') for name in index)}


def verify_metadata(store, public, origin=COMPATIBILITY_ORIGIN, platforms=wg.PLATFORMS):
    """Check legacy origins without downloading any complete object twice."""
    channels, received = [], 0
    for platform in platforms:
        name = publication.channel_path(platform)
        head_data, _, status = fetch(origin, name, publication.MAX_CHANNEL)
        if status != 200 or head_data != wg.child(store, name).read_bytes():
            raise ValueError('Compatibility origin is not serving the current signed channel')
        head = publication.verify_channel(head_data, public, platform=platform)
        manifest_data, _, status = fetch(origin, head['manifest']['path'], head['manifest']['size'])
        if status != 200:
            raise ValueError('Compatibility origin is missing the current manifest')
        publication.verify_documents(head_data, manifest_data, public, platform=platform)
        received += len(head_data) + len(manifest_data)
        channels.append({'platform': platform, 'build': head['build'], 'version': head['version'],
                         'channel_sha256': wg.digest(head_data), 'manifest_sha256': head['manifest']['sha256']})
    return {'verified': True, 'origin': origin, 'channels': channels, 'download_bytes': received}


def reconstruct_case(manifest, base, origin, downloaded):
    platform = manifest['platform']
    operations = wg.plan(manifest, base)
    object_bytes = 0
    for operation in operations:
        entry = operation['file']
        if operation['kind'] == 'reuse':
            raw = wg.release_file(base, operation['source'], platform).read_bytes()
        else:
            item = operation['object']
            key = item['sha256']
            if key not in downloaded:
                object_name = f'objects/{key[:2]}/{key}'
                data, _, status = fetch(origin, object_name, item['size'])
                if status != 200 or len(data) != item['size'] or wg.digest(data) != key:
                    raise ValueError('Public update object has an invalid length or digest')
                downloaded[key] = data
                object_bytes += len(data)
            data = downloaded[key]
            if len(data) != item['size']:
                raise ValueError('Conflicting downloaded object size')
            if operation['kind'] == 'raw':
                raw = data
            elif operation['kind'] == 'zlib':
                raw = wg.decode(data, entry['size'])
            else:
                source = wg.release_file(base, operation['source'], platform).read_bytes()
                if len(source) != item['base_size'] or wg.digest(source) != item['base_sha256']:
                    raise ValueError('Base changed during public update verification')
                wg.validate_patch(data, entry['size'])
                raw = bsdiff4.patch(source, data)
        if len(raw) != entry['size'] or wg.digest(raw) != entry['sha256']:
            raise ValueError('Public update failed exact target reconstruction')
    unique = {op['object']['sha256']: op['object']['size'] for op in operations if 'object' in op}
    sample = next((op['object'] for op in operations if 'object' in op and op['object']['size']), manifest['files'][0]['full'])
    return {'base': str(base), 'files': len(operations),
            'reused_files': sum(op['kind'] == 'reuse' for op in operations),
            'patched_files': sum(op['kind'] == 'bsdiff4' for op in operations),
            'full_files': sum(op['kind'] in ('raw', 'zlib') for op in operations),
            'client_object_bytes': sum(unique.values()), 'verification_object_bytes': object_bytes,
            'reconstructed': True}, sample


def verify_downloads(store, public, bases, origin=PUBLIC_ORIGIN, channel='stable', now=None):
    now = now or wg.utcnow()
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.query or parsed.fragment or not origin.endswith('/'):
        raise ValueError('An HTTPS update origin ending in / is required')
    heads, _ = publication.verify_release(store, public, tuple(bases), channel=channel, now=now)
    results, downloaded = [], {}
    for expected in heads:
        platform = expected['platform']
        name = publication.channel_path(platform, channel)
        expected_data = wg.child(store, name).read_bytes()
        head_data, headers, status = fetch(origin, name, publication.MAX_CHANNEL)
        if status != 200 or head_data != expected_data:
            raise ValueError('Public channel differs from the verified local publication')
        head = publication.verify_channel(head_data, public, platform=platform, channel=channel, now=now)
        manifest_data, _, status = fetch(origin, head['manifest']['path'], head['manifest']['size'])
        if status != 200:
            raise ValueError('Manifest did not return HTTP 200')
        _, manifest, _ = publication.verify_documents(head_data, manifest_data, public, platform=platform, channel=channel, now=now)
        candidates = bases[platform] if isinstance(bases[platform], (list, tuple)) else [bases[platform]]
        if not candidates:
            raise ValueError('At least one verification base is required for each platform')
        cases = []
        for base in candidates:
            case, sample = reconstruct_case(manifest, base, origin, downloaded)
            cases.append(case)
        total = len(head_data) + len(manifest_data)
        object_bytes = sum(case['verification_object_bytes'] for case in cases)
        total += object_bytes
        etag = headers.get('ETag')
        if not etag:
            raise ValueError('Channel ETag is required for conditional checks')
        _, _, conditional = fetch(origin, name, publication.MAX_CHANNEL, {'If-None-Match': etag})
        if conditional != 304:
            raise ValueError('Channel conditional request did not return HTTP 304')
        # A single byte verifies resumable objects without another full transfer.
        if sample['size']:
            sample_name = f'objects/{sample["sha256"][:2]}/{sample["sha256"]}'
            _, sample_headers, sample_status = fetch(origin, sample_name, 0, method='HEAD')
            sample_etag = sample_headers.get('ETag', '')
            if sample_status != 200 or not sample_etag.startswith('"') or not sample_etag.endswith('"'):
                raise ValueError('Resumable objects require a strong ETag')
            partial, range_headers, range_status = fetch(origin, sample_name, 1, {'Range': 'bytes=0-0', 'If-Range': sample_etag})
            if (range_status != 206 or len(partial) != 1 or range_headers.get('ETag') != sample_etag or
                    range_headers.get('Content-Range') != f'bytes 0-0/{sample["size"]}'):
                raise ValueError('Object range request did not return the exact HTTP 206 range')
            total += 1
        results.append({'platform': platform, 'channel': channel, 'version': head['version'], 'build': head['build'],
                        'channel_sha256': wg.digest(head_data), 'manifest_sha256': head['manifest']['sha256'],
                        'files': len(manifest['files']), 'cases': cases,
                        'object_bytes': object_bytes, 'download_bytes': total,
                        'conditional_304': True, 'range_206': True, 'strong_if_range': True, 'reconstructed': True})
    public_bytes = public.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    availability = verify_availability(store, public, origin, tuple(bases), channel)
    return {'schema': 1, 'kind': 'weekglass-public-download-verification', 'verified': True,
            'checked_at': wg.timestamp(now), 'origin': origin, 'key_id': wg.digest(public_bytes),
            'channels': results, 'download_bytes': sum(item['download_bytes'] for item in results), **availability}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, required=True)
    parser.add_argument('--windows-base', type=Path, action='append')
    parser.add_argument('--android-base', type=Path, action='append')
    parser.add_argument('--origin', default=PUBLIC_ORIGIN)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    bases = {platform: selected for platform, selected in
             [('windows-x64', args.windows_base), ('android-arm64', args.android_base)] if selected}
    if not bases:
        parser.error('Specify --windows-base, --android-base, or both')
    public = serialization.load_pem_public_key(args.public_key.read_bytes())
    if not isinstance(public, Ed25519PublicKey):
        raise ValueError('Ed25519 public key required')
    result = verify_downloads(args.store, public, bases, args.origin)
    wg.write_atomic(args.report, json.dumps(result, indent=2).encode())
    print(json.dumps(result))


if __name__ == '__main__':
    main()
