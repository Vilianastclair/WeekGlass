"""Benchmark actual local release folders. Uses an ephemeral, in-memory test key."""
import argparse
import json
from pathlib import Path
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import weekglass_updates as wg


def disk_bytes(store):
    return sum(p.stat().st_size for p in store.rglob('*') if p.is_file())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Benchmark output must be a new directory')
    args.output.mkdir(parents=True)
    key = Ed25519PrivateKey.generate()
    store = args.output / 'store'
    before = wg.inventory(args.base)
    target = wg.inventory(args.target)
    started = time.perf_counter()
    wg.build(args.base, [], store, key, '0.14.0', 15)
    old_store_size = disk_bytes(store)
    manifest, payload = wg.build(args.target, [args.base], store, key, '0.15.0', 16)
    build_seconds = time.perf_counter() - started
    (args.output / 'test-manifest.json').write_bytes(manifest)
    (args.output / 'test-public-key.pem').write_bytes(key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
    operations = wg.plan(payload, args.base)
    full_files = {op['file']['full']['sha256']: op['file']['full']['size']
                  for op in operations if op['kind'] != 'reuse'}
    started = time.perf_counter()
    stats = wg.reconstruct(manifest, key.public_key(), args.base, store,
                           args.output / 'reconstructed', floor=15)
    reconstruction_seconds = time.perf_counter() - started
    assert wg.inventory(args.output / 'reconstructed') == target
    assert wg.inventory(args.base) == before
    full_zip_bytes = args.zip.stat().st_size
    report = {
        'generated_at': wg.timestamp(wg.utcnow()),
        'base_version': '0.14.0', 'target_version': '0.15.0',
        'base_build': 15, 'target_build': 16,
        'platform': 'windows-x64', 'prototype_only': True,
        'verification': 'All reconstructed file hashes match target; base unchanged.',
        'full_zip_bytes': full_zip_bytes,
        'file_level_update_bytes_with_manifest': sum(full_files.values()) + len(manifest),
        'selected_update': stats,
        'saved_percent_vs_full_zip': round((1 - stats['download_bytes'] / full_zip_bytes) * 100, 4),
        'publisher_new_object_bytes': disk_bytes(store) - old_store_size,
        'publisher_upload_bytes_with_manifest': disk_bytes(store) - old_store_size + len(manifest),
        'base_object_store_bytes': old_store_size,
        'combined_object_store_bytes': disk_bytes(store),
        'unpacked_target_bytes': sum(entry['size'] for entry in target.values()),
        'build_seconds_including_base_publication': round(build_seconds, 3),
        'reconstruction_seconds': round(reconstruction_seconds, 3),
        'changed_files': [{'path': op['file']['path'], 'selected': op['kind'],
                          'selected_bytes': op['object']['size'],
                          'compressed_or_raw_full_bytes': op['file']['full']['size'],
                          'target_uncompressed_bytes': op['file']['size']}
                         for op in operations if op['kind'] != 'reuse'],
        'limits': 'Local bytes excluding HTTP/TLS overhead; temporary test signing identity, '
                  'no live installation, publication or production signing key.'}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
