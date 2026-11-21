# Plan (mirrors docs/PROMPT.md §8)

Legend: `[x]` done and verified, `[~]` in progress / partially verified, `[ ]` not started.

## Phase 0: scaffold and toolchain proof

- [ ] Repo files: README stub, MIT LICENSE, THIRD_PARTY_NOTICES.md, CLAUDE.md, docs/PLAN.md,
      docs/DECISIONS.md, docs/BUDGET.md, config/, .gitignore; PROMPT.md moved to docs/PROMPT.md
- [ ] Public repo `nemura0/nemura-stereometer` created and pushed with `gh`
- [ ] `ci.yml` on macos-26 (newest Xcode on the image) builds and runs tests
- [ ] Hello-world CLAP pass-through with a Metal editor (runtime shaders, CAMetalDisplayLink)
- [ ] Wrapped to VST3 + AUv2 (clap-wrapper), Universal, installed to ~/Library/Audio/Plug-Ins/*
- [ ] auval passes
- [ ] pluginval strictness 8 passes, arm64 and x86_64 (`arch -x86_64`), VST3 and AU
- [ ] clap-validator passes
- [ ] AU loads out of process in a tiny test host (`kAudioComponentInstantiation_LoadOutOfProcess`)
- [ ] Self-signed identity created; app and plugins signed with it
- [ ] Audio-capture permission survives a rebuild (owner approves the prompt once)
- [ ] CI secret export documented (`gh secret set`)
- [ ] Baseline: reference app measured
- [ ] Baseline: MiniMeters measurement prepared
- [ ] **CHECKPOINT A** (owner: Ableton AU/VST3, FL VST3/AU/CLAP; MiniMeters Stereometer-only layout)

## Phase 1: core

- [ ] SPSC ring, shm registry and ring
- [ ] DSP: M/S, log radius, band color, correlation, balance, auto-gain
- [ ] Settings schema (key, type, range, default, group, label) as the single source of truth
- [ ] JSON, preset files with migration
- [ ] Original colormaps and `.map` import
- [ ] C API
- [ ] Tests: correlation (+1 identical, −1 inverted, ≈0 independent noise)
- [ ] Tests: balance, mapping, log scale
- [ ] Tests: schema round-trip; Swift ↔ C++ schema agreement
- [ ] Tests: ring concurrency stress
- [ ] Tests: cross-process shm via `fork`, layout check on both architectures
- [ ] Tests: RT microbenchmark within budget

## Phase 2: renderer and NEMURA mode

- [ ] Shared renderer: all modes, view options, color modes, shapes, lines, glow, guides, meters
- [ ] Paced playhead, Auto frame rate, idle stop
- [ ] `scripts/snapshots.sh` renders offscreen PNGs per mode from a test WAV
- [ ] NEMURA mode: 3 original concepts, a snapshot of each
- [ ] **CHECKPOINT B** (snapshots, pacing stats, Instant calibrated against the reference)

## Phase 3: app

- [ ] Overlay window: transparent, click-through, all Spaces, hover controls, size presets
- [ ] Process tap: output-device changes, permission flow, silent-buffer detection
- [ ] UI: source picker, menu-bar popover, Settings window, preset import/export, hotkeys,
      frame-rate setting, `--feed`

## Phase 4: plugin

- [ ] Bit-exact pass-through (null test), mono and stereo layouts, versioned state save/restore
- [ ] Shared-memory send with status indicator; multiple instances
- [ ] Editor: shared renderer + schema-generated settings panel; open/close loops without leaks
- [ ] Every validator green on both architectures; OOP AU test delivers audio to the app
- [ ] **CHECKPOINT C** (10-minute DAW checklist for Ableton and FL)

## Phase 5: polish, performance, release

- [ ] `scripts/perf.sh` meets §7 budgets against the baselines
- [ ] `.dmg` (app) and `.pkg` (AU/VST3/CLAP to /Library/Audio/Plug-Ins, per-format choices)
- [ ] `release.yml` on `v*`: build, test, validate, sign, package, GitHub Release + SHA-256
- [ ] Homebrew tap `nemura0/homebrew-tap` (casks `stereometer`, `stereometer-plugins`, self-updating)
- [ ] README (English): features, install, unsigned-app steps, permission/privacy, DAW usage, build
- [ ] **CHECKPOINT D** (release draft + README; then tag v1.0.0 and publish)
