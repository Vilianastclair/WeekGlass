"""Build a signed update publication locally; does not upload or install it."""
from __future__ import annotations
import argparse
import base64
from datetime import timedelta
import getpass
import json
from pathlib import Path
import re

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
import weekglass_updates as wg

MAX_CHANNEL = 16 * 1024


def channel_path(platform='windows-x64', channel='stable'):
    if platform not in wg.PLATFORMS or channel not in ('stable', 'preview'):
        raise ValueError('Unsupported platform/channel')
    return f'channels/{platform}/{channel}.json'


def verify_channel(data, public, floor=0, platform='windows-x64', channel='stable', now=None):
    channel_path(platform, channel)
    if len(data) > MAX_CHANNEL:
        raise ValueError('Channel metadata too large')
    outer = json.loads(data)
    public_bytes = public.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    if outer.get('format') != 1 or outer.get('key_id') != wg.digest(public_bytes):
        raise ValueError('Untrusted channel signing identity')
    raw = base64.b64decode(outer['signed'], validate=True)
    public.verify(base64.b64decode(outer['signature'], validate=True), raw)
    payload = json.loads(raw)
    now = now or wg.utcnow()
    if (payload.get('schema') != 1 or payload.get('kind') != 'weekglass-channel' or
            payload.get('product') != 'weekglass' or payload.get('platform') != platform or
            payload.get('channel') != channel or type(payload.get('build')) is not int or
            payload['build'] < max(1, floor) or not isinstance(payload.get('version'), str) or not payload['version']):
        raise ValueError('Invalid channel identity or rollback')
    generated, expires = wg.parse_time(payload['generated_at']), wg.parse_time(payload['expires_at'])
    if not generated <= now + timedelta(minutes=5) or not now < expires <= generated + timedelta(days=7):
        raise ValueError('Expired or future channel metadata')
    descriptor = payload['manifest']
    if (not wg.SHA.fullmatch(descriptor['sha256']) or type(descriptor['size']) is not int or
            not 0 < descriptor['size'] <= wg.MAX_MANIFEST or
            descriptor['path'] != f'manifests/{platform}/{channel}/{payload["build"]}/{descriptor["sha256"]}.json'):
        raise ValueError('Unsafe manifest reference')
    return payload


def verify_documents(head_data, manifest_data, public, floor=0, platform='windows-x64', channel='stable', now=None):
    """Verify public metadata and derive the complete set that must stay live."""
    head = verify_channel(head_data, public, floor, platform, channel, now)
    descriptor = head['manifest']
    if len(manifest_data) != descriptor['size'] or wg.digest(manifest_data) != descriptor['sha256']:
        raise ValueError('Channel/manifest integrity mismatch')
    manifest = wg.verify(manifest_data, public, platform, channel, floor, now)
    if manifest['build'] != head['build'] or manifest['version'] != head['version']:
        raise ValueError('Channel/manifest release mismatch')
    files = {}
    for record in manifest['files']:
        for item in [record['full'], *record['patches']]:
            path = f'objects/{item["sha256"][:2]}/{item["sha256"]}'
            value = {'sha256': item['sha256'], 'size': item['size']}
            if path in files and files[path] != value:
                raise ValueError('Conflicting object descriptors')
            files[path] = value
    files[descriptor['path']] = {'sha256': descriptor['sha256'], 'size': descriptor['size']}
    files[channel_path(platform, channel)] = {'sha256': wg.digest(head_data), 'size': len(head_data)}
    return head, manifest, files


def verify_publication(store, public, floor=0, platform='windows-x64', channel='stable', now=None):
    head_data = wg.child(store, channel_path(platform, channel)).read_bytes()
    head = verify_channel(head_data, public, floor, platform, channel, now)
    result = verify_documents(head_data, wg.child(store, head['manifest']['path']).read_bytes(),
                              public, floor, platform, channel, now)
    for name, item in result[2].items():
        if name.startswith('objects/'):
            wg.get_object(store, item)
    return result


