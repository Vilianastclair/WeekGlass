#!/usr/bin/env bash
# A differently signed or rebuilt vault would have a new Keychain partition.
set -euo pipefail
arch="${1:?}"; case "$arch" in arm64|x64);; *) exit 2;; esac
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
dir="${RUNNER_TEMP:?}/weekglass-signing"; mkdir -p "$dir/frozen"
config="$root/tooling/macos-account/frozen-components.json"
read_field(){ /usr/bin/plutil -extract "$arch.$1" raw -o - "$config"; }
tag="$(read_field tag)"; repo="$(read_field repo)"
[[ "$repo" == Vilianastclair/WeekGlass-macOS-validation && "${GITHUB_REPOSITORY:?}" == "$repo" ]]
name="xpc-$arch.tar.gz"
gh release download "$tag" -R "$repo" --pattern "$name" --dir "$dir/frozen"
python3 - "$config" "$arch" "$dir" <<'PY'
import hashlib,json,pathlib,sys,tarfile
f,arch,location=sys.argv[1:];dest=pathlib.Path(location);data=json.load(open(f))[arch];archive=dest/'frozen'/('xpc-'+arch+'.tar.gz')
if 'sha256:'+hashlib.sha256(archive.read_bytes()).hexdigest()!=data['signed_files'][archive.name]:raise SystemExit('Frozen credential service checksum did not match the signed component inventory')
base='WeekGlassAccount.xpc/Contents/'
files={base+'Info.plist',base+'MacOS/WeekGlassAccount',base+'_CodeSignature/CodeResources'}
parents={str(p) for name in files for p in pathlib.PurePosixPath(name).parents}-{'.'}
with tarfile.open(archive,'r:gz') as t:
    members=t.getmembers()
    if ({m.name for m in members if m.isfile()}!=files or any(not (m.isfile() and m.name in files or m.isdir() and m.name in parents) for m in members) or len({m.name for m in members})!=len(members)):raise SystemExit('Unexpected frozen service bundle structure')
    for m in members:
        if m.isfile():
            p=dest/m.name;p.parent.mkdir(exist_ok=True,parents=True)
            with p.open('xb') as out:out.write(t.extractfile(m).read())
            p.chmod(0o755 if m.name.endswith('/MacOS/WeekGlassAccount') else 0o644)
PY
vault="$dir/WeekGlassAccount.xpc"
codesign --verify --strict --deep -R "=identifier \"$(read_field identifier)\" and certificate leaf = H\"$(read_field signer)\"" "$vault"
record="$(codesign -dvvv "$vault" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$record" == "$(read_field cdhashes.0)" ]]
