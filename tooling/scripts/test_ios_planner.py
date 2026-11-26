"""Build the normal entry point and exercise it in a new, disposable iPhone simulator."""

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "client"


def output(*command):
    return subprocess.check_output(command, cwd=APP, text=True).strip()


def run(*command):
    subprocess.run(command, cwd=APP, check=True)


def choose_iphone(inventory):
    # Match an installed iOS runtime to a device type it actually supports.
    runtimes = sorted(
        (rt for rt in inventory["runtimes"] if rt["isAvailable"] and
         ".SimRuntime.iOS-" in rt["identifier"]),
        key=lambda rt: tuple(map(int, rt["version"].split("."))),
        reverse=True,
    )
    for runtime in runtimes:
        types = runtime.get("supportedDeviceTypes", [])
        for device in types:
            if ".SimDeviceType.iPhone-" in device["identifier"]:
                return device["identifier"], runtime["identifier"]
        for device in inventory["devices"].get(runtime["identifier"], []):
            kind = device.get("deviceTypeIdentifier", "")
            if device["isAvailable"] and ".SimDeviceType.iPhone-" in kind:
                return kind, runtime["identifier"]
    raise SystemExit("请先在 Xcode 安装 iOS Simulator 运行时和 iPhone 机型。")


def main():
    if platform.system() != "Darwin":
        raise SystemExit("iPhone 模拟器验收需要装有 Xcode 的 Mac。")
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("请把 Flutter 3.47.9 的 bin 目录加入 PATH。")
    pin = json.loads((ROOT / "tooling/versions.json").read_text())["flutter"]
    sdk = json.loads(output(flutter, "--version", "--machine"))
    if sdk["frameworkVersion"] != pin["version"] or sdk["dartSdkVersion"] != pin["dart"]:
        raise SystemExit(f"需要 Flutter {pin['version']} 和 Dart {pin['dart']}。")
    device, runtime = choose_iphone(json.loads(output("xcrun", "simctl", "list", "-j")))
    run(flutter, "pub", "get", "--enforce-lockfile")
    run(flutter, "build", "ios", "--simulator", "--debug", "--config-only", "--no-pub")
    base = APP / "build/ios-planner-test"
    base.mkdir(parents=True, exist_ok=True)
    result = Path(tempfile.mkdtemp(dir=base, prefix="run-")) / "Planner.xcresult"
    sim = output("xcrun", "simctl", "create", f"WeekGlass UI {os.getpid()}", device, runtime)
    try:
        print(f"{device}  {runtime}\n{result}", flush=True)
        run("xcrun", "simctl", "boot", sim)
        run("xcrun", "simctl", "bootstatus", sim, "-b")
        run("xcodebuild", "-workspace", "ios/Runner.xcworkspace", "-scheme", "Runner",
            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={sim}",
            "-parallel-testing-enabled", "NO", "-only-testing:RunnerUITests",
            "-derivedDataPath", str(base / "DerivedData"), "-resultBundlePath", str(result),
            "test")
    finally:
        run("xcrun", "simctl", "delete", sim)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
