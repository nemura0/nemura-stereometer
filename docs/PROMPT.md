# NEMURA Stereometer: Master Build Prompt (v1)

> **Operator notes (for Vicente; the agent can skip this box)**
> - Before starting:
>   - In Xcode › Settings › Intelligence, allow external agents to use Xcode tools.
>   - Keep Xcode open.
>   - Restart Claude Code so it loads the new MCP servers, plugins and skills.
> - Open Claude Code in the Claude desktop app on `/Volumes/X9 Pro/05 DEV/nemura-stereometer` and send: `Read PROMPT.md and execute it.`
> - Model: Opus 5.5. Effort: **Max** for Phases 0–2, **High** for 3–4, **Medium** for 5.
> - The agent pauses at checkpoints A–D. Total budget: 2–3 days.

---

## 0. Role, goal, working rules

You are a senior macOS audio engineer (Core Audio, CLAP/VST3/AU, Metal, Swift/SwiftUI/AppKit, C++20). Build **NEMURA Stereometer v1** end to end in this folder and publish it as the public GitHub repo **nemura0/nemura-stereometer**. The owner is Vicente Guerra (GitHub `nemura0`, artist brand NEMURA).

**Time budget: 2–3 working days.** Prefer the simplest design that meets the acceptance criteria. No speculative abstractions and no extra ceremony: no subagent fleets, no custom slash commands, no long design docs.

