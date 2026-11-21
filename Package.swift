// swift-tools-version: 6.0
// The app (Swift 6) and its Swift tests. Sources/{Core,Render,CoreC} are the same files CMake
// compiles for the plugins and C++ tests; scripts/check-sources.sh verifies that both builds
// compile the same set. Build through scripts/build.sh, which also bundles and signs the app.
import PackageDescription

// Mirrors nmr_warnings in CMakeLists.txt: the 14.2 deployment target is enforced at compile time.
let clangWarnings = [
  "-Wall", "-Wextra", "-Wno-unused-parameter",
  "-Werror=unguarded-availability-new", "-Werror=return-type",
]
// Objective-C classes in shared code get a per-target suffix (Sources/Render/include/nmr/objc_names.h).
let objcSuffix = "_App"

let package = Package(
  name: "NMR",
  platforms: [.macOS("14.2")],
  products: [
    .executable(name: "nmr-app", targets: ["App"])
  ],
  targets: [
    .target(
      name: "NMRCore",
      path: "Sources/Core",
      cxxSettings: [.headerSearchPath("third_party"), .unsafeFlags(clangWarnings)]
    ),
    .target(
      name: "NMRRender",
      dependencies: ["NMRCore"],
      path: "Sources/Render",
      cSettings: [.define("NMR_OBJC_SUFFIX", to: objcSuffix), .unsafeFlags(clangWarnings)],
      cxxSettings: [.define("NMR_OBJC_SUFFIX", to: objcSuffix), .unsafeFlags(clangWarnings)],
      linkerSettings: [
        .linkedFramework("Foundation"), .linkedFramework("AppKit"), .linkedFramework("Metal"),
        .linkedFramework("QuartzCore"), .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
      ]
    ),
    .target(
      name: "NMRCoreC",
      dependencies: ["NMRRender"],
      path: "Sources/CoreC",
      cSettings: [.define("NMR_OBJC_SUFFIX", to: objcSuffix), .unsafeFlags(clangWarnings)],
      cxxSettings: [.define("NMR_OBJC_SUFFIX", to: objcSuffix), .unsafeFlags(clangWarnings)]
    ),
    .executableTarget(
      name: "App",
      dependencies: ["NMRCoreC"],
      path: "App"
    ),
    .testTarget(
      name: "AppTests",
      dependencies: ["App", "NMRCoreC"],
      path: "Tests/Swift"
    ),
  ],
  cxxLanguageStandard: .cxx20
)
