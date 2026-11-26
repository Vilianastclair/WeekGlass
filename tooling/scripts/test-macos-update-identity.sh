#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tooling/scripts/test-macos-update-identity.sh [--evidence DIRECTORY]

Use a disposable macOS login with an unlocked login keychain. Two local test
apps use the same unique bundle ID, release sandbox and different ad hoc code
identities. The current app is replaced at the same path between launches.
This test starts the local executables directly; test downloaded app opening
separately through Finder. No real WeekGlass data or Keychain item is used.
EOF
}

evidence=''
case "${1:-}" in
  '') [[ $# -eq 0 ]] || { usage >&2; exit 2; } ;;
  --help|-h) usage; exit 0 ;;
  --evidence) [[ $# -eq 2 && -n "$2" ]] || { usage >&2; exit 2; }; evidence="$2" ;;
  *) usage >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The upgrade identity test requires macOS with Xcode.' >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/weekglass-identity.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
if [[ -z "$evidence" ]]; then
  evidence="$(mktemp -d "${TMPDIR:-/tmp}/weekglass-identity-logs.XXXXXX")"
else
  # Each run writes to its own directory, even when the log parent is reused.
  mkdir -p "$evidence"
  evidence="$(mktemp -d "${evidence%/}/run.XXXXXX")"
fi
evidence="$(cd "$evidence" && pwd -P)"
printf 'Upgrade identity evidence: %s\n' "$evidence"
cd "$scratch"
scratch="$(pwd -P)"
run_id="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
bundle_id="com.viliana.weekglass.identity-test.$run_id"
entitlements="$root/apps/client/macos/Runner/Release.entitlements"
app_name='WeekGlass Identity Test.app'
active="$scratch/live/$app_name"
old="$scratch/old/$app_name"
new="$scratch/new/$app_name"
mkdir -p "$scratch/live"

{
  sw_vers
  printf 'Architecture: %s\nBundle ID: %s\n' "$(uname -m)" "$bundle_id"
  xcrun swiftc --version
} 2>&1 | tee "$evidence/environment.log"

build() {
  local app="$1" version="$2" version_flag="$3"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>WeekGlass Identity Test</string>
  <key>CFBundleExecutable</key><string>probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version.0</string>
  <key>CFBundleVersion</key><string>$version</string>
</dict>
</plist>
EOF
  xcrun swiftc -D "$version_flag" "$root/tooling/scripts/verify-macos-update-identity.swift" \
    -o "$app/Contents/MacOS/probe" || return
  /usr/bin/codesign --force --sign - --timestamp=none --entitlements "$entitlements" "$app" || return
  /usr/bin/codesign --verify --strict --verbose=2 "$app" || return
  /usr/bin/codesign --display -r - --verbose=4 "$app"
}
build "$old" 1 PROBE_V1 2>&1 | tee "$evidence/old-signature.log"
build "$new" 2 PROBE_V2 2>&1 | tee "$evidence/new-signature.log"
old_dr="$(sed -n '/^designated => /p' "$evidence/old-signature.log")"
new_dr="$(sed -n '/^designated => /p' "$evidence/new-signature.log")"
if [[ -z "$old_dr" || -z "$new_dr" || "$old_dr" == "$new_dr" ]]; then
  echo 'Expected distinct designated requirements for the two ad hoc builds.' >&2
  exit 1
fi

probe() {
  local step="$1" mode="$2" log="$evidence/$1.log" status=0 process_status pid deadline
  "$active/Contents/MacOS/probe" "$mode" "$bundle_id" > "$log" 2>&1 &
  pid=$!
  deadline=$((SECONDS + 20))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill -KILL "$pid" 2>/dev/null || true
      status=124
      break
    fi
    sleep 0.2
  done
  wait "$pid" || {
    process_status=$?
    if [[ "$status" -eq 0 ]]; then status=$process_status; fi
  }
  if [[ "$status" -eq 124 ]]; then
    printf 'Timed out waiting for the probe; inspect macOS for a container prompt.\n' >> "$log"
  fi
  printf 'Exit status: %s\n' "$status" >> "$log"
  printf '\n%s\n' "$step"
  cat "$log"
  return "$status"
}

/usr/bin/ditto "$old" "$active"
baseline=0
upgrade=0
probe old-write write && probe old-read read || baseline=$?
if [[ "$baseline" -eq 0 ]]; then
  mv -- "$active" "$scratch/previous.app"
  /usr/bin/ditto "$new" "$active"
  probe new-read read || upgrade=$?
  mv -- "$active" "$scratch/tested-new.app"
  mv -- "$scratch/previous.app" "$active"
fi
cleanup=0
probe old-cleanup cleanup || cleanup=$?
if [[ "$baseline" -ne 0 ]]; then
  printf '\nThe old version could not establish its baseline; the upgrade was not measured.\n'
  exit 1
fi
if [[ "$upgrade" -ne 0 ]]; then
  printf '\nThe new version did not retain automatic access. See new-read.log for the failing resource.\n'
  exit 1
fi
if [[ "$cleanup" -ne 0 ]]; then
  printf '\nThe old version could not remove the isolated fixture; see old-cleanup.log.\n'
  exit 1
fi
printf '\nThe new version read all three resources without Keychain interaction.\n'
