"""Publish verified missing update objects through SSH to a fixed WeekGlass root.

The server never receives signing keys or computes binary patches. Only missing
objects and changed metadata are uploaded. All writes are under REMOTE_ROOT.
"""
from __future__ import annotations
import argparse
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
import build_publication as publication
import weekglass_updates as wg

REMOTE_ROOT = '/srv/weekglass-publication/updates/v1'

# Python 3.6-compatible: the existing server's system interpreter may be old.
# No secret material is sent, and no caller-provided filesystem root is accepted.
REMOTE_SCRIPT = Path(__file__).with_name('remote_store.py').read_text(encoding='utf-8')


def ssh_command(host, action):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}', host):
        raise ValueError('Use a configured SSH host alias')
    return ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', host,
            'python3 -c ' + shlex.quote(REMOTE_SCRIPT) + ' ' + shlex.quote(action)]


def publish(store, public, host='weekglass-update-host', channel='stable', dry_run=False, platform='windows-x64'):
    platforms = wg.PLATFORMS if platform == 'all' else (platform,)
    heads, index = publication.verify_release(store, public, platforms=platforms, channel=channel)
    head = heads[0]
    result = subprocess.run(ssh_command(host, 'inventory'), input=json.dumps(index).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    missing = json.loads(result.stdout)['missing']
    if len(missing) != len(set(missing)) or any(name not in index for name in missing):
        raise ValueError('Invalid remote inventory')
    selected = {name: index[name] for name in missing}
    report = {'build': head['build'], 'version': head['version'], 'needed_files': len(selected),
              'needed_bytes': sum(x['size'] for x in selected.values()),
              'reused_files': len(index)-len(selected), 'dry_run': dry_run,
              'platforms': list(platforms), 'channel': channel}
    if dry_run or not selected:
        report['remote_verified'] = not selected
        return report
    with tempfile.TemporaryFile() as archive:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            metadata = json.dumps(selected).encode()
            info = tarfile.TarInfo('INDEX.json'); info.size = len(metadata)
            tar.addfile(info, io.BytesIO(metadata))
            for name in sorted(selected):
                data = wg.child(store, name).read_bytes()
                if len(data) != index[name]['size'] or wg.digest(data) != index[name]['sha256']:
                    raise ValueError('Local publication changed after validation')
                info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o644
                tar.addfile(info, io.BytesIO(data))
        report['transfer_archive_bytes'] = archive.tell()
        archive.seek(0)
        result = subprocess.run(ssh_command(host, 'upload'), stdin=archive,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        report.update(json.loads(result.stdout))
    # Verify all referenced objects and final head at the destination, using
    # the expected hashes produced from the independently pinned public key.
    result = subprocess.run(ssh_command(host, 'inventory'), input=json.dumps(index).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    if json.loads(result.stdout)['missing']:
        raise ValueError('Post-publication remote integrity mismatch')
    report['remote_verified'] = True
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, required=True)
    parser.add_argument('--host', default='weekglass-update-host')
    parser.add_argument('--channel', choices=('stable', 'preview'), default='stable')
    parser.add_argument('--platform', choices=(*wg.PLATFORMS, 'all'), default='windows-x64')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    public = serialization.load_pem_public_key(args.public_key.read_bytes())
    if not isinstance(public, Ed25519PublicKey):
        raise ValueError('Ed25519 public key required')
    try:
        print(json.dumps(publish(args.store, public, args.host, args.channel, args.dry_run, args.platform)))
    except subprocess.CalledProcessError as error:
        # Remote code handles only public metadata, not any credential values.
        raise RuntimeError('SSH publication failed: ' + error.stderr.decode(errors='replace')[-2000:]) from None


if __name__ == '__main__':
    main()
