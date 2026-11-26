#!/usr/bin/env bash
# Each signing input has exactly the sealed Mach-O, bundle metadata, resource
# envelope, entitlements and designated requirement; never a private key.
set -euo pipefail
mode="$1"; key="$2"
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
leaf=942A2793EB98F519A4D23E5626C96D2EED0FA03C
cpu="$(uname -m)"; case "$cpu" in arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) exit 2 ;; esac
stage="$RUNNER_TEMP/weekglass-signing"
mkdir -p "$stage"
case "$key" in
  xpc-"$arch") app="$stage/WeekGlassAccount.xpc"; target=WeekGlassAccount; id=com.viliana.weekglass.account ;;
  app-a-"$arch") app="$stage/A/WeekGlass.app"; target=WeekGlass; id=com.viliana.weekglass; version=0.22.12; build=61 ;;
  app-b-arm64) [[ "$arch" == arm64 ]]; app="$stage/B/WeekGlass.app"; target=WeekGlass; id=com.viliana.weekglass; version=0.22.13; build=62 ;;
  *) echo 'Unexpected native signing key' >&2; exit 2 ;;
esac
binary="$app/Contents/MacOS/$target"; req="$stage/request-$key"
rule="identifier \"$id\" and certificate leaf = H\"$leaf\""
if [[ "$mode" == seal ]]; then
  if [[ "$target" == WeekGlassAccount ]]; then
    bash "$root/tooling/macos-account/build-account-service.sh" "$cpu" com.viliana.weekglass "$leaf" "$stage"
  else
    helper="$stage/WeekGlassAccount.xpc"
    codesign --verify --strict -R "=identifier \"com.viliana.weekglass.account\" and certificate leaf = H\"$leaf\"" "$helper"
    cd "$root/apps/client"
    public="$(plutil -extract public_ed_key raw -o - "$root/tooling/macos-update.json")"
    url="$(plutil -extract "$arch" raw -o - "$root/tooling/macos-update.json")"
    cfg="$stage/$key.xcconfig"
    { printf 'ARCHS = %s\nCODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO\n' "$cpu"
      printf 'WG_MAC_UPDATE_FEED_URL = https:/$()/%s\n' "${url#https://}"
      printf 'WG_MAC_UPDATE_PUBLIC_KEY = %s\n' "$public"
    } > "$cfg"
    flutter --suppress-analytics pub get --enforce-lockfile
    XCODE_XCCONFIG_FILE="$cfg" flutter --suppress-analytics build macos --release --no-pub --build-name "$version" --build-number "$build" --dart-define="WEEKGLASS_RELEASE_VERSION=$version" --dart-define="WEEKGLASS_RELEASE_BUILD=$build"
    mkdir -p "$(dirname "$app")"; ditto "$PWD/build/macos/Build/Products/Release/WeekGlass.app" "$app"
    mkdir -p "$app/Contents/XPCServices"
    ditto "$helper" "$app/Contents/XPCServices/WeekGlassAccount.xpc"
    ditto "${WEEKGLASS_MAC_COURSE_RUNTIME_DIR:?}" "$app/Contents/Resources/course_adapter"
    codesign --display --entitlements - --xml "$app" > "$stage/$key.entitlements"
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$stage/$key.entitlements" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$stage/$key.entitlements"
    fi
    codesign --force --sign - --timestamp=none --entitlements "$stage/$key.entitlements" "$app"
  fi
  mkdir "$req"; cp "$binary" "$req/MachO"; cp "$app/Contents/Info.plist" "$req/Info.plist"
  cp "$app/Contents/_CodeSignature/CodeResources" "$req/CodeResources"
  codesign --display --entitlements - --xml "$app" > "$req/Entitlements.plist"
  csreq -r "=$rule" -b "$req/Requirement.bin"
elif [[ "$mode" == receive ]]; then
  dest="$stage/signed-$key"; mkdir -p "$dest"
  SECONDS=0
  until gh release download "native-signed-$GITHUB_RUN_ID" -R "$GITHUB_REPOSITORY" --pattern "$key.macho" --dir "$dest" 2>"$dest/wait.log"; do
    if (( SECONDS >= 1800 ));then cat "$dest/wait.log" >&2;echo "Waiting for $key timed out." >&2;exit 1;fi
    sleep 12
  done
  cat "$dest/$key.macho" > "$binary"
  codesign --verify --strict --deep "$app"; codesign --verify -R "=$rule" "$app"
  codesign --display -r- "$app"
else exit 2; fi
