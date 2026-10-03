# OpenTTD HarmonyOS — Port Build, Release and Maintenance Guide

This is the single entry point for every workflow of the OpenTTD 15.3 HarmonyOS
port: clean bootstrap from a fresh checkout, host tooling, both-ABI target
builds, HAP packaging and inspection, host tests, physical-device test
commands, debug signing, crash symbolication, dependency updates and the
upstream-delta policy.

The older fixture suites describe contracts and do not establish real-device
functionality. The current API 26 debugging evidence is recorded in §3.1 and
§12; release approval still requires the physical-device workflows.

> **Release status — debugging in progress.** The complete OpenTTD engine has
> compiled and packaged for arm64-v8a and x86_64. Debug signing and installation
> on a HarmonyOS 7 MateBook succeeded. Chinese rendering, new-world generation,
> sandbox save/load, keyboard pause, window resize, touch-drag road construction
> and normal exit/relaunch have run on that device. MIDI produces nonzero PCM through OHAudio. Audio
> listening, complete gameplay and tablet release approval remain pending.

---

## 1. Repository layout (HarmonyOS scope)

| Path | Purpose |
|---|---|
| `harmonyos/` | HarmonyOS app shell: `AppScope/`, `entry/` (ArkTS ability + `cpp/` native bridge), `product.json5`, `build-profile.json5`, `dependencies/` governance |
| `src/os/harmonyos/` | OS shims (HARMONYOS-gated): crashlog, HiLog, main, paths, font, locale, storage helpers (`harmonyos_{crashlog,log,main,paths,font,locale}.cpp`) |
| `src/video/harmonyos_v.{h,cpp}` | EGL/GLES video driver |
| `src/video/harmonyos_input.cpp` | input bridge core (keyboard/mouse/trackpad) |
| `src/video/harmonyos_touch.{h,cpp}` | touch/gesture recognizer |
| `src/sound/harmonyos_s.cpp` | OHAudio sound driver |
| `src/music/harmonyos_m.cpp` | MIDI playback through TinySoundFont and the OpenTTD mixer |
| `cmake/HarmonyOS.cmake` | first-class platform guard (rejects generic-Unix sources) |
| `scripts/harmonyos/` | every build/test/package/inspect script (see §2) |
| `docs/harmonyos/` | contracts and guides (this document plus the files listed in §13) |
| `.github/workflows/harmonyos-build.yml` | CI pipeline (build → package → inspect → license → secret scan → device gates) |

---

## 2. Script inventory

All scripts live in `scripts/harmonyos/` and are run from the repository root as
`bash scripts/harmonyos/<script>.sh [args]`. None embed user-specific absolute
paths; SDK discovery is deterministic via `bootstrap.sh`.
The SDK feature probe is run separately with Python 3 and an explicit SDK root
(see §3.1).

| Script | Purpose |
|---|---|
| `bootstrap.sh [--check-only]` | validate DevEco SDK (API 26), sysroots (arm64-v8a + x86_64), clang, cmake, ninja, node, hvigor, ohpm; emit `build/harmonyos/toolchain-manifest.json` |
| `probe-cxx20.py --sdk-root <sdk> --output <dir> [--abi <abi>]` | compile individual C++20 features against the selected SDK, record compiler/library metadata and both default/experimental results; does not build the engine or HAP |
| `build-host-tools.sh` | build native host generators `strgen` / `settingsgen` into `build/host-tools/` |
| `build-target.sh <abi> <mode> [--configure-only] [--perf]` | configure/build the game target per ABI (`arm64-v8a`\|`x86_64`, `Debug`\|`Release`) |
| `package.sh <Debug\|Release> [--perf]` | hvigor `assembleHap` (dual-ABI) + staged rawfile data + full release artifact set |
| `inspect-native-artifacts.py --hap <hap> --native-build-root <dir>` | verify optimization, full engine presence, ELF architecture, symbols and matching Build IDs |
| `inspect-release.sh <dir-or-hap> [--self-test]` | gate the packaged artifact (bundle/version/devices/permissions/ABIs/rawfile/SBOM/secrets) |
| `test-platform-guards.sh [-v]` | host: CMake platform guard (positive + negative configure) |
| `test-desktop-input.sh` | host: keyboard/mouse/trackpad bridge fixtures |
| `test-touch-gestures.sh` | host: touch/gesture recognizer fixtures |
| `test-input-matrix.sh` | host: input-matrix fixtures (IME, stylus, wheel, gestures) |
| `test-storage-font-locale.sh` | host: storage/font/locale helpers |
| `test-storage-contract.sh [--refresh-manifest]` | host: packaged-data manifest (fixture + tamper negative) |
| `test-audio-driver.sh` | host: OHAudio driver hot-path model (mixer, interrupt) |
| `test-video-driver.sh` | host: EGL dirty-rect + surface-recreation model |
| `test-render-contract.sh` | host: render-contract fixtures (dirty unions, clip, stale-gen) |
| `test-bridges.sh` | host: text-input/IME, picker, clipboard/browser bridge state machines |
| `test-lifecycle-bridge.sh` | host: Catch2 lifecycle + thread-ownership contract |
| `test-network-diagnostics.sh [-v]` | host: protocol constants, URL allowlist, HiLog, BuildID policy |
| `test-diagnostics-policy.sh [-v]` | host: diagnostics/security policy (forbidden APIs, secrets, permissions) |
| `test-hap-contents.sh [hap]` | post-assembly structural check of the HAP |
| `test-docs-guide.sh [-v]` | validates THIS guide (paths + commands + blocked gates) — §11 |
| `ci-local.sh [-v]` | local CI-equivalent runner (syntax, bootstrap, secrets, policy, yaml) |
| `ci-policy-check.sh` | structural policy gate over `.github/workflows/*.yml` |
| `check-licenses.sh` | SBOM/license consistency gate |
| `check-dependency-manifest.sh` | dependency manifest governance gate |
| `deps/run-deps.sh` | fetch + verify native dependency recipes |

