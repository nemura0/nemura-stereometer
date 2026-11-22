#!/bin/bash
# Renders the snapshot set into build/snapshots/: each mode and draw style from the test mix.
#   scripts/snapshots.sh [--at SECONDS] [extra nmr_snapshot options...]
set -euo pipefail
cd "$(dirname "$0")/.."

cmake --build build --target nmr_snapshot nmr_make_test_wav >/dev/null
out=build/snapshots
mkdir -p "$out"
wav="$out/mix.wav"
[ -f "$wav" ] || ./build/Tests/tools/nmr_make_test_wav mix "$wav" --seconds 10 >/dev/null

shot() {
  local name=$1
  shift
  ./build/Tests/tools/nmr_snapshot "$wav" "$out/$name.png" "$@"
}

extra=("$@")
shot goniometer --mode goniometer ${extra[@]+"${extra[@]}"}
shot goniometer_log --mode goniometer_log --guides full ${extra[@]+"${extra[@]}"}
shot half --mode half ${extra[@]+"${extra[@]}"}
shot half_log --mode half_log --guides full ${extra[@]+"${extra[@]}"}
shot lissajous --mode lissajous ${extra[@]+"${extra[@]}"}
shot goniometer_lines --mode goniometer --draw lines ${extra[@]+"${extra[@]}"}
shot antiphase --mode goniometer --at 8.5 ${extra[@]+"${extra[@]}"}
shot transparent --mode goniometer --background 00000000 ${extra[@]+"${extra[@]}"}
shot glow --mode goniometer --glow 60 ${extra[@]+"${extra[@]}"}