Rules:
1. **The decisions in §3 are final.** Don't brainstorm alternatives or write a new plan: §8 *is* the plan. Skip any workflow skill that wants to brainstorm or re-plan; its debugging, TDD and verification skills are welcome. Re-open a decision only if it is technically blocked. In that case make the smallest change, log it in `docs/DECISIONS.md`, and continue.
2. **Verify, don't recall.**
   - Look up Apple APIs in the docs that ship with Xcode (the `axiom-apple-docs` skill, or the Xcode MCP's documentation search).
   - Check API availability against the **macOS 14.2** deployment target.
   - For CLAP, clap-wrapper and VST3 behavior, read their sources.
3. **Use the installed tooling:**
   - XcodeBuildMCP and the Xcode MCP (build, run, logs, docs)
   - swift-lsp and clangd-lsp
   - the `realtime-audio-macos` skill (mandatory reading)
   - the `audio-plugin-validators` plugin
   - pluginval (`/Applications/pluginval.app`), `clap-validator` (`~/.local/bin`) and `auval`
   - `gh`, logged in as nemura0
4. **Small vertical steps.** Build and test after each one, commit with Conventional Commits, and push. CI must be green before every checkpoint.
5. **Keep the working docs current:** `CLAUDE.md` (≤150 lines), `docs/PLAN.md` (checkboxes) and `docs/DECISIONS.md`. After any context compaction, re-read them first.
6. **English everywhere:** code, comments, UI, docs, commits, release notes.
7. **The reference prototype is read-only:** `/Volumes/X9 Pro/05 DEV/stereometer` and `/Applications/Stereometer.app`. Read and measure them, but never modify, move or overwrite them. The new app is named `NEMURA Stereometer.app` so it never replaces the old one.
8. **Ask only when blocked** or at a checkpoint, and always with options plus your recommendation.

## 1. Product

A free, open-source, native stereometer for Apple Silicon Macs: a goniometer/vectorscope plus correlation and balance meters.

1. **NEMURA Stereometer.app.** A floating, borderless meter whose background can be fully transparent (adjustable color and opacity). It shows one source at a time, chosen by the user:
   - the Mac's whole system output, through a Core Audio process tap with no drivers (**default**), or
   - a plugin instance sending from a DAW.
2. **NEMURA Stereometer plugin (CLAP, VST3, AU).** A zero-latency, bit-exact pass-through insert. Per instance, the user chooses whether it sends its audio to the app, shows the same meter inside the DAW, or both.

Goals, in priority order:
1. Perfectly fluid motion at the display refresh rate. No stutter, ever.
2. Very low CPU/GPU/RAM/energy use, near zero when idle.
3. Beautiful (glow, color) **and** functional for mixing: accurate geometry, readable correlation and balance. The owner splits his use about 50/50 between mixing and filming the screen for content.
4. Deep customization, including a reaction speed that goes from instant to slow.
5. One original **NEMURA** display mode in the owner's aesthetic.

**Reference prototype** (SwiftPM + Metal + process tap). The owner loves its fluidity and colors. Reuse good ideas and snippets, but fix its problems:
- it requires macOS 15+
- ad-hoc signing makes macOS ask for permission on every build
- it redraws a fixed 1,024-sample window every frame
- persistence is per frame instead of time-based
- it runs two full-screen float16 passes per frame
- the IO proc runs on a dispatch queue
- the UI is Spanish-only
- MiniMeters' colormap is copied into the code
- there is no plugin

**MiniMeters** is the functional bar to beat in look, feel and efficiency. Never copy its assets, colormaps, names or text. Importing a user's own `.map` files is fine.

## 2. Hard constraints

- **Targets.** macOS 14.2+ on Apple Silicon. The app is arm64 only. The plugins are Universal 2 (arm64 + x86_64) so DAWs running under Rosetta can load them.
- **Dev machine.** MacBook Pro M5, macOS 27.2.1, Xcode 27.2 / Swift 6.4.2 at `/Volumes/X9 Pro/Applications/Xcode.app`, CMake 4.4.2 + Ninja, Homebrew, gh.
- **No other Mac or VM for testing.** Enforce the deployment target at compile time: `-Werror=unguarded-availability-new` for C and ObjC++, plus Swift availability checks. Never use an API newer than 14.2 without a guarded fallback.
- **No Metal Toolchain.** The Xcode Metal Toolchain isn't installed (Xcode 26+ ships it separately), so don't depend on `xcrun metal`. Embed the shader source and compile it at runtime once per process, caching the library and pipelines.
- **Must work in every major DAW.**
  - Ableton Live 12 and FL Studio are the owner's DAWs; he tests them manually at checkpoints.
  - Logic Pro, Bitwig, Reaper, Studio One and Cubase are covered by the validators and an out-of-process AU test.
- **Unsigned distribution.** No Apple Developer Program, no notarization.
- **License.** MIT, with permissive dependencies only.
- **Audio paths** follow the `realtime-audio-macos` skill with zero exceptions.

## 3. Decisions (final)

| Area | Decision |
|---|---|
| **Plugin stack** | A CLAP plugin in C++20, wrapped to **VST3 + AUv2** with free-audio **clap-wrapper**. All MIT/Apache: CLAP, clap-wrapper, VST3 SDK (MIT since 3.8), AudioUnitSDK. Pin exact tags/commits.<br>**Fallback**, only if Phase 0 proves clap-wrapper can't deliver working AU + VST3 editors in Ableton and FL: JUCE 8 + clap-juce-extensions, with the license changed to AGPL-3.0. Log the switch. |
| **App** | Swift 6 (language mode 6). SwiftUI for Settings and the menu-bar popover; AppKit for the overlay window. Built with SwiftPM plus a bundling script. |
| **Shared core** | One C++20 / Objective-C++ core used by both app and plugin: DSP, settings schema + JSON, presets, colormaps, shared-memory transport, Metal renderer and the process-tap capture. Swift reaches it through a small C API (opaque handles, POD structs). The meter must look identical in the app and in the DAW. |
| **Rendering** | `CAMetalLayer` driven by `CAMetalDisplayLink` on a dedicated render thread. Runtime-compiled shaders. Paced playhead (§7). |
| **System capture** | Global stereo process tap plus a private aggregate device. The IO proc uses a **nil queue** (HAL real-time thread) and is written in C++/ObjC++, never in Swift. |
| **Plugin → app** | POSIX shared memory: one registry segment plus one lock-free SPSC ring per instance. The plugin's audio thread only `memcpy`s and publishes an atomic counter. No network, no XPC. |
| **Plugin params** | No host-automatable parameters in v1. All settings live in versioned JSON plugin state, saved with the DAW project. |
| **Sync** | App and plugin share the settings schema and the preset files. No live two-way sync in v1. |
| **Signing** | A stable **self-signed** code-signing identity, kept in the local keychain and as a CI secret, signs both app and plugins, so the audio-capture permission survives rebuilds and updates. Ad-hoc signing is the fallback. Never commit keys. |
| **Build** | CMake builds the core, renderer, plugin, wrappers and C++ tests. SwiftPM builds the app and Swift tests. Both compile the same `Sources/Core`, `Sources/Render` and `Sources/CoreC` files, and a CI check keeps the two in sync. One entry point: `scripts/build.sh`. |
| **Libraries** | Only vendored single headers: nlohmann/json (MIT) and doctest (MIT). Anything else needs a logged reason. |
| **Names/IDs** | Product "NEMURA Stereometer" (short: Stereometer); vendor "NEMURA".<br>App bundle `dev.vicguerra.stereometer`. CLAP id `dev.vicguerra.stereometer`. AU `aufx`, subtype `Stmt`, manufacturer `Nmra`.<br>**Every name and ID comes from one file in `config/`**, and `scripts/rename.sh` renames the product in one step (the owner may rename it later). |
| **Repo** | **Public** `nemura0/nemura-stereometer` from day one (public repos get free macOS CI minutes), branch `main`. Homebrew tap: `nemura0/homebrew-tap`. |

## 4. Architecture

```
config/              product name, IDs, version (single source of truth)
Sources/Core/        C++20: rings, shm transport, DSP, settings schema/JSON, presets, colormaps
Sources/Render/      Objective-C++: Metal renderer (C++ classes holding Metal objects), embedded shaders,
                     process-tap capture (app only)
Sources/CoreC/       C API over Core + Render for Swift
App/                 Swift: overlay window, source picker, menu bar, Settings, presets UI
Plugin/              CLAP plugin + editor NSView (ObjC++), clap-wrapper targets (VST3, AUv2)
Tests/               doctest (C++), Swift Testing, plugin host tests (null test, out-of-process AU)
scripts/             build, sign, package (dmg/pkg), validate, perf, snapshots, rename
.github/workflows/   ci.yml, release.yml
```

**Data flow.** Source (tap IO proc or plugin `process()`) → SPSC ring (copy only) → render thread reads at the paced playhead → analysis (M/S, band color, correlation, balance, auto-gain) → GPU. **No analysis runs on audio threads.**

**Objective-C classes.** Every ObjC class in shared or plugin code (views, the display-link delegate, action targets) is declared through a macro that appends a per-target suffix. Hosts can load the AU, VST3 and CLAP builds into one process, and ObjC class names are global.

**Shared-memory protocol** (versioned; implement exactly):
- **Registry `/nmr.stm.reg`.** macOS shm names are limited to 31 characters. Layout: a header with magic and version, then 16 slots. Each slot holds:
  - state
  - instance id
  - pid
  - heartbeat (mach time)
  - sample rate
  - channels
  - UTF-8 name[64]
  - ring name
- **Ring `/nmr.stm.r<slot>`.**
  - Header: magic, version, capacity, sample rate, and a 64-bit write counter (atomic, 128-byte aligned).
  - Data: interleaved float32 stereo.
  - Capacity: a power-of-two frame count of at least 250 ms at 192 kHz (65,536 frames, about 512 KB).
- **Plugin lifecycle.** The plugin claims a slot on activate (from a non-RT thread), writes from the audio thread, updates its heartbeat, and releases the slot on deactivate.
- **App side.** The app lists slots whose heartbeat is under 1 s old, reads lock-free and discards lapped data. Stale slots are reclaimed. Permissions are 0600.
- **Source names.** Use CLAP track-info when the host provides it. Otherwise the plugin UI shows an editable name (default "Stereometer 1", "Stereometer 2", …). Mono tracks send L = R.

## 5. Features (v1 scope)

**Display modes.** The reference's five, renamed generically, plus NEMURA:
1. Goniometer: full plane, the classic M/S diamond
2. Goniometer (Log): radius compressed in dB, range 24–72 dB (default 48)
3. Half goniometer: folded to the upper half, 2:1 viewport
4. Half goniometer (Log)
5. Lissajous: connected lines
6. **NEMURA**: original (Phase 2)

**View options:**
- orientation M/S (mono vertical) or L/R (X = L, Y = R)
- draw style dots or lines
- guides off, subtle or full (mono axis, L/R axes, unit circle)

**Meters.** A correlation bar (−1…+1) with a short history strip, and an L/R balance bar. Each can be toggled, numeric readouts are optional, and the integration time is selectable.

**Settings.** All apply live and all are stored in presets.

| Group | Settings |
|---|---|
| Points & lines | point size 0.5–12 pt; shape soft/circle/square; line thickness 0.5–6 px; density ×1–×8 (interpolated points); brightness; glow amount |
| Response | trail time 5–2000 ms, with presets:<br>• Instant (≈15 ms; calibrate it to match the reference's feel)<br>• Fast 30 ms, Medium 100 ms, Slow 300 ms, Very slow 1000 ms<br>Meter integration 50 ms–3 s |
| Level | gain −24…+36 dB; auto-gain off/slow/fast |
| Color | color mode: frequency, solid, amplitude or mid-side<br>colormaps: an original set including **Iris** (built on #8993FF) plus 4–5 more<br>import a user's MiniMeters `.map` files; solid color picker |
| Window (app) | background color + opacity 0–100 % (default: fully transparent)<br>always on top; click-through (global ⌃⌥⌘S); show/hide (global ⌃⌥⌘H)<br>visible on all Spaces and over full-screen apps<br>hover controls (close, minimize, settings); size presets + free resize<br>Dock icon on/off (the menu-bar icon is always on) |
| Performance | frame rate Auto / 120 / 60 / 30 |

**Presets.** Versioned JSON shared by app and plugin, stored in `~/Library/Application Support/NEMURA/Stereometer/Presets`, with import/export in the app. Factory presets:
- **Mix** (functional): guides, meters, Medium response
- **Stage** (for filming): no guides, glow, Instant response
- **NEMURA**: the original mode
- **Classic**

**App UX.** Organized and easy for any user; visually halfway between native macOS and a plugin look.
- **Menu-bar popover:**
  - a source picker listing System Output and live plugin instances
  - mode, with thumbnails drawn by the real renderer
  - preset, opacity and click-through
  - "Settings…"
- **Settings window (⌘,):** native SwiftUI controls, a sidebar with the groups above, a dark theme with a #8993FF accent, and a live preview on the meter itself.
- **Right-click menu** on the meter with the same quick items.
- **First run:** one sheet explains the audio-capture permission. If it is denied (silent buffers), show how to enable it.

**Plugin editor.** The meter fills the editor. A slim top bar holds:
- "Send to app", with a status dot: connected / app not running / unavailable in this host
- mode, preset and response
- a gear that opens a settings panel generated from the shared schema, built from stock AppKit controls

The editor is resizable. Its background is a solid color, since DAWs can't show transparency.

## 6. Out of scope (v1)

- per-band correlation
- per-app capture
- input devices
- multiple meter windows
- live app↔plugin sync
- auto-update
- launch at login
- AUv3
- Windows/Linux
- notarization

## 7. Fluidity and performance

**Frame pacing (goal #1)**
- **Auto frame rate.** Run at the display's maximum refresh (120 Hz on ProMotion, otherwise 60 Hz) with a **fixed** `preferredFrameRateRange` (min = max). Never use a variable rate while animating.
  - If more than 1 % of frames over 2 s are late, step down to a fixed 60 Hz and say so in Settings.
  - The user can force 120, 60 or 30.
- **Paced playhead.** Each frame draws the samples between the previous and the current playhead. The playhead trails the newest sample by an adaptive latency (about 1.5 × the largest observed block, clamped to 3–50 ms), advances by `sampleRate × dt`, and corrects drift gently.
  - Acceptance: a host block size of 2,048 frames still renders as even motion.
  - Measure the per-frame sample-count variance.
- **Time-based constants only.** Decay is `exp(-dt/τ)`, computed from the link's real timestamps.
- **Presentation.** Present at the link's target time, keep at most 3 frames in flight, and skip a frame rather than block. Nothing in the frame path runs on the main thread.
- **Idle.**
  - After silence longer than the trail time + 250 ms, draw one clear frame and stop the link (0 fps, 0 % GPU).
  - Resume on the first non-silent block, using a cheap low-rate check.
  - Also stop when the window is occluded or minimized, or when the plugin editor is hidden.

**Budgets.** Gate them in CI where they're measurable. Otherwise measure them with `scripts/perf.sh` on this Mac, and record the results in `docs/BUDGET.md`.
- **Plugin audio thread** (write + publish of 256 stereo frames): p50 ≤ 0.5 µs, p99 ≤ 2 µs, measured with a microbenchmark.
- **App** (medium window, 120 Hz, music playing):
  - CPU % and memory footprint ≤ **both** Phase 0 baselines: the reference app and MiniMeters with only its Stereometer module, at the same window size
  - zero dropped frames over 60 s
  - p99 frame interval within ±1 ms of the target
- **Idle** (5 s of silence): app CPU < 0.3 % and GPU ≈ 0. With the plugin editor closed, there is no render work at all.
- **Tools:** `top -l`, `footprint`, Instruments (Metal System Trace) and the display link's presentation callbacks. Use `powermetrics` only if the owner provides sudo.
- **Reproducible input:** support `--feed <file.wav>` (debug) in the app. The reference app accepts `STEREOMETER_DEBUG_FILE=<wav>`.

## 8. Phases, acceptance criteria, checkpoints

Mirror this list as checkboxes in `docs/PLAN.md`. At each **CHECKPOINT**, stop, report using the §10 format, and wait.

### Phase 0: scaffold and toolchain proof (~3 h)

- **Repo files:**
  - README stub, MIT `LICENSE`, `THIRD_PARTY_NOTICES.md`
  - `CLAUDE.md` with commands, invariants and a summary of the RT rules
  - `docs/PLAN.md`, `docs/DECISIONS.md`, `docs/BUDGET.md`
  - `config/` and `.gitignore`
  - Move this file to `docs/PROMPT.md`.
- **Publish:** create and push the public repo with `gh`. Add `ci.yml` on `macos-26` (select the newest Xcode on the image) to build and run tests.
- **Hello-world plugin.** Prove the whole plugin pipeline with a CLAP pass-through that has a Metal editor:
  - wrap it to VST3 + AUv2, build it Universal, and install it to `~/Library/Audio/Plug-Ins/*`
  - `auval`, pluginval (strictness 8, both architectures via `arch -x86_64`) and `clap-validator` all pass
  - the AU loads **out of process** in a tiny test host (`kAudioComponentInstantiation_LoadOutOfProcess`)
- **Signing.** Create the self-signed identity and sign with it. Verify the audio-capture permission survives a rebuild (ask the owner to approve the prompt once). Document how to export the identity to CI secrets with `gh secret set`.
- **Baselines.** Measure the reference app now, and prepare the MiniMeters measurement.

**CHECKPOINT A**
- The owner loads the hello-world in Ableton Live 12 (AU, VST3) and FL Studio (VST3, AU, CLAP).
- The owner sets MiniMeters to a Stereometer-only layout so you can measure it.
- If loading or the editors fail and you can't fix it quickly, apply the JUCE fallback.

### Phase 1: core (~4 h)

Build:
- SPSC ring, shm registry and ring
- DSP: M/S, log radius, band color, correlation, balance, auto-gain
- settings schema, the single source of truth (key, type, range, default, group, label)
- JSON, preset files with migration
- original colormaps and `.map` import
- the C API

Tests:
- correlation: identical signals = +1, inverted = −1, independent noise ≈ 0
- balance, mapping, log scale
- schema round-trip, and Swift ↔ C++ schema agreement
- ring concurrency stress
- cross-process shm via `fork`, with a layout check on both architectures
- RT microbenchmark within budget

### Phase 2: renderer and the NEMURA mode (~5 h)

- **Shared renderer:**
  - all modes, view options, color modes, shapes, lines, glow, guides and meters
  - paced playhead, Auto frame rate, idle stop
  - `scripts/snapshots.sh` renders offscreen PNGs per mode from a test WAV
- **NEMURA mode.** Design **3 original concepts** in the owner's aesthetic: dark, vampiric, Y2K "metalheart"/chrome. Hero color periwinkle-iris **#8993FF**; warning accent **#E03C60**.
  - Each concept must look stunning on camera **and** stay honest for mixing: mono, width and phase problems must be obvious at a glance.
  - Ideas, not requirements:
    - an iris-like bloom with a chrome-white hot core
    - a mono "spine" with side "wings"
    - a thin chrome 0 dBFS ring
    - the halo tinting toward #E03C60 when correlation goes negative
  - Render a snapshot of each concept.

**CHECKPOINT B**
- Show the snapshots of every mode, including the 3 NEMURA concepts; the owner picks one concept.
- Report the pacing stats.
- Calibrate the Instant response side by side with the reference.

### Phase 3: app (~5 h)

- **Overlay window:** transparent, click-through, all Spaces, hover controls, size presets.
- **Process tap:** handle output-device changes, the permission flow and silent-buffer detection.
- **UI:** source picker, menu-bar popover, Settings window, preset import/export, hotkeys, the frame-rate setting, and `--feed`.

### Phase 4: plugin (~4 h)

- **Processing:** bit-exact pass-through (null test), mono and stereo layouts, versioned state save/restore.
- **Send:** shared-memory send with a status indicator; multiple instances.
- **Editor:** the shared renderer plus the schema-generated settings panel. It survives open/close loops without leaks.
- **Validation:** every validator green on both architectures, and the out-of-process AU test delivers audio to the app.

**CHECKPOINT C**
Give the owner a 10-minute DAW checklist for Ableton and FL:
- each format loads
- send to the app and switch sources
- save, close and reopen the project
- run 10 instances
- open and close the editor

### Phase 5: polish, performance and release (~5 h)

- **Performance.** `scripts/perf.sh` meets §7 against the baselines; fix any regressions.
- **Packaging.** A `.dmg` for the app, and a `.pkg` that installs AU/VST3/CLAP into `/Library/Audio/Plug-Ins` with per-format choices.
- **`release.yml`.** On a `v*` tag it:
  1. builds, tests and validates
  2. signs with the self-signed identity from secrets
  3. packages
  4. publishes a GitHub Release with SHA-256 checksums
- **Homebrew tap.** `nemura0/homebrew-tap`, with casks `stereometer` (app) and `stereometer-plugins` (pkg).
  - The tap updates itself from the latest release through a scheduled + manual workflow, so no cross-repo token is needed.
  - Install: `brew tap nemura0/tap && brew trust nemura0/tap && brew install --cask stereometer`.
  - Don't strip quarantine silently; put the Gatekeeper steps in `caveats`.
- **README** (English):
  - what it is, with a GIF/screenshots, and the features
  - install via DMG, PKG or Homebrew
  - "This app is unsigned": System Settings › Privacy & Security › Open Anyway, or `xattr -dr com.apple.quarantine "/Applications/NEMURA Stereometer.app"`
  - the audio-capture permission and privacy (audio never leaves the Mac)
  - plugin usage per DAW
  - building from source, license and credits

**CHECKPOINT D**
Show the release draft and the README. After approval, tag **v1.0.0** and publish.

## 9. Gotchas (read before Phase 0)

- **Shared memory**
  - macOS shm names are ≤ 31 characters, including the `/`.
  - Logic, GarageBand and Final Cut can host AUs out of process, and sandboxed hosts may block shm. Detect it and show "Send unavailable in this host"; never block or crash.
  - Don't add `resourceUsage`/`sandboxSafe` unless a test proves they're needed.
- **Plugin binaries**
  - A host can load the AU, VST3 and CLAP builds into one process. Use per-target ObjC class names, no Swift in the plugins, and `-fvisibility=hidden`.
  - After installing an AU, run `killall -9 AudioComponentRegistrar`.
  - In the x86_64 slice, set FTZ/DAZ.
- **Audio capture**
  - The TCC audio-capture grant is bound to the code signature, which is why we use the self-signed identity.
  - A denied grant delivers silent buffers, not errors.
  - An IO proc block with a nil queue runs on the HAL real-time thread.
- **CI**
  - clap-wrapper can fetch the VST3 SDK and AudioUnitSDK. Pin both and cache them in CI.
  - CI's Xcode is older than this Mac's. Keep the code compiling on both (avoid Swift-6.4-only features), or use the Xcode 27 runner image if one is available.
  - GitHub runners have no reliable GPU, so GPU tests must skip cleanly there.
- **Distribution**
  - Homebrew 6+ requires `brew trust` for third-party taps, and unsigned casks can't go in homebrew/cask.
  - Installing the new app must never replace `/Applications/Stereometer.app` (the reference).

## 10. Checkpoint report format (short)

1. **Done:** the `PLAN.md` items now checked.
2. **Evidence:** commands and their key output lines, snapshots, metrics vs. budgets.
3. **Deviations** from this prompt, and why.
4. **Risks and open questions.**
5. **What the owner must do or decide now.**

## 11. Start now

1. Read this prompt, the reference project and the `realtime-audio-macos` skill.
2. Reply in ≤10 lines with your understanding and any **blocking** questions.
3. Begin Phase 0.
