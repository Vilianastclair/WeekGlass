"""Publish both platforms, verify public reconstruction, then remove old data.

This is the normal release entry point. Cleanup runs by default only after all
checks pass, and the final report includes actual transmitted bytes. No backups
are made. --dry-run only checks local publications and the remote inventory.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

import publish_ssh
import prune_ssh
import verify_http
import weekglass_updates as wg


def publish_release(store, public, bases, report_path, host='weekglass-update-host', origin=verify_http.PUBLIC_ORIGIN, dry_run=False):
    report = {'schema': 1, 'kind': 'weekglass-release-publication', 'started_at': wg.timestamp(wg.utcnow()),
              'dry_run': dry_run, 'completed': False, 'stage': 'upload'}
    def save():
        wg.write_atomic(report_path, json.dumps(report, ensure_ascii=False, indent=2).encode())
    try:
        report['upload'] = publish_ssh.publish(store, public, host=host, platform='all', dry_run=dry_run)
        save()
        if dry_run:
            report['stage'] = 'dry-run-complete'
            return report
        report['stage'] = 'verify-downloads'
        save()
        report['verification'] = verify_http.verify_downloads(store, public, bases, origin)
        report['compatibility'] = verify_http.verify_metadata(store, public)
        report['stage'] = 'remove-unreachable'
        save()
        report['cleanup'] = prune_ssh.prune(public, report['verification'], host=host, apply=True)
        report['stage'] = 'verify-after-cleanup'
        save()
        report['after_cleanup'] = verify_http.verify_availability(store, public, origin)
        retired = [name for name in report['cleanup']['obsolete_paths'] if name.startswith('manifests/')]
        status_counts = {}
        for name in retired:
            _, _, status = verify_http.fetch(origin, name, 0, method='HEAD')
            status_counts[str(status)] = status_counts.get(str(status), 0) + 1
        report['after_cleanup']['retired_manifest_statuses'] = status_counts
        report['completed'] = True
        report['stage'] = 'complete'
        report['completed_at'] = wg.timestamp(wg.utcnow())
        return report
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, required=True)
    parser.add_argument('--windows-base', type=Path, required=True, action='append')
    parser.add_argument('--android-base', type=Path, required=True, action='append')
    parser.add_argument('--host', default='weekglass-update-host')
    parser.add_argument('--origin', default=verify_http.PUBLIC_ORIGIN)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    public = serialization.load_pem_public_key(args.public_key.read_bytes())
    if not isinstance(public, Ed25519PublicKey):
        raise ValueError('Ed25519 public key required')
    result = publish_release(args.store, public, {'windows-x64': args.windows_base, 'android-arm64': args.android_base},
                             args.report, args.host, args.origin, args.dry_run)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
