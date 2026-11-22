# NEMURA Stereometer: agent notes

Native goniometer/vectorscope + correlation/balance meter for Apple Silicon Macs.
Two products from one C++20/ObjC++ core: an overlay app (Swift) and a CLAP plugin wrapped
to VST3 + AUv2 with clap-wrapper. The full brief is `docs/PROMPT.md`; its §3 decisions are final.

**After any context compaction, re-read this file, `docs/PLAN.md` and `docs/DECISIONS.md` first.**

## Commands

```bash
scripts/build.sh                 # everything: deps, CMake (core/plugin/tests), SwiftPM app, bundle, sign
scripts/build.sh plugin          # CMake only (Universal plugins + C++ tests)
scripts/build.sh app             # SwiftPM app + bundle + sign
scripts/build.sh test            # C++ (ctest) + Swift tests
scripts/install-plugins.sh       # copy CLAP/VST3/AU to ~/Library/Audio/Plug-Ins, reset AU cache
scripts/validate.sh              # auval, pluginval (arm64 + x86_64), clap-validator, OOP AU test
scripts/gen-config.sh [--check]  # regenerate Sources/Core/include/nmr/product_config.h
scripts/fetch-deps.sh            # pinned CLAP / clap-wrapper / VST3 SDK / AudioUnitSDK into external/
scripts/check-sources.sh         # CMake and SwiftPM compile the same Sources/{Core,Render,CoreC}
scripts/capture-probe.sh [s]     # end-to-end system-audio capture check with the built app (0 = audio arrived)
scripts/capture-probe.sh [s] --meter|--instance|--feed  # the meter in-process; a stand-in plugin
                                 # instance (build/Tests/tools/nmr_fake_instance); a WAV played in
                                 # a loop (the app also takes `--feed <file.wav>`)
scripts/perf.sh reference|minimeters  # baselines: CPU % + footprint at a window size (docs/BUDGET.md)
```

Toolchain: Xcode 27.2 at `/Volumes/X9 Pro/Applications/Xcode.app` (selected), CMake 4.4 + Ninja.
Validators: `/Applications/pluginval.app`, `~/.local/bin/clap-validator`, `auval`.

## Layout

```
config/product.env   names, IDs, version: the single source of truth (rename via scripts/rename.sh)
Sources/Core/        C++20: rings, shm transport, DSP, settings schema/JSON, presets, colormaps
Sources/Render/      ObjC++: Metal renderer (C++ classes holding Metal objects), shaders, tap capture
Sources/CoreC/       C API (opaque handles, POD structs) used by Swift
App/                 Swift 6 app (SwiftPM target), bundled by scripts/bundle-app.sh
Plugin/              CLAP plugin + editor NSView (ObjC++), clap-wrapper targets
Tests/               doctest (C++), Swift Testing, host tests (null test, out-of-process AU)
external/            fetched SDKs (gitignored, pinned in scripts/fetch-deps.sh)
docs/                PROMPT (brief), PLAN, DECISIONS, BUDGET, SIGNING (identity, CI secrets)
```

## Invariants (do not break)

- Deployment target **macOS 14.2**. C/ObjC++ build with `-Werror=unguarded-availability-new`;
  every newer API needs `@available`/`#available` plus a fallback. No `xcrun metal`: shaders are
  embedded source compiled at runtime once per process and cached.
- App is arm64 only. Plugins are Universal 2 (arm64 + x86_64); FTZ/DAZ set in the x86_64 slice.
- Every ObjC class in shared/plugin code is declared via `NMR_OBJC(Name)` (`Sources/Render/include/nmr/objc_names.h`),
  which appends the per-target suffix (`_Clap`, `_Vst3`, `_Au`, `_App`, `_Test`). Hosts may load
  all three plugin formats into one process. No Swift in plugins; `-fvisibility=hidden`.
- No host-automatable parameters in v1. Plugin settings = versioned JSON state.
- Settings live in one schema table (`Sources/Core/settings.cpp`, `Id` order). Setting keys and
  choice keys are stored in plugin state and presets: renaming one needs a migration step
  (`Sources/Core/settings_migration.h`) and a version bump. Swift's `SettingKey` follows (SchemaTests).
- Plugin → app transport is POSIX shm only (`/nmr.stm.reg`, `/nmr.stm.r<slot>`), names ≤ 31 chars,
  mode 0600. Protocol layout is versioned; change the version on any layout change.
- All product names/IDs come from `config/product.env`. Never hardcode them elsewhere.
- Never touch the reference prototype (`/Volumes/X9 Pro/05 DEV/stereometer`,
  `/Applications/Stereometer.app`): read/measure only. Our app is `NEMURA Stereometer.app`.
- Never commit signing keys. English everywhere. MIT; permissive deps only (see THIRD_PARTY_NOTICES.md).
- Never copy MiniMeters assets, colormaps, names or text. Importing a user's own `.map` file is fine.

## Real-time rules (audio threads: tap IO proc, plugin `process()`)

The brief's `realtime-audio-macos` skill does not exist on this Mac; the owner installed
`realtime-audio-architecture` (Python/PortAudio playback) instead, applied in the 2026-11-21 audit
(docs/DECISIONS.md). These rules follow established practice and are applied with zero exceptions:

1. No heap allocation or deallocation (no `new`/`malloc`/`std::vector` growth/`std::string`, no
   `std::function` captures that allocate). Preallocate everything on a non-RT thread.
2. No locks of any kind (mutex, `@synchronized`, `dispatch_sync`, semaphores, condition variables),
   no waiting, no `sleep`. Use wait-free SPSC structures and `std::atomic` with explicit orderings.
3. No syscalls or blocking I/O: no file/network/shm open, no `printf`/`NSLog`/`os_log`, no
   `mach_absolute_time` beyond the cheap commpage read, no `shm_open`/`mmap` (do those on activate).
4. No Objective-C messaging, Swift, ARC retain/release, blocks capturing ObjC objects, or
   CoreFoundation calls. The tap IO proc is C++/ObjC++ registered with a **nil dispatch queue**
   (it runs on the HAL real-time thread) and touches only C++ state.
5. No unbounded work: O(frames) loops only, no analysis on audio threads (just `memcpy` + publish).
6. Never throw. Guard NaN/Inf at the reader side, not with branches that change the audio.
7. The plugin's audio path is bit-exact pass-through; never write different samples to the output.
8. Atomics: writer stores data, then `store(counter, release)`; reader `load(acquire)`, copies, then
   re-reads the counter to detect a lap and discards lapped data.
9. Tear down in order: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → destroy the aggregate →
   destroy the tap; the plugin unmaps shm only after `deactivate`. Never free what an audio thread
   may still touch.
10. Capture follows the output device: rebuild the tap on default-output, device-death, sample-rate
    or tap-format changes, off the main thread. Threads that feed the display run at
    user-interactive QoS, never background. Failures surface in the UI; no silent fallback.

## Conventions

- C++: `nmr::` namespace, snake_case files, `PascalCase` types, `camelCase` functions; no exceptions
  across the C API; JSON via nlohmann (`Sources/Core/third_party`), tests via doctest.
- Swift 6 language mode; SwiftUI for Settings/popover, AppKit for the overlay window.
- Conventional Commits (`feat:`, `fix:`, `chore:`, `test:`, `docs:`, `ci:`, `perf:`), small vertical
  steps, build + test before each commit, push to `main`. CI must be green before checkpoints.
- Keep `docs/PLAN.md` checkboxes and `docs/DECISIONS.md` current; budgets in `docs/BUDGET.md`.
