# NEMURA Stereometer

A free, open-source, native stereometer for Apple Silicon Macs: a goniometer/vectorscope with
correlation and balance meters.

- **NEMURA Stereometer.app**: a floating, borderless meter with an optionally fully transparent
  background. It shows the Mac's whole system output (Core Audio process tap, no drivers) or a
  plugin instance sending from your DAW.
- **NEMURA Stereometer plugin** (CLAP, VST3, AU): a zero-latency, bit-exact pass-through insert
  that can send its audio to the app, show the same meter inside the DAW, or both.

> **Status:** under construction (v1 in progress). Requires macOS 14.2 or later on Apple Silicon.

## Building from source

```bash
scripts/build.sh
```

Requirements: Xcode 26 or later, CMake 3.28+, Ninja.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
