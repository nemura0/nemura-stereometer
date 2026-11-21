# Third-party notices

NEMURA Stereometer is MIT-licensed. It uses the following third-party software, all under
permissive licenses. Exact versions are pinned in `scripts/fetch-deps.sh` (SDKs fetched at build
time) or vendored in the tree (single headers).

| Component | Version | License | Use |
|---|---|---|---|
| [CLAP](https://github.com/free-audio/clap) | 1.2.10 | MIT, © 2021 Alexandre Bique | Plugin API (headers) |
| [clap-wrapper](https://github.com/free-audio/clap-wrapper) | 0.18.0 | MIT, © 2022 defiantnerd | VST3 and AUv2 wrappers around the CLAP |
| [VST 3 SDK](https://github.com/steinbergmedia/vst3sdk) | 3.8.0 build 66 | MIT, © 2025 Steinberg Media Technologies GmbH | VST3 wrapper (compiled in) |
| [AudioUnitSDK](https://github.com/apple/AudioUnitSDK) | 1.1.0 | Apache-2.0, © Apple Inc. | AUv2 wrapper (compiled in) |
| [nlohmann/json](https://github.com/nlohmann/json) | 3.12.0 | MIT, © 2013-2025 Niels Lohmann | Settings and preset JSON (vendored header) |
| [doctest](https://github.com/doctest/doctest) | 2.5.3 | MIT, © 2016-2025 Viktor Kirilov | C++ unit tests only (vendored header) |

VST is a registered trademark of Steinberg Media Technologies GmbH. Audio Units is a trademark of
Apple Inc. This project is not affiliated with or endorsed by either.

The full license texts ship with each component: `external/*/LICENSE*` after
`scripts/fetch-deps.sh`, and at the top of each vendored header.

## Apache-2.0 notice (AudioUnitSDK)

Copyright © Apple Inc. Licensed under the Apache License, Version 2.0. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed
to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