def verify_release(store, public, platforms=wg.PLATFORMS, channel='stable', now=None):
    """A joint publication must point both platforms at the same release."""
    releases, files = [], {}
    for platform in platforms:
        head, manifest, index = verify_publication(store, public, platform=platform, channel=channel, now=now)
        if releases and (head['build'], head['version']) != (releases[0]['build'], releases[0]['version']):
            raise ValueError('All platforms must use the same version and build')
        for name, item in index.items():
            if name in files and files[name] != item:
                raise ValueError('Conflicting platform objects')
            files[name] = item
        releases.append(head)
    if not releases:
        raise ValueError('Choose at least one platform')
    return releases, files


def build_publication(target, bases, store, key, version, build, channel='stable', now=None, platform='windows-x64'):
    now = now or wg.utcnow()
    head_name = channel_path(platform, channel)
    existing = wg.child(store, head_name)
    old_manifest = None
    if existing.exists():
        # Expired heads may be renewed but never silently rolled back.
        outer = json.loads(existing.read_bytes())
        old = json.loads(base64.b64decode(outer['signed'], validate=True))
        public = key.public_key()
        public.verify(base64.b64decode(outer['signature'], validate=True), base64.b64decode(outer['signed'], validate=True))
        if old['build'] > build or (old['build'] == build and old['version'] != version):
            raise ValueError('Publication cannot roll back the channel')
        if old['build'] == build:
            previous = wg.child(store, old['manifest']['path']).read_bytes()
            if wg.digest(previous) != old['manifest']['sha256']:
                raise ValueError('Existing manifest integrity mismatch')
            wrapped = json.loads(previous)
            previous_raw = base64.b64decode(wrapped['signed'], validate=True)
            public.verify(base64.b64decode(wrapped['signature'], validate=True), previous_raw)
            old_manifest = json.loads(previous_raw)
    data, payload = wg.build(target, bases, store, key, version, build, platform=platform, channel=channel, now=now)
    if old_manifest is not None:
        identity = lambda manifest: [(f['path'], f['size'], f['sha256']) for f in manifest['files']]
        if identity(old_manifest) != identity(payload):
            raise ValueError('A published build cannot change its installed file contents; increment build')
    manifest_hash = wg.digest(data)
    manifest_name = f'manifests/{platform}/{channel}/{build}/{manifest_hash}.json'
    wg.write_atomic(wg.child(store, manifest_name), data)
    head = {'schema': 1, 'kind': 'weekglass-channel', 'product': 'weekglass',
            'platform': platform, 'channel': channel, 'version': version, 'build': build,
            'generated_at': wg.timestamp(now), 'expires_at': wg.timestamp(now + timedelta(days=7)),
            'manifest': {'path': manifest_name, 'sha256': manifest_hash, 'size': len(data)}}
    wg.write_atomic(existing, wg.envelope(head, key))
    _, _, files = verify_publication(store, key.public_key(), floor=build, platform=platform, channel=channel, now=now)
    return {'build': build, 'version': version, 'platform': platform, 'channel': head_name, 'manifest': manifest_name,
            'objects': sum(x.startswith('objects/') for x in files),
            'publication_bytes': sum(x['size'] for x in files.values()), 'verified': True}


def load_private(path, passphrase_file=None):
    # Passphrase is never in argv/environment or tool output; preserve exact bytes.
    password = passphrase_file.read_bytes() if passphrase_file else getpass.getpass('Signing-key passphrase: ').encode()
    key = serialization.load_pem_private_key(path.read_bytes(), password=password)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError('Ed25519 private key required')
    return key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--base', type=Path, action='append', default=[])
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--passphrase-file', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--channel', choices=('stable', 'preview'), default='stable')
    parser.add_argument('--platform', choices=wg.PLATFORMS, default='windows-x64')
    args = parser.parse_args()
    print(json.dumps(build_publication(args.target, args.base, args.store,
                     load_private(args.private_key, args.passphrase_file), args.version, args.build,
                     args.channel, platform=args.platform)))


if __name__ == '__main__':
    main()
