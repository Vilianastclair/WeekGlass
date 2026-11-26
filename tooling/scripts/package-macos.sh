#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tooling/scripts/package-macos.sh [--course-asset PATH] [--java-home /path/to/JDK/Contents/Home]

Build, validate, and open the macOS release app from a disposable installation.
Run in a clean macOS graphical login without existing WeekGlass data.
The DMG and local evidence are written to apps/client/build/weekglass-macos.

PATH points to a course_adapter directory with a prepared runtime, or its portable
ZIP with course_adapter/{engine.jar,lib/,licenses/,parser.policy}. With the ZIP,
use a native JDK 17 via --java-home or JAVA_HOME. Omitting PATH produces a
candidate without the offline course parser.
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }

course_asset=
java_home="${JAVA_HOME:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --course-asset) [[ $# -gt 1 ]] || die 'Missing course asset path.'; course_asset="$2"; shift ;;
    --java-home) [[ $# -gt 1 ]] || die 'Missing JDK home path.'; java_home="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == Darwin ]] || die 'The macOS release requires macOS with Xcode.'
host="$(uname -m)"
case "$host" in
  arm64) arch=arm64 ;;
  x86_64) arch=x64 ;;
  *) die "Unsupported macOS build architecture: $host" ;;
esac

if [[ -n "$course_asset" ]]; then
  [[ -d "$course_asset" || -f "$course_asset" ]] || die "Course asset not found: $course_asset"
  course_asset="$(cd "$(dirname "$course_asset")" && pwd)/$(basename "$course_asset")"
  if [[ -f "$course_asset" ]]; then
    [[ -x "$java_home/bin/jlink" ]] || die 'Use a complete native JDK 17 through --java-home or JAVA_HOME.'
    java_home="$(cd "$java_home" && pwd)"
  fi
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
versions="$root/tooling/versions.json"
command -v flutter >/dev/null 2>&1 || die 'Put the pinned Flutter SDK from tooling/versions.json on PATH.'

cd "$root/apps/client"
artifact_root="$PWD/build/weekglass-macos"
mkdir -p "$artifact_root/verification"
evidence="$(mktemp -d "$artifact_root/verification/package.XXXXXX")"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/weekglass-macos-package.XXXXXX")"
mount_point="$scratch/mounted"
mounted=false
cleanup() {
  if { $mounted || [[ -e "$mount_point/WeekGlass.app" ]]; } && ! /usr/bin/hdiutil detach "$mount_point"; then
    printf 'Could not detach the test image. Its files remain at %s.\n' "$scratch" >&2
    return
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

printf 'Package evidence: %s\n' "$evidence"
{
  xcodebuild -version
  sw_vers
  printf 'Host architecture: %s\n' "$host"
  printf 'Login session: %s\n' "$(launchctl managername)"
  printf 'Git commit: %s\n' "$(git rev-parse HEAD)"
  git status --short
  installed="$(flutter --suppress-analytics --version --machine)"
  actual_flutter="$(printf '%s' "$installed" | /usr/bin/plutil -extract frameworkVersion raw -o - -)"
  actual_dart="$(printf '%s' "$installed" | /usr/bin/plutil -extract dartSdkVersion raw -o - -)"
  required_flutter="$(/usr/bin/plutil -extract flutter.version raw -o - "$versions")"
  required_dart="$(/usr/bin/plutil -extract flutter.dart raw -o - "$versions")"
  printf 'Flutter %s with Dart %s\n' "$actual_flutter" "$actual_dart"
  [[ "$required_flutter" == "$actual_flutter" && "$required_dart" == "$actual_dart" ]] ||
    die "Use Flutter $required_flutter with Dart $required_dart."
} 2>&1 | tee "$evidence/toolchain.log"

# Use the normal entry point. The configuration matches the architecture of the test Mac.
printf 'ARCHS = %s\n' "$host" > "$scratch/release.xcconfig"
{
  flutter --suppress-analytics pub get --enforce-lockfile
  XCODE_XCCONFIG_FILE="$scratch/release.xcconfig" \
    flutter --suppress-analytics build macos --release --no-pub
} 2>&1 | tee "$evidence/build.log"

built_app="$PWD/build/macos/Build/Products/Release/WeekGlass.app"
staging="$scratch/image"
app="$staging/WeekGlass.app"
mkdir -p "$staging"
/usr/bin/ditto "$built_app" "$app"
ln -s /Applications "$staging/Applications"

plist="$app/Contents/Info.plist"
bundle_id=com.viliana.weekglass
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")"
build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$plist")"
expected_version="$(awk '$1 == "version:" { print $2; exit }' pubspec.yaml)"
[[ "$version+$build" == "$expected_version" ]] || die "Expected $expected_version; built $version+$build."
entitlements="$PWD/macos/Runner/Release.entitlements"

verify_app() {
  local candidate="$1" info="$1/Contents/Info.plist" executable aot signature key
  local extracted="$scratch/verified-entitlements.plist"
  printf '\nVerifying %s\n' "$candidate"
  executable="$candidate/Contents/MacOS/$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info")"
  aot="$candidate/Contents/Frameworks/App.framework/App"
  [[ -x "$executable" && -s "$aot" ]] || die 'The executable or Flutter AOT framework is missing.'
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")" == "$bundle_id" ]] ||
    die 'The app does not use its production bundle identifier.'
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info")+$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info")" == "$expected_version" ]] ||
    die 'The app version or build number changed.'
  [[ "$(xcrun lipo -archs "$executable")" == "$host" && "$(xcrun lipo -archs "$aot")" == "$host" ]] ||
    die "The app executable and Flutter AOT framework must both target $host."
  xcrun lipo -verify_arch "$host" "$candidate/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$candidate"
  signature="$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1)"
  printf '%s\n' "$signature"
  grep -qx 'Signature=adhoc' <<< "$signature" || die 'The app must use an ad hoc signature.'
  /usr/bin/codesign --display --entitlements - "$candidate" > "$extracted"
  for key in com.apple.security.app-sandbox com.apple.security.network.client \
             com.apple.security.network.server com.apple.security.files.user-selected.read-write; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$extracted")" == true ]] ||
      die "The signed app is missing the entitlement $key."
  done
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$extracted" 2>/dev/null)" != true ]] ||
    die 'The release signature allows debug attachment.'
  printf 'Bundle: %s %s (%s) with Flutter AOT and release sandbox\n' "$bundle_id" "$expected_version" "$host"
}

