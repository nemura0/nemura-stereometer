#!/usr/bin/env bash
# Packages the built, signed app and plugins for release, into build/dist/.
#
#   scripts/package.sh dmg        <Name>-<version>.dmg: the app, a link to /Applications, LICENSE
#   scripts/package.sh pkg        <Name>-Plugins-<version>.pkg: CLAP, VST3 and AU, one choice each,
#                                 into /Library/Audio/Plug-Ins (or ~/Library for "only me")
#   scripts/package.sh checksums  SHA256SUMS for everything in build/dist
#   scripts/package.sh [all]      all three
#
# Build first (scripts/build.sh). Nothing here is signed by Apple: the .dmg is signed with the
# project's identity (docs/SIGNING.md) when it is available, and the .pkg is unsigned (installer
# signing needs an Apple-issued certificate); the README says how to open both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
BUILD="${NMR_BUILD_DIR:-$ROOT/build}"
DIST="$BUILD/dist"
STAGE="$BUILD/package-stage"
FILE_NAME="${NMR_PRODUCT_NAME// /-}"
APP="$BUILD/app/$NMR_PRODUCT_NAME.app"
PLUGINS="$BUILD/plugins/$NMR_PRODUCT_NAME"
MIN_MACOS="14.2"

die() {
  echo "error: $*" >&2
  exit 1
}

# The bundle exists, its signature holds, and its version is the one in product.env.
check_bundle() { # bundle
  local bundle="$1" version
  [[ -d "$bundle" ]] || die "missing $bundle (run scripts/build.sh)"
  codesign --verify --strict --deep "$bundle" || die "$bundle: signature does not verify"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$bundle/Contents/Info.plist")"
  [[ "$version" == "$NMR_VERSION" ]] ||
    die "$bundle is version $version, config/product.env says $NMR_VERSION (rebuild)"
}

make_dmg() {
  check_bundle "$APP"
  local out="$DIST/$FILE_NAME-$NMR_VERSION.dmg" folder="$STAGE/dmg"
  rm -rf "$folder" "$out"
  mkdir -p "$folder" "$DIST"
  ditto "$APP" "$folder/$NMR_PRODUCT_NAME.app"
  ln -s /Applications "$folder/Applications"
  cp "$ROOT/LICENSE" "$folder/LICENSE.txt"
  hdiutil create -quiet -volname "$NMR_PRODUCT_NAME $NMR_VERSION" -srcfolder "$folder" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$out"
  "$ROOT/scripts/sign.sh" "$out"
  hdiutil verify -quiet "$out"
  rm -rf "$folder"
  echo "wrote $out"
}

# One component package per format. Not relocatable: Installer would otherwise update a copy
# of the bundle it found anywhere on disk instead of installing into the plug-in folder.
component_pkg() { # ext folder id_suffix
  local ext="$1" folder="$2" suffix="$3"
  local root="$STAGE/pkg/root-$suffix" plist="$STAGE/pkg/$suffix.plist" bundle="$PLUGINS.$ext"
  check_bundle "$bundle"
  mkdir -p "$root"
  ditto "$bundle" "$root/$NMR_PRODUCT_NAME.$ext"
  pkgbuild --analyze --root "$root" "$plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Delete :0:BundleIsRelocatable' "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$plist"
  local scripts=()
  if [[ "$ext" == "component" ]]; then scripts=(--scripts "$STAGE/pkg/scripts-au"); fi
  pkgbuild --quiet --root "$root" --component-plist "$plist" \
    --identifier "$NMR_PLUGIN_BUNDLE_ID.pkg.$suffix" --version "$NMR_VERSION" \
    --install-location "/Library/Audio/Plug-Ins/$folder" ${scripts[@]+"${scripts[@]}"} \
    "$STAGE/pkg/$suffix.pkg"
}

distribution_xml() {
  local id="$NMR_PLUGIN_BUNDLE_ID.pkg"
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$NMR_PRODUCT_NAME Plug-ins $NMR_VERSION</title>
  <license file="LICENSE.txt"/>
  <options customize="always" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true" enable_currentUserHome="true"/>
  <volume-check>
    <allowed-os-versions><os-version min="$MIN_MACOS"/></allowed-os-versions>
  </volume-check>
  <choices-outline>
    <line choice="clap"/>
    <line choice="vst3"/>
    <line choice="au"/>
  </choices-outline>
  <choice id="clap" title="CLAP" description="For CLAP hosts: Bitwig, REAPER, FL Studio.">
    <pkg-ref id="$id.clap"/>
  </choice>
  <choice id="vst3" title="VST3" description="For VST3 hosts: Ableton Live, Cubase.">
    <pkg-ref id="$id.vst3"/>
  </choice>
  <choice id="au" title="Audio Unit" description="For AU hosts: Logic Pro, GarageBand.">
    <pkg-ref id="$id.au"/>
  </choice>
  <pkg-ref id="$id.clap" version="$NMR_VERSION">clap.pkg</pkg-ref>
  <pkg-ref id="$id.vst3" version="$NMR_VERSION">vst3.pkg</pkg-ref>
  <pkg-ref id="$id.au" version="$NMR_VERSION">au.pkg</pkg-ref>
</installer-gui-script>
XML
}

make_pkg() {
  local out="$DIST/$FILE_NAME-Plugins-$NMR_VERSION.pkg"
  rm -rf "$STAGE/pkg" "$out"
  mkdir -p "$STAGE/pkg/scripts-au" "$STAGE/pkg/resources" "$DIST"
  # The registrar caches the component list; restart it so hosts and auval see the new AU.
  cat >"$STAGE/pkg/scripts-au/postinstall" <<'SH'
#!/bin/sh
killall -9 AudioComponentRegistrar 2>/dev/null || true
exit 0
SH
  chmod 755 "$STAGE/pkg/scripts-au/postinstall"
  component_pkg clap CLAP clap
  component_pkg vst3 VST3 vst3
  component_pkg component Components au
  cp "$ROOT/LICENSE" "$STAGE/pkg/resources/LICENSE.txt"
  distribution_xml >"$STAGE/pkg/distribution.xml"
  productbuild --quiet --distribution "$STAGE/pkg/distribution.xml" \
    --resources "$STAGE/pkg/resources" --package-path "$STAGE/pkg" "$out"
  rm -rf "$STAGE/pkg"
  echo "wrote $out"
}

make_checksums() {
  [[ -d "$DIST" ]] || die "nothing in $DIST to checksum"
  (
    cd "$DIST"
    rm -f SHA256SUMS
    local files=()
    for f in *.dmg *.pkg; do [[ -f "$f" ]] && files+=("$f"); done
    ((${#files[@]} > 0)) || die "no .dmg or .pkg in $DIST"
    shasum -a 256 "${files[@]}" >SHA256SUMS
    cat SHA256SUMS
  )
}

case "${1:-all}" in
  dmg) make_dmg ;;
  pkg) make_pkg ;;
  checksums) make_checksums ;;
  all)
    make_dmg
    make_pkg
    make_checksums
    ;;
  *)
    echo "usage: scripts/package.sh [all|dmg|pkg|checksums]" >&2
    exit 2
    ;;
esac
