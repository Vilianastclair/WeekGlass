import base64
import bz2
import copy
import json
from pathlib import Path
import random
import sys
import tempfile
import unittest
from datetime import timedelta
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import weekglass_updates as wg
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class UpdatesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='weekglass-update-test-')
        self.root = Path(self.tmp.name)
        self.base, self.target, self.store = (self.root / s for s in ['base', 'target', 'store'])
        self.base.mkdir()
        self.target.mkdir()
        self.key = Ed25519PrivateKey.generate()
        self.public = self.key.public_key()
        raw = random.Random(934).randbytes(96 * 1024)
        changed = bytearray(raw)
        changed[14000:14020] = b'updated-file-content'
        self.write(self.base, 'same.dll', b'shared binary' * 1024)
        self.write(self.target, 'same.dll', b'shared binary' * 1024)
        self.write(self.base, 'app.bin', raw)
        self.write(self.target, 'app.bin', bytes(changed))
        self.write(self.base, 'old-name.txt', b'renamed unchanged content')
        self.write(self.target, 'nested/new-name.txt', b'renamed unchanged content')
        self.write(self.base, 'removed.txt', b'removed')
        self.write(self.target, '新增说明.txt', '新的说明'.encode())
        self.manifest, self.payload = wg.build(self.target, [self.base], self.store,
                                             self.key, '0.15.0', 15)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, root, name, data):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def apply(self, manifest=None, destination=None):
        return wg.reconstruct(manifest or self.manifest, self.public, self.base,
                              self.store, destination or self.root / 'result', floor=14)

    def test_roundtrip_reuses_renames_removes_old_and_never_mutates_base(self):
        before = wg.inventory(self.base)
        stats = self.apply()
        self.assertEqual(wg.inventory(self.target), wg.inventory(self.root / 'result'))
        self.assertEqual(before, wg.inventory(self.base))
        self.assertEqual(stats['reused'], 2)
        self.assertEqual(stats['patched'], 1)
        self.assertEqual(stats['full'], 1)
        self.assertFalse((self.root / 'result' / 'removed.txt').exists())

    def test_selected_transfer_is_smaller_than_full_for_each_patch(self):
        for op in wg.plan(self.payload, self.base):
            if op['kind'] == 'bsdiff4':
                self.assertLess(op['object']['size'], op['file']['full']['size'])

    def test_republishing_reuses_content_addressed_objects(self):
        first = {p.relative_to(self.store): p.stat().st_size for p in self.store.rglob('*') if p.is_file()}
        wg.build(self.target, [self.base], self.store, self.key, '0.15.0', 15)
        second = {p.relative_to(self.store): p.stat().st_size for p in self.store.rglob('*') if p.is_file()}
        self.assertEqual(first, second)

    def test_locally_modified_base_falls_back_to_verified_full(self):
        (self.base / 'app.bin').write_bytes(b'locally modified')
        stats = self.apply()
        self.assertEqual(stats['patched'], 0)
        self.assertEqual(wg.inventory(self.target), wg.inventory(self.root / 'result'))

    def test_unsigned_manifest_tamper_rejected(self):
        outer = json.loads(self.manifest)
        payload = json.loads(base64.b64decode(outer['signed']))
        payload['build'] = 999
        outer['signed'] = base64.b64encode(json.dumps(payload).encode()).decode()
        with self.assertRaises(InvalidSignature):
            self.apply(json.dumps(outer).encode())
        self.assertFalse((self.root / 'result').exists())

    def test_sync_server_cannot_substitute_signing_key(self):
        foreign = Ed25519PrivateKey.generate().public_key()
        with self.assertRaises(ValueError):
            wg.verify(self.manifest, foreign)

    def test_signed_unsafe_paths_rejected(self):
        for path in ['../outside.txt', '/absolute', 'C:/outside', 'a\\b', 'CON.txt',
                     'sub/NUL', 'a/../x', 'x.', 'x ', 'a//b', 'a:stream', 'a?b']:
            with self.subTest(path=path):
                payload = copy.deepcopy(self.payload)
                payload['files'][0]['path'] = path
                with self.assertRaises(ValueError):
                    self.apply(wg.envelope(payload, self.key))
        self.assertFalse((self.root / 'result').exists())

    def test_signed_case_and_file_directory_collisions_rejected(self):
        for pair in [('Name', 'name'), ('a', 'a/b')]:
            with self.subTest(pair=pair):
                payload = copy.deepcopy(self.payload)
                payload['files'][0]['path'], payload['files'][1]['path'] = pair
                with self.assertRaises(ValueError):
                    wg.verify(wg.envelope(payload, self.key), self.public)

    def test_corrupted_object_rejected_and_staging_cleaned(self):
        op = next(op for op in wg.plan(self.payload, self.base) if op['kind'] == 'bsdiff4')
        path = wg.object_path(self.store, op['object']['sha256'])
        data = bytearray(path.read_bytes())
        data[-1] ^= 1
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.apply()
        self.assertFalse((self.root / 'result').exists())
        self.assertEqual(list(self.root.glob('.wg-staging-*')), [])

    def test_wrong_target_hash_rejected(self):
        payload = copy.deepcopy(self.payload)
        payload['files'][0]['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'target mismatch'):
            self.apply(wg.envelope(payload, self.key))
        self.assertFalse((self.root / 'result').exists())

    def test_rollback_expiry_platform_channel_rejected(self):
        for kwargs in [{'floor': 16}, {'channel': 'preview'}, {'platform': 'android-arm64'},
                       {'now': wg.utcnow() + timedelta(days=31)},
                       {'now': wg.utcnow() - timedelta(days=1)}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                wg.verify(self.manifest, self.public, **kwargs)

    def test_bounded_decompression_rejects_expansion_and_trailing_data(self):
        with self.assertRaises(ValueError):
            wg.decode(zlib.compress(b'A' * 1000000), 20)
        with self.assertRaises(ValueError):
            wg.decode(zlib.compress(b'A') + b'extra', 1)

    def test_bsdiff_stream_expansion_and_invalid_controls_rejected(self):
        def make_patch(control, diff, extra, size):
            streams = [bz2.compress(x) for x in (control, diff, extra)]
            return (b'BSDIFF40' + len(streams[0]).to_bytes(8, 'little') +
                    len(streams[1]).to_bytes(8, 'little') + size.to_bytes(8, 'little') +
                    b''.join(streams))
        zero = bytes(24)
        for patch in [make_patch(zero, b'A' * 1000000, b'', 1),
                      make_patch(bytes(1000000), b'', b'', 1),
                      make_patch((2).to_bytes(8, 'little') + bytes(16), b'a', b'', 1)]:
            with self.subTest(length=len(patch)), self.assertRaises(ValueError):
                wg.validate_patch(patch, 1)

    def test_existing_or_live_destination_rejected(self):
        for dest in [self.base, self.base / 'nested', self.target]:
            with self.subTest(dest=dest), self.assertRaises(ValueError):
                self.apply(destination=dest)

    def test_maximum_three_bases_and_store_outside_input(self):
        with self.assertRaises(ValueError):
            wg.build(self.target, [self.base] * 4, self.store, self.key, '0.15', 15)
        with self.assertRaises(ValueError):
            wg.build(self.target, [], self.target / 'objects', self.key, '0.15', 15)

    def test_base_changed_mid_staging_rejected(self):
        original = wg.get_object
        def changed_during_download(store, descriptor):
            data = original(store, descriptor)
            if descriptor['encoding'] == 'bsdiff4':
                (self.base / 'app.bin').write_bytes(b'changed after planning')
            return data
        from unittest.mock import patch
        with patch.object(wg, 'get_object', changed_during_download):
            with self.assertRaisesRegex(ValueError, 'Base changed'):
                self.apply()
        self.assertFalse((self.root / 'result').exists())


if __name__ == '__main__':
    unittest.main()
