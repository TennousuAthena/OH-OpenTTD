# NOTICES — OpenTTD HarmonyOS Port

Third-party software notices for the OpenTTD 15.3 HarmonyOS port.

This file enumerates every third-party component used by the HarmonyOS port
(native dependencies, NDK-provided runtime components, and upstream-bundled
third-party code), its SPDX license identifier, and where its license text can
be found. The CycloneDX and SPDX SBOMs under `harmonyos/dependencies/` are
derived from the same manifest (`harmonyos/dependencies/manifest.json`) and are
validated by `scripts/harmonyos/check-licenses.sh` in CI.

## OpenTTD

- **Component**: OpenTTD 15.3
- **License**: GPL-2.0-only
- **License text**: `COPYING.md` (repository root)
- **Source**: https://github.com/OpenTTD/OpenTTD (tag `15.3`,
  commit `14ec60f248547d4d062a1160f0fc26d742319888`)

## Pinned native dependencies (fetched as immutable archives)

| Component | Version | SPDX | Linkage | ABI | License file in source |
|-----------|---------|------|---------|-----|------------------------|
| zlib | 1.3.1 | Zlib | static | arm64-v8a, x86_64 | `zlib.h` (copyright notice in header) |
| XZ Utils (liblzma) | 5.6.3 | 0BSD | static | arm64-v8a, x86_64 | `COPYING` |
| libpng | 1.6.45 | libpng-2.0 | static | arm64-v8a, x86_64 | `LICENSE` |
| FreeType | 2.13.3 | FTL | static | arm64-v8a, x86_64 | `docs/FTL.TXT` |
| HarfBuzz | 10.1.0 | MIT | static | arm64-v8a, x86_64 | `COPYING` |
| ICU (ICU4C) | 75.1 | ICU | static | arm64-v8a, x86_64 | `icu4c/LICENSE` |
| libcurl | 8.11.1 | curl | static | arm64-v8a, x86_64 | `COPYING` |
| libopus | 1.5.2 | BSD-3-Clause | static | arm64-v8a, x86_64 | `COPYING` |
| opusfile | 0.12 | BSD-3-Clause | static | arm64-v8a, x86_64 | `COPYING` |
| LZO (liblzo2) — optional | 2.10 | GPL-2.0-only | static | arm64-v8a, x86_64 | `COPYING` |

Full URLs, verified SHA-256 values and update owners are recorded in
`harmonyos/dependencies/manifest.json`.

## NDK-provided runtime components (API 23)

These components are provided by the HarmonyOS NDK sysroot pinned by
`scripts/harmonyos/bootstrap.sh` (API 23, SDK 6.1.0.105). They are not fetched
as archives and carry no SHA-256 in the manifest.

- **LLVM libc++ (C++ runtime)** — Apache-2.0 (LLVM project)
- **C++ standard threads (std::thread)** — Apache-2.0 (LLVM project)
- **Bionic libc / system libraries** — BSD-2-Clause / Apache-2.0 (OpenBSD/AOSP)

## Upstream-bundled third-party components (in-tree)

These components ship inside the OpenTTD source tree (see `README.md` §3.0
"Licensing") and are part of the OpenTTD GPLv2 distribution exception list.

| Component | Path | SPDX | License file |
|-----------|------|------|--------------|
| squirrel | `src/3rdparty/squirrel` | Zlib | `src/3rdparty/squirrel/COPYRIGHT` |
| md5 | `src/3rdparty/md5` | Zlib | comments in source files |
| fmt | `src/3rdparty/fmt` | MIT | `src/3rdparty/fmt/LICENSE.rst` |
| nlohmann-json | `src/3rdparty/nlohmann` | MIT | `src/3rdparty/nlohmann/LICENSE.MIT` |
| opengl-headers (khrplatform.h) | `src/3rdparty/opengl` | MIT | `src/3rdparty/opengl/khrplatform.h` |
| catch2 | `src/3rdparty/catch2` | BSL-1.0 | `src/3rdparty/catch2/LICENSE.txt` |
| icu-scriptrun | `src/3rdparty/icu` | Unicode-DFS-2016 | `src/3rdparty/icu/LICENSE` |
| monocypher | `src/3rdparty/monocypher` | BSD-2-Clause AND CC0-1.0 | `src/3rdparty/monocypher/LICENSE.md` |
| openttd-social-integration-api | `src/3rdparty/openttd_social_integration_api` | MIT | `src/3rdparty/openttd_social_integration_api/LICENSE` |
| llvm-checkatomic | `cmake/3rdparty/llvm` | Apache-2.0 | `cmake/3rdparty/llvm/LICENSE.txt` |

## Excluded libraries

The following libraries are intentionally NOT used by the HarmonyOS port:

| Library | Reason |
|---------|--------|
| SDL (SDL2) | HarmonyOS rendering/input are native (NativeWindow XComponent, NAPI); SDL would duplicate the platform layer. |
| Allegro | Legacy video/audio backend not supported on HarmonyOS; no documented requirement. |
| FluidSynth | MIDI synthesis via external soundfont not supported on HarmonyOS; no documented requirement. |
| Fontconfig | Font discovery on HarmonyOS uses system font APIs; fontconfig is not available in the NDK. |
| Breakpad | Crash reporting uses the HarmonyOS crash kit; no documented requirement for Breakpad. |

## TLS / trust store policy

libcurl must be built to use the **HarmonyOS system trust store** via the NDK
TLS provider. Bundling a third-party CA bundle (`cacert.pem`) is forbidden:
certificate validation must follow the platform trust store.

## Update policy

Each pinned dependency records an `updateOwner` in
`harmonyos/dependencies/manifest.json`. Updates require a new immutable release
URL, a freshly verified SHA-256, and a review of the license field before the
manifest and SBOMs are regenerated. Mutable branches (main/master/latest) are
forbidden as fetch sources.
