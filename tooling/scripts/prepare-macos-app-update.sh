#!/usr/bin/env bash
set -euo pipefail

# Build A and B using the production updater and an isolated data fixture.
# Stop on the first failure. Only test-macos-app-update.sh starts A; only
# Sparkle may install or start B. Never publish these temporary identities.
[[ "$(uname -s):$(uname -m)" == Darwin:arm64 ]] || { echo 'Requires an Apple Silicon Mac.' >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/weekglass-upgrade.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch"/{keys,tools/sparkle,tools/rcodesign,A,B,feed}
chmod 700 "$scratch/keys"
cd "$root/apps/client"
evidence="$PWD/build/weekglass-macos/verification"
mkdir -p "$evidence"
exec > >(tee "$evidence/upgrade-build.log") 2>&1
sw_vers
xcodebuild -version
printf 'Commit: %s. Architecture: %s. Login session: %s.\n' "$(git rev-parse HEAD)" "$(uname -m)" "$(launchctl managername)"
/usr/sbin/spctl --status
tools="$scratch/tools"
download() {
  local url="$1" archive="$2" digest="$3"
  curl --fail --location --retry 2 --silent --show-error "$url" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | /usr/bin/shasum -a 256 -c -
}
download 'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-aarch64-apple-darwin.tar.gz' \
  "$tools/rcodesign.tgz" d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a
download 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz' \
  "$tools/sparkle.txz" 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
tar -xf "$tools/rcodesign.tgz" -C "$tools/rcodesign"
tar -xf "$tools/sparkle.txz" -C "$tools/sparkle"
rc="$(find "$tools/rcodesign" -name rcodesign -type f -print -quit)"
sign_update="$(find "$tools/sparkle" -name sign_update -type f -print -quit)"
[[ -x "$rc" && -x "$sign_update" ]]

# The project certificate is never added to a keychain or trusted by macOS.
# Native codesign verifies the result of the offline signer against our own DR.
keys="$scratch/keys"
cat > "$keys/openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = signing
[dn]
CN = WeekGlass Ephemeral Upgrade Test
O = WeekGlass
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
(umask 077
 openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -config "$keys/openssl.cnf" \
   -out "$keys/cert.pem" -keyout "$keys/openssl.key"
 openssl pkcs8 -topk8 -nocrypt -in "$keys/openssl.key" -out "$keys/key.pem")
cert="$(openssl x509 -in "$keys/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
id=com.viliana.weekglass.updatesmoke
requirement="identifier \"$id\" and certificate leaf = H\"$cert\""
/usr/bin/csreq -r "=$requirement" -b "$keys/requirement.bin"
public="$(xcrun swift - "$keys/sparkle.key" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"
printf 'ARCHS = arm64\nWEEKGLASS_MACOS_BUNDLE_SUFFIX = .updatesmoke\n' > "$scratch/test.xcconfig"
flutter --suppress-analytics pub get --enforce-lockfile
feed_url='http://127.0.0.1:18765/appcast.xml'
build_candidate() {
  local dest="$1" version="$2" build="$3" app plist ent
  XCODE_XCCONFIG_FILE="$scratch/test.xcconfig" flutter --suppress-analytics build macos --release --no-pub \
    --target integration_test/macos_app_update_entry.dart --build-name "$version" --build-number "$build"
  app="$dest/WeekGlass.app"; plist="$app/Contents/Info.plist"; ent="$dest/entitlements.plist"
  ditto "$PWD/build/macos/Build/Products/Release/WeekGlass.app" "$app"
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == "$id" ]]
  [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")+$(plutil -extract CFBundleVersion raw -o - "$plist")" == "$version+$build" ]]
  /usr/bin/codesign --display --entitlements - --xml "$app" > "$ent"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ent")" == true ]]
  /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name' "$ent" | grep -Fq "$id-spki"
  plutil -replace SUFeedURL -string "$feed_url" "$plist"
  plutil -replace SUPublicEDKey -string "$public" "$plist"
  # The fixture alone can use HTTP on the one loopback address. The appcast
  # and payload still require signatures; production uses HTTPS.
  plutil -insert NSAppTransportSecurity -json '{"NSExceptionDomains":{"127.0.0.1":{"NSExceptionAllowsInsecureHTTPLoads":true}}}' "$plist"
  [[ -d "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" ]]
  "$rc" sign --shallow --timestamp-url none --pem-file "$keys/cert.pem" --pem-file "$keys/key.pem" \
    --binary-identifier "$id" --entitlements-xml-file "$ent" --code-requirements-file "$keys/requirement.bin" "$app"
  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/codesign --verify -R "=$requirement" "$app"
  /usr/bin/codesign --display -r- "$app"
}
build_candidate "$scratch/A" 0.22.8 57
build_candidate "$scratch/B" 0.22.9 58
feed="$scratch/feed"
archive=WeekGlass-0.22.9.zip
ditto -c -k --sequesterRsrc --keepParent "$scratch/B/WeekGlass.app" "$feed/$archive"
signature="$("$sign_update" --ed-key-file "$keys/sparkle.key" "$feed/$archive")"
cat > "$feed/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>WeekGlass</title><item><title>WeekGlass 0.22.9</title>
<sparkle:version>58</sparkle:version><sparkle:shortVersionString>0.22.9</sparkle:shortVersionString>
<enclosure url="http://127.0.0.1:18765/$archive" type="application/octet-stream" $signature/>
</item></channel></rss>
EOF
"$sign_update" --ed-key-file "$keys/sparkle.key" "$feed/appcast.xml"
cp "$feed/appcast.xml" "$evidence/appcast.xml"
bash "$root/tooling/scripts/test-macos-app-update.sh" "$scratch/A/WeekGlass.app" "$feed" 0.22.9 58
