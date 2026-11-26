"""Build and verify a personal-signing IPA from the normal iPhone app entry point."""
import filecmp
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/client"
MACHO = {bytes.fromhex(x) for x in ("feedface", "feedfacf", "cefaedfe", "cffaedfe",
                                    "cafebabe", "cafebabf", "bebafeca", "bfbafeca")}


def require(value, message):
    if not value:
        raise SystemExit(message)


def output(*args):
    return subprocess.check_output(args, cwd=APP, text=True).strip()


def run(*args, cwd=APP):
    subprocess.run(args, cwd=cwd, check=True)


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MACHO


def prepare_payload(bundle, version, build):
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    for key, expected in {"CFBundleDisplayName": "WeekGlass",
                          "CFBundleIdentifier": "com.viliana.weekglass",
                          "CFBundleShortVersionString": version,
                          "CFBundleVersion": str(build),
                          "CFBundleSupportedPlatforms": ["iPhoneOS"],
                          "DTPlatformName": "iphoneos"}.items():
        require(info.get(key) == expected, f"{key}: expected {expected}, got {info.get(key)}")
    forbidden = [p for p in bundle.rglob("*") if p.suffix.lower() in
                 {".mobileprovision", ".provisionprofile", ".p12", ".pfx", ".pem", ".key", ".cer",
                  ".der", ".xctest"}]
    require(not forbidden, f"Signing or test material in payload: {forbidden}")
    executables = [p for p in bundle.rglob("*") if is_macho(p)]
    runner = bundle / info["CFBundleExecutable"]
    aot = bundle / "Frameworks/App.framework/App"
    engine = bundle / "Frameworks/Flutter.framework/Flutter"
    require({runner, aot, engine} <= set(executables), "Missing app, AOT or Flutter engine")
    platforms = {}
    for path in executables:
        require(output("xcrun", "lipo", "-archs", path) == "arm64", f"Wrong architecture: {path}")
        commands = output("xcrun", "vtool", "-show-build", path)
        require(re.search(r"^\s*platform\s+IOS\s*$", commands, re.M) or
                "LC_VERSION_MIN_IPHONEOS" in commands, f"Wrong platform: {path}\n{commands}")
        # Flutter signs some frameworks ad hoc even with --no-codesign. Remove
        # those linker/engine signatures in the staged copy, before archiving.
        if "LC_CODE_SIGNATURE" in output("xcrun", "otool", "-l", path):
            run("codesign", "--remove-signature", path)
            require("LC_CODE_SIGNATURE" not in output("xcrun", "otool", "-l", path),
                    f"Signature still present: {path}")
        platforms[path.relative_to(bundle).as_posix()] = "iphoneos/arm64"
    for signature in bundle.rglob("_CodeSignature"):
        shutil.rmtree(signature)

    symbols = output("xcrun", "nm", "-gU", aot)
    require("kDartIsolateSnapshotInstructions" in symbols and "kDartIsolateSnapshotData" in symbols,
            "Dart AOT snapshot not found in App.framework")
    assets = aot.parent / "flutter_assets"
    for name in ("kernel_blob.bin", "vm_snapshot_data", "isolate_snapshot_data"):
        require(not (assets / name).exists(), f"Debug runtime data present: {name}")
    for name in ("Assets.car", "Frameworks/App.framework/flutter_assets/AssetManifest.bin",
                 "Frameworks/App.framework/flutter_assets/FontManifest.json"):
        require((bundle / name).stat().st_size > 0, f"Missing {name}")
    fonts = json.loads((assets / "FontManifest.json").read_text())
    require(any(f["family"] == "WeekGlassSans" and any(x["asset"] == "assets/fonts/NotoSansSC-Variable.ttf"
                for x in f["fonts"]) for f in fonts), "WeekGlassSans font is not registered")
    source_assets = sorted(p for p in (APP / "assets").rglob("*") if p.is_file())
    for src in source_assets:
        dst = assets / src.relative_to(APP)
        require(dst.is_file() and filecmp.cmp(src, dst, shallow=False), f"Unexpected asset: {dst}")
    registrant = (APP / "ios/Runner/GeneratedPluginRegistrant.m").read_text()
    plugins = sorted(set(re.findall(r'\bregistrarForPlugin:@"([^"]+)"', registrant)))
    require({"SqflitePlugin", "FilePickerPlugin", "SharedPreferencesPlugin", "FlutterTimezonePlugin"}
            <= set(plugins), f"Missing planner plugins: {plugins}")
    runner_code = runner.read_bytes()
    for plugin in plugins:
        require(plugin.encode() in runner_code, f"Missing plugin registration in Runner: {plugin}")

    return {"bundle_id": info["CFBundleIdentifier"], "minimum_os": info["MinimumOSVersion"],
            "executables": platforms, "aot": True, "source_assets": len(source_assets),
            "plugins": plugins}


def main():
    pin = json.loads((ROOT / "tooling/versions.json").read_text())["flutter"]
    sdk = json.loads(output("flutter", "--version", "--machine"))
    require(sdk["frameworkVersion"] == pin["version"] and sdk["dartSdkVersion"] == pin["dart"],
            f"Use Flutter {pin['version']} and Dart {pin['dart']}")
    identity = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", (APP / "pubspec.yaml").read_text(), re.M)
    require(identity, "Missing version+build")
    version, build = identity.group(1), int(identity.group(2))
    commit = output("git", "rev-parse", "HEAD")
    run("flutter", "pub", "get", "--enforce-lockfile")
    run("flutter", "build", "ios", "--release", "--no-codesign", "--no-pub")
    source = APP / "build/ios/iphoneos/Runner.app"
    product = APP / "build/ios/device-package"
    product.mkdir(parents=True, exist_ok=True)
    name = f"WeekGlass-iOS-{version}-arm64-unsigned.ipa"
    with tempfile.TemporaryDirectory(dir=product.parent) as temp:
        stage = Path(temp)
        bundle = stage / "Payload/Runner.app"
        shutil.copytree(source, bundle, symlinks=True)
        checks = prepare_payload(bundle, version, build)
        archive = stage / name
        run("/usr/bin/zip", "-qryX", archive, "Payload", cwd=stage)
        with zipfile.ZipFile(archive) as packed:
            require(packed.testzip() is None, "IPA CRC failed")
            require(all(n.startswith("Payload/") for n in packed.namelist()), "Unexpected IPA root")
            require(packed.getinfo("Payload/Runner.app/Runner").external_attr >> 16 & 0o111,
                    "Runner lost its executable permission")
        with archive.open("rb") as data:
            digest = hashlib.sha256(data.read()).hexdigest()
        receipt = {"commit": commit, "version": version, "build": build, "platform": "iphoneos",
                   "arch": "arm64", "signing": "unsigned", "device_release_verified": True,
                   "asset": {"name": name, "bytes": archive.stat().st_size,
                             "digest": f"sha256:{digest}"}, "checks": checks}
        detail = archive.with_suffix(".json")
        detail.write_text(json.dumps(receipt, indent=2) + "\n")
        # Keep the upload directory exclusive to this build and never publish stale files.
        require(not any(p.name not in (name, detail.name) for p in product.iterdir()),
                f"Use an empty output directory: {product}")
        os.replace(archive, product / name)
        os.replace(detail, product / detail.name)
        print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