---

## 3. Clean bootstrap (fresh checkout)

Requirements:

- macOS (the verified host) with **DevEco Studio** installed at
  `/Applications/DevEco-Studio.app` (API 26, SDK 26.0.0.x — exact contract is
  enforced by `bootstrap.sh`).
- Both `openharmony/native/` and `hms/native/` installed inside the SDK root.

From a fresh checkout (no `build/`):

```bash
# 1. Validate the SDK/toolchain; writes build/harmonyos/toolchain-manifest.json
bash scripts/harmonyos/bootstrap.sh --check-only

# 2. Build the host generators (strgen, settingsgen) natively for macOS
bash scripts/harmonyos/build-host-tools.sh
```

`bootstrap.sh` fails with a precise message if the SDK is missing, the API
level is not 26, either ABI sysroot is absent, or any tool is missing. On any
failure it exits nonzero and **never creates or mutates `build/`**.

Environment overrides (all optional):

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default
export DEVECO_HOME=/Applications/DevEco-Studio.app/Contents/tools
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
```

The bootstrap script accepts either `Contents/sdk/default` or its parent
`Contents/sdk`, and records the normalized SDK roots in its manifest.

### 3.1. Toolchain checkpoint (2026-10-03)

HarmonyOS 7 uses API 26; the official download center currently lists
[DevEco Studio 26.0.0.851 Release](https://developer.huawei.com/consumer/cn/download/deveco-studio).
The bootstrap and standalone configure scripts now use the API 26 SDK layout.
Bootstrap and both ABI configure operations completed successfully with this SDK.

The previous DevEco 6.1.1 SDK reported API 24 / version 6.1.1.125. The newly
installed DevEco 26.0.0 SDK reports API 26 / version 26.0.0.105. Both SDKs
use OHOS Clang 15.0.4 and libc++ 15004. The API 26 feature report is saved at
`build/harmonyos/cxx20-probe-api26/report.json`.

Real-engine configuration passes after forwarding SDK parameters through
ExternalProject and the IPO test project. Both complete ABI engines linked,
ArkTS compiled, and a signed HAP installed on the MateBook. The first runtime
faults were duplicate NAPI module registration and video-driver selection.
Those were fixed; liblzma is now linked for the compressed title scene.
The MateBook's GLES calls returned null/zero through `libGLESv2`; changing the
renderer link to `libGLESv3` produced a valid OpenGL ES 3.2 context and stopped
the startup exit. The full-screen panel seen earlier was the system music panel,
not the lock screen; closing it made the game accessible. Real-device Chinese
rendering, world generation, save/load and road construction now work. Runtime
approval remains incomplete. An SDK upgrade alone does not resolve
the C++20 gaps below.

Measured bundled tools: Clang 15.0.4, libc++ 15004, CMake 3.28.2, Ninja 1.13.2,
Node 24.14.1, Hvigor 6.26.8, ohpm 26.0.0.630.

To build the current compression and font dependencies, cache the
manifest-pinned archive and run the real build recipe:

```bash
mkdir -p build/harmonyos/deps-cache
curl -fL https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.gz \
  -o build/harmonyos/deps-cache/xz-5.6.3.tar.gz
