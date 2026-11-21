#!/usr/bin/env bash
# Copies the built CLAP, VST3 and AU bundles to ~/Library/Audio/Plug-Ins and makes the Audio Unit
# registrar rescan, so hosts and auval see the new build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
: "${NMR_PRODUCT_NAME:?config/product.env must define NMR_PRODUCT_NAME}"
SRC="${NMR_BUILD_DIR:-$ROOT/build}/plugins"
DEST="${NMR_PLUGIN_INSTALL_DIR:-$HOME/Library/Audio/Plug-Ins}"

for pair in "clap:CLAP" "vst3:VST3" "component:Components"; do
  ext="${pair%%:*}"
  folder="${pair##*:}"
  bundle="$SRC/$NMR_PRODUCT_NAME.$ext"
  target="$DEST/$folder/$NMR_PRODUCT_NAME.$ext"
  if [[ ! -d "$bundle" ]]; then
    echo "error: missing $bundle (run scripts/build.sh plugin)" >&2
    exit 1
  fi
  codesign --verify --strict --deep "$bundle"
  mkdir -p "$DEST/$folder"
  rm -rf "$target"
  ditto "$bundle" "$target"
  echo "installed $target"
done

# The registrar caches the component list; kill it so the new AU is picked up.
killall -9 AudioComponentRegistrar 2>/dev/null || true
