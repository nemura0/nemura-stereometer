#!/usr/bin/env bash
# CPU and memory measurements for docs/BUDGET.md (docs/PROMPT.md §7).
#
#   scripts/perf.sh reference [--width PT] [--seconds S]
#   scripts/perf.sh minimeters [--seconds S]
#
# reference   The read-only prototype. Its app re-saves its settings on every launch, so this
#             measures an identical copy of /Applications/Stereometer.app under its own bundle
#             identifier and settings domain: the owner's saved reference settings with the
#             window set to --width (default 360 pt, the reference's "medium"), fed the test mix
#             through STEREOMETER_DEBUG_FILE (no tap, nothing audible). The original app and its
#             settings are only read. The copy, its settings and the mix are removed afterwards.
# minimeters  MiniMeters as the owner left it (only its Stereometer module, sized to match),
#             launched if needed, while afplay plays the test mix through the default output.
#             The meter's window size is reported so the reference can be measured to match.
#
# Each run waits 5 s, samples %CPU and memory once a second with top for --seconds (default 60),
# takes a footprint at the end, prints a summary and writes perf-results/<name>.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
BUILD="${NMR_BUILD_DIR:-$ROOT/build}"
OUT="$ROOT/perf-results"
WORK="$OUT/work"
TOOL="$BUILD/Tests/tools/nmr_make_test_wav"
WARMUP_SECONDS=5
REFERENCE_APP=/Applications/Stereometer.app
REFERENCE_DOMAIN=dev.stereometer.clean
REFERENCE_COPY_ID="$NMR_APP_BUNDLE_ID.baseline-reference"
MINIMETERS_APP=/Applications/MiniMeters.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

target="${1:-}"
[[ -n "$target" ]] || usage
shift
width=360
seconds=60
while (($#)); do
  case "$1" in
    --width) width="${2:-}"; shift 2 ;;
    --seconds) seconds="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$width" =~ ^[0-9]+$ ]] && ((width >= 100 && width <= 4000)) || die "--width must be 100-4000"
[[ "$seconds" =~ ^[0-9]+$ ]] && ((seconds >= 5 && seconds <= 600)) || die "--seconds must be 5-600"

make_mix() { # seconds
  [[ -x "$TOOL" ]] || die "missing $TOOL (run scripts/build.sh plugin)"
  mkdir -p "$WORK"
  "$TOOL" mix "$WORK/mix.wav" --seconds "$1" >/dev/null
}

wait_for_pid() { # pgrep arguments...
  local pid
  for _ in $(seq 1 100); do
    pid="$(pgrep "$@" | head -1 || true)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_pid() { # pid (not our child: launched through LaunchServices)
  kill "$1" 2>/dev/null || return 0
  for _ in $(seq 1 50); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -9 "$1" 2>/dev/null || true
}

# Samples one process after the warm-up. Prints a JSON object.
measure() { # pid seconds
  local pid="$1" count="$2"
  sleep "$WARMUP_SECONDS"
  kill -0 "$pid" 2>/dev/null || die "process $pid exited during the warm-up"
  # The first top sample has no interval to measure CPU over, so it is dropped.
  local samples
  samples="$(top -l "$((count + 1))" -s 1 -pid "$pid" -stats pid,cpu,mem |
    awk -v pid="$pid" '$1 == pid { print $2, $3 }' | tail -n +2)"
  local taken
  taken="$(grep -c . <<<"$samples" || true)"
  ((taken >= count * 9 / 10)) || die "only $taken of $count samples (did the process exit?)"
  local cpu mem
  cpu="$(awk '{ print $1 }' <<<"$samples" | jq -s -c .)"
  mem="$(awk '{
      v = $2; gsub(/[+-]/, "", v); unit = substr(v, length(v)); n = substr(v, 1, length(v) - 1) + 0
      if (unit == "K") n /= 1024; else if (unit == "G") n *= 1024; else if (unit != "M") n = v / 1048576
      printf "%.1f\n", n }' <<<"$samples" | jq -s -c .)"
  local footprint peak
  read -r footprint peak < <(footprint -f bytes "$pid" 2>/dev/null |
    awk '$1 == "phys_footprint:" { f = $2 } $1 == "phys_footprint_peak:" { p = $2 }
         END { print f + 0, p + 0 }')
  local windows
  windows="$(osascript -l JavaScript "$ROOT/scripts/lib/window-sizes.js" "$pid")"
  jq -n --argjson cpu "$cpu" --argjson mem "$mem" --argjson windows "$windows" \
    --argjson footprint "$footprint" --argjson peak "$peak" '
    def q(p): sort | .[((length - 1) * p) | floor];
    def r1: . * 10 | round / 10;
    {
      cpu_percent: {
        mean: ($cpu | add / length | r1), median: ($cpu | q(0.5)), p95: ($cpu | q(0.95)),
        max: ($cpu | max), samples: ($cpu | length)
      },
      memory_mib: {
        footprint_end: ($footprint / 1048576 | r1), footprint_peak: ($peak / 1048576 | r1),
        top_max: ($mem | max)
      },
      windows: $windows
    }'
}

