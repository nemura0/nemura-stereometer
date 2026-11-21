#!/usr/bin/env bash
# End-to-end check of system-audio capture with the built app (scripts/build.sh first).
#
#   scripts/capture-probe.sh [seconds]
#
# Plays a quiet test tone (1 kHz at -60 dBFS) with afplay, launches the app through LaunchServices
# in --tap-probe mode (so the app itself, not the terminal, is the process macOS asks about), and
# reports whether non-silent audio arrived. The first run on a Mac shows the audio-capture
# permission prompt; someone must click Allow. A denied permission still starts the tap but
# delivers only zeros.
#
# Exit status: 0 audio captured, 1 silent capture, 2 the tap did not start.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
BUILD="${NMR_BUILD_DIR:-$ROOT/build}"
APP="$BUILD/app/$NMR_PRODUCT_NAME.app"
TOOL="$BUILD/Tests/tools/nmr_make_test_wav"
OUT="$BUILD/probe"
CAPTURE_SECONDS="${1:-4}"

for required in "$APP" "$TOOL"; do
  if [[ ! -e "$required" ]]; then
    echo "error: missing $required (run scripts/build.sh)" >&2
    exit 2
  fi
done
mkdir -p "$OUT"
"$TOOL" tone "$OUT/probe-tone.wav" --seconds 120 --freq 1000 --dbfs -60 >/dev/null
rm -f "$OUT/tap-probe.json"

afplay "$OUT/probe-tone.wav" &
player=$!
trap 'kill "$player" 2>/dev/null || true; rm -f "$OUT/probe-tone.wav"' EXIT

# -W waits for the app to exit, -n starts a new instance.
open -W -n "$APP" --args --tap-probe "$CAPTURE_SECONDS" --out "$OUT/tap-probe.json"

if [[ ! -f "$OUT/tap-probe.json" ]]; then
  echo "error: the app wrote no report" >&2
  exit 2
fi
cat "$OUT/tap-probe.json"
if [[ "$(jq -r .started "$OUT/tap-probe.json")" != "true" ]]; then
  echo "RESULT: the tap did not start"
  exit 2
fi
if (($(jq -r .nonzero_frames "$OUT/tap-probe.json") > 0)); then
  echo "RESULT: audio captured"
  exit 0
fi
echo "RESULT: silent capture (permission denied, or nothing reached the output device)"
exit 1
