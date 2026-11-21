#!/usr/bin/env bash
# Wraps the SwiftPM app binary into "<NMR_BUILD_DIR>/app/<NMR_PRODUCT_NAME>.app" and signs it.
# Run `scripts/build.sh app` (which calls this) rather than calling it directly.
#
#   scripts/bundle-app.sh <path-to-built-binary>
#
# The bundle never goes to /Applications here, so it can never replace the reference app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
: "${NMR_PRODUCT_NAME:?config/product.env must define NMR_PRODUCT_NAME}"
BINARY="${1:?usage: scripts/bundle-app.sh <path-to-built-binary>}"
APP="${NMR_BUILD_DIR:-$ROOT/build}/app/$NMR_PRODUCT_NAME.app"
PLIST="$APP/Contents/Info.plist"

if [[ ! -x "$BINARY" ]]; then
  echo "error: no executable at $BINARY" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NMR_PRODUCT_NAME"

plutil -create xml1 "$PLIST"
set_string() { plutil -insert "$1" -string "$2" "$PLIST"; }
set_bool() { plutil -insert "$1" -bool "$2" "$PLIST"; }
set_string CFBundleDevelopmentRegion en
set_string CFBundleExecutable "$NMR_PRODUCT_NAME"
set_string CFBundleIdentifier "$NMR_APP_BUNDLE_ID"
set_string CFBundleInfoDictionaryVersion 6.0
set_string CFBundleName "$NMR_PRODUCT_SHORT"
set_string CFBundleDisplayName "$NMR_PRODUCT_NAME"
set_string CFBundlePackageType APPL
set_string CFBundleShortVersionString "$NMR_VERSION"
set_string CFBundleVersion "$NMR_BUILD"
set_string LSMinimumSystemVersion 14.2
set_string LSApplicationCategoryType public.app-category.music
set_string NSHumanReadableCopyright "$NMR_COPYRIGHT"
set_string NSPrincipalClass NSApplication
set_bool NSHighResolutionCapable YES
set_string NSAudioCaptureUsageDescription \
  "$NMR_PRODUCT_NAME reads the audio your Mac is playing to draw the meter. The audio is analyzed on this Mac and is never recorded or sent anywhere."
plutil -lint "$PLIST" >/dev/null

"$ROOT/scripts/sign.sh" "$APP"
echo "bundled $APP"