# Writes perf-results/<name>.json (stats + context) and prints a one-line summary.
report() { # name label version stats-json input
  local name="$1" label="$2" version="$3" stats="$4" input="$5"
  mkdir -p "$OUT"
  local file="$OUT/$name-$(date -u +%Y%m%dT%H%M%SZ).json"
  jq -n --argjson stats "$stats" --arg label "$label" --arg version "$version" \
    --arg input "$input" --arg macos "$(sw_vers -productVersion)" \
    --arg model "$(sysctl -n hw.model)" --arg chip "$(sysctl -n machdep.cpu.brand_string)" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson seconds "$seconds" \
    --argjson warmup "$WARMUP_SECONDS" '
    { target: $label, version: $version, date: $date, macos: $macos, model: $model, chip: $chip,
      input: $input, warmup_seconds: $warmup, seconds: $seconds } + $stats' >"$file"
  jq -r '"\(.target) \(.version): CPU mean \(.cpu_percent.mean)%"
    + " (median \(.cpu_percent.median), p95 \(.cpu_percent.p95), max \(.cpu_percent.max)),"
    + " footprint \(.memory_mib.footprint_end) MiB (peak \(.memory_mib.footprint_peak)),"
    + " windows " + ([.windows[] | "\(.width)x\(.height) layer \(.layer)"] | join(", "))' "$file"
  echo "wrote $file"
}

# The owner's saved reference settings (read only) with the window resized. Empty if none.
reference_settings() { # width
  local plist="$WORK/reference-defaults.plist"
  defaults export "$REFERENCE_DOMAIN" "$plist" 2>/dev/null || return 0
  plutil -extract 'meterSettings\.v1' raw -o - "$plist" 2>/dev/null | base64 --decode |
    jq -c --argjson w "$1" '
      .frame = { x: 200, y: 200, width: $w,
                 height: ($w * ((.frame.height // 1) / (.frame.width // 1))) }' || true
  rm -f "$plist"
}

REF_COPY=""
REF_PID=""
cleanup_reference() {
  if [[ -n "$REF_PID" ]]; then stop_pid "$REF_PID"; fi
  defaults delete "$REFERENCE_COPY_ID" >/dev/null 2>&1 || true
  if [[ -n "$REF_COPY" && -d "$REF_COPY" ]]; then
    "$LSREGISTER" -u "$REF_COPY" >/dev/null 2>&1 || true
    rm -rf "$REF_COPY"
  fi
  rm -f "$WORK/mix.wav"
}

run_reference() {
  [[ -d "$REFERENCE_APP" ]] || die "missing $REFERENCE_APP"
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$REFERENCE_APP/Contents/Info.plist")"
  REF_COPY="$WORK/Stereometer reference copy.app"
  trap cleanup_reference EXIT
  make_mix 30 # the reference loops the file

  rm -rf "$REF_COPY"
  ditto "$REFERENCE_APP" "$REF_COPY"
  plutil -replace CFBundleIdentifier -string "$REFERENCE_COPY_ID" "$REF_COPY/Contents/Info.plist"
  codesign --force --sign - "$REF_COPY" 2>/dev/null

  local settings
  settings="$(reference_settings "$width")"
  defaults delete "$REFERENCE_COPY_ID" >/dev/null 2>&1 || true
  if [[ -n "$settings" ]]; then
    defaults write "$REFERENCE_COPY_ID" meterSettings.v1 -data \
      "$(printf '%s' "$settings" | xxd -p | tr -d '\n')"
  elif ((width != 360)); then
    die "no saved reference settings to resize; only the default 360 pt is available"
  fi

  open -n -g --env "STEREOMETER_DEBUG_FILE=$WORK/mix.wav" "$REF_COPY"
  REF_PID="$(wait_for_pid -f "$REF_COPY/Contents/MacOS/")" || die "the reference copy did not start"
  local stats
  stats="$(measure "$REF_PID" "$seconds")"
  # The reference's DisplayMode raw values, in its menu order.
  local mode="default mode"
  if [[ -n "$settings" ]]; then
    mode="$(jq -r '["scaled unipolar", "scaled bipolar", "linear unipolar", "linear bipolar",
      "lissajous"][.mode] // "mode \(.mode)"' <<<"$settings")"
  fi
  report "reference-${width}pt" "reference (Stereometer.app copy, $mode, ${width} pt)" \
    "$version" "$stats" "STEREOMETER_DEBUG_FILE: nmr_make_test_wav mix (30 s, looped)"
}

PLAYER=""
cleanup_player() {
  if [[ -n "$PLAYER" ]]; then
    kill "$PLAYER" 2>/dev/null && wait "$PLAYER" 2>/dev/null || true
  fi
  rm -f "$WORK/mix.wav"
}

run_minimeters() {
  [[ -d "$MINIMETERS_APP" ]] || die "MiniMeters is not installed at $MINIMETERS_APP"
  local version pid
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$MINIMETERS_APP/Contents/Info.plist")"
  pid="$(pgrep -x MiniMeters | head -1 || true)"
  if [[ -z "$pid" ]]; then
    open -g "$MINIMETERS_APP"
    pid="$(wait_for_pid -x MiniMeters)" || die "MiniMeters did not start"
  fi
  trap cleanup_player EXIT
  make_mix "$((WARMUP_SECONDS + seconds + 10))"
  afplay "$WORK/mix.wav" &
  PLAYER=$!
  local stats
  stats="$(measure "$pid" "$seconds")"
  report "minimeters" "MiniMeters (owner's Stereometer-only layout)" "$version" "$stats" \
    "afplay: nmr_make_test_wav mix through the default output"
}

case "$target" in
  reference) run_reference ;;
  minimeters) run_minimeters ;;
  *) usage ;;
esac
