# Performance budgets and measurements

Budgets from `docs/PROMPT.md` §7. Measured on the dev machine (MacBook Pro M5, macOS 27.2.1,
built-in Liquid Retina XDR, ProMotion 120 Hz) with `scripts/perf.sh` unless noted.

## Budgets

| Area | Budget | Gate |
|---|---|---|
| Plugin audio thread: write + publish 256 stereo frames | p50 ≤ 0.5 µs, p99 ≤ 2 µs | microbenchmark (CI) |
| App CPU %, medium window, 120 Hz, music | ≤ reference app **and** ≤ MiniMeters (Stereometer-only) | perf.sh (local) |
| App memory footprint, same conditions | ≤ both baselines | perf.sh (local) |
| Dropped frames over 60 s | 0 | perf.sh (local) |
| p99 frame interval | target ± 1 ms | perf.sh (local) |
| Idle (5 s silence) | app CPU < 0.3 %, GPU ≈ 0; plugin editor closed → no render work | perf.sh (local) |

## Baselines (Phase 0)

Measured with `scripts/perf.sh reference` and `scripts/perf.sh minimeters`: 5 s warm-up, then
%CPU and memory once a second for 60 s (`top -l 61 -s 1`, first sample dropped) and a
`footprint` at the end. Input: the `nmr_make_test_wav mix` signal (partials, correlated noise,
kick, anti-phase every 8 s). Raw JSON lands in `perf-results/` (gitignored). GPU time is not
measured yet (needs Instruments, or `powermetrics` with sudo).

| App | Window | Mode | Input | CPU % mean / median / p95 | Footprint (peak) | Date |
|---|---|---|---|---|---|---|
| Reference `Stereometer.app` 1.0 | 360 × 360 pt (medium) | Lissajous, colormap | debug file | **9.8** / 9.7 / 11.2 | **91.1 MiB** (91.4) | 2026-11-21 |
| Reference `Stereometer.app` 1.0 | 949 × 949 pt (owner's size) | Lissajous, colormap | debug file | 9.6 / 9.7 / 11.9 | 160.1 MiB (176.5) | 2026-11-21 |
| MiniMeters 1.0.29, Stereometer only | 1512 × 949 pt (owner's window, full width) | owner's | system audio (mix via `afplay`) | 14.2 / 14.1 / 14.8 | 703.9 MiB (726.1) | 2026-11-21 |
| MiniMeters 1.0.29, Stereometer only | 360 × 360 pt | owner's | system audio | _pending_ | _pending_ | when the owner resizes it |

The **medium (360 pt) rows are the gate** for the app budget; our app is compared in its
Lissajous-equivalent mode at the same window size.

How the reference is measured without touching it: its app re-saves its settings on every
launch, so `perf.sh` measures an identical copy (`ditto`, a new bundle identifier, ad-hoc
re-signed) whose settings domain gets the owner's saved reference settings with only the window
frame changed. The original bundle and its settings are only read, and the copy, its domain and
the WAV are deleted after the run. The reference draws with an `MTKView` at 120 fps while audio
is non-silent (30 fps when silent) and, with `STEREOMETER_DEBUG_FILE`, runs no process tap.

MiniMeters procedure (Checkpoint A):

1. The owner gives MiniMeters a layout with only its Stereometer module and sizes the window to
   about 360 × 360 pt; it must stay visible and uncovered during the run.
2. `scripts/perf.sh minimeters` plays the mix through the default output with `afplay` for
   about 75 s (MiniMeters meters system audio) and reports the window size it measured.
3. If that size is not 360 pt, `scripts/perf.sh reference --width <size>` re-measures the
   reference at the same size, so both baselines match.

## Results

| Area | Result | Budget | How | Date |
|---|---|---|---|---|
| Plugin audio thread: write + publish 256 stereo frames into a shared ring, plus the owner-checked heartbeat | arm64: p50 83 ns, p99 125–167 ns; x86_64 under Rosetta: p50 42 ns, p99 125 ns | p50 ≤ 0.5 µs, p99 ≤ 2 µs | `nmr_tests` RT budget case, Release, 200k runs at user-interactive QoS, three runs each (CI checks it on both architectures; the timer resolution is 41.7 ns) | 2026-11-21 |
