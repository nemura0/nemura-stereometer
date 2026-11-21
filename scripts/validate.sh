#!/usr/bin/env bash
# Runs every plugin validator against the installed plugins (scripts/install-plugins.sh first):
#
#   auval -strict              AU, arm64 and x86_64 (Rosetta)
#   pluginval (strictness 8)   VST3 and AU, arm64 and x86_64 (Rosetta)
#   clap-validator             CLAP
#   nmr_au_oop_host            AU loaded out of process + bit-exact null test, arm64 and x86_64
#
# Logs: build/validate/<check>.log. Exits non-zero if any check fails.
# Overrides: PLUGINVAL, CLAP_VALIDATOR, NMR_PLUGINVAL_STRICTNESS, NMR_SKIP_GUI_TESTS=1 (CI),
# NMR_BUILD_DIR, NMR_PLUGIN_INSTALL_DIR.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
BUILD_DIR="${NMR_BUILD_DIR:-$ROOT/build}"
LOGS="$BUILD_DIR/validate"
PLUGINS="${NMR_PLUGIN_INSTALL_DIR:-$HOME/Library/Audio/Plug-Ins}"
PLUGINVAL="${PLUGINVAL:-/Applications/pluginval.app/Contents/MacOS/pluginval}"
CLAP_VALIDATOR="${CLAP_VALIDATOR:-$(command -v clap-validator || echo "$HOME/.local/bin/clap-validator")}"
STRICTNESS="${NMR_PLUGINVAL_STRICTNESS:-8}"
OOP_HOST="$BUILD_DIR/Tests/host/nmr_au_oop_host"
AU_CODES=("$NMR_AU_TYPE" "$NMR_AU_SUBTYPE" "$NMR_AU_MANUFACTURER")

mkdir -p "$LOGS"
failures=()

run() { # name command...
  local name="$1"
  shift
  printf '%-24s ' "$name"
  if "$@" >"$LOGS/$name.log" 2>&1; then
    echo "pass"
  else
    echo "FAIL  ($LOGS/$name.log)"
    failures+=("$name")
  fi
}

x86() { /usr/bin/arch -x86_64 "$@"; }

clap_validate() { # clap-validator exits 0 when tests fail to run; require "0 failed" too
  local out
  out="$("$CLAP_VALIDATOR" validate "$1" 2>&1)" || {
    printf '%s\n' "$out"
    return 1
  }
  printf '%s\n' "$out"
  printf '%s\n' "$out" | sed -e 's/\x1b\[[0-9;]*m//g' | grep -qE '[0-9]+ tests run, [0-9]+ passed, 0 failed'
}

rosetta=false
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then rosetta=true; fi
if ! $rosetta; then echo "note: Rosetta not installed; x86_64 checks skipped"; fi

pluginval_args=(--strictness-level "$STRICTNESS" --timeout-ms 120000)
if [[ "${NMR_SKIP_GUI_TESTS:-0}" == "1" ]]; then pluginval_args+=(--skip-gui-tests); fi

run auval.arm64 auval -strict -v "${AU_CODES[@]}"
$rosetta && run auval.x86_64 x86 auval -strict -v "${AU_CODES[@]}"

for pair in "vst3:VST3" "au:Components"; do
  label="${pair%%:*}"
  folder="${pair##*:}"
  ext="$label"
  [[ "$label" == "au" ]] && ext="component"
  bundle="$PLUGINS/$folder/$NMR_PRODUCT_NAME.$ext"
  run "pluginval.$label.arm64" "$PLUGINVAL" "${pluginval_args[@]}" "$bundle"
  $rosetta && run "pluginval.$label.x86_64" x86 "$PLUGINVAL" "${pluginval_args[@]}" "$bundle"
done

run clap-validator clap_validate "$PLUGINS/CLAP/$NMR_PRODUCT_NAME.clap"

run au-oop.arm64 "$OOP_HOST"
$rosetta && run au-oop.x86_64 x86 "$OOP_HOST"

if ((${#failures[@]} > 0)); then
  echo "FAILED: ${failures[*]}"
  exit 1
fi
echo "all validators passed"
