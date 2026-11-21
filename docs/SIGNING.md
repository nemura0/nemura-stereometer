# Code signing

NEMURA Stereometer is distributed unsigned by Apple (no Developer Program, no notarization), but
every build is signed with one stable **self-signed** identity, "NEMURA Stereometer Self-Signed"
(`NMR_SIGNING_IDENTITY` in `config/product.env`). Ad-hoc signing is only the fallback for builds
that have no access to the identity (pull requests from forks).

## Why a stable identity

macOS stores the audio-capture permission (TCC service `kTCCServiceAudioCapture`) together with
the app's *designated requirement*. With an ad-hoc signature that requirement is the binary's code
hash, so every rebuild looks like a new app and macOS asks again. With the self-signed identity it
is:

```text
identifier "dev.vicguerra.stereometer" and certificate root = H"eef7e7de1f8b9390f913b4cf139bfbb9da9be956"
```

which every build signed with the same certificate satisfies. Verified on 2026-11-21: after the
owner approved the prompt once, a rebuild with a different code hash was allowed without a prompt.
tccd logged `matchesCodeRequirement: … certificate root = H"eef7…"; status: 0` and
`Allowed (User Consent)`.

## Local setup (once per Mac)

```bash
scripts/make-signing-identity.sh
```

It creates `~/.nemura-signing/` (mode 0700) holding:

| File | Content |
|---|---|
| `signing.keychain-db` | a dedicated keychain with the identity; never added to the search list, so the login keychain is untouched |
| `keychain-password` | random password for that keychain |
| `identity.p12` | certificate + private key (RSA 3072, valid 10 years, code-signing EKU) |
| `identity.p12-password` | random password for the `.p12` |

`scripts/sign.sh` (called by `scripts/build.sh`) signs with it by certificate hash. Nothing in this
directory may ever be committed; `.gitignore` also blocks `*.p12`, `*.keychain-db` and friends.

**Back up** `identity.p12` and its password (for example in a password manager). If the identity is
lost, a new one changes the certificate root hash and every user approves the permission once more
after updating.

**If the private key leaks**, anyone could sign an app with our bundle identifier that inherits the
users' audio-capture grant. Rotate: delete `~/.nemura-signing`, run the script again, update the
CI secrets and ship a release (users approve once).

## CI secrets

Export the identity to the repository secrets once (values are read from stdin, so they never
appear on a command line):

```bash
base64 -i ~/.nemura-signing/identity.p12 | tr -d '\n' | gh secret set NMR_SIGNING_P12_BASE64 --repo nemura0/nemura-stereometer
```

```bash
tr -d '\n' < ~/.nemura-signing/identity.p12-password | gh secret set NMR_SIGNING_P12_PASSWORD --repo nemura0/nemura-stereometer
```

The release workflow (Phase 5) imports them into a temporary keychain and points `scripts/sign.sh`
at it through `NMR_SIGNING_DIR`:

```bash
export NMR_SIGNING_DIR="$RUNNER_TEMP/nemura-signing"
mkdir -p "$NMR_SIGNING_DIR" && chmod 700 "$NMR_SIGNING_DIR"
printf '%s' "$NMR_SIGNING_P12_BASE64" | base64 --decode > "$NMR_SIGNING_DIR/identity.p12"
openssl rand -hex 32 > "$NMR_SIGNING_DIR/keychain-password"
kc="$NMR_SIGNING_DIR/signing.keychain-db"
security create-keychain -p "$(cat "$NMR_SIGNING_DIR/keychain-password")" "$kc"
security set-keychain-settings "$kc"
security unlock-keychain -p "$(cat "$NMR_SIGNING_DIR/keychain-password")" "$kc"
security import "$NMR_SIGNING_DIR/identity.p12" -k "$kc" -P "$NMR_SIGNING_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$NMR_SIGNING_DIR/keychain-password")" "$kc"
```

The CI workflow for pushes and pull requests (`ci.yml`) does not need the identity: without it
`scripts/sign.sh` signs ad-hoc and prints a warning.

## Checking a build

```bash
codesign -d -r- "build/app/NEMURA Stereometer.app"
```

```bash
scripts/capture-probe.sh
```

The first command prints the designated requirement above. The second plays a −60 dBFS tone,
runs the app's `--tap-probe` mode through LaunchServices and reports whether non-silent audio
arrived (a denied permission yields only zeros).

No hardened runtime is used: it only matters for notarization, which is out of scope.
