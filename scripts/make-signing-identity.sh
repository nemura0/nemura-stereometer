#!/usr/bin/env bash
# Creates the self-signed code-signing identity for local builds (once per machine).
#
# macOS ties the audio-capture permission (TCC) to an app's code signature. Ad-hoc signatures
# change on every build, so the permission would be requested again after each rebuild; a stable
# self-signed certificate keeps it. The identity lives in its own keychain (never the login
# keychain) under ~/.nemura-signing (mode 0700), protected by a random password stored next to
# it. Trust settings are not touched: codesign does not need a trusted certificate.
#
# Nothing here belongs in git. docs/SIGNING.md explains how to export the identity to CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
DIR="${NMR_SIGNING_DIR:-$HOME/.nemura-signing}"
KEYCHAIN="$DIR/signing.keychain-db"
OPENSSL=/usr/bin/openssl

if [[ -f "$KEYCHAIN" ]]; then
  echo "signing identity already exists in $KEYCHAIN"
  exit 0
fi

umask 077
mkdir -p "$DIR"
chmod 700 "$DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

keychain_password="$("$OPENSSL" rand -hex 32)"
p12_password="$("$OPENSSL" rand -hex 32)"

cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NMR_SIGNING_IDENTITY
O = $NMR_VENDOR
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -name "$NMR_SIGNING_IDENTITY" -inkey "$work/key.pem" \
  -in "$work/cert.pem" -out "$DIR/identity.p12" -passout "pass:$p12_password"

# `security create-keychain` also appends the new keychain to the user's search list. Put the
# list back exactly as it was: signing always names this keychain explicitly.
original_keychains=()
while IFS= read -r entry; do
  entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  [[ -n "$entry" ]] && original_keychains+=("$entry")
done < <(security list-keychains -d user)

security create-keychain -p "$keychain_password" "$KEYCHAIN"
if ((${#original_keychains[@]} > 0)); then
  security list-keychains -d user -s "${original_keychains[@]}"
fi
security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
security unlock-keychain -p "$keychain_password" "$KEYCHAIN"
security import "$DIR/identity.p12" -k "$KEYCHAIN" -P "$p12_password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
  "$KEYCHAIN" >/dev/null

printf '%s\n' "$keychain_password" >"$DIR/keychain-password"
printf '%s\n' "$p12_password" >"$DIR/identity.p12-password"

echo "created \"$NMR_SIGNING_IDENTITY\" in $KEYCHAIN"
"$OPENSSL" x509 -in "$work/cert.pem" -noout -subject -enddate -fingerprint -sha256
