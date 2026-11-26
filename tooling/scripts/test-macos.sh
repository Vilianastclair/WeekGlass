#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tooling/scripts/test-macos.sh [--package] [--verify-launch]

Run the isolated macOS interaction tests and build the normal debug app.
  --package        Save the debug app as a ZIP under apps/client/build/weekglass-macos.
  --verify-launch  Check the normal app window; with --package, launch the extracted ZIP.
                   Use a clean macOS login without existing WeekGlass data.

Set WEEKGLASS_MAC_COURSE_RUNTIME_DIR to an absolute prepared macOS course_adapter
directory to exercise the bundled Java engine as well.
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
course_runtime="${WEEKGLASS_MAC_COURSE_RUNTIME_DIR:-}"
embedded_runtime="$app/Contents/Resources/course_adapter"
if [[ -n "$course_runtime" ]]; then
  if [[ "$course_runtime" != /* || ! -f "$course_runtime/engine.jar" || ! -x "$course_runtime/runtime/bin/java" ]]; then
    printf 'Invalid prepared macOS course_adapter directory: %s\n' "$course_runtime" >&2
    exit 1
  fi
  course_runtime="$(cd "$course_runtime" && pwd -P)"
  if [[ "$course_runtime" == "$(pwd -P)/build/"* ]]; then
    echo 'Prepare the reusable course adapter outside the Flutter build directory.' >&2
    exit 1
  fi
fi

embed_course_runtime() {
  if [[ -n "$course_runtime" ]]; then
    local entitlements="$scratch/debug-entitlements.plist"
    /usr/bin/codesign --display --entitlements - --xml "$app" > "$entitlements"
    /usr/bin/ditto "$course_runtime" "$embedded_runtime"
    # The runtime has separately signed nested binaries. Sign only this app
    # after embedding, preserving the normal debug sandbox permissions.
    /usr/bin/codesign --force --sign - --entitlements "$entitlements" "$app"
  fi
}

# This directory exists only when this script embedded a previous test runtime.
rm -rf -- "$embedded_runtime"

# The test build has its own sandbox and is reused by both test processes.
course_fixture="$(/usr/bin/base64 < test/fixtures/school_portal/zhengfang.html | tr -d '\r\n')"
printf 'WEEKGLASS_MACOS_BUNDLE_SUFFIX = .smoke\n' > "$scratch/smoke.xcconfig"
XCODE_XCCONFIG_FILE="$scratch/smoke.xcconfig" \
  flutter --suppress-analytics build macos --debug --no-pub --target "$target" \
    --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false \
    --dart-define=WEEKGLASS_MAC_SMOKE_BUILD=true \
    --dart-define="WEEKGLASS_MAC_COURSE_FIXTURE=$course_fixture" \
    2>&1 | tee "$evidence/smoke-build.log"
if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")" != "$bundle_id.smoke" ]]; then
  echo 'The smoke build requires its own macOS sandbox.' >&2
  exit 1
fi
embed_course_runtime 2>&1 | tee -a "$evidence/smoke-build.log"
smoke_id="$(uuidgen)"
image_fixture="$(/usr/bin/base64 < test/fixtures/timetable_image/fictional-timetable.png | tr -d '\r\n')"
for phase in create reopen; do
  printf '\nNative interaction test: %s\n' "$phase"
  WEEKGLASS_MAC_SMOKE_ID="$smoke_id" \
  WEEKGLASS_MAC_IMAGE_FIXTURE="$image_fixture" \
  WEEKGLASS_MAC_SMOKE_ARTIFACTS="$evidence/screenshots" \
  WEEKGLASS_MAC_SMOKE_PHASE="$phase" \
    flutter --suppress-analytics drive --debug --no-pub -d macos \
      --target "$target" --driver test_driver/macos_smoke_driver.dart \
      --use-application-binary="$app" 2>&1 | tee "$evidence/$phase.log"
done
for screenshot in create-planner.png course-preview.png reopen-details.png; do
  if [[ ! -s "$evidence/screenshots/$screenshot" ]]; then
    printf 'Missing smoke screenshot: %s\n' "$screenshot" >&2
    exit 1
  fi
  /usr/bin/sips -g pixelWidth -g pixelHeight "$evidence/screenshots/$screenshot" \
    >> "$evidence/screenshots.log"
done

# Replace the test entry point with the normal app.
rm -rf -- "$embedded_runtime"
flutter --suppress-analytics build macos --debug --no-pub 2>&1 | tee "$evidence/build.log"
embed_course_runtime 2>&1 | tee -a "$evidence/build.log"
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

launch_app="$app"
if $package; then
  archive="$artifact_root/WeekGlass-macOS-debug.zip"
  staged_archive="$scratch/WeekGlass-macOS-debug.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staged_archive"
  if $verify_launch; then
    /usr/bin/ditto -x -k "$staged_archive" "$scratch/package"
    launch_app="$scratch/package/WeekGlass.app"
  fi
fi
/usr/bin/codesign --verify --deep --strict --verbose=1 "$launch_app" 2>&1 \
  | tee -a "$evidence/bundle.log"

if $verify_launch; then
  xcrun swiftc -parse-as-library "$root/tooling/scripts/verify-macos-launch.swift" -o "$scratch/verify-launch"
  "$scratch/verify-launch" "$launch_app" 2>&1 | tee "$evidence/launch.log"
fi

if $package; then
  mv -f -- "$staged_archive" "$archive"
  printf 'Debug package: %s (%s bytes)\n' "$archive" "$(stat -f '%z' "$archive")" \
    | tee -a "$evidence/bundle.log"
fi

printf 'Verification finished in %s seconds.\n' "$SECONDS" | tee -a "$evidence/bundle.log"
