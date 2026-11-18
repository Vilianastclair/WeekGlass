"""Create the Windows parser's private, redistributable runtime with the project JDK."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    config = json.loads((root / "tooling/versions.json").read_text(encoding="utf-8"))
    toolchain = Path(os.environ.get("WEEKGLASS_TOOLCHAIN_HOME", config["toolchainRoot"]))
    java = toolchain / "jdk/current"
    version = config["java"]["version"]
    release = (java / "release").read_text(encoding="utf-8").splitlines()
    if f'JAVA_VERSION="{version}"' not in release or 'IMPLEMENTOR="Microsoft"' not in release:
        raise SystemExit("Use the pinned Microsoft JDK from tooling/versions.json to build the Windows runtime.")
    out = Path(sys.argv[1])
    out.parent.mkdir(exist_ok=True, parents=True)
    # MSBuild creates the output directory before invoking us, while jlink
    # requires a fresh directory. A failed link must not leave a success stamp.
    with tempfile.TemporaryDirectory(dir=out.parent) as temporary:
        image = Path(temporary) / "image"
        subprocess.run([str(java / "bin/jlink.exe"), "--add-modules",
                        "java.base,java.xml,java.logging,jdk.unsupported",
                        "--strip-debug", "--compress=2", "--no-header-files", "--no-man-pages",
                        "--output", str(image)], check=True)
        shutil.copytree(image, out, dirs_exist_ok=True)


if __name__ == "__main__":
    main()
