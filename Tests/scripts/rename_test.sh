#!/usr/bin/env bash
# Tests scripts/rename.sh on a scratch copy of the files it touches (never on the repo itself).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nmr-rename-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# A fresh copy of the repo files rename.sh reads and writes.
fresh() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo/scripts" "$WORK/repo/config" "$WORK/repo/Sources/Core/include/nmr"
  cp "$ROOT/scripts/rename.sh" "$ROOT/scripts/gen-config.sh" "$WORK/repo/scripts/"
  cp "$ROOT/config/product.env" "$WORK/repo/config/"
  cp "$ROOT/Sources/Core/include/nmr/product_config.h" "$WORK/repo/Sources/Core/include/nmr/"
  cp "$ROOT/README.md" "$WORK/repo/"
}

value() { # key -> value in the scratch product.env
  (source "$WORK/repo/config/product.env" && eval "printf '%s' \"\$$1\"")
}

expect_value() { # key expected
  local got
  got="$(value "$1")"
  [[ "$got" == "$2" ]] || fail "$1 is '$got', expected '$2'"
}

run() { "$WORK/repo/scripts/rename.sh" "$@" >"$WORK/out" 2>&1; }

# 1. A name-only rename changes the display names and keeps every identifier.
fresh
old_name="$(value NMR_PRODUCT_NAME)"
old_app_id="$(value NMR_APP_BUNDLE_ID)"
old_clap_id="$(value NMR_CLAP_ID)"
old_identity="$(value NMR_SIGNING_IDENTITY)"
run --name "Acme Phase Scope" --short "Phase Scope" --vendor "Acme" ||
  fail "rename failed: $(cat "$WORK/out")"
expect_value NMR_PRODUCT_NAME "Acme Phase Scope"
expect_value NMR_PRODUCT_SHORT "Phase Scope"
expect_value NMR_VENDOR "Acme"
expect_value NMR_APP_BUNDLE_ID "$old_app_id"
expect_value NMR_CLAP_ID "$old_clap_id"
expect_value NMR_SIGNING_IDENTITY "$old_identity"
grep -qF '#define NMR_PRODUCT_NAME "Acme Phase Scope"' \
  "$WORK/repo/Sources/Core/include/nmr/product_config.h" || fail "product_config.h not regenerated"
grep -qF "# Acme Phase Scope" "$WORK/repo/README.md" || fail "README title not renamed"
grep -qF "$old_name" "$WORK/repo/README.md" && fail "README still names '$old_name'"
"$WORK/repo/scripts/gen-config.sh" --check >/dev/null || fail "header stale after rename"

# 2. --ids moves the bundle, CLAP and log identifiers under a new reverse-DNS base.
fresh
run --name "Acme Phase Scope" --ids com.acme.phasescope ||
  fail "rename --ids failed: $(cat "$WORK/out")"
expect_value NMR_APP_BUNDLE_ID "com.acme.phasescope"
expect_value NMR_PLUGIN_BUNDLE_ID "com.acme.phasescope.plugin"
expect_value NMR_CLAP_ID "com.acme.phasescope"
expect_value NMR_LOG_SUBSYSTEM "com.acme.phasescope"

# 3. --dry-run prints the change and writes nothing.
fresh
before="$(shasum "$WORK/repo/config/product.env" "$WORK/repo/README.md")"
run --name "Acme Phase Scope" --dry-run || fail "dry run failed: $(cat "$WORK/out")"
[[ "$before" == "$(shasum "$WORK/repo/config/product.env" "$WORK/repo/README.md")" ]] ||
  fail "dry run wrote files"
grep -qF "Acme Phase Scope" "$WORK/out" || fail "dry run did not show the new name"

# 4. Values that would break product.env, a bundle path or a C string are refused, untouched.
for bad in "" 'Bad "Quote"' 'Back\slash' 'Dollar $HOME' 'Slash/Name' 'Tick `x`' \
  "$(printf 'New\nLine')"; do
  fresh
  before="$(shasum "$WORK/repo/config/product.env")"
  if run --name "$bad"; then fail "accepted name '$bad'"; fi
  [[ "$before" == "$(shasum "$WORK/repo/config/product.env")" ]] ||
    fail "'$bad' changed product.env"
done
fresh
if run --name "Acme" --ids "not a domain"; then fail "accepted --ids 'not a domain'"; fi
long_short="$(printf 'x%.0s' {1..60})"
if run --name "Acme" --short "$long_short"; then fail "accepted a 60-char short name"; fi
if run --bogus; then fail "accepted an unknown option"; fi
if run; then fail "ran without --name"; fi

if ((failures > 0)); then
  echo "$failures rename test(s) failed" >&2
  exit 1
fi
echo "rename tests passed"
