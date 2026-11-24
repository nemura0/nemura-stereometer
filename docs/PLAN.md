# Plan (mirrors docs/PROMPT.md §8)

Legend: `[x]` done and verified, `[~]` in progress / partially verified, `[ ]` not started.

## Phase 0: scaffold and toolchain proof

- [x] Repo files: README stub, MIT LICENSE, THIRD_PARTY_NOTICES.md, CLAUDE.md, docs/PLAN.md,
      docs/DECISIONS.md, docs/BUDGET.md, config/, .gitignore; PROMPT.md moved to docs/PROMPT.md
- [x] Public repo `nemura0/nemura-stereometer` created and pushed with `gh`
- [x] `ci.yml` on macos-26 (newest Xcode on the image) builds and runs tests
- [x] Hello-world CLAP pass-through with a Metal editor (runtime shaders, CAMetalDisplayLink;
      the hello scene was replaced by the meter in Phase 2)
- [x] Wrapped to VST3 + AUv2 (clap-wrapper), Universal, installed to ~/Library/Audio/Plug-Ins/*
- [x] auval passes
- [x] pluginval strictness 8 passes, arm64 and x86_64 (`arch -x86_64`), VST3 and AU
- [x] clap-validator passes
- [x] AU loads out of process in a tiny test host (`kAudioComponentInstantiation_LoadOutOfProcess`)
- [x] Self-signed identity created; app and plugins signed with it
- [x] Audio-capture permission survives a rebuild (owner approves the prompt once)
- [x] CI secret export documented (`gh secret set`)
- [x] Baseline: reference app measured
- [x] Baseline: MiniMeters measurement prepared
- [~] **CHECKPOINT A**: Ableton Live 12 loads and draws the editor (owner, 2026-11-21); FL Studio
      (VST3, AU, CLAP) pending; MiniMeters measured at 1512 × 949 pt, 360 pt run pending

## Phase 1: core

- [x] SPSC ring, shm registry and ring (protocol v1: docs/DECISIONS.md)
- [x] DSP: M/S, log radius, band color, correlation, balance, auto-gain
- [x] Settings schema (key, type, range, default, group, label) as the single source of truth
- [x] JSON, preset files with migration
- [x] Original colormaps and `.map` import
- [x] C API: schema, setting values, JSON, presets and colormaps, with the app's Swift wrappers
- [x] Tests: correlation (+1 identical, −1 inverted, ≈0 independent noise)
- [x] Tests: balance, mapping, log scale
- [x] Tests: schema round-trip; Swift ↔ C++ schema agreement
- [x] Tests: ring concurrency stress (in process, and across processes with laps and skips)
- [x] Tests: cross-process shm via `fork`, layout check on both architectures, and a writer
      under the other architecture (arm64 ↔ x86_64)
- [x] Tests: RT microbenchmark within budget (docs/BUDGET.md)

## Phase 2: renderer and NEMURA mode

- [x] Shared renderer: all modes, view options, color modes, shapes, lines, guides, meters,
      glow and numeric readouts (offscreen GPU tests)
- [x] Paced playhead, Auto frame rate, idle stop; the render thread runs the DSP with FTZ/DAZ
      in the x86_64 slice (its filters decay into subnormals in silence); the plugin editor
      shows its input (the app's capture is wired in Phase 3)
- [x] `scripts/snapshots.sh` renders offscreen PNGs per mode from a test WAV
- [x] NEMURA mode: 3 original concepts (Iris Bloom, Spine & Wings, Metalheart), a snapshot of
      each, normal and in antiphase (`scripts/snapshots.sh`)
- [~] **CHECKPOINT B**: snapshots, pacing stats and the Instant calibration reported; the owner
      picked Iris Bloom (2026-11-22); the side-by-side Instant check in Live is pending

## Phase 3: app

- [x] Settings → scene (`meterSettings`), with the NEMURA look (Iris Bloom) in the original mode
      and the NEMURA factory preset
- [x] Overlay window: transparent non-activating panel, click-through, all Spaces and over
      full-screen apps, hover controls (hide, minimize, quick menu), size presets + free resize,
      kept on screen, right-click quick menu, global hotkeys ⌃⌥⌘S / ⌃⌥⌘H (checked in-process by
      `scripts/capture-probe.sh --meter`; the look and the mouse feel are for the owner to try)
- [x] The app meters the system output: `SystemCapture` follows output-device changes (default
      output, device death, sample rate, tap format; rebuilt off the main thread, a failed start
      retried), only the tap's stream on for the IO proc (an output device with inputs, e.g.
      VB-Cable, does not count as microphone use), `scripts/capture-probe.sh --meter`
- [x] Permission flow and silent-buffer detection: a first-run window explains the permission
      before the first capture; exact zeros while another process plays (and no sound ever seen)
      show a notice on the meter that opens the help (System Settings › Screen & System Audio
      Recording); capture failures show a notice with Try Again. Checked in-process by
      `scripts/capture-probe.sh --meter` (signal seen, no notice while sound plays, the notice
      fits at 240 and 720 pt); the denied path itself is covered by unit tests only (the owner's
      grant is never changed)
- [x] Settings kept between runs (`SettingsStore`: the plugin's JSON in the app's defaults;
      click-through always starts off; the probe keeps nothing)
- [x] Menu-bar popover: System Output and the capture's state, the mode with thumbnails drawn by
      the meter's renderer (`ThumbnailRenderer`, from the test mix), preset, background opacity,
      click-through, Settings…, Quit (checked in-process by `scripts/capture-probe.sh --meter`:
      icon, layout, a mode chosen there reaches the meter)
- [x] Settings window (⌘,, the popover, the gear, the quick menu): a sidebar with the schema's
      groups and Presets, rows generated from the schema (frame rate included), live on the
      meter; presets saved, imported, exported, deleted; `.map` colormaps imported. The look of
      the window and the popover on screen is for the owner to check
- [x] Source picker in the popover: System Output, the live plugin instances (from the shm
      registry, polled every 0.25 s) and, with `--feed <file.wav>`, the file played in a loop
      with no capture. A chosen instance that stops stays chosen and says so. Checked by
      `scripts/capture-probe.sh --instance` (a stand-in instance, `nmr_fake_instance`) and
      `--feed`; real plugins send in Phase 4. The picker's look is for the owner to check

### Owner feedback, 2026-11-22 (fix before Phase 4; work resumes when the owner says "retomar")

- [x] Square cuts at the meter's top and bottom edges: the trace's glow ends in a straight
      horizontal line, as if the image were clipped to a box (seen in the half modes at the top and
      bottom of the vertical trace). Nothing may end in a hard edge: find what clips (the draw
      area, the trail/accumulation texture, the scissor or viewport, the half-plane mask) and make
      the glow fade out instead
- [x] Quality drops as density, glow and other settings go up: the meter turns blurry and
      blown-out, "like 144p". Check the resolution of the offscreen textures (backing scale,
      drawable size vs. accumulation size), how the glow blur is sized, and the clipping or
      saturation of bright cores; it must stay sharp at every setting
- [x] Settings open behind the meter: the user has to click elsewhere or move the meter to reach
      them. Settings must open over the meter, attached to it, like MiniMeters' settings panel
      (a panel docked to the meter window, not a separate window that falls behind). Reference
      screenshot from the owner: MiniMeters' in-window settings (layout idea only; copy none of
      its text, names or assets)
- Fixed 2026-11-23 (DECISIONS: light bleed and edge fade, glow halo, Settings panel); waiting
  for the owner's look on screen before Phase 4
- [x] Still blurry on screen (point 5.9 pt, density 5, glow 65 %): sharp soft dots, density only
      where there is a gap, a halo that follows the trace (DECISIONS: sharp dots)
- [x] Maximize and restore by double-clicking the meter's top edge (DECISIONS: fill the screen)
- The owner checked the sharpness and the double-click zoom on screen on 2026-11-23: works.
  Dragging anywhere on the meter still moves it (the owner chose to keep that)

## Phase 4: plugin

- [x] Bit-exact pass-through (null test), mono and stereo layouts, versioned state save/restore
      (DECISIONS: plugin layouts, plugin state, plugin host test)
- [x] Shared-memory send with status indicator; multiple instances
      (DECISIONS: plugin send, plugin editor)
- [x] Editor: shared renderer + schema-generated settings panel; open/close loops without leaks
      (DECISIONS: plugin editor)
- [x] Every validator green on both architectures; OOP AU test delivers audio to the app
      (DECISIONS: OOP AU send test)
- [x] **CHECKPOINT C** (10-minute DAW checklist for Ableton and FL): VST3, AU and CLAP work in
      Ableton and FL Studio (owner, 2026-11-24); soft dots made beads after their screenshot
      (DECISIONS: bead dots)

## Phase 5: polish, performance, release

- [ ] `scripts/perf.sh` meets §7 budgets against the baselines
- [ ] `.dmg` (app) and `.pkg` (AU/VST3/CLAP to /Library/Audio/Plug-Ins, per-format choices)
- [ ] `release.yml` on `v*`: build, test, validate, sign, package, GitHub Release + SHA-256
- [ ] Homebrew tap `nemura0/homebrew-tap` (casks `stereometer`, `stereometer-plugins`, self-updating)
- [ ] README (English): features, install, unsigned-app steps, permission/privacy, DAW usage, build
- [ ] `scripts/rename.sh` renames the product in one step (§3)
- [ ] **CHECKPOINT D** (release draft + README; then tag v1.0.0 and publish)
