#!/usr/bin/env bash
# Renames the product in one step: rewrites config/product.env, regenerates product_config.h and
# renames the product in README.md. Rebuild afterwards (scripts/build.sh).
#
#   scripts/rename.sh --name "Acme Phase Scope" [--short "Phase Scope"] [--vendor "Acme"]
#                     [--ids com.acme.phasescope] [--dry-run]
#
#   --name     full product name: app bundle, plugin bundles, window and menu titles
#   --short    short name: menu bar, plugin instance names ("Phase Scope 2"); default: unchanged
#   --vendor   vendor shown by hosts; default: unchanged
#   --ids      also move the app, plugin, CLAP and log identifiers under this reverse-DNS base.
#              DAWs then see a different plugin (sessions lose it) and macOS asks again for the
#              audio-capture permission. Without --ids every identifier stays, and so do saved
#              settings, presets, plugin state and the permission.
#   --dry-run  print the new values and write nothing
#
# Kept on purpose: AU type/subtype/manufacturer codes, shm and ObjC prefixes, the settings folder,
# the signing identity and the GitHub repo. Change those in config/product.env by hand, knowing
# what each one breaks (the comments there say).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/config/product.env"
README="$ROOT/README.md"
MAX_NAME_BYTES=60   # bundle names and window titles stay readable
MAX_SHORT_BYTES=40  # instance names add " NN" and must fit the 64-byte shm slot name

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '5,6p' "$0" | cut -c3- >&2
  exit 2
}

# Safe inside a double-quoted product.env value, a C string literal and a bundle file name.
check_text() { # label value max_bytes
  local label="$1" value="$2" max="$3"
  [[ -n "$value" ]] || die "$label is empty"
  [[ "$value" != *[\"\\\$\`/]* ]] || die "$label may not contain \", \\, \$, \` or /"
  [[ "$value" != *[[:cntrl:]]* ]] || die "$label may not contain control characters"
  [[ "$value" == "${value#[[:space:]]}" && "$value" == "${value%[[:space:]]}" ]] ||
    die "$label may not start or end with a space"
  local bytes
  bytes="$(printf '%s' "$value" | wc -c | tr -d ' ')"
  ((bytes <= max)) || die "$label is $bytes bytes, at most $max"
}

name="" short="" vendor="" ids="" dry_run=0
while (($# > 0)); do
  case "$1" in
    --name | --short | --vendor | --ids)
      (($# >= 2)) || die "$1 needs a value"
      case "$1" in
        --name) name="$2" ;;
        --short) short="$2" ;;
        --vendor) vendor="$2" ;;
        --ids) ids="$2" ;;
      esac
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help) usage ;;
    *) die "unknown option $1 (see the top of scripts/rename.sh)" ;;
  esac
done
[[ -n "$name" ]] || usage

# shellcheck source=../config/product.env
source "$ENV_FILE"
old_name="$NMR_PRODUCT_NAME"
short="${short:-$NMR_PRODUCT_SHORT}"
vendor="${vendor:-$NMR_VENDOR}"
check_text "--name" "$name" "$MAX_NAME_BYTES"
check_text "--short" "$short" "$MAX_SHORT_BYTES"
check_text "--vendor" "$vendor" "$MAX_NAME_BYTES"

changes=(
  "NMR_PRODUCT_NAME=$name"
  "NMR_PRODUCT_SHORT=$short"
  "NMR_VENDOR=$vendor"
)
if [[ -n "$ids" ]]; then
  [[ "$ids" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] ||
    die "--ids must be lowercase reverse DNS, like com.acme.phasescope"
  changes+=(
    "NMR_APP_BUNDLE_ID=$ids"
    "NMR_PLUGIN_BUNDLE_ID=$ids.plugin"
    "NMR_CLAP_ID=$ids"
    "NMR_LOG_SUBSYSTEM=$ids"
  )
fi

for change in "${changes[@]}"; do
  key="${change%%=*}"
  old="${!key}"
  new="${change#*=}"
  if [[ "$old" == "$new" ]]; then
    printf '  %-22s %s (unchanged)\n' "$key" "$old"
  else
    printf '  %-22s %s -> %s\n' "$key" "$old" "$new"
  fi
done
if ((dry_run)); then
  echo "dry run: nothing written"
  exit 0
fi

# Rewrite only the KEY="value" lines that change; comments and order stay as they are.
tmp="$(mktemp "$ENV_FILE.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "${changes[@]}" | awk '
  NR == FNR { i = index($0, "="); value[substr($0, 1, i - 1)] = substr($0, i + 1); next }
  {
    i = index($0, "=")
    key = i > 0 ? substr($0, 1, i - 1) : ""
    if (key in value) print key "=\"" value[key] "\""; else print
  }' - "$ENV_FILE" >"$tmp"
mv "$tmp" "$ENV_FILE"
trap - EXIT

"$ROOT/scripts/gen-config.sh"

if [[ -f "$README" && "$old_name" != "$name" ]]; then
  OLD="$old_name" NEW="$name" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$README"
  echo "renamed \"$old_name\" in README.md"
fi

cat <<EOF
Renamed. Next:
  scripts/build.sh                  rebuild (bundles take the new name)
  scripts/install-plugins.sh        reinstall; remove the old "$old_name" plug-ins by hand
  git diff                          review, then commit
Docs and the GitHub repo keep their names; rename those separately if you want.
EOF