python3 scripts/harmonyos/build-runtime-deps.py --dep liblzma \
  --sdk-root /Applications/DevEco-Studio.app/Contents/sdk/default
curl -fL https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz \
  -o build/harmonyos/deps-cache/freetype-2.13.3.tar.xz
python3 scripts/harmonyos/build-runtime-deps.py --dep freetype \
  --sdk-root /Applications/DevEco-Studio.app/Contents/sdk/default
python3 scripts/harmonyos/stage-assets.py
```

The recipe verifies the archive against `harmonyos/dependencies/manifest.json`
before extraction, produces real static libraries for both ABIs, and records
build provenance and licenses. Asset staging verifies the official OpenGFX2,
OpenSFX and OpenMSX packages and processes the upstream metadata templates.
OpenMSX's MIDI files must be extracted: the upstream music search does not scan
tar archives. Staging also verifies the pinned Debian TimGM6mb archive and includes
the soundfont and its GPL-2.0 notice. TinySoundFont 0.9 is vendored at commit
`853a0a171759f1ddba0de1442133a75912bbeffa` with its MIT license and provenance.

SDK-only feature checks give the same results for both ABIs:

| Feature | Default | `_LIBCPP_ENABLE_EXPERIMENTAL` |
|---|---|---|
| Concepts, scalar defaulted `<=>`, tuple `<=>` | pass | pass |
| Implicit dependent `typename` (P0634R3) | fail | fail |
| Parenthesized aggregate initialization, aggregate CTAD with a base | fail | fail |
| ranges `count_if`, `lower_bound`, `binary_search` | fail | pass |
| array, vector, string `<=>` | fail | fail |
| `<source_location>` | fail | fail |

The independently repeated checks give these results with both the API 24
and API 26 SDKs. They are measurements of those specific installed builds,
not a guarantee for every future API 26 SDK. Repeat them after a toolchain
update:

```bash
python3 scripts/harmonyos/probe-cxx20.py \
  --sdk-root /Applications/DevEco-Studio.app/Contents/sdk/default \
  --abi arm64-v8a --abi x86_64 \
  --output build/harmonyos/cxx20-probe-current-sdk
```

Use the new installation's SDK root if it differs. The probe accepts either
`native/` or `openharmony/native/` beneath that root. It writes source files,
object files, per-feature compiler logs and `report.json`; it excludes this
project's compatibility headers. Exit 1 means at least one selected probe
failed; exit 2 means the probe could not run. Passing these checks establishes
only those features, not complete C++20 support or successful engine linking
and execution.

The engine keeps C++20 enabled. Compatibility changes explicitly add
dependent `typename`, enable libc++ 15's experimental ranges algorithms,
and specify the comparison category for affected defaulted container
comparisons. The existing local `source_location` header remains necessary.
These changes must also pass the complete engine build and runtime checks.

For HarmonyOS 7 adaptation, the
[official upgrade guide](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation)
recommends matching IDE and command-line toolchains, checking API behavior
changes (including `targetSdkVersion` isolation), and verifying devices on
both old and new OS versions. DevEco 26 also adds native debugging startup
acceleration, minidump/coredump parsing, HWASan diagnostics and emulator CLI
input/layout support; see its
[release notes](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/deveco-studio-new-features-2600).

---

## 4. Build the game target (both ABIs)

The port ships **two ABIs in one HAP** — `arm64-v8a` (physical tablet / 2-in-1)
and `x86_64` (emulator / x86 PC). The signing template is
`harmonyos/build-profile.json5.example`; copy it to `build-profile.json5`, fill
in your own debug signing material, then build. The local signing file is
ignored by Git.

```bash
# Configure + build each ABI (Debug or Release)
bash scripts/harmonyos/build-target.sh arm64-v8a Debug
bash scripts/harmonyos/build-target.sh x86_64  Debug
# or Release:
bash scripts/harmonyos/build-target.sh arm64-v8a Release
bash scripts/harmonyos/build-target.sh x86_64  Release

