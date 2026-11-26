#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tooling/scripts/test-macos.sh [--package] [--verify-launch]

Run the isolated macOS interaction tests and build the normal debug app.
  --package        Save the debug app as a ZIP under apps/client/build/weekglass-macos.
  --verify-launch  Open the built app and verify its window. Use a clean macOS login
                   without existing WeekGlass data, because this opens the normal app.
EOF
}

package=false
verify_launch=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package=true ;;
    --verify-launch) verify_launch=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The native WeekGlass test and build require macOS with Xcode.' >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
versions="$root/tooling/versions.json"
required_flutter="$(/usr/bin/plutil -extract flutter.version raw -o - "$versions")"
required_dart="$(/usr/bin/plutil -extract flutter.dart raw -o - "$versions")"
if ! command -v flutter >/dev/null 2>&1; then
  printf 'Set PATH to Flutter %s from https://docs.flutter.dev/install/archive\n' "$required_flutter" >&2
  exit 1
fi

cd "$root/apps/client"
artifact_root="$PWD/build/weekglass-macos"
mkdir -p "$artifact_root/verification"
evidence="$(mktemp -d "$artifact_root/verification/run.XXXXXX")"
printf 'Test evidence: %s\n' "$evidence"
{
  xcodebuild -version
  sw_vers
  printf 'Host architecture: %s\n' "$(uname -m)"
  installed="$(flutter --suppress-analytics --version --machine)"
  actual_flutter="$(printf '%s' "$installed" | /usr/bin/plutil -extract frameworkVersion raw -o - -)"
  actual_dart="$(printf '%s' "$installed" | /usr/bin/plutil -extract dartSdkVersion raw -o - -)"
  if [[ "$actual_flutter" != "$required_flutter" || "$actual_dart" != "$required_dart" ]]; then
    printf 'Need Flutter %s with Dart %s; found Flutter %s with Dart %s.\n' \
      "$required_flutter" "$required_dart" "$actual_flutter" "$actual_dart" >&2
    exit 1
  fi
  printf 'Flutter %s with Dart %s\n' "$actual_flutter" "$actual_dart"
  printf 'Git commit: %s\n' "$(git rev-parse HEAD)"
  git status --short
} 2>&1 | tee "$evidence/toolchain.log"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/weekglass-macos.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$evidence/screenshots"

flutter --suppress-analytics pub get --enforce-lockfile
app="$PWD/build/macos/Build/Products/Debug/WeekGlass.app"
plist="$app/Contents/Info.plist"
bundle_id=com.viliana.weekglass
target=integration_test/macos_smoke_test.dart

# The test build has its own sandbox and is reused by both test processes.
printf 'WEEKGLASS_MACOS_BUNDLE_SUFFIX = .smoke\n' > "$scratch/smoke.xcconfig"
XCODE_XCCONFIG_FILE="$scratch/smoke.xcconfig" \
  flutter --suppress-analytics build macos --debug --no-pub --target "$target" \
    --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false \
    2>&1 | tee "$evidence/smoke-build.log"
if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")" != "$bundle_id.smoke" ]]; then
  echo 'The smoke build requires its own macOS sandbox.' >&2
  exit 1
fi
smoke_id="$(uuidgen)"
for phase in create reopen; do
  printf '\nNative interaction test: %s\n' "$phase"
  WEEKGLASS_MAC_SMOKE_ID="$smoke_id" \
  WEEKGLASS_MAC_SMOKE_ARTIFACTS="$evidence/screenshots" \
  WEEKGLASS_MAC_SMOKE_PHASE="$phase" \
    flutter --suppress-analytics drive --debug --no-pub -d macos \
      --target "$target" --driver test_driver/macos_smoke_driver.dart \
      --use-application-binary="$app" 2>&1 | tee "$evidence/$phase.log"
done
for screenshot in create-planner.png reopen-details.png; do
  if [[ ! -s "$evidence/screenshots/$screenshot" ]]; then
    printf 'Missing smoke screenshot: %s\n' "$screenshot" >&2
    exit 1
  fi
done

# Replace the test entry point with the normal app.
flutter --suppress-analytics build macos --debug --no-pub 2>&1 | tee "$evidence/build.log"
executable="$app/Contents/MacOS/$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist")"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")"
build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$plist")"
expected_version="$(awk '$1 == "version:" { print $2; exit }' pubspec.yaml)"
actual_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")"
if [[ ! -x "$executable" || "$version+$build" != "$expected_version" || "$actual_id" != "$bundle_id" ]]; then
  printf 'Invalid app bundle: %s (%s, %s); expected %s and %s.\n' \
    "$app" "$actual_id" "$version+$build" "$bundle_id" "$expected_version" >&2
  exit 1
fi
xcrun lipo "$executable" -verify_arch "$(uname -m)"
printf 'Built %s (%s; %s)\n' "$app" "$version+$build" "$(xcrun lipo -archs "$executable")" \
  | tee "$evidence/bundle.log"

if $verify_launch; then
  cat > "$scratch/VerifyLaunch.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import Darwin

struct LaunchFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@main
struct VerifyLaunch {
  @MainActor
  static func main() async {
    do {
      try await verify()
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  @MainActor
  static func verify() async throws {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let identifier = Bundle(url: url)?.bundleIdentifier else {
      throw LaunchFailure(message: "The candidate bundle has no identifier.")
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
      throw LaunchFailure(message: "WeekGlass is running. Use a clean macOS login with WeekGlass closed.")
    }

    let options = NSWorkspace.OpenConfiguration()
    options.createsNewApplicationInstance = true
    let app = try await NSWorkspace.shared.openApplication(at: url, configuration: options)

    var window: CGRect?
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
      ) as? [[String: Any]] ?? []
      window = windows.lazy.compactMap { info -> CGRect? in
        guard info[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
              info[kCGWindowLayer as String] as? Int == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
      }.first
      if window != nil { break }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    let exitedEarly = app.isTerminated
    if !exitedEarly {
      _ = app.terminate()
      let quitDeadline = ProcessInfo.processInfo.systemUptime + 5
      while !app.isTerminated && ProcessInfo.processInfo.systemUptime < quitDeadline {
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
      if !app.isTerminated { _ = app.forceTerminate() }
    }
    if exitedEarly { throw LaunchFailure(message: "The candidate quit before showing a window.") }
    guard let window else {
      throw LaunchFailure(message: "The candidate did not show an on-screen window within 30 seconds.")
    }
    print("LaunchServices opened WeekGlass with a native window (\(Int(window.width)) × \(Int(window.height))).")
  }
}
SWIFT
  xcrun swiftc -parse-as-library "$scratch/VerifyLaunch.swift" -o "$scratch/verify-launch"
  "$scratch/verify-launch" "$app" 2>&1 | tee "$evidence/launch.log"
fi

if $package; then
  archive="$artifact_root/WeekGlass-macOS-debug.zip"
  staged_archive="$evidence/WeekGlass-macOS-debug.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staged_archive"
  mv -f -- "$staged_archive" "$archive"
  printf 'Debug package: %s (%s bytes)\n' "$archive" "$(stat -f '%z' "$archive")" \
    | tee -a "$evidence/bundle.log"
fi

printf 'Verification finished in %s seconds.\n' "$SECONDS" | tee -a "$evidence/bundle.log"
