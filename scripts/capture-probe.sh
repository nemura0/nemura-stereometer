#!/usr/bin/env bash
# End-to-end check of system-audio capture with the built app (scripts/build.sh first).
#
#   scripts/capture-probe.sh [seconds] [--meter]
#
# --meter runs the meter window itself (--meter-probe) instead of the bare tap: it checks that the
# captured audio reaches the view (the view is drawing, not idle for silence).
# Plays a quiet test tone (1 kHz at -60 dBFS) with afplay, launches the app through LaunchServices
# in --tap-probe mode (so the app itself, not the terminal, is the process macOS asks about), and
# reports whether non-silent audio arrived. The first run on a Mac shows the audio-capture
# permission prompt; someone must click Allow. A denied permission still starts the tap but
# delivers only zeros.
#
# Exit status: 0 audio captured (with --meter: drawn), 1 silent capture (or an idle meter),
# 2 the tap did not start (or bad arguments). With --meter, the seconds count from the capture's
# first report.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
BUILD="${NMR_BUILD_DIR:-$ROOT/build}"
APP="$BUILD/app/$NMR_PRODUCT_NAME.app"
TOOL="$BUILD/Tests/tools/nmr_make_test_wav"
OUT="$BUILD/probe"
CAPTURE_SECONDS=4
MODE=tap
for arg in "$@"; do
  case "$arg" in
    --meter) MODE=meter ;;
    *)
      if [[ ! "$arg" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "usage: scripts/capture-probe.sh [seconds] [--meter]" >&2
        exit 2
      fi
      CAPTURE_SECONDS="$arg"
      ;;
  esac
done

if ! command -v jq >/dev/null; then
  echo "error: jq is required (brew install jq)" >&2
  exit 2
fi

for required in "$APP" "$TOOL"; do
  if [[ ! -e "$required" ]]; then
    echo "error: missing $required (run scripts/build.sh)" >&2
    exit 2
  fi
done
mkdir -p "$OUT"
"$TOOL" tone "$OUT/probe-tone.wav" --seconds 120 --freq 1000 --dbfs -60 >/dev/null
rm -f "$OUT/tap-probe.json" "$OUT/meter-probe.json"

afplay "$OUT/probe-tone.wav" &
player=$!
trap 'kill "$player" 2>/dev/null || true; wait "$player" 2>/dev/null || true
      rm -f "$OUT/probe-tone.wav"' EXIT

# -W waits for the app to exit, -n starts a new instance.
if [[ "$MODE" == meter ]]; then
  open -W -n "$APP" --args --meter-probe "$CAPTURE_SECONDS" --out "$OUT/meter-probe.json"
  if [[ ! -f "$OUT/meter-probe.json" ]]; then
    echo "error: the app wrote no report" >&2
    exit 2
  fi
  cat "$OUT/meter-probe.json"; echo
  case "$(jq -r .phase "$OUT/meter-probe.json")" in
    capturing) ;;
    starting)
      echo "RESULT: the capture had not started (is the permission prompt still open?)"
      exit 2
      ;;
    *)
      echo "RESULT: the capture failed at $(jq -r .failed_step "$OUT/meter-probe.json")"
      exit 2
      ;;
  esac
  overlay_ok='.overlay.visible and .overlay.resizes and .overlay.click_through_toggles
    and .overlay.notice_fits'
  if [[ "$(jq -r "$overlay_ok" "$OUT/meter-probe.json")" != "true" ]]; then
    echo "RESULT: the overlay window did not behave (see .overlay above)"
    exit 1
  fi
  if [[ "$(jq -r '.rendering and (.idle | not)' "$OUT/meter-probe.json")" != "true" ]]; then
    echo "RESULT: the meter is idle (silent capture, or the audio does not reach the view)"
    exit 1
  fi
  # The probe always watches the signal: the sound playing must be seen, with no notice shown.
  case "$(jq -r .signal "$OUT/meter-probe.json")" in
    sound) ;;
    silence_while_playing)
      echo "RESULT: only zeros arrive while audio plays (the permission looks denied)"
      exit 1
      ;;
    *)
      echo "RESULT: the meter draws, but the signal watch saw no sound"
      exit 1
      ;;
  esac
  if [[ "$(jq -r '.notice == null' "$OUT/meter-probe.json")" != "true" ]]; then
    echo "RESULT: the meter shows a notice while it draws sound (see .notice above)"
    exit 1
  fi
  echo "RESULT: the meter draws the captured audio, sees the sound, and the overlay behaves"
  exit 0
fi
open -W -n "$APP" --args --tap-probe "$CAPTURE_SECONDS" --out "$OUT/tap-probe.json"

if [[ ! -f "$OUT/tap-probe.json" ]]; then
  echo "error: the app wrote no report" >&2
  exit 2
fi
cat "$OUT/tap-probe.json"; echo
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