# Configure only (dependency-resolution boundary, no compile):
bash scripts/harmonyos/build-target.sh arm64-v8a Release --configure-only
```

Exit codes: `0` configure/build ok; `2` bad args; `3` bootstrap/toolchain
environment failed; `4` platform guard triggered (a forbidden generic-Unix
source was pulled in — see `cmake/HarmonyOS.cmake`).

---

## 5. Package the HAP and inspect the release

```bash
# Assemble the dual-ABI HAP + all AppGallery-ready artifacts
bash scripts/harmonyos/package.sh Release     # or Debug

# Gate the result (fails with precise message on any violation)
bash scripts/harmonyos/inspect-release.sh build/harmonyos/release/Release
# Prove the gate fires when an ABI is removed:
bash scripts/harmonyos/inspect-release.sh build/harmonyos/release/Release --self-test
```

`package.sh` orchestrates hvigor directly:

```bash
node <DevEco>/Contents/tools/hvigor/bin/hvigorw.js assembleHap \
     --mode module -p product=default -p buildMode=release
```

Artifacts land in `build/harmonyos/release/<Mode>/`:

| Artifact | Description |
|---|---|
| `openttd-15.3-<git>.hap` | dual-ABI HAP (`entry-default-unsigned.hap` before rename) |
| `symbols/{arm64-v8a,x86_64}/*.so` | **unstripped** native libs (symbolication, §8) |
| `symbols/buildid-map.json` | ELF BuildID → library map |
| `native-build-manifest.json` | verified compiler policy and packaged/native/symbol Build IDs |
| `source/openttd-15.3-<git>-src.tar.gz` | `git archive` of the port branch |
| `sbom/` (`sbom.spdx.json`, `sbom.cyclonedx.json`, `manifest.json`) | SBOMs + dependency manifest |
| `NOTICES.md`, `SOURCE_OFFER.txt` | GPLv2 notices + source offer |
| `SHA256SUMS` | sha256 of every artifact |
| `release-manifest.json` | machine-readable release description |

Key contract points (W4.T20):

- Rawfile data (baseset + `src/lang/*.lng` via `strgen`) is **regenerated on
  every package run and then deleted** from the source tree — `git status`
  stays clean, `build/` is the only mutation.
- hvigor **strips** native libs in the HAP (`DoNativeStrip`), but the shipped
  libs keep the **same BuildID** as the unstripped intermediates — that is the
  debugger correlation contract.
- `inspect-release.sh` checks (R1–R9): bundle `org.openttd.openttd`, version
  `15.3` / code `15000300`, `deviceTypes` contains `tablet` + `2in1`,
  `ohos.permission.INTERNET` only, both ABIs present in `libs/`, required
  rawfile resources, SBOM/license files, and no secrets (`[/]Users/`, `.p1[2]`,
  `PRIVATE KEY`).

---

### 5.1 Native performance builds

Native Debug and Release builds default to `-O2 -g`, including DevEco's normal
Debug launch. `--perf` enables bounded per-second diagnostics;
`--unoptimized-debug` deliberately restores `-O0` for a Debug comparison.
See [the performance guide](performance.md) for diagnostic HAP commands,
artifact verification, counter interpretation and physical-device comparison.

## 6. Host tests (no device required)

All host suites run entirely on the build host and need no HarmonyOS device.
Run every suite that exists; each exits nonzero on failure:

```bash
bash scripts/harmonyos/test-platform-guards.sh        # guard/configure policy
bash scripts/harmonyos/test-desktop-input.sh          # keyboard/mouse/trackpad
bash scripts/harmonyos/test-touch-gestures.sh         # touch/gesture recognizer
bash scripts/harmonyos/test-input-matrix.sh           # input matrix (IME, stylus...)
bash scripts/harmonyos/test-storage-font-locale.sh    # storage/font/locale
bash scripts/harmonyos/test-storage-contract.sh       # packaged-data manifest
bash scripts/harmonyos/test-audio-driver.sh           # OHAudio hot paths
bash scripts/harmonyos/test-video-driver.sh           # EGL dirty-rect/recreate
bash scripts/harmonyos/test-render-contract.sh        # render contract fixtures
bash scripts/harmonyos/test-bridges.sh                # text-input/picker/system bridges
bash scripts/harmonyos/test-lifecycle-bridge.sh       # lifecycle + thread ownership
bash scripts/harmonyos/test-network-diagnostics.sh    # protocol constants + policy
bash scripts/harmonyos/test-diagnostics-policy.sh     # security/diagnostics policy
```

Optional flags: `-v` (verbose) on `test-network-diagnostics.sh`,
`test-diagnostics-policy.sh`, `test-platform-guards.sh`;
`--refresh-manifest` on `test-storage-contract.sh` (regenerates the committed
`manifest-expected.json` idempotently).

The full upstream Catch2/regression/save-load/protocol host suite runs in the
normal OpenTTD host build (`build/host-test`):

```bash
cd build/host-test && ctest --output-on-failure   # 96/96 green at commit f501aff507
```

`scripts/harmonyos/ci-local.sh` runs the always-green local CI lanes:
script syntax check, `bootstrap.sh --check-only`, tracked-file secret scan,
workflow structural policy, and workflow YAML parse.

---

## 7. Physical-device release test commands

The following are the planned release-suite commands. `test-device.sh` has
not yet been implemented; current MateBook debugging uses DevEco and its bundled
HDC directly. See §12 for current evidence:

```bash
# tablet profile
bash scripts/harmonyos/test-device.sh "${HARMONY_TABLET_DEVICE}" tablet
# 2-in-1 / PC profile
bash scripts/harmonyos/test-device.sh "${HARMONY_2IN1_DEVICE}" 2in1
```

where `HARMONY_TABLET_DEVICE` / `HARMONY_2IN1_DEVICE` are the `hdc` serials of
the two required physical devices. The device suite must: query and record the
real model/OS/API/ABI/display/density; execute cold launch, desktop/touch
workflows, resize/freeform/split/fullscreen, orientation/DPI, IME, audio,
save/reload, picker, clipboard, URL, network and accessibility-label cases;
and return machine-readable PASS for every case. Lifecycle/performance/audio/
multiplayer soak budgets live in the plan (Todo 23) and are likewise gated on
the same two physical profiles. Neither Previewer nor emulator may substitute
for release approval.

Manual device access (useful once hardware is attached) requires the DevEco
`hdc` binary — it is **not** on `PATH` on this machine:

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/toolchains/hdc
"$HDC" list targets                          # list attached device serials
"$HDC" install -r <signed>.hap               # install a signed HAP
"$HDC" shell aa start -a EntryAbility -b org.openttd.openttd
```

---

## 8. Debug signing and crash symbolication

### Debug signing

Full procedure: [`docs/harmonyos/debug-signing.md`](./debug-signing.md).
Summary (W1/§4 of the release guide):

1. Generate a throwaway key outside the repo: `/tmp/openttd-ohos-debug-signing/`.
2. Create the matching debug certificate in AppGallery Connect and download
   `profile.p7b`.
3. Copy `harmonyos/build-profile.json5.example` to
   `harmonyos/build-profile.json5`, fill in the `signingConfigs` fields, and
   reference the config from the product. Keep the filled-in file local.
4. Verify signed vs unsigned: a signed HAP contains the `EBBG` signature block;
   an unsigned one does not.

`package.sh` deliberately produces the **unsigned** staged HAP so the build is
green in CI without credentials. Release signing requires the AGC manual flow
(release certificate + release profile for the exact `org.openttd.openttd`
bundle); there is no self-serve release profile, and only the signed HAP may be
uploaded to AppGallery.

### Symbolication

Native crash stacks from a shipped HAP resolve against the **unstripped**
intermediates collected by `package.sh`:

```bash
# Release artifacts always carry symbols:
ls build/harmonyos/release/Release/symbols/{arm64-v8a,x86_64}/
cat build/harmonyos/release/Release/symbols/buildid-map.json
```

- The unstripped intermediate and the stripped shipped lib keep the **same
  `.note.gnu.build-id`** — correlate a crash by BuildID before running the
  debugger.
- Use `llvm-symbolizer`/`lldb` against the unstripped `.so` for the matching
  ABI; `buildid-map.json` maps ELF BuildID → library name/path.
- Symbol index generation is a pure-python ELF parser (no `llvm-readelf`
  dependency; only `nm` and `python3` are guaranteed present).

---

## 9. Dependency updates and upstream-delta policy

### Dependency updates

Native third-party libraries are governed by `docs/harmonyos/dependencies.md`
and `harmonyos/dependencies/`:

- The dependency set, versions, hashes and license info are pinned in the
  governance artifacts under `harmonyos/dependencies/` (see `dependencies.md`
  §“Governance artifacts”).
- `scripts/harmonyos/deps/run-deps.sh` fetches and verifies each recipe in
  `scripts/harmonyos/deps/recipes/` (zlib, libpng, freetype, harfbuzz, icu,
  liblzma, lzo, opus, opusfile, libcurl, threads, libcxx, …).
- `scripts/harmonyos/check-dependency-manifest.sh` enforces the manifest;
  `scripts/harmonyos/check-licenses.sh` gates license/SBOM consistency.
- **Update procedure:** (1) change the recipe in
  `scripts/harmonyos/deps/recipes/<lib>.sh` (new version + pinned hash); (2)
  re-run `deps/run-deps.sh` to fetch/verify; (3) re-run
  `check-dependency-manifest.sh` and `check-licenses.sh`; (4) rebuild both ABIs
  and rerun the host suites (§6) before packaging (§5). Never bump a
  dependency without updating its hash and license record in the same change.

### Upstream-delta policy

The port tracks pinned OpenTTD **15.3**; the baseline and provenance are
documented in [`docs/harmonyos/source-provenance.md`](./source-provenance.md)
(upstream remote, `git fsck`, ancestor check). The delta policy:

- **Allowed platform changes only** under `src/os/harmonyos`, the Harmony
  driver files (`src/video/harmonyos_*`, `src/sound/harmonyos_s.cpp`),
  the app shell (`harmonyos/`), CMake gates (`cmake/HarmonyOS.cmake`), and
  `scripts/`, `tests/`, `docs/`.
- **Any edit outside that allowlist** must be called out in
  `docs/harmonyos/upstream-delta.md` with its necessity and regression
  coverage. As of this guide, `src/network/core/config.h` is byte-identical to
  upstream (verified, no protocol drift).
- No SDL/engine dependency, gameplay/protocol/save-format redesign, excluded
  device target, secret, proprietary asset, analytics or unrelated refactor may
  enter the branch (final scope-fidelity gate, plan F4).
- Keep commits atomic per subsystem and maintain buildability after each wave;
  never combine generated caches, credentials or evidence blobs with product
  commits.

---

## 10. Known limitations

| Limitation | Impact |
|---|---|
| **Physical-device gates unverified** (T22/T23) | MateBook debugging is active; tablet and full release PASS evidence are pending (see §12) |
| No `test-device.sh` deliverable committed | The device suite script itself is not present in the repo because Todo 22 was blocked before its commit |
| x86_64 emulator only | x86_64 ABI builds and packages, but is labeled supplemental; cannot substitute for physical-device approval |
| Unsigned packaging | `package.sh` outputs unsigned HAPs; release signing requires the manual AGC flow |
| Release store submission excluded | AppGallery submission is not started; requires signed HAP + privacy policy + passing device gates |
| No arm-linux-ohos sysroot | 32-bit ARM is warn-only in bootstrap; only `arm64-v8a` and `x86_64` are shipped |
| HarmonyOS-only sound/video | `harmonyos_s.cpp` / `harmonyos_v.*` compile only for HARMONYOS (host suites model, not run, the real drivers) |

---

## 11. Documentation validation

`scripts/harmonyos/test-docs-guide.sh` verifies this guide end-to-end:

```bash
bash scripts/harmonyos/test-docs-guide.sh        # documentation validation
bash scripts/harmonyos/test-docs-guide.sh -v     # verbose
```

It checks that every documented script and path exists, runs `bootstrap.sh
--check-only`, runs the existing host guard/input/storage/audio/video/bridge/
network test suites, and reports the physical-device gates (T22/T23) as
**BLOCKED** with the exact reason. The script **exits 0 for documentation
validation** while clearly distinguishing the blocked physical gates from
green lanes.

---

## 12. Physical-device verification — current state

A HUAWEI MateBook Pro is connected and reports HarmonyOS 7.0.0 / API 26.
The bundled HDC executable is under
`Contents/sdk/default/openharmony/toolchains/hdc`.

Verified during the current debug session:

- Full engine libraries for arm64-v8a and x86_64 compiled and linked; ArkTS and
  HAP packaging completed with warnings and no compile errors.
- Huawei developer login completed; debug certificate/profile generation,
  HAP signing and installation succeeded.
- Duplicate NAPI registration was fixed. Resource preparation, XComponent
  callbacks and the actual game engine entry ran on the physical MateBook.
- Engine logs identified an unavailable video-driver selection. The driver
  factory was corrected and liblzma was built to support the title savegame.
- Linking the renderer to `libGLESv3` fixes the real device's empty GLES calls.
  EGL now reports a current context with OpenGL ES 3.2 B312 / Maleoon 916.
  The title scene and normal world render on the device. The earlier full-screen
  obstruction was the system music panel, not a lock screen.
- FreeType 2.13.3 is linked for both ABIs. The system locale selects Traditional
  Chinese on this device; native font enumeration finds a font covering the
  required glyphs. System font candidates are cached once per process to avoid
  repeating enumeration for every savegame load.
- The Chinese main menu, a new 256 x 256 world, city navigation, F1 pause/resume
  and window maximization have been exercised. A sandbox save survived HAP
  updates and loaded successfully. The road save also survived a later update,
  restoring 1951-01-21, GBP 97,057, the built road and its paused state.
- Native API 26 touch MOVE events on this MateBook report `isPressed=false`.
  Using each point's DOWN/MOVE/UP type fixes prematurely ended gestures.
  A continuous touch swipe built a road connecting Dedston; the financial
  window records GBP 643 in construction costs.
- The HarmonyOS MIDI driver uses TinySoundFont and TimGM6mb with the existing
  OpenTTD MIDI parser and mixer. Theme and in-game tracks produce nonzero
  48 kHz stereo PCM and advance through the playlist. Audible output awaits
  listening confirmation; PCM logs alone are not audio approval.
- Normal in-game exit returns 0, notifies ArkTS through a thread-safe NAPI
  callback, and terminates the ability. The game window disappears and a
  subsequent launch starts a new engine process; the survey opt-out is retained.
- The online content directory fetches its real server list. Content downloads
  and multiplayer sessions remain unverified.
- Window hiding on this PC does not always emit UIAbility `onBackground`.
  Window visibility is now combined with ability foreground state to suspend
  the engine. On the physical device, hiding stops OHAudio and restoring restarts
  it. A world paused before hiding remains paused with the same date/funds; a
  running world resumes running after restoration.
- Native mouse input builds a road-connected depot, opens its vehicle list,
  buys exactly one MPS Regal bus and starts it. The live view shows the bus
  travelling on the road at 56 km/h. The vehicle world was saved separately as
  `Dedston Transport, 1951-12-06.sav`; the final HAP update restored its road,
  depot, one bus, paused state, date and GBP 89,516 funds. This does not establish
  station loading, transport profit or all vehicle types.
- PC mouse clicks also generate compatibility touch events. Event-source
  filtering removes the duplicate click while preserving explicit touchscreen
  events. The final build was checked with both native mouse input and explicit
  touchscreen input: mouse clicks queue one press/release pair, touchscreen
  taps open/load the save dialog, and a single tap places a road tile. Tool-type
  filtering is used only when the event source is unknown.
- The final signed HAP (`deveco-api26-mixed-input-build.log`) compiled in
  16 s 35 ms, installed and passed the checks above. All 142 packaged resource
  hashes match the staged manifest. Its normal exit again returned 0 and
  destroyed the game window; releasing an already-destroyed visibility
  listener does not prevent native shutdown.
- Trackpad/IME input, complete transport operation and stability checks
  remain pending.

Logs and build evidence are kept under `build/harmonyos/`. Existing contract
fixtures and library presence checks do not substitute for these runtime cases.
No tablet release evidence or complete release PASS is claimed.

---

## 13. Related documentation

| Document | Contents |
|---|---|
| `docs/harmonyos/release-guide.md` | AppGallery release flow (signing, privacy, store metadata, checklist) |
| `docs/harmonyos/debug-signing.md` | ephemeral debug key + AGC debug profile procedure |
| `docs/harmonyos/dependencies.md` | native dependency governance, recipes, update policy |
| `docs/harmonyos/source-provenance.md` | upstream 15.3 baseline + provenance verification |
| `docs/harmonyos/diagnostics-policy.md` | URL allowlist, HiLog privacy, crash watchers |
| `docs/harmonyos/input-matrix.md` | keyboard/mouse/touch/stylus/IME mapping matrix |
| `docs/harmonyos/render-contract.md` | legacy CPU render oracle and fixture contract |
| `docs/harmonyos/performance.md` | optimized native builds, diagnostic counters and device comparisons |
| `docs/harmonyos/storage-contract.md` | packaged-data / sandbox storage contract |
| `COMPILING.md` (upstream) | upstream compile guide (host platforms) |
