"""Remove only unreachable release data after both public clients are verified.

Default is a read-only plan. --apply deletes the approved snapshot under the
publication lock without retaining backups. It never touches application data,
containers, host web configuration, or files outside the fixed update root.
"""
from __future__ import annotations

import argparse
import base64
from datetime import timedelta
import json
from pathlib import Path
import re
import subprocess

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

import build_publication as publication
import publish_ssh as remote
import weekglass_updates as wg

CHANNEL = re.compile(r'^channels/(windows-x64|android-arm64)/(stable|preview)\.json$')


def verified_plan(snapshot, public, verification, now=None):
    now = now or wg.utcnow()
    public_bytes = public.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    key_id = wg.digest(public_bytes)
    checks = []
    reports = [verification] if isinstance(verification, dict) else verification
    for report in reports:
        if (report.get('schema') != 1 or report.get('kind') != 'weekglass-public-download-verification' or
                report.get('verified') is not True or report.get('key_id') != key_id or
                not wg.parse_time(report['checked_at']) <= now < wg.parse_time(report['checked_at']) + timedelta(hours=24) or
                report.get('origin') not in ('https://cloud.viliana.cn/updates/v1/', 'https://cloud.viliana.cn:8443/updates/v1/')):
            raise ValueError('A recent pinned-key public download verification is required')
        checks.extend(report.get('channels', []))
    if snapshot.get('unknown'):
        raise ValueError('Unknown public files require explicit review before cleanup')
    files, documents = snapshot['files'], snapshot['documents']
    calculated = wg.digest(json.dumps(files, sort_keys=True, separators=(',', ':')).encode())
    if calculated != snapshot['snapshot_sha256']:
        raise ValueError('Invalid remote inventory fingerprint')
    keep, heads = {}, {}
    for name in files:
        match = CHANNEL.fullmatch(name)
        if not match:
            continue
        platform, channel = match.groups()
        head_data = base64.b64decode(documents[name], validate=True)
        head = publication.verify_channel(head_data, public, platform=platform, channel=channel, now=now)
        manifest_data = base64.b64decode(documents[head['manifest']['path']], validate=True)
        _, _, index = publication.verify_documents(head_data, manifest_data, public, platform=platform, channel=channel, now=now)
        for key, item in index.items():
            if key in keep and keep[key] != item:
                raise ValueError('Conflicting current object references')
            if files.get(key) != item:
                raise ValueError('Current channel references a missing or corrupted file')
            keep[key] = item
        heads[name] = head
    if keep != snapshot['keep']:
        raise ValueError('Remote reachable set differs from signed manifests')
    stable = [heads.get(publication.channel_path(platform)) for platform in wg.PLATFORMS]
    if any(head is None for head in stable):
        raise ValueError('Both stable platforms must be published before cleanup')
    for head in stable:
        matching = [check for check in checks if check['platform'] == head['platform'] and check['channel'] == 'stable']
        if len(matching) != 1:
            raise ValueError('Both platforms need their own successful client download verification')
        check = matching[0]
        name = publication.channel_path(head['platform'])
        if (check.get('reconstructed') is not True or check.get('conditional_304') is not True or check.get('range_206') is not True or
                check.get('build') != head['build'] or check.get('version') != head['version'] or
                check.get('channel_sha256') != keep[name]['sha256'] or check.get('manifest_sha256') != head['manifest']['sha256']):
            raise ValueError('Download verification does not match the current stable publication')
    obsolete = {name: item for name, item in files.items() if name not in keep}
    return {'snapshot_sha256': calculated, 'keep': keep, 'delete': obsolete}


def prune(public, verification, host='weekglass-update-host', apply=False):
    result = subprocess.run(remote.ssh_command(host, 'snapshot'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    snapshot = json.loads(result.stdout)
    plan = verified_plan(snapshot, public, verification)
    report = {'dry_run': not apply, 'retained_files': len(plan['keep']),
              'obsolete_files': len(plan['delete']), 'obsolete_bytes': sum(item['size'] for item in plan['delete'].values()),
              'obsolete_paths': sorted(plan['delete'])}
    if apply:
        result = subprocess.run(remote.ssh_command(host, 'prune'), input=json.dumps(plan).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        report.update(json.loads(result.stdout))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-key', type=Path, required=True)
    parser.add_argument('--verification-report', type=Path, required=True, action='append',
                        help='One dual-platform report or one report per platform')
    parser.add_argument('--host', default='weekglass-update-host')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    public = serialization.load_pem_public_key(args.public_key.read_bytes())
    if not isinstance(public, Ed25519PublicKey):
        raise ValueError('Ed25519 public key required')
    try:
        reports = [json.loads(path.read_text(encoding='utf-8')) for path in args.verification_report]
        result = prune(public, reports, args.host, args.apply)
    except subprocess.CalledProcessError as error:
        raise RuntimeError('SSH cleanup failed: ' + error.stderr.decode(errors='replace')[-2000:]) from None
    if args.report:
        wg.write_atomic(args.report, json.dumps(result, indent=2).encode())
    print(json.dumps(result))


if __name__ == '__main__':
    main()
