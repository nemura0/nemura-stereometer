#!/usr/bin/env bash
# The one build entry point.
#
#   scripts/build.sh [all]   deps + CMake (core, Universal plugins, C++ tests) + SwiftPM app
#   scripts/build.sh plugin  deps + CMake only (plugins signed in build/plugins)
#   scripts/build.sh app     SwiftPM app (arm64), bundled and signed in build/app
#   scripts/build.sh test    C++ tests (ctest: native, plus x86_64 under Rosetta) + Swift tests
#
# Environment: NMR_BUILD_DIR (default build/), NMR_CONFIG (Release or Debug; default Release),
# NMR_WERROR=ON (warnings in project code are errors; CI sets it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/product.env
source "$ROOT/config/product.env"
BUILD="${NMR_BUILD_DIR:-$ROOT/build}"
CONFIG="${NMR_CONFIG:-Release}"
WERROR="${NMR_WERROR:-OFF}"

# The native SwiftPM build system, explicitly: SwiftBuild (the default from Swift 6.4) records the
# deployment target as the SDK version in the binary, which would opt the app into macOS 14.2
# compatibility behaviors on newer systems (docs/DECISIONS.md).
SWIFT_ARGS=(--package-path "$ROOT" --build-system native --arch arm64)
if [[ "$WERROR" == "ON" ]]; then SWIFT_ARGS+=(-Xswiftc -warnings-as-errors); fi
SWIFT_CONFIG=release
if [[ "$CONFIG" == "Debug" ]]; then SWIFT_CONFIG=debug; fi

deps() {
  "$ROOT/scripts/fetch-deps.sh"
  "$ROOT/scripts/gen-config.sh" --check
}

build_cmake() {
  cmake -S "$ROOT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE="$CONFIG" -DNMR_WERROR="$WERROR"
  cmake --build "$BUILD"
  local plugins="$BUILD/plugins/$NMR_PRODUCT_NAME"
  "$ROOT/scripts/sign.sh" "$plugins.clap" "$plugins.vst3" "$plugins.component"
}

build_app() {
  swift build "${SWIFT_ARGS[@]}" -c "$SWIFT_CONFIG"
  local bin
  bin="$(swift build "${SWIFT_ARGS[@]}" -c "$SWIFT_CONFIG" --show-bin-path)"
  NMR_BUILD_DIR="$BUILD" "$ROOT/scripts/bundle-app.sh" "$bin/nmr-app"
}

run_tests() {
  ctest --test-dir "$BUILD" --output-on-failure
  swift test "${SWIFT_ARGS[@]}"
}

case "${1:-all}" in
  all)
    deps
    build_cmake
    build_app
    ;;
  plugin)
    deps
    build_cmake
    ;;
  app)
    "$ROOT/scripts/gen-config.sh" --check
    build_app
    ;;
  test) run_tests ;;
  *)
    echo "usage: scripts/build.sh [all|plugin|app|test]" >&2
    exit 2
    ;;
esac
