# HarmonyOS Diagnostics & Security Policy — OpenTTD 15.3 Port

This document is the **single source of truth** that locks the diagnostic,
security and dependency-governance contracts for the OpenTTD HarmonyOS port.
It is enforced by `scripts/harmonyos/test-diagnostics-policy.sh` in CI.

The policy covers:

1. HiLog domains / tags / privacy formatting
2. OpenTTD log-file location
3. HiAppEvent crash / freeze watcher contract
4. Symbol archive & BuildID handling
5. NAPI error envelopes
6. URL allowlist (`https`, `http` only)
7. Dependency & source-delta allowlists
8. Forbidden APIs, permissions and secrets

## 1. HiLog domains / tags / privacy formatting

OpenTTD's native diagnostics surface through **HiLog** (`hilog/log.h`,
`hilog_ndk.z`). Only the NAPI translation unit
(`harmonyos/entry/src/main/cpp/napi_init.cpp`) may include HiLog headers; all
other native code logs through the shared helpers.

| Contract | Value |
|----------|-------|
| `LOG_DOMAIN` | `0x0F00` (OpenTTD reserved application domain) |
| `LOG_TAG` | `"OpenTTD_Native"` (fixed, non-localised) |
| Level mapping | OpenTTD `Debug()` 0–2 → `OH_LOG_ERROR/WARN/INFO`; 3–10 → `OH_LOG_DEBUG` |
| Privacy marker | **every** `fmt` argument in a format string MUST carry `%{public}` or `%{private}` |

Rules:

- **No bare format specifiers.** `%s`, `%d`, `%x`, … without an explicit
  `%{public}` or `%{private}` marker are forbidden in any HiLog format string.
  This is the "private log fields are not printed public" guarantee: a value
  flagged `%{private}` is redacted in the public/system HiLog stream and never
  appears in shared logs.
- Default to `%{private}` for anything derived from user/game data (player
  names, company names, passwords/tokens, savegame paths, content metadata).
- Use `%{public}` only for safe diagnostic counters and fixed identifiers
  (domain, tag, internal state ordinals, signal numbers).

Reference: `hilog-guidelines-ndk.md`.

## 2. OpenTTD log-file location

OpenTTD writes its main log to `_log_file` which the port binds to the
**application sandbox**, never to `/data`, HOME, or any unrestricted path.

| Contract | Value |
|----------|-------|
| File | `<sandbox filesDir>/openttd.log` |
| Derivation | `_personal_dir + "openttd.log"` (see `src/fileio.cpp`) mapped to the HarmonyOS `filesDir` sandbox |
| Crash logs | `<sandbox filesDir>/crash<YYYYmmddHHMMSS>.json.log` (see `src/crashlog.cpp`) |
| Encoding | UTF-8; lines prefixed `[YYYY-MM-DD HH:MM:SS] ` (see `GetLogPrefix`) |

A fixture must never open a log at an absolute external path; `_log_file` and
crash-log names are derived solely from the sandbox personal directory.

## 3. HiAppEvent crash / freeze watcher contract

The native port registers a **HiAppEvent** watcher so that crashes and freezes
are observable platform-side and correlated with the OpenTTD crash log.

| Contract | Value |
|----------|-------|
| Watcher name | `"openttd_diagnostics"` |
| Event domain | `HiAppEvent::domain` (system domain for APP_CRASH / APP_FREEZE) |
| Watched events | `APP_CRASH`, `APP_FREEZE`, `APP_LAUNCH` |
| Subscription | `HiAppEvent` watcher with `eventTypes = FAULT\|LIFECYCLE` |
| Correlation | crash `eventId` recorded into the OpenTTD crash-log JSON so the two are joinable offline |

Implementation notes:

- The OpenTTD crash handler (`src/os/harmonyos/crashlog_harmonyos.cpp`) keeps
  the existing signal-setup/longjmp structure but intentionally produces an
  **empty stacktrace** because HarmonyOS libc has no `execinfo`/`backtrace`.
- Crash JSON is written to the sandbox (`CreateFileName(".json.log")`) exactly
  as on other platforms.
- A freeze is detected platform-side (main-thread watchdog) and reported via
  `APP_FREEZE`; the watcher contract binds both to the same eventId namespace.

Reference: `hiappevent-watcher-crash-events-ndk.md`, `use-napi-about-crash.md`.

## 4. Symbol archive & BuildID handling

Release debuggability must not leak game symbols into the shipped HAP.

| Contract | Value |
|----------|-------|
| HAP native libs | **stripped** (`libentry.so`, `libopenttd.so`) — no `.symtab`/`.debug_*` |
| BuildID | retained in the stripped lib (`.note.gnu.build-id`) so it can be correlated back to the build |
| Symbol archive | an **offline index** (`build/harmonyos/symbols/symbols-<abi>.index`) listing each built `.so`'s BuildID + exported symbol addresses/names |
| Indexing input | the **unstripped** build outputs in `build/…/intermediates/…/obj/<abi>/`, produced by the release build, never by unzipping the HAP |
| Correlation | crash log records `openttd.build_date` + hash; the symbol index maps those to BuildID → symbol table |

Rules:

- The symbol index is generated **without entering the HAP**: it is built from
  the intermediate (unstripped) objects before/independently of packaging.
- Strip happens only in the release packaging step; the BuildID (set at link
  time) is preserved through the strip.
- A device on-site can symbolize a crash by `BuildID` against the offline
  index, without shipping symbols to the device.

## 5. NAPI error envelopes