if [[ -n "$course_asset" ]]; then
  {
    course="$course_asset"
    if [[ -f "$course_asset" ]]; then
      course="$scratch/course_adapter"
      bash "$root/tooling/scripts/prepare-macos-course-adapter.sh" "$course_asset" "$java_home" "$course"
    fi
    jars=("$course"/lib/*.jar)
    licenses=("$course"/licenses/*.txt)
    [[ -s "$course/engine.jar" && -s "$course/parser.policy" && -s "${jars[0]}" && -s "${licenses[0]}" ]] ||
      die 'The course assets are missing the engine, dependencies, policy, or licenses.'
    [[ -x "$course/runtime/bin/java" && -s "$course/runtime/lib/modules" ]] || die 'The linked course runtime is incomplete.'
    xcrun lipo -verify_arch "$host" "$course/runtime/bin/java"
    /usr/bin/codesign --verify --strict "$course/runtime/bin/java"
    "$course/runtime/bin/java" -version
    installed_course="$app/Contents/Resources/course_adapter"
    /usr/bin/ditto "$course" "$installed_course"
    # Re-seal the app after adding resources; keep the existing framework signatures.
    /usr/bin/codesign --force --sign - --timestamp=none --entitlements "$entitlements" "$app"
  } 2>&1 | tee "$evidence/course-assets.log"
else
  printf 'This candidate has no bundled offline course parser.\n' | tee "$evidence/course-assets.log"
fi

verify_app "$app" 2>&1 | tee "$evidence/before-image.log"

filename="WeekGlass-macOS-$arch-$version.dmg"
dmg="$scratch/$filename"
mkdir -p "$mount_point" "$scratch/Applications"
{
  /usr/bin/hdiutil create -srcfolder "$staging" -volname WeekGlass -format UDZO -fs HFS+ "$dmg"
  /usr/bin/hdiutil verify "$dmg"
  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg"
} 2>&1 | tee "$evidence/image.log"
mounted=true
[[ "$(readlink "$mount_point/Applications")" == /Applications ]] || die 'The DMG has no Applications shortcut.'
verify_app "$mount_point/WeekGlass.app" 2>&1 | tee "$evidence/mounted-app.log"

installed_app="$scratch/Applications/WeekGlass.app"
/usr/bin/ditto "$mount_point/WeekGlass.app" "$installed_app"
/usr/bin/hdiutil detach "$mount_point" 2>&1 | tee -a "$evidence/image.log"
mounted=false
verify_app "$installed_app" 2>&1 | tee "$evidence/copied-app.log"

if [[ -n "$course_asset" ]]; then
  (
    cd "$installed_app/Contents/Resources/course_adapter"
    ./runtime/bin/java -Xint --list-modules
    printf '%s\n' '{"op":"parse","adapter":"csv","source":"name,day,first,last,teacher,room,weeks\nPhysics,2,1,2,Lee,A101,1-8"}' |
      ./runtime/bin/java -Xint -Djava.security.manager -Djava.security.policy==parser.policy -jar engine.jar > "$evidence/course-result.json"
    [[ "$(/usr/bin/plutil -extract courses.0.name raw -o - "$evidence/course-result.json")" == Physics ]] ||
      die 'The parser copied from the DMG did not read the example course.'
    printf 'The runtime and parser copied from the DMG parsed the documented CSV example.\n'
  ) 2>&1 | tee "$evidence/course-runtime.log"
fi

gatekeeper_status=0
/usr/sbin/spctl --assess --type execute --verbose=4 "$installed_app" > "$evidence/gatekeeper-assessment.log" 2>&1 || gatekeeper_status=$?
quarantined=false
quarantine="$(/usr/bin/xattr -p com.apple.quarantine "$installed_app" 2>/dev/null)" && quarantined=true
{
  /usr/sbin/spctl --status
  cat "$evidence/gatekeeper-assessment.log"
  printf 'Gatekeeper assessment exit status: %s\n' "$gatekeeper_status"
  printf 'Ad hoc code integrity uses no Developer ID and no notarization. macOS can block the first launch of an Internet download under standard Gatekeeper policy.\n'
  printf 'Apple support: https://support.apple.com/en-us/102445\n'
  if $quarantined; then
    printf 'Internet quarantine attribute: %s\n' "$quarantine"
  else
    printf 'This locally built installation copy has no Internet quarantine attribute.\n'
  fi
} 2>&1 | tee "$evidence/gatekeeper.log"

{
  xcrun swiftc -parse-as-library "$root/tooling/scripts/verify-macos-launch.swift" -o "$scratch/verify-launch"
  "$scratch/verify-launch" "$installed_app" "$evidence/first-launch.png"
} 2>&1 | tee "$evidence/first-launch.log"

manifest="${dmg%.dmg}.json"
digest="$(/usr/bin/shasum -a 256 < "$dmg" | awk '{print $1}')"
bytes="$(stat -f '%z' "$dmg")"
parser_included=false
[[ -z "$course_asset" ]] || parser_included=true
/usr/bin/plutil -create json "$manifest"
/usr/bin/plutil -insert commit -string "$(git rev-parse HEAD)" "$manifest"
/usr/bin/plutil -insert version -string "$version" "$manifest"
/usr/bin/plutil -insert build -integer "$build" "$manifest"
/usr/bin/plutil -insert arch -string "$arch" "$manifest"
/usr/bin/plutil -insert asset -json '{}' "$manifest"
/usr/bin/plutil -insert asset.name -string "$filename" "$manifest"
/usr/bin/plutil -insert asset.bytes -integer "$bytes" "$manifest"
/usr/bin/plutil -insert asset.digest -string "sha256:$digest" "$manifest"
/usr/bin/plutil -insert native_launch -bool true "$manifest"
/usr/bin/plutil -insert adhoc_verified -bool true "$manifest"
/usr/bin/plutil -insert course_adapter -bool "$parser_included" "$manifest"
/usr/bin/plutil -insert gatekeeper -json '{}' "$manifest"
/usr/bin/plutil -insert gatekeeper.assessment_exit_status -integer "$gatekeeper_status" "$manifest"
/usr/bin/plutil -insert gatekeeper.assessment -string "$(cat "$evidence/gatekeeper-assessment.log")" "$manifest"
/usr/bin/plutil -insert gatekeeper.internet_quarantine -bool "$quarantined" "$manifest"

mv -f -- "$dmg" "$artifact_root/$filename"
mv -f -- "$manifest" "$artifact_root/${filename%.dmg}.json"
printf 'Validated DMG: %s (%s bytes)\n' "$artifact_root/$filename" "$bytes" |
  tee "$evidence/package.log"
