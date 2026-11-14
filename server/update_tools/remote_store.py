"""Fixed-root SSH helper. Keep compatible with the host's Python 3.6 stdlib.

This file is sent as Python source, never installed as a service. Signing keys
stay on the release workstation. Every destructive action holds the same lock
as publication and revalidates the exact independently verified snapshot.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile
import tempfile

ROOT=Path('/srv/weekglass-publication/updates/v1')
PLATFORM = r'(windows-x64|android-arm64)'
CHANNEL = re.compile(r'^channels/' + PLATFORM + r'/(stable|preview)\.json$')
PATTERN = re.compile(r'^(objects/[a-f0-9]{2}/[a-f0-9]{64}|manifests/' + PLATFORM +
                     r'/(stable|preview)/[1-9][0-9]*/[a-f0-9]{64}\.json|channels/' +
                     PLATFORM + r'/(stable|preview)\.json)$')
RETIRED = re.compile(r'^channels/' + PLATFORM + r'/(stable|preview)\.withdrawn-build-[1-9][0-9]*\.json$')


def child(name, retired=False):
    if not isinstance(name, str) or not (PATTERN.fullmatch(name) or (retired and RETIRED.fullmatch(name))):
        raise ValueError('Invalid publication path')
    p = ROOT
    for piece in name.split('/'):
        p = p / piece
        if p.is_symlink():
            raise ValueError('Symlinks forbidden')
    if os.path.commonpath([str(p.resolve()), str(ROOT.resolve())]) != str(ROOT.resolve()):
        raise ValueError('Path escaped')
    if name.startswith('objects/') and name.split('/')[1] != name.split('/')[2][:2]:
        raise ValueError('Object prefix mismatch')
    return p


def digest_file(p):
    h = hashlib.sha256()
    with p.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def descriptor(p):
    return {'sha256': digest_file(p), 'size': p.stat().st_size}


def valid_index(index):
    if not isinstance(index, dict) or len(index) > 20000:
        raise ValueError('Invalid publication index')
    for name, item in index.items():
        child(name)
        if (not isinstance(item, dict) or type(item.get('size')) is not int or
                not 0 <= item['size'] <= 256 * 1024 ** 2 or
                not re.fullmatch('[a-f0-9]{64}', item.get('sha256', ''))):
            raise ValueError('Invalid object descriptor')
    return index


def payload(data):
    return json.loads(base64.b64decode(json.loads(data)['signed'], validate=True))


def references(head_name, head_data, reader):
    head = payload(head_data)
    platform, channel = head_name.split('/')[1], head_name.split('/')[2][:-5]
    manifest = head['manifest']
    name = 'manifests/{}/{}/{}/{}.json'.format(platform, channel, head['build'], manifest['sha256'])
    if (head['platform'] != platform or head['channel'] != channel or manifest['path'] != name):
        raise ValueError('Invalid channel/manifest relationship')
    manifest_data = reader(name)
    if len(manifest_data) != manifest['size'] or hashlib.sha256(manifest_data).hexdigest() != manifest['sha256']:
        raise ValueError('Channel/manifest integrity mismatch')
    document = payload(manifest_data)
    if any(document[key] != head[key] for key in ('build', 'version', 'platform', 'channel')):
        raise ValueError('Channel/manifest release mismatch')
    result = {head_name: {'sha256': hashlib.sha256(head_data).hexdigest(), 'size': len(head_data)},
              name: {'sha256': manifest['sha256'], 'size': manifest['size']}}
    for entry in document['files']:
        for item in [entry['full']] + entry['patches']:
            object_name = 'objects/{}/{}'.format(item['sha256'][:2], item['sha256'])
            value = {'sha256': item['sha256'], 'size': item['size']}
            if object_name in result and result[object_name] != value:
                raise ValueError('Conflicting object reference')
            result[object_name] = value
    return valid_index(result)


def snapshot():
    files, unknown = {}, []
    for here, dirs, names in os.walk(str(ROOT), followlinks=False):
        for name in list(dirs):
            path = Path(here) / name
            relative = path.relative_to(ROOT).as_posix()
            if path.is_symlink():
                raise ValueError('Symlinks forbidden in public store')
            if Path(here) == ROOT and name.startswith('.incoming-'):
                dirs.remove(name)
        for name in names:
            path = Path(here) / name
            relative = path.relative_to(ROOT).as_posix()
            if relative == '.publish.lock':
                continue
            if path.is_symlink():
                raise ValueError('Symlinks forbidden in public store')
            if PATTERN.fullmatch(relative) or RETIRED.fullmatch(relative):
                files[relative] = descriptor(child(relative, retired=True))
            else:
                unknown.append(relative)
    documents = {}
    keep = {}
    for name in sorted(files):
        if CHANNEL.fullmatch(name):
            data = child(name).read_bytes()
            if len(data) > 16384:
                raise ValueError('Channel metadata too large')
            refs = references(name, data, lambda key: child(key).read_bytes())
            for key, value in refs.items():
                if key in keep and keep[key] != value:
                    raise ValueError('Conflicting live references')
                keep[key] = value
            documents[name] = base64.b64encode(data).decode('ascii')
            manifest_name = payload(data)['manifest']['path']
            manifest_data = child(manifest_name).read_bytes()
            if len(manifest_data) > 4 * 1024 ** 2:
                raise ValueError('Manifest too large')
            documents[manifest_name] = base64.b64encode(manifest_data).decode('ascii')
    state = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'files': files, 'documents': documents, 'keep': keep, 'snapshot_sha256': state, 'unknown': sorted(unknown)}


def upload():
    stage = Path(tempfile.mkdtemp(prefix='.incoming-', dir=str(ROOT)))
    try:
        with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as tar:
            first = tar.next()
            if first is None or first.name != 'INDEX.json' or first.size > 4 * 1024 ** 2 or not first.isfile():
                raise ValueError('Missing index')
            index = valid_index(json.load(tar.extractfile(first)))
            amount = sum(item['size'] for item in index.values())
            if amount > 2 * 1024 ** 3:
                raise ValueError('Publication too large')
            if shutil.disk_usage(str(ROOT)).free - amount < 6 * 1024 ** 3:
                raise ValueError('Preserve host free-space reserve')
            staged = {}
            while True:
                entry = tar.next()
                if entry is None:
                    break
                if entry.name in staged or entry.name not in index or not entry.isfile():
                    raise ValueError('Unexpected archive entry')
                item = index[entry.name]
                if entry.size != item['size']:
                    raise ValueError('Object size mismatch')
                temp = stage / str(len(staged))
                with temp.open('wb') as out:
                    source = tar.extractfile(entry)
                    for block in iter(lambda: source.read(1024 * 1024), b''):
                        out.write(block)
                    out.flush()
                    os.fsync(out.fileno())
                if descriptor(temp) != item:
                    raise ValueError('Object digest mismatch')
                staged[entry.name] = temp
            if set(staged) != set(index):
                raise ValueError('Incomplete upload')
        def available(name):
            return staged.get(name) or child(name)
        for name, item in index.items():
            dest = child(name)
            if CHANNEL.fullmatch(name):
                new = payload(staged[name].read_bytes())
                if dest.exists():
                    old = payload(dest.read_bytes())
                    if (new['build'] < old['build'] or new['generated_at'] < old['generated_at'] or
                            (new['build'] == old['build'] and new['version'] != old['version'])):
                        raise ValueError('Channel rollback')
                refs = references(name, staged[name].read_bytes(), lambda key: available(key).read_bytes())
                for key, expected in refs.items():
                    if descriptor(available(key)) != expected:
                        raise ValueError('Referenced content missing or corrupt')
            elif dest.exists() and descriptor(dest) != item:
                raise ValueError('Refusing to overwrite corrupted immutable content')
        order = sorted(index, key=lambda name: (2 if name.startswith('channels/') else 1 if name.startswith('manifests/') else 0, name))
        for name in order:
            dest = child(name)
            dest.parent.mkdir(parents=True, exist_ok=True)
            os.chmod(str(staged[name]), 0o644)
            os.replace(str(staged[name]), str(dest))
        return {'uploaded_files': len(index), 'uploaded_bytes': amount}
    finally:
        shutil.rmtree(str(stage))


def prune(request):
    current = snapshot()
    if current['unknown']:
        raise ValueError('Unknown store files require explicit review')
    if current['snapshot_sha256'] != request['snapshot_sha256']:
        raise ValueError('Store changed after verification; retry from a fresh snapshot')
    keep = valid_index(request['keep'])
    if keep != current['keep']:
        raise ValueError('Deletion plan must retain every current full object and patch')
    required = ['channels/{}/stable.json'.format(platform) for platform in ('windows-x64', 'android-arm64')]
    if any(name not in keep for name in required):
        raise ValueError('Both stable platforms must be published before cleanup')
    for name, item in keep.items():
        if current['files'].get(name) != item:
            raise ValueError('Current release is incomplete or corrupt')
    obsolete = {name: item for name, item in current['files'].items() if name not in keep}
    if request['delete'] != obsolete:
        raise ValueError('Deletion plan does not match verified unreachable files')
    for name in sorted(obsolete):
        child(name, retired=True).unlink()
    # Remove only empty directories beneath these three fixed public trees.
    for prefix in ('objects', 'manifests', 'channels'):
        root = ROOT / prefix
        if root.exists():
            for here, dirs, names in os.walk(str(root), topdown=False):
                if Path(here) != root and not os.listdir(here):
                    Path(here).rmdir()
    after = snapshot()
    if after['files'] != keep:
        raise ValueError('Post-cleanup store verification failed')
    return {'removed_files': len(obsolete), 'removed_bytes': sum(item['size'] for item in obsolete.values()),
            'retained_files': len(keep), 'remote_verified': True}


for root in [Path('/srv'), Path('/srv/weekglass-publication'), Path('/srv/weekglass-publication/updates'), ROOT]:
    if root.is_symlink():
        raise ValueError('Publication root cannot be a symlink')
if not ROOT.is_dir():
    raise ValueError('Provision WeekGlass update root first')
action = sys.argv[1]
if action == 'inventory':
    index = valid_index(json.load(sys.stdin))
    missing = [name for name, item in index.items() if not child(name).is_file() or descriptor(child(name)) != item]
    print(json.dumps({'missing': missing}))
elif action in ('upload', 'snapshot', 'prune'):
    with (ROOT / '.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = upload() if action == 'upload' else snapshot() if action == 'snapshot' else prune(json.load(sys.stdin))
        print(json.dumps(result))
else:
    raise ValueError('Unknown action')
