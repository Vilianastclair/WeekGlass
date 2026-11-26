#!/usr/bin/env bash
# Build the fixed per-architecture OAuth service once. No keys are available
# to this build. The final signature is applied by the maintainer.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: build-account-service.sh architecture host-id leaf-fingerprint stage-directory' >&2;exit 2; }
arch="$1"; host="$2"; leaf="$3"; out="$4"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] && [[ "$leaf" =~ ^[a-fA-F0-9]{40}$ ]] &&
  [[ "$host" == com.viliana.weekglass || "$host" == com.viliana.weekglass.updatesmoke ]] || exit 2
root="$(cd "$(dirname "$0")/../.." && pwd -P)"; app="$out/WeekGlassAccount.xpc"; mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$host.account</string>
<key>CFBundleExecutable</key><string>WeekGlassAccount</string><key>CFBundleName</key><string>WeekGlassAccount</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>XPC!</string><key>LSMinimumSystemVersion</key><string>12.0</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string>
<key>RunLoopType</key><string>dispatch_main</string><key>JoinExistingSession</key><true/></dict></dict></plist>
EOF
extra=()
if [[ "$host" == com.viliana.weekglass.updatesmoke ]]; then
  [[ -f "${WG_TEST_GRANT_DIR:?}/test-ca.pem" ]]; cert="$(openssl x509 -in "$WG_TEST_GRANT_DIR/test-ca.pem" -outform DER | base64 |tr -d '\r\n')"
  extra+=("-DWG_TEST_SERVER_CA=\"$cert\"")
fi
# Empty arrays need the + form on Apple's bash 3.2 when using set -u.
xcrun clang -arch "$arch" -mmacosx-version-min=12.0 -Os -fobjc-arc -fblocks -Wno-deprecated-declarations   "-DWG_LEAF=\"$leaf\"" "-DWG_HOST_ID=\"$host\"" ${extra[@]+"${extra[@]}"}   "$root/apps/client/macos/AccountService/Account.m" -framework Security -framework Foundation   -o "$app/Contents/MacOS/WeekGlassAccount"
codesign -f -s - --timestamp=none --entitlements "$root/apps/client/macos/AccountService/Release.entitlements" "$app"