All native → ArkTS calls return a **structured error envelope** so failures
round-trip without lossy string-only messages and without `any`.

```ts
interface NativeError {
  code: number;      // stable, documented error code (0 = success)
  domain: string;    // e.g. "Lifecycle", "Surface", "IO"
  message: string;   // human-readable, `%{private}`-safe (no PII)
}
```

| Contract | Value |
|----------|-------|
| Return shape | `{ code, domain, message }` object; success uses `code: 0` |
| Native side | built with `napi_create_error`/`napi_create_object` + `napi_set_named_property` |
| ArkTS side | typed `interface NativeError`, never `Object`/`Record` |
| Privacy | `message` never embeds player names, tokens or absolute sandbox paths |
| Nonfatal | picker/I/O cancellations return `code != 0` + a typed domain, NOT an exception |

A fixture compiles a `NativeError`-shaped struct, serializes it to a NAPI-style
JSON object and reads it back, asserting byte/field identity round-trips.

## 6. URL allowlist (`https`, `http` only)

All outbound HTTP(S) traffic (content download, master server, survey, …)
uses the port's pinned `libcurl`. Protocols are strictly limited.

| Allow | Deny |
|-------|------|
| `https://` | `file://`, `ftp://`, `gopher://`, `data:`, arbitrary schemes |
| `http://` (per OpenTTD config allowlist) | TLS downgrade / cleartext login |

Rules:

- libcurl must bind the **HarmonyOS system trust store**; a bundled CA bundle
  is forbidden (see `docs/harmonyos/dependencies.md` `tlsPolicy`).
- A static scan rejects any non-(http|https) URL scheme in native and bridge
  sources.

## 7. Dependency & source-delta allowlists

### 7.1 Dependency allowlist

Pinned native dependencies live in `harmonyos/dependencies/manifest.json`
(see `docs/harmonyos/dependencies.md`). **No new third-party native
dependency** may be added outside this manifest, and the set is:

`threads, libcxx, zlib, liblzma, libpng, freetype, harfbuzz, icu, libcurl,
opus, opusfile, lzo`

Explicitly excluded: SDL, Allegro, FluidSynth, Fontconfig, Breakpad.

### 7.2 Source-delta allowlist

Only the following paths may differ from the upstream `15.3` tag:

```
harmonyos/
src/os/harmonyos/
docs/harmonyos/
scripts/harmonyos/
cmake/HarmonyOS.cmake
cmake/CompileFlags.cmake   (guarded "AND NOT HARMONYOS" edits only)
cmake/InstallAndPackage.cmake
cmake/Options.cmake
src/music/CMakeLists.txt   (guarded edits only)
src/os/CMakeLists.txt      (guarded edits only)
src/os/unix/CMakeLists.txt (guarded edits only)
CMakeLists.txt             (guarded "AND NOT HARMONYOS" edits only)
.github/workflows/harmonyos-build.yml
.gitignore
```

A source whose path falls outside this allowlist (e.g. a new file under
`src/network/`) is rejected by the delta check.

## 8. Forbidden APIs, permissions and secrets

### 8.1 Forbidden native APIs

Static policy scan rejects any use of the following in `src/os/harmonyos/`
and the native bridge (`harmonyos/entry/src/main/cpp/`):

| API | Reason |
|-----|--------|
| `fork(`, `vfork(` | No process spawning in the HarmonyOS sandbox |
| `exec*` (`execvp`, `execve`, `execl`, …) | See above; also blocks `OSOpenBrowser`-style escapes |
| `system(`, `popen(` | Shell escaping, never available |
| `dlopen(` with a non-allowlisted / dynamic path | Only the pinned runtime split of `libopenttd.so` is permitted; **arbitrary** `dlopen` is forbidden |
| `execinfo.h`, `backtrace(`, `backtrace_symbols(` | HarmonyOS libc has no `execinfo` |

The single allowed `dlopen` is the fixed, allowlisted `dlopen("libopenttd.so", …)`
in `napi_init.cpp` (the two-library split). Every other `dlopen` occurrence is
a policy violation.

### 8.2 Permission allowlist

The HAP may declare **only** the `ohos.permission.INTERNET`
(`system_grant`) permission. Any unrelated permission (location, camera,
microphone, storage, …) in `module.json5` is rejected. This is the
"unreviewed permissions" gate — every permission must be reviewed and
justified before it may be added.

### 8.3 Secrets scan

The tracked tree must not contain private-key material, high-entropy tokens,
or CI secrets. The scan looks for, at minimum:

- `BEGIN ... PRIVATE KEY` / `BEGIN RSA PRIVATE KEY` blocks
- AWS access-key patterns (`AKIA…`, `ASIA…`)
- GitHub tokens (`ghp_…`)
- `.p12` / `.p7b` / `.cer`/`.csr` signing material leaked into tracked files
- `password`/`token`/`api_key` literals assigned real-looking secrets

Signing material lives **outside** the repo (`/tmp/openttd-ohos-debug-signing/`,
gitignored) — see `docs/harmonyos/debug-signing.md`.

## Enforcement

`scripts/harmonyos/test-diagnostics-policy.sh` statically enforces every
section above and runs negative fixtures:

- a fixture that calls `execvp` → policy exits nonzero;
- a fixture that requests an unrelated permission → policy exits nonzero;
- a fixture with a leaked secret → policy exits nonzero;
- a fixture with non-allowlisted URL/dlopen/execinfo → policy exits nonzero.

Acceptance gate: the test reports PASS only when the real sources are clean
and every negative fixture is rejected.
