import base64
from datetime import timedelta
import io
import json
from pathlib import Path
import random
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_publication as pub
import publish_release as lifecycle
import publish_ssh as remote
import prune_ssh as cleanup
import verify_http as http
import weekglass_updates as wg
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class ReleaseLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = self.root / 'store'
        self.key = Ed25519PrivateKey.generate()
        self.public = self.key.public_key()
        self.now = wg.utcnow()
        seed = random.Random(42).randbytes(24000)
        self.windows_old, self.windows_new = self.root / 'windows-old', self.root / 'windows-new'
        self.windows_old.mkdir()
        self.windows_new.mkdir()
        for directory in (self.windows_old, self.windows_new):
            (directory / 'shared.dll').write_bytes(seed[:4000])
        (self.windows_old / 'weekglass.exe').write_bytes(seed)
        (self.windows_new / 'weekglass.exe').write_bytes(seed[:4000] + b'new binary' + seed[4010:])
        self.apk_old, self.apk_new = self.root / 'old.apk', self.root / 'new.apk'
        self.apk_old.write_bytes(seed * 2)
        self.apk_new.write_bytes(seed[:1000] + b'new apk' + seed[1007:] + seed)
        self.bases = {'windows-x64': self.windows_old, 'android-arm64': self.apk_old}
        self.old_releases = {}
        for platform, target in self.bases.items():
            self.old_releases[platform] = pub.build_publication(target, [], self.store, self.key, '0.20.0', 24,
                                                               now=self.now, platform=platform)
        self.old_head = (self.store / self.old_releases['windows-x64']['channel']).read_bytes()
        for platform, target in [('windows-x64', self.windows_new), ('android-arm64', self.apk_new)]:
            pub.build_publication(target, [self.bases[platform]], self.store, self.key, '0.20.2', 26,
                                  now=self.now + timedelta(seconds=1), platform=platform)

    def helper(self, action, wire=b'', root=None):
        root = root or self.store
        source = remote.REMOTE_SCRIPT.replace("ROOT=Path('/srv/weekglass-publication/updates/v1')", f'ROOT=Path({str(root)!r})')
        stdin = io.TextIOWrapper(io.BytesIO(wire), encoding='utf-8')
        stdout = io.StringIO()
        fcntl = types.SimpleNamespace(LOCK_EX=2, flock=lambda *args: None)
        with patch.dict(sys.modules, {'fcntl': fcntl}), patch.object(sys, 'argv', ['helper', action]), \
                patch.object(sys, 'stdin', stdin), patch.object(sys, 'stdout', stdout), \
                patch('shutil.disk_usage', return_value=types.SimpleNamespace(free=10 * 1024 ** 3)):
            exec(compile(source, 'local_remote_helper', 'exec'), {})
        return json.loads(stdout.getvalue())

    def fake_fetch(self, origin, name, limit, headers=None, method='GET'):
        path = self.store / name
        if not path.is_file():
            if method == 'HEAD':
                return b'', {}, 404
            raise FileNotFoundError(name)
        data = path.read_bytes()
        response_headers = {'ETag': '"' + wg.digest(data) + '"', 'Content-Length': str(len(data))}
        if method == 'HEAD':
            return b'', response_headers, 200
        if headers and headers.get('If-None-Match') == response_headers['ETag']:
            return b'', response_headers, 304
        if headers and headers.get('Range') == 'bytes=0-0':
            return data[:1], {**response_headers, 'Content-Range': f'bytes 0-0/{len(data)}'}, 206
        if len(data) > limit:
            raise ValueError('Response exceeds limit')
        return data, response_headers, 200

    def verification(self, bases=None):
        with patch.object(http, 'fetch', side_effect=self.fake_fetch):
            return http.verify_downloads(self.store, self.public, bases or self.bases,
                                         now=self.now + timedelta(seconds=2))

    def test_android_direct_apk_raw_and_delta_roundtrip(self):
        head, manifest, _ = pub.verify_publication(self.store, self.public, platform='android-arm64')
        record = manifest['files'][0]
        self.assertEqual(record['path'], 'weekglass.apk')
        self.assertEqual(record['full'], {'encoding': 'raw', 'sha256': record['sha256'], 'size': record['size']})
        self.assertEqual(len(record['patches']), 1)
        self.assertLess(record['patches'][0]['size'], record['full']['size'])
        destination = self.root / 'reconstructed'
        wg.reconstruct((self.store / head['manifest']['path']).read_bytes(), self.public,
                       self.apk_old, self.store, destination, platform='android-arm64')
        self.assertEqual((destination / 'weekglass.apk').read_bytes(), self.apk_new.read_bytes())

    def test_android_rejects_extra_files_and_compressed_apk(self):
        with self.assertRaises(ValueError):
            pub.build_publication(self.windows_new, [], self.store, self.key, '0.20.2', 26, platform='android-arm64')
        _, manifest, _ = pub.verify_publication(self.store, self.public, platform='android-arm64')
        manifest['files'][0]['full']['encoding'] = 'zlib'
        with self.assertRaises(ValueError):
            wg.verify(wg.envelope(manifest, self.key), self.public, platform='android-arm64')

    def test_joint_publication_refuses_different_builds(self):
        pub.build_publication(self.apk_new, [], self.store, self.key, '0.20.3', 27, platform='android-arm64')
        with self.assertRaises(ValueError), patch.object(remote.subprocess, 'run') as ssh:
            remote.publish(self.store, self.public, platform='all')
        ssh.assert_not_called()

    def test_public_downloads_choose_smallest_and_deduplicate_multiple_bases(self):
        bases = {platform: [base, base] for platform, base in self.bases.items()}
        report = self.verification(bases)
        self.assertEqual(len(report['channels']), 2)
        for result in report['channels']:
            self.assertEqual(result['cases'][0]['patched_files'], 1)
            self.assertEqual(result['cases'][1]['verification_object_bytes'], 0)
            self.assertTrue(result['reconstructed'])
        self.assertGreater(report['head_200_objects'], 0)

    def test_cleanup_removes_old_apk_and_manifests_but_retains_current_patches(self):
        retired = self.store / 'channels/windows-x64/stable.withdrawn-build-24.json'
        retired.write_bytes(self.old_head)
        snapshot = self.helper('snapshot')
        plan = cleanup.verified_plan(snapshot, self.public, self.verification(), now=self.now + timedelta(seconds=3))
        old_apk_hash = wg.digest(self.apk_old.read_bytes())
        old_apk_object = f'objects/{old_apk_hash[:2]}/{old_apk_hash}'
        self.assertIn(old_apk_object, plan['delete'])
        _, manifest, _ = pub.verify_publication(self.store, self.public, platform='android-arm64')
        patch_hash = manifest['files'][0]['patches'][0]['sha256']
        self.assertIn(f'objects/{patch_hash[:2]}/{patch_hash}', plan['keep'])
        result = self.helper('prune', json.dumps(plan).encode())
        self.assertTrue(result['remote_verified'])
        self.assertFalse((self.store / old_apk_object).exists())
        self.assertFalse(retired.exists())
        pub.verify_release(self.store, self.public)
        self.assertEqual(self.helper('snapshot')['files'], plan['keep'])

    def test_cleanup_keeps_both_current_heads_when_only_windows_advances(self):
        pub.build_publication(self.windows_new, [self.windows_old], self.store, self.key, '0.20.3', 27,
                              now=self.now + timedelta(seconds=1), platform='windows-x64')
        snapshot = self.helper('snapshot')
        reports = [self.verification({platform: base}) for platform, base in self.bases.items()]
        self.assertEqual([report['channels'][0]['build'] for report in reports], [27, 26])
        for broken in ([reports[0]], [reports[1]], [*reports, reports[0]]):
            with self.assertRaisesRegex(ValueError, 'Both platforms need their own'):
                cleanup.verified_plan(snapshot, self.public, broken, now=self.now + timedelta(seconds=3))
        stale = {**reports[1], 'checked_at': wg.timestamp(self.now - timedelta(days=2))}
        with self.assertRaisesRegex(ValueError, 'recent pinned-key'):
            cleanup.verified_plan(snapshot, self.public, [reports[0], stale], now=self.now + timedelta(seconds=3))
        plan = cleanup.verified_plan(snapshot, self.public, reports, now=self.now + timedelta(seconds=3))
        for platform, build in zip(self.bases, (27, 26)):
            head, _, index = pub.verify_publication(self.store, self.public, platform=platform)
            self.assertEqual(head['build'], build)
            self.assertEqual({name: plan['keep'][name] for name in index}, index)
        result = self.helper('prune', json.dumps(plan).encode())
        self.assertTrue(result['remote_verified'])
        self.assertEqual(self.helper('snapshot')['files'], plan['keep'])

    def test_cleanup_retains_the_named_corresponding_source_archives(self):
        directory = self.store / 'source'
        directory.mkdir()
        admin_source = directory / 'weekglass-cloud-20261117-admin.tar.gz'
        admin_source.write_bytes(b'prior corresponding source')
        snapshot = self.helper('snapshot')
        self.assertEqual(snapshot['unknown'], [])
        self.assertNotIn('source/' + admin_source.name, snapshot['files'])
        plan = cleanup.verified_plan(snapshot, self.public, self.verification(), now=self.now + timedelta(seconds=3))
        self.assertTrue(plan['delete'])

        new_source = directory / 'weekglass-cloud-20261118-schedule.tar.gz'
        new_source.write_bytes(b'new corresponding source')
        result = self.helper('prune', json.dumps(plan).encode())

        self.assertTrue(result['remote_verified'])
        self.assertEqual(result['removed_files'], len(plan['delete']))
        self.assertEqual(admin_source.read_bytes(), b'prior corresponding source')
        self.assertEqual(new_source.read_bytes(), b'new corresponding source')

    def test_cleanup_refuses_an_unlisted_archive_after_planning(self):
        verification = self.verification()
        plan = cleanup.verified_plan(self.helper('snapshot'), self.public, verification,
                                     now=self.now + timedelta(seconds=3))
        name = 'source/weekglass-cloud-20261118-schedule-deploy.tar.gz'
        unknown = self.store / name
        unknown.parent.mkdir()
        unknown.write_bytes(b'unreviewed')

        snapshot = self.helper('snapshot')
        self.assertEqual(snapshot['unknown'], [name])
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            cleanup.verified_plan(snapshot, self.public, verification, now=self.now + timedelta(seconds=3))
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            self.helper('prune', json.dumps(plan).encode())
        self.assertTrue(all((self.store / item).is_file() for item in plan['delete']))

    def test_snapshot_refuses_symlink_with_corresponding_source_name(self):
        source = self.store / 'source' / 'weekglass-cloud-20261118-schedule.tar.gz'
        source.parent.mkdir()
        try:
            source.symlink_to(self.apk_old)
        except OSError as exc:
            if getattr(exc, 'winerror', None) == 1314:
                self.skipTest('Windows symlink privilege is unavailable')
            raise
        with self.assertRaisesRegex(ValueError, 'Symlinks forbidden'):
            self.helper('snapshot')

    def test_cleanup_requires_successful_current_dual_downloads(self):
        snapshot = self.helper('snapshot')
        report = self.verification()
        for mutation in ('one-platform', 'wrong-head', 'wrong-manifest', 'wrong-build', 'wrong-version',
                         'failed-reconstruction', 'failed-conditional', 'failed-range', 'stale'):
            broken = json.loads(json.dumps(report))
            if mutation == 'one-platform':
                broken['channels'].pop()
            elif mutation == 'wrong-head':
                broken['channels'][0]['channel_sha256'] = '0' * 64
            elif mutation == 'wrong-manifest':
                broken['channels'][1]['manifest_sha256'] = '0' * 64
            elif mutation == 'wrong-build':
                broken['channels'][1]['build'] -= 1
            elif mutation == 'wrong-version':
                broken['channels'][1]['version'] = '0.20.0'
            elif mutation == 'failed-reconstruction':
                broken['channels'][0]['reconstructed'] = False
            elif mutation == 'failed-conditional':
                broken['channels'][0]['conditional_304'] = False
            elif mutation == 'failed-range':
                broken['channels'][0]['range_206'] = False
            else:
                broken['checked_at'] = wg.timestamp(self.now - timedelta(days=2))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                cleanup.verified_plan(snapshot, self.public, broken, now=self.now + timedelta(seconds=3))

    def test_cleanup_refuses_unknown_files_and_changed_snapshot(self):
        snapshot = self.helper('snapshot')
        plan = cleanup.verified_plan(snapshot, self.public, self.verification(), now=self.now + timedelta(seconds=3))
        wg.put(self.store, b'unexpected new object', 'raw')
        with self.assertRaisesRegex(ValueError, 'Store changed'):
            self.helper('prune', json.dumps(plan).encode())
        (self.store / 'unreviewed.apk').write_bytes(b'unreviewed')
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            cleanup.verified_plan(self.helper('snapshot'), self.public, self.verification(), now=self.now + timedelta(seconds=3))

    def test_cleanup_cannot_delete_a_reachable_patch(self):
        plan = cleanup.verified_plan(self.helper('snapshot'), self.public, self.verification(), now=self.now + timedelta(seconds=3))
        _, manifest, _ = pub.verify_publication(self.store, self.public, platform='android-arm64')
        patch_hash = manifest['files'][0]['patches'][0]['sha256']
        name = f'objects/{patch_hash[:2]}/{patch_hash}'
        plan['delete'][name] = plan['keep'].pop(name)
        with self.assertRaisesRegex(ValueError, 'retain every current'):
            self.helper('prune', json.dumps(plan).encode())
        self.assertTrue((self.store / name).is_file())

    def test_missing_current_object_blocks_cleanup(self):
        report = self.verification()
        _, _, index = pub.verify_publication(self.store, self.public, platform='android-arm64')
        name = next(name for name in index if name.startswith('objects/'))
        (self.store / name).unlink()
        with self.assertRaisesRegex(ValueError, 'missing or corrupted'):
            cleanup.verified_plan(self.helper('snapshot'), self.public, report, now=self.now + timedelta(seconds=3))

    def test_remote_joint_upload_checks_objects_before_head_commit(self):
        _, index = pub.verify_release(self.store, self.public)
        destination = self.root / 'remote'
        destination.mkdir()
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            raw = json.dumps(index).encode()
            info = tarfile.TarInfo('INDEX.json')
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
            for name in index:
                raw = (self.store / name).read_bytes()
                info = tarfile.TarInfo(name)
                info.size = len(raw)
                archive.addfile(info, io.BytesIO(raw))
        self.helper('upload', output.getvalue(), destination)
        pub.verify_release(destination, self.public)

    def test_normal_release_always_cleans_and_checks_live_heads_afterwards(self):
        verification = self.verification()
        events = []
        def upload(*args, **kwargs):
            events.append('upload')
            self.assertEqual(kwargs['platform'], 'all')
            return {'needed_bytes': 123}
        def verify(*args, **kwargs):
            events.append('verify')
            return verification
        def prune(*args, **kwargs):
            events.append('prune')
            self.assertTrue(kwargs['apply'])
            plan = cleanup.verified_plan(self.helper('snapshot'), self.public, verification, now=self.now + timedelta(seconds=3))
            result = self.helper('prune', json.dumps(plan).encode())
            return {**result, 'obsolete_paths': sorted(plan['delete'])}
        with patch.object(remote, 'publish', side_effect=upload), patch.object(http, 'verify_downloads', side_effect=verify), \
                patch.object(cleanup, 'prune', side_effect=prune), patch.object(http, 'fetch', side_effect=self.fake_fetch):
            report = lifecycle.publish_release(self.store, self.public, self.bases, self.root / 'report.json')
        self.assertEqual(events, ['upload', 'verify', 'prune'])
        self.assertTrue(report['completed'])
        self.assertGreater(report['after_cleanup']['head_200_objects'], 0)
        self.assertEqual(set(report['after_cleanup']['retired_manifest_statuses']), {'404'})

    def test_failed_public_verification_never_cleans(self):
        with patch.object(remote, 'publish', return_value={}), \
                patch.object(http, 'verify_downloads', side_effect=ValueError('bad download')), patch.object(cleanup, 'prune') as prune:
            with self.assertRaises(ValueError):
                lifecycle.publish_release(self.store, self.public, self.bases, self.root / 'report.json')
        prune.assert_not_called()
        report = json.loads((self.root / 'report.json').read_text())
        self.assertFalse(report['completed'])
        self.assertEqual(report['stage'], 'verify-downloads')


if __name__ == '__main__':
    unittest.main()
