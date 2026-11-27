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
| Paced playhead: samples per frame with host blocks of 256, 1024 and 2048 frames | SD 0.06–0.14 % of the mean (at most ±3 samples around 400 or 800); no sample skipped or drawn twice | even motion with 2048-frame blocks | the playhead tests' model (a block source up to 0.5 ms late, frame callbacks up to 0.2 ms late), 18 s after a 2 s warm-up, 44.1 and 48 kHz, 60 and 120 Hz; `nmr_tests` gates SD ≤ 0.5 % | 2026-11-22 |
| App vs reference, Lissajous, 360 pt, 120 Hz, mix: three interleaved pairs of 30 s (`perf.sh reference --seconds 30`, then `perf.sh app --seconds 30`) | CPU mean, app / reference: 9.0 / 9.0, 8.2 / 8.1, 6.5 / 7.9 (the last pair stepped down to 60 Hz); footprint 89.0–93.9 MiB / 88.6–89.9 MiB; 8–11 of 3600 frames dropped; interval p1/p99 8.33 ms; render thread p99 0.38 ms a frame, GPU p99 0.28 ms | CPU and footprint ≤ reference; 0 dropped; p99 interval 8.33 ± 1 ms | **CPU at parity, footprint within 5 MiB, dropped frames over budget.** The machine was busy throughout (WindowServer 25–35 %, other apps 10–100 %), so the reference's 9.8 % / 91.1 MiB from a quiet day is not the comparison; only the interleaved pairs are. Before the two fixes below the app was 0.6–1.0 points and 10–20 MiB above the reference in the same pairs. Dropped frames are drawables the compositor never presented; our frames are encoded on time. Re-measure on a quiet machine before release | 2026-11-27 |
| App idle, silence (`perf.sh app --idle`) | CPU 0.3 % (median 0.3, p95 0.4); 0 frames drawn, GPU 0; footprint 52.0 MiB | CPU < 0.3 %, GPU ≈ 0 | The renderer stops completely. All of the 0.3 % is the `--feed` file player (the tap's stand-in, which wakes every 5 ms like a device), and `top` resolves only 0.1 %, so the gate fails at its boundary. One earlier run drew 105 frames with spikes to 4.6 % while the machine was busy; that did not repeat | 2026-11-27 |

### What the profile showed (2026-11-27)

`xcrun xctrace record --template "Time Profiler"` on the app, 10 s at 120 Hz: 72 % of the CPU
samples are on the render thread, and 68 % of those are the driver setting up render passes
(`renderCommandEncoderWithDescriptor:`), about 0.05 ms each; the draws themselves barely show.
The frame's CPU cost is the number of passes, so:

- **Glow in two passes, not three.** The across and down blurs are one 5 × 5 bilinear pass, the
  separable kernel's exact product (bilinear sampling factors per axis). Snapshots match the old
  ones to within one 8-bit level. A frame is now 4 passes: scope, glow down, glow blur,
  composite.
- **No private arrays in shaders.** The first version of that pass kept its weights in a local
  array, which the compiler put in private memory; the driver then reserved about 10 MB of GPU
  scratch. Program-scope `constant` arrays cost nothing.
- **`--feed` maps the WAV** (`mmap`) instead of reading it into a buffer: the freed 11 MB buffer
  stayed dirty in malloc's cache and counted in the footprint (–11 MB).

The rest of the footprint is about 42 MB of Metal's own memory (pipelines compiled at launch),
13 MB of small allocations, the feed's decoded 11 MB and 10 MB of drawables. `leaks` finds none,
and the heap holds steady at about 21 MB over minutes.
