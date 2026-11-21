#!/usr/bin/env bash
# Verifies that CMake and SwiftPM compile exactly the same Sources/{Core,Render,CoreC} files.
#
#   scripts/check-sources.sh [release|debug]   (the SwiftPM configuration to inspect; default release)
#
# Run after both builds exist (scripts/build.sh). Checks, per directory:
#   1. sources sit at the top level only (CMake globs non-recursively; SwiftPM recurses) and no
#      two share a file stem;
#   2. CMake compiled every source (build/compile_commands.json) and nothing else;
#   3. SwiftPM compiled every source (its object files) and nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${NMR_BUILD_DIR:-$ROOT/build}"
SWIFT_CONFIG="${1:-release}"
COMMANDS="$BUILD/compile_commands.json"
SWIFT_BIN="$(swift build --package-path "$ROOT" --build-system native --arch arm64 \
  -c "$SWIFT_CONFIG" --show-bin-path)"
SOURCE_PATTERN='\.(c|cc|cpp|m|mm)$'

if [[ ! -f "$COMMANDS" ]]; then
  echo "error: $COMMANDS missing (run scripts/build.sh)" >&2
  exit 1
fi

status=0
report() { # label expected actual
  if [[ "$2" != "$3" ]]; then
    echo "MISMATCH $1"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/  /' || true
    status=1
  fi
}

for pair in "Core:NMRCore" "Render:NMRRender" "CoreC:NMRCoreC"; do
  dir="${pair%%:*}"
  target="${pair##*:}"
  src="$ROOT/Sources/$dir"

  nested="$(find "$src" -mindepth 2 -type f | grep -E "$SOURCE_PATTERN" || true)"
  if [[ -n "$nested" ]]; then
    echo "error: sources in subdirectories of Sources/$dir (CMake would not compile them):"
    printf '  %s\n' "$nested"
    status=1
  fi

  expected="$(find "$src" -maxdepth 1 -type f | grep -E "$SOURCE_PATTERN" | sed 's|.*/||' | sort)"
  stems="$(printf '%s\n' "$expected" | sed -E 's/\.[^.]+$//' | sort)"
  if [[ "$(printf '%s\n' "$stems" | uniq -d)" != "" ]]; then
    echo "error: two sources in Sources/$dir share a file stem"
    status=1
  fi

  cmake_files="$(jq -r '.[].file' "$COMMANDS" | grep -F "/Sources/$dir/" |
    grep -vF "/Sources/$dir/include/" | sed 's|.*/||' | sort -u)"
  report "CMake vs Sources/$dir" "$expected" "$cmake_files"

  swift_objects="$(find "$SWIFT_BIN/$target.build" -maxdepth 1 -name '*.o' 2>/dev/null |
    sed -E 's|.*/||; s/\.o$//' | sort)"
  report "SwiftPM ($target) vs Sources/$dir" "$expected" "$swift_objects"
done

if ((status == 0)); then echo "CMake and SwiftPM compile the same sources"; fi
exit "$status"
