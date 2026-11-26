#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 || "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'Usage on a Mac: bash tooling/scripts/prepare-macos-course-adapter.sh course_adapter.zip JDK/Contents/Home output/course_adapter' >&2
  exit 2
fi
die() { printf '%s\n' "$*" >&2; exit 1; }

archive="$1"
java_home="$2"
output="$3"
host="$(uname -m)"
[[ -f "$archive" ]] || die "Course asset ZIP not found: $archive"
[[ -x "$java_home/bin/jlink" && -x "$java_home/bin/java" && -d "$java_home/jmods" ]] ||
  die 'Use a complete native JDK 17.'
[[ ! -e "$output" && ! -L "$output" ]] || die "Course output already exists: $output"

xcrun lipo "$java_home/bin/java" -verify_arch "$host"
jdk_version="$(/usr/bin/awk -F '"' '$1 == "JAVA_VERSION=" { print $2 }' "$java_home/release")"
[[ "$jdk_version" == 17 || "$jdk_version" == 17.* ]] || die "Use JDK 17; found $jdk_version."
"$java_home/bin/java" -version

parent="$(dirname "$output")"
mkdir -p "$parent"
scratch="$(mktemp -d "$parent/.course.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/extracted"
/usr/bin/ditto -x -k "$archive" "$scratch/extracted"
course="$scratch/extracted/course_adapter"
[[ -s "$course/engine.jar" && -s "$course/parser.policy" ]] || die 'The course ZIP is missing engine.jar or parser.policy.'
jars=("$course"/lib/*.jar)
licenses=("$course"/licenses/*.txt)
[[ -s "${jars[0]}" && -s "${licenses[0]}" ]] || die 'The course ZIP has no JAR dependencies or license notices.'

staged="$scratch/staged"
mkdir -p "$staged/lib" "$staged/licenses"
cp "$course/engine.jar" "$course/parser.policy" "$staged/"
cp "${jars[@]}" "$staged/lib/"
cp "${licenses[@]}" "$staged/licenses/"
"$java_home/bin/jlink" --module-path "$java_home/jmods" \
  --add-modules java.base,java.xml,java.logging,jdk.unsupported \
  --strip-debug --compress=2 --no-header-files --no-man-pages --output "$staged/runtime"

[[ -x "$staged/runtime/bin/java" && -s "$staged/runtime/lib/modules" ]] || die 'The linked course runtime is incomplete.'
# The app launches Java as a direct child, so the tool inherits its app sandbox.
# Re-seal native Java files modified by jlink without adding runtime privileges.
while IFS= read -r -d '' binary; do
  if [[ "$(/usr/bin/file -b "$binary")" == *Mach-O* ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$binary"
    /usr/bin/codesign --verify --strict "$binary"
  fi
done < <(/usr/bin/find "$staged/runtime" -type f -print0)
mv -- "$staged" "$output"
printf 'Prepared the %s course parser and JDK %s runtime at %s.\n' "$host" "$jdk_version" "$output"
