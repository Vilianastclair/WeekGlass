#!/usr/bin/env bash
set -euo pipefail
# A and B are the release app with the integration fixture entry and the same
# signing configuration. This script never replaces, launches, or re-signs B.
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# == 4 ]] || die 'Usage: test-macos-app-update.sh A.app SIGNED_FEED_DIR B_VERSION B_BUILD'
[[ "$(uname -s)" == Darwin ]] || die 'Use a disposable graphical macOS login.'
old="$1"; feed="$2"; version="$3"; build="$4"
[[ -d "$old" && -f "$feed/appcast.xml" ]] || die 'Provide A.app and the signed local feed for B.'
id=com.viliana.weekglass.updatesmoke
plist="$old/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == "$id" ]] || die 'Wrong test bundle ID.'
[[ "$(plutil -extract SUFeedURL raw -o - "$plist")" == 'http://127.0.0.1:18765/appcast.xml' ]] ||
  die 'The old candidate is not bound to the isolated feed.'
for key in SURequireSignedFeed SUVerifyUpdateBeforeExtraction SUEnableInstallerLauncherService; do
  [[ "$(plutil -extract "$key" raw -o - "$plist")" == true ]] || die "Required setting missing: $key"
done
[[ "$(plutil -extract SUSignedFeedFailureExpirationInterval raw -o - "$plist")" == 0 ]] ||
  die 'A signed-feed failure must never expire.'
container="$HOME/Library/Containers/$id"
[[ ! -e "$container" ]] || die "Use a clean disposable login: $container already exists."
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
evidence="$root/apps/client/build/weekglass-macos/verification"
mkdir -p "$evidence" "$HOME/Applications"
evidence="$(mktemp -d "$evidence/update.XXXXXX")"
install="$(mktemp -d "$HOME/Applications/WeekGlassUpdate.XXXXXX")"
app="$install/WeekGlass.app"
exe="$app/Contents/MacOS/WeekGlass"
server=''
cleanup() {
  local status=$?
  if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi
  # Only a process with this run's installed executable may be stopped.
  local p
  while read -r p; do
    if [[ -n "$p" && "$(ps -p "$p" -o comm= 2>/dev/null || :)" == "$exe" ]]; then
      kill -TERM "$p" 2>/dev/null || :
    fi
  done < <(ps -A -o pid=,comm= | awk -v path="$exe" 'index($0, path) {print $1}')
  if [[ "$status" == 0 ]]; then
    # This newly created installation is disposable; the receipt is kept separately.
    case "$install" in "$HOME"/Applications/WeekGlassUpdate.*) rm -rf -- "$install" ;; esac
  fi
}
trap cleanup EXIT
/usr/bin/ditto "$old" "$app"
feed="$(cd "$feed" && pwd -P)"
# Confirm our own successful bind before opening the application; a preexisting
# HTTP listener must never become the fixture server.
python3 -u - "$feed" "$evidence/server-ready" > "$evidence/http.log" 2>&1 <<'PY' &
import functools, http.server, pathlib, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with http.server.ThreadingHTTPServer(("127.0.0.1", 18765), handler) as server:
    pathlib.Path(sys.argv[2]).touch()
    server.serve_forever()
PY
server=$!
for _ in {1..30}; do
  [[ ! -e "$evidence/server-ready" ]] || break
  kill -0 "$server" 2>/dev/null || die 'The loopback feed server did not start.'
  sleep .1
done
[[ -e "$evidence/server-ready" ]] || die 'The test feed did not start.'
SECONDS=0
/usr/bin/open -n "$app"
support="$container/Data/Library/Application Support"
receipt=''
for _ in {1..180}; do
  if [[ -d "$support" ]]; then
    receipt="$(find "$support" -name upgrade-result.json -type f -print -quit 2>/dev/null || :)"
    [[ -z "$receipt" || ! -s "$receipt" ]] || break
  fi
  sleep 1
done
if [[ -z "$receipt" || ! -s "$receipt" ]]; then
  /usr/bin/log show --last 4m --info --style compact --predicate \
    'process == "WeekGlass" OR process == "Autoupdate" OR process == "Installer" OR subsystem == "org.sparkle-project.Sparkle"' \
    > "$evidence/installer.log" 2>&1 || :
  if [[ -d "$support" ]]; then
    find "$support" -name upgrade-input.json -exec cp '{}' "$evidence/upgrade-input.json" ';'
  fi
  cat "$evidence/http.log"
  die "The app did not finish the upgrade. See $evidence"
fi
cp "$receipt" "$evidence/update-result.json"
python3 - "$receipt" "$exe" "$version" "$build" <<'PY'
import json, os, pathlib, subprocess, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if "error" in result:
    raise SystemExit("Upgrade failed: " + result["error"])
exe = os.path.realpath(sys.argv[2])
if not (result["version"] == sys.argv[3] and result["build"] == int(sys.argv[4]) > result["previousBuild"]
        and result["pid"] != result["previousPid"] and os.path.realpath(result["executable"]) == exe
        and all(result[k] is True for k in ("schedule", "appearance", "fileKeychain", "plannerFrame"))):
    raise SystemExit("The successor identity, launch path, or retained data did not match.")
cmd = subprocess.check_output(["ps", "-p", str(result["pid"]), "-o", "comm="], text=True).strip()
if os.path.realpath(cmd) != exe:
    raise SystemExit("The successor is not running from the original installed path.")
print(f"Updated {result['previousBuild']} to {result['version']} ({result['build']}); "
      f"planner visible, schedule, appearance and file-based Keychain read back.")
PY
/usr/bin/codesign --verify --deep --strict "$app"
# Capture only the existing successor process; never open a window on its behalf.
successor="$(plutil -extract pid raw -o - "$receipt")"
window="$(xcrun swift - "$successor" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    if window[kCGWindowOwnerPID as String] as? Int == pid,
       window[kCGWindowLayer as String] as? Int == 0,
       let bounds = window[kCGWindowBounds as String] as? NSDictionary,
       let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
       rect.width >= 800, rect.height >= 560,
       let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
SWIFT
)"
/usr/sbin/screencapture -x -o -l "$window" "$evidence/successor.png"
printf 'Elapsed: %s seconds. Evidence: %s\n' "$SECONDS" "$evidence"
