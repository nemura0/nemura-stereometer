#!/usr/bin/env bash
# Fetches the pinned plugin SDKs into external/ (gitignored). Idempotent: a dependency is
# re-fetched only when its pin changes. CI caches external/ keyed on this file's hash.
#
# Only the plugin build (CMake) needs these. The app (SwiftPM) does not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${NMR_EXTERNAL_DIR:-$ROOT/external}"

# name | url | commit | tag (for humans)
DEPS=(
  "clap|https://github.com/free-audio/clap.git|195b42a004144fab0b3cf95e9c067187d15365b7|1.2.10"
  "clap-wrapper|https://github.com/free-audio/clap-wrapper.git|c3a2531a5e66572b4246fc64271e2103d0de37bb|v0.18.0"
  "vst3sdk|https://github.com/steinbergmedia/vst3sdk.git|9fad9770f2ae8542ab1a548a68c1ad1ac690abe0|v3.8.0_build_66"
  "AudioUnitSDK|https://github.com/apple/AudioUnitSDK.git|53a9a2008aae7fb1b0a9f093dd523b9b12f6c0d9|AudioUnitSDK-1.1.0"
)
# The VST3 SDK superproject pins these submodules; vstgui4, doc and tutorials are not needed.
VST3_SUBMODULES=(base pluginterfaces public.sdk cmake)

fetch() { # dir url commit
  local dir="$1" url="$2" commit="$3"
  if [[ -f "$dir/.nmr-pin" && "$(cat "$dir/.nmr-pin")" == "$commit" ]]; then
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth 1 origin "$commit"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  echo "$commit" >"$dir/.nmr-pin"
  echo "fetched $(basename "$dir") @ ${commit:0:10}"
}

mkdir -p "$DEST"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name url commit tag <<<"$entry"
  fetch "$DEST/$name" "$url" "$commit"
done

# VST3 submodules at the exact commits the superproject records.
for sub in "${VST3_SUBMODULES[@]}"; do
  sub_commit="$(git -C "$DEST/vst3sdk" ls-tree HEAD "$sub" | awk '{print $3}')"
  sub_url="$(git -C "$DEST/vst3sdk" config -f .gitmodules --get "submodule.$sub.url")"
  if [[ -z "$sub_commit" || -z "$sub_url" ]]; then
    echo "error: vst3sdk submodule '$sub' not found" >&2
    exit 1
  fi
  # .gitmodules uses URLs relative to the superproject (../vst3_base).
  if [[ "$sub_url" == ../* ]]; then
    sub_url="https://github.com/steinbergmedia/${sub_url#../}"
  fi
  fetch "$DEST/vst3sdk/$sub" "$sub_url" "$sub_commit"
done

echo "dependencies ready in $DEST"
