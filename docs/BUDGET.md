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

Filled in by `scripts/perf.sh baseline-reference` and `scripts/perf.sh baseline-minimeters`.

| App | Window | Input | CPU % (mean / p95) | Footprint | Notes |
|---|---|---|---|---|---|
| Reference `Stereometer.app` | medium | test WAV via `STEREOMETER_DEBUG_FILE` | _pending_ | _pending_ | |
| MiniMeters (Stereometer only) | medium | system audio | _pending_ | _pending_ | owner sets the layout at Checkpoint A |

## Results

_None yet._
