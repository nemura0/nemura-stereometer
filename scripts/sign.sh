#!/usr/bin/env bash
# Signs bundles (app, .clap, .vst3, .component) with the self-signed identity created by
# scripts/make-signing-identity.sh. Without it (e.g. a CI pull request) it signs ad-hoc and
# warns: the build still runs, but the app's audio-capture permission will not survive rebuilds.
#
#   scripts/sign.sh <bundle>...
#
# NMR_SIGNING_DIR overrides ~/.nemura-signing (CI imports the identity into a temporary one).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
DIR="${NMR_SIGNING_DIR:-$HOME/.nemura-signing}"
KEYCHAIN="$DIR/signing.keychain-db"

if (($# == 0)); then
  echo "usage: scripts/sign.sh <bundle>..." >&2
  exit 2
fi

if [[ -f "$KEYCHAIN" && -f "$DIR/keychain-password" ]]; then
  security unlock-keychain -p "$(cat "$DIR/keychain-password")" "$KEYCHAIN"
  # Sign by certificate hash so another identity with the same name can never be picked.
  identity="$(security find-identity -p codesigning "$KEYCHAIN" |
    awk -v name="\"$NMR_SIGNING_IDENTITY\"" 'index($0, name) {print $2; exit}')"
  if [[ -z "$identity" ]]; then
    echo "error: \"$NMR_SIGNING_IDENTITY\" not found in $KEYCHAIN" >&2
    exit 1
  fi
  sign_args=(--sign "$identity" --keychain "$KEYCHAIN")
  label="$NMR_SIGNING_IDENTITY"
else
  echo "warning: no signing identity in $DIR (run scripts/make-signing-identity.sh); signing ad-hoc" >&2
  sign_args=(--sign -)
  label="ad-hoc"
fi

for bundle in "$@"; do
  if [[ ! -d "$bundle" ]]; then
    echo "error: not a bundle: $bundle" >&2
    exit 1
  fi
  codesign --force --timestamp=none "${sign_args[@]}" "$bundle"
  codesign --verify --strict --deep "$bundle"
  echo "signed ($label): $bundle"
done
