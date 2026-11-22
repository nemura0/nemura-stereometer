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
shot antiphase --mode goniometer --at 7.8 ${extra[@]+"${extra[@]}"}
shot transparent --mode goniometer --background 00000000 ${extra[@]+"${extra[@]}"}
shot glow --mode goniometer --glow 60 ${extra[@]+"${extra[@]}"}
shot readouts --mode goniometer --readouts on ${extra[@]+"${extra[@]}"}
shot readouts_antiphase --mode goniometer --readouts on --at 7.8 ${extra[@]+"${extra[@]}"}

# The NEMURA concept looks, each at the default moment and in the mix's antiphase passage.
concept() {
  local name=$1
  shift
  shot "$name" "$@" ${extra[@]+"${extra[@]}"}
  shot "${name}_antiphase" "$@" --at 7.8 ${extra[@]+"${extra[@]}"}
}
concept concept_iris_bloom --mode goniometer --color solid --glow 70 --whiten 0.2 \
  --guides off --ring C8CCD8B0 --glow-color 8993FF --glow-warn E03C60 --readouts on
concept concept_spine_wings --mode goniometer --draw lines --color midside \
  --stops 0:F2F4FA,0.5:8993FF,0.8:E03C60,1:E03C60 --guide-strong C8CCD870 --glow 20 \
  --readouts on
concept concept_metalheart --mode goniometer_log --color amplitude --colormap chrome \
  --guides full --guide-strong 9EA4B860 --guide-weak 6A708430 --ring C8CCD8B0 --glow 40 \
  --glow-color 8993FF --glow-warn E03C60 --readouts on
