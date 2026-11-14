import base64
from datetime import timedelta
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import types
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_publication as pub
import publish_ssh as remote
import weekglass_updates as wg
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.base, self.target, self.store = [self.root/x for x in ['base', 'target', 'store']]
        self.base.mkdir(); self.target.mkdir()
        (self.base/'app.exe').write_bytes(b'previous release' * 1000)
        (self.target/'app.exe').write_bytes(b'new release' * 1000)
        self.key = Ed25519PrivateKey.generate()
        self.now = wg.utcnow()
        self.result = pub.build_publication(self.target, [self.base], self.store, self.key, '0.15.0', 16, now=self.now)

    def tearDown(self):
        self.tmp.cleanup()

    def head(self):
        return (self.store/self.result['channel']).read_bytes()

    def test_signed_channel_binds_manifest_and_every_object(self):
        head, manifest, files = pub.verify_publication(self.store, self.key.public_key(), floor=16)
        self.assertEqual(head['build'], manifest['build'])
        self.assertEqual(head['manifest']['path'], self.result['manifest'])
        self.assertEqual(sum(item['size'] for item in files.values()), self.result['publication_bytes'])
        self.assertTrue(any(x.startswith('objects/') for x in files))

    def test_channel_tampering_and_foreign_key_fail(self):
        outer = json.loads(self.head())
        raw = json.loads(base64.b64decode(outer['signed']))
        raw['build'] = 99
        outer['signed'] = base64.b64encode(json.dumps(raw).encode()).decode()
        with self.assertRaises(InvalidSignature):
            pub.verify_channel(json.dumps(outer).encode(), self.key.public_key())
        with self.assertRaises(ValueError):
            pub.verify_channel(self.head(), Ed25519PrivateKey.generate().public_key())

    def test_channel_expiry_rollback_platform_and_origin_rules(self):
        for kwargs in ({'floor':17}, {'platform':'android-arm64'}, {'channel':'preview'}, {'now':self.now+timedelta(days=8)}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                pub.verify_channel(self.head(), self.key.public_key(), **kwargs)
        raw = pub.verify_channel(self.head(), self.key.public_key())
        raw['manifest']['path'] = 'https://malicious.invalid/app.exe'
        with self.assertRaises(ValueError):
            pub.verify_channel(wg.envelope(raw,self.key), self.key.public_key())

    def test_corrupt_manifest_or_object_is_rejected_before_upload(self):
        manifest_path = self.store/self.result['manifest']
        saved = manifest_path.read_bytes()
        manifest_path.write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            pub.verify_publication(self.store, self.key.public_key())
        manifest_path.write_bytes(saved)
        _, _, files = pub.verify_publication(self.store, self.key.public_key())
        object_name = next(x for x in files if x.startswith('objects/'))
        (self.store/object_name).write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            remote.publish(self.store,self.key.public_key())

    def test_publisher_cannot_lower_existing_build(self):
        with self.assertRaises(ValueError):
            pub.build_publication(self.target,[self.base],self.store,self.key,'0.14.0',15)

    def test_metadata_renewal_preserves_build_contents(self):
        pub.build_publication(self.target,[self.base],self.store,self.key,'0.15.0',16,now=self.now+timedelta(minutes=1))
        (self.target/'app.exe').write_bytes(b'changed build with reused version')
        with self.assertRaises(ValueError):
            pub.build_publication(self.target,[self.base],self.store,self.key,'0.15.0',16)

    def test_no_change_sends_no_objects(self):
        with patch.object(remote.subprocess,'run',return_value=subprocess.CompletedProcess([],0,b'{"missing":[]}')) as call:
            report = remote.publish(self.store,self.key.public_key())
        self.assertEqual(call.call_count,1)
        self.assertEqual(report['needed_bytes'],0)

    def test_only_missing_bytes_sent_and_reverified(self):
        head, _, index = pub.verify_publication(self.store,self.key.public_key())
        selected = [self.result['channel']]
        calls=[]
        def fake_run(command,**kwargs):
            calls.append(command)
            if len(calls)==1:
                return subprocess.CompletedProcess([],0,json.dumps({'missing':selected}).encode())
            if len(calls)==2:
                with tarfile.open(fileobj=kwargs['stdin'],mode='r') as tar:
                    names=tar.getnames()
                    self.assertEqual(set(names),{'INDEX.json',*selected})
                    self.assertEqual(tar.extractfile(selected[0]).read(),self.head())
                return subprocess.CompletedProcess([],0,json.dumps({'uploaded_files':1,'uploaded_bytes':index[selected[0]]['size']}).encode())
            return subprocess.CompletedProcess([],0,b'{"missing":[]}')
        with patch.object(remote.subprocess,'run',side_effect=fake_run):
            result=remote.publish(self.store,self.key.public_key())
        self.assertTrue(result['remote_verified'])
        self.assertEqual(len(calls),3)
        self.assertEqual(result['needed_files'],1)

    def test_bad_inventory_cannot_request_other_files(self):
        with patch.object(remote.subprocess,'run',return_value=subprocess.CompletedProcess([],0,b'{"missing":["../../secret"]}')):
            with self.assertRaises(ValueError): remote.publish(self.store,self.key.public_key())

    def test_dry_run_never_uploads(self):
        with patch.object(remote.subprocess,'run',return_value=subprocess.CompletedProcess([],0,json.dumps({'missing':[self.result['channel']]}).encode())) as call:
            result=remote.publish(self.store,self.key.public_key(),dry_run=True)
        self.assertEqual(call.call_count,1)
        self.assertTrue(result['dry_run'])

    def test_ssh_argument_cannot_be_option_or_command(self):
        for host in ['-oProxyCommand=bad','wuhan;cat secret','a b','root@host']:
            with self.subTest(host=host), self.assertRaises(ValueError): remote.ssh_command(host,'inventory')
        compile(remote.REMOTE_SCRIPT,'remote_helper','exec')

    def run_local_helper(self, destination, wire):
        # Exercise the Linux helper's file/hash/ordering logic without any SSH.
        # Only its test copy receives a temporary root; production root is fixed.
        source=remote.REMOTE_SCRIPT.replace("ROOT=Path('/srv/weekglass-publication/updates/v1')", f'ROOT=Path({str(destination)!r})')
        stdin=io.TextIOWrapper(io.BytesIO(wire),encoding='utf-8')
        stdout=io.StringIO()
        fake_fcntl=types.SimpleNamespace(LOCK_EX=2,flock=lambda *args:None)
        with patch.dict(sys.modules,{'fcntl':fake_fcntl}), patch.object(sys,'argv',['helper','upload']), patch.object(sys,'stdin',stdin), patch.object(sys,'stdout',stdout), patch('shutil.disk_usage',return_value=types.SimpleNamespace(free=10*1024**3)):
            exec(compile(source,'local_remote_helper','exec'),{})
        return json.loads(stdout.getvalue())

    def archive(self, index, corrupt=False):
        output=io.BytesIO()
        with tarfile.open(fileobj=output,mode='w') as tar:
            raw=json.dumps(index).encode();info=tarfile.TarInfo('INDEX.json');info.size=len(raw)
            tar.addfile(info,io.BytesIO(raw))
            for name in index:
                raw=(self.store/name).read_bytes()
                if corrupt: raw=b'x'*len(raw)
                info=tarfile.TarInfo(name);info.size=len(raw)
                tar.addfile(info,io.BytesIO(raw))
        return output.getvalue()

    def test_remote_helper_actual_staging_and_atomic_commit(self):
        _,_,index=pub.verify_publication(self.store,self.key.public_key())
        destination=self.root/'remote';destination.mkdir()
        result=self.run_local_helper(destination,self.archive(index))
        self.assertEqual(result['uploaded_files'],len(index))
        pub.verify_publication(destination,self.key.public_key())
        self.assertFalse(list(destination.glob('.incoming-*')))

    def test_remote_helper_corruption_never_changes_current_channel(self):
        _,_,index=pub.verify_publication(self.store,self.key.public_key())
        destination=self.root/'remote';destination.mkdir()
        self.run_local_helper(destination,self.archive(index))
        previous=(destination/self.result['channel']).read_bytes()
        with self.assertRaises(ValueError):
            self.run_local_helper(destination,self.archive(index,corrupt=True))
        self.assertEqual((destination/self.result['channel']).read_bytes(),previous)
        self.assertFalse(list(destination.glob('.incoming-*')))


if __name__=='__main__': unittest.main()
