# HarmonyOS Storage, Packaged-Resource and User-Document Contract

This document is the single source of truth for **where** the OpenTTD
HarmonyOS port reads and writes data. It maps every OpenTTD search path and
subdirectory to the HarmonyOS app sandbox, defines how immutable packaged game
data is shipped (rawfile) and materialized, and specifies the
`DocumentViewPicker` import/export bridge, upgrade markers, free-space errors
and URI temporary-permission behavior.

The contract is enforced by `scripts/harmonyos/test-storage-contract.sh`
(host-side, no device required) against the fixtures under
`scripts/harmonyos/test-fixtures/storage/`.

## Scope and hard rules

1. **No `$HOME`, no XDG, no external unrestricted paths.** HarmonyOS Stage
   apps have no home directory and no shared/external storage. Every writable
   path is derived from the `Context` (`filesDir`, `cacheDir`, `tempDir`,
   `databaseDir`, `preferencesDir`). The upstream branches in
   `src/fileio.cpp:756-801` (`GetHomeDir()`, `XDG_DATA_HOME`,
   `~/.local/share`, `~/.config`) and `src/fileio.cpp:911-932`
   (`config_home`) MUST be compiled out with `#ifdef HARMONYOS`; `GetHomeDir()`
   returns an empty string on HarmonyOS.
2. **Read-only packaged data never leaves the HAP.** Base graphics/sounds,
   language files, basesets, AI/GS scripts shipped with the app live in
   `resources/rawfile/` and are read through the NDK `OH_ResourceManager`
   rawfile API. They are copied into the sandbox **only** when a concrete
   filesystem path is required by an upstream code path, and then only through
   the atomic materialization protocol in
   [Materialization](#first-run-materialization-and-upgrade-markers).
3. **Everything under one sandbox root.** All persistent paths below are
   lexically under `<filesDir>`. Code MUST NOT construct paths from user
   input without passing through the path guard
   [Path containment](#path-containment-rule) and MUST NOT follow symlinks.

## Sandbox roots

| Root | Derivation | Durability | Purpose |
|------|-----------|------------|---------|
| `<filesDir>` | `context.filesDir` (`/data/storage/el2/base/haps/entry/files`) | persistent, app-update safe | personal dir, saves, scenarios, content, config |
| `<cacheDir>` | `context.cacheDir` (`/data/storage/el2/base/haps/entry/cache`) | system-purgeable | decode caches, base64/graphics scratch |
| `<tempDir>` | `context.tempDir` (`/data/storage/el2/base/temp`) | cleared on app exit | picker import/export staging |
| `<rawfile>` | HAP `resources/rawfile/` | read-only, immutable per install | packaged game data (no path) |
| `<bundleCodeDir>` | `context.bundleCodeDir` (`/data/storage/el1/bundle/...`) | read-only | native libs; never scanned for game data |

The encryption level `el2` is mandatory for user-created content (saves,
scenarios, screenshots). Nothing user-visible is ever written below `el1`.

## OpenTTD subdirectory mapping

`src/fileio_type.h:88-108` enumerates `Subdirectory`; the relative layout in
`src/fileio.cpp:38-56` is preserved **verbatim** under the personal root so
upstream `FioGetDirectory`/`FioFindDirectory` semantics keep working.

| `Subdirectory` | Relative (unchanged) | HarmonyOS resolved path | Writable? |
|----------------|----------------------|-------------------------|-----------|
| `BASE_DIR` | `` | `<filesDir>/openttd/` | yes |
| `SAVE_DIR` | `save/` | `<filesDir>/openttd/save/` | yes |
| `AUTOSAVE_DIR` | `save/autosave/` | `<filesDir>/openttd/save/autosave/` | yes |
| `SCENARIO_DIR` | `scenario/` | `<filesDir>/openttd/scenario/` | yes |
| `HEIGHTMAP_DIR` | `scenario/heightmap/` | `<filesDir>/openttd/scenario/heightmap/` | yes |
| `OLD_GM_DIR` | `gm/` | `<filesDir>/openttd/gm/` (legacy, empty) | yes |
| `OLD_DATA_DIR` | `data/` | `<filesDir>/openttd/data/` (materialized copies) | yes |
| `BASESET_DIR` | `baseset/` | rawfile first, then `<filesDir>/openttd/baseset/` | user dir yes |
| `NEWGRF_DIR` | `newgrf/` | rawfile first, then `<filesDir>/openttd/newgrf/` | user dir yes |
| `LANG_DIR` | `lang/` | rawfile first, then `<filesDir>/openttd/lang/` | user dir yes |
| `AI_DIR` | `ai/` | rawfile first, then `<filesDir>/openttd/ai/` | user dir yes |
| `AI_LIBRARY_DIR` | `ai/library/` | rawfile first, then `<filesDir>/openttd/ai/library/` | user dir yes |
| `GAME_DIR` | `game/` | rawfile first, then `<filesDir>/openttd/game/` | user dir yes |
| `GAME_LIBRARY_DIR` | `game/library/` | rawfile first, then `<filesDir>/openttd/game/library/` | user dir yes |
| `SCREENSHOT_DIR` | `screenshot/` | `<filesDir>/openttd/screenshot/` | yes |
| `SOCIAL_INTEGRATION_DIR` | `social_integration/` | not shipped; disabled on HarmonyOS | — |
| `DOCS_DIR` | `docs/` | `<filesDir>/openttd/docs/` (generated) | yes |

## Search path mapping

`src/fileio_type.h:113-127` enumerates `Searchpath`. On HarmonyOS the vector
of *valid* search paths is reduced to exactly two plus a virtual layer:

| `Searchpath` | HarmonyOS behavior |
|--------------|--------------------|
| `SP_WORKING_DIR` | **disabled** — sandboxed apps have no meaningful CWD; `_do_scan_working_directory = false` |
| `SP_PERSONAL_DIR_XDG` | **compiled out** (`USE_XDG` off) |
| `SP_PERSONAL_DIR` | `<filesDir>/openttd/` |
| `SP_SHARED_DIR` | **disabled** — no shared-files concept |
| `SP_BINARY_DIR` | **disabled** — never scans `bundleCodeDir` |
| `SP_INSTALLATION_DIR` | **virtual** — routed to the rawfile catalog via `OH_ResourceManager` (see below) |
| `SP_APPLICATION_BUNDLE_DIR` | **virtual** — same rawfile catalog |
| `SP_AUTODOWNLOAD_DIR` | `<filesDir>/openttd/content_download/` |
| `SP_AUTODOWNLOAD_PERSONAL_DIR` | `<filesDir>/openttd/content_download/` (identical root) |
| `SP_AUTODOWNLOAD_PERSONAL_DIR_XDG` | **compiled out** |

### Virtual installation layer (rawfile)

`SP_INSTALLATION_DIR`/`SP_APPLICATION_BUNDLE_DIR` cannot be real directory
paths because rawfile entries have no filesystem location. The port therefore
adds a thin `FioOpenFile`/`FioFindFullPath` interposition: before falling back
to `<filesDir>/openttd/<subdir>`, a lookup consults the packaged manifest
(`packaged-manifest.json` generated into rawfile at build time). If the
relative path matches, the file is opened with
`OH_ResourceManager_OpenRawFile` and the handle is wrapped in a `FileHandle`.
Consequences:

- `FileExists` on the virtual layer returns true iff the rawfile catalog lists
  the entry (no `stat` possible).
- `FioFindDirectory` returns the real `<filesDir>` directory when the user has
  added content there; otherwise the subdirectory does not "exist" — matching
  upstream semantics of "first valid directory".

## First-run materialization and upgrade markers

A small number of upstream code paths require real filesystem paths (e.g.
`openttd.grf`/`sample.cat` reads, tar/base-set extraction). For these files
only, the port materializes them from rawfile into
`<filesDir>/openttd/data/` (and `baseset/`, `lang/` as needed) exactly once
per install, atomically.

### Marker file

`<filesDir>/openttd/.storage-version` is a text file, written atomically:

```
STORAGE_VERSION=<uint>
RESOURCE_GEN=<uint>          # packaged rawfile generation (bump on any packaged change)
MANIFEST_SHA256=<hex>        # sha256 of the source packaged-manifest.json
COMPLETED=1
```

`STORAGE_VERSION` is the contract/protocol version (currently `3`, see the
fixtures). `RESOURCE_GEN` is bumped by the build whenever the set or bytes of
packaged rawfile data changes; the fixture manifest carries the same value.

### Materialization protocol (per entry)

For each manifest entry `(relpath, size, sha256)`:

1. Compute required space = sum of all entry sizes + headroom
   (`MAX(64 MiB, 8% of total)`). Query `statvfs(<filesDir>)`; if
   `f_bavail * f_frsize < required` → fail the whole materialization with
   typed `LOW_SPACE` (see [Free-space errors](#free-space-errors)). Nothing is
   written.
2. Write `<dest>.partial.<sha16>` (copying from the rawfile handle). After each
   entry, `fsync()` the file and the containing directory.
3. Verify the copied bytes' SHA-256 equals the manifest entry. On mismatch →
   delete the partial, fail with typed `IO_ERROR` (checksum), abort.
4. `rename(<dest>.partial.<sha16>, <dest>)` — atomic on the same filesystem.
5. After all entries: write `.storage-version` via tmp+`rename`.

Interruption at **any** step is safe:

- A leftover `<dest>.partial.*` file is ignored on the next run and removed
  during the next materialization pass.
- A complete-but-renamed `<dest>` whose marker was not yet written leaves
  `.storage-version` absent/old → the next run treats it as stale and
  **re-verifies every dest against the manifest SHA-256**; matching dests are
  kept (no rewrite), missing/mismatched dests are re-materialized.
- Packaged source bytes are never modified by any step, so packaged checksums
  are provably unchanged (asserted by the test).

### Stale-version handling

On launch the port reads `.storage-version`:

| Condition | Action |
|-----------|--------|
| file missing / unparsable | full materialization |
| `STORAGE_VERSION != 3` (contract evolved) | wipe `data/` copies, full materialization |
| `RESOURCE_GEN != packaged GEN` (app upgraded) | re-verify all dest checksums; re-materialize changed entries |
| `MANIFEST_SHA256` differs from current manifest | re-verify/re-materialize as above |
| `COMPLETED=1` and all three match | no-op — use materialized copies as-is |

Downgrade (install an older HAP over a newer one) is detected the same way:
the packaged `RESOURCE_GEN` is *lower* than the marker → mismatch → the
materialized tree is rebuilt to match the downgraded package exactly. The
marker is never trusted as "fresh" without also matching the current manifest
hash.

## Free-space errors

All sandbox writes route through one gate. The gate returns a **typed,
nonfatal** result rather than throwing/crashing:

| Code | Meaning | Recovery |
|------|---------|----------|
| `LOW_SPACE` | `statvfs` free space below required + headroom, or `ENOSPC` during copy | delete partials, surface a `LOW_SPACE` notice with free/required bytes; no retry loop |
| `IO_ERROR` | `statvfs`/read/write/fsync/rename failure | delete partials, surface typed error with errno |
| `PATH_ESCAPE` | user-supplied name fails the path guard | typed error, nothing written |
| `OK` | success | — |

A failed materialization MUST leave the filesystem in the same observable
state as before it started except for ignorable `.partial.*` files.

## Path containment rule

Every path that can be influenced by a user, a picked filename, a network
download or a savegame filename passes through `SanitizeRelative(name)`:

1. Reject NUL, `/` and `\` as *path separators*, a leading `.`, an empty name,
   and any exact `.` or `..` component. Names are single path components only
   (callers add them to a fixed base directory).
2. Reject `:` drive-letter prefixes and any component containing characters
   outside the portable filename set `[A-Za-z0-9._-]`.
3. Reject names starting with `~`.
4. After joining, assert the result is lexically under the sandbox root, and
   `realpath` the created file/dir to prove it did not escape via a symlink —
   if the real path is not under the root, the file is deleted and
   `PATH_ESCAPE` is returned.
5. Never create symlinks inside the sandbox.

## Content download

The online-content manager writes exclusively to
`<filesDir>/openttd/content_download/` (`SP_AUTODOWNLOAD_PERSONAL_DIR`,
same directory served as `SP_AUTODOWNLOAD_DIR`). Downloads land as
`<name>.partial.<sha16>` and are renamed only after the SHA-256 recorded by
the content server is verified. This directory is durable (not in `cacheDir`)
so downloaded NewGRFs survive a cache purge; a system-initiated cleanup of
`cacheDir` therefore never removes user-downloaded content.

`cacheDir` is used for transient scratch only (decoded sprite caches, tar
scratch), each under `<cacheDir>/openttd/`, and may be wiped at any time.

## DocumentViewPicker import/export

Import and export are **asynchronous, cancellable** operations mediated by the
system picker UI. The native side never blocks; results are delivered on the
JS thread via a **cancellable TSFN bridge**.

### URI temporary-permission behavior

- `DocumentViewPicker.select()` / `save()` return `file://` URIs with a
  **temporary** read (select) or write (save) grant.
- The grant is valid only for the current process lifetime / URI validity
  window. URIs MUST NOT be persisted; after app relaunch (or picker
  re-entry) a previously returned URI is invalid.
- Every picked URI is consumed exactly once: the file is copied into the
  sandbox immediately, then the URI is dropped.
- Using an expired/invalid URI yields the typed, nonfatal result
  `INVALID_URI` — it is never a fatal crash and never retried automatically.

### Import (user picks a save/scenario into the app)

1. User taps "Import save" → JS calls the native import entry point with a
   `pendingJobId`.
2. JS invokes `DocumentViewPicker.select()`.
3. **Cancel:** the picker is dismissed (system back, or explicit cancel) →
   `select()` rejects/returns empty → the bridge resolves the pending job with
   typed `CANCELLED`. No sandbox write happens, no error dialog.
4. **Success:** for each URI, JS streams/copies the content into a temp
   staging file under `tempDir`, then hands the staging path to native, which
   atomically moves it into `SAVE_DIR`/`SCENARIO_DIR` (path guard applied to
   the picked display name; the display name is sanitized before use).
5. Result (`OK` / `CANCELLED` / `INVALID_URI` / `LOW_SPACE` / `IO_ERROR`) is
   returned to the UI as a typed value.

### Export (app writes a save/scenario to a user-chosen location)

1. User taps "Export save" → native writes the document to a staging file in
   `tempDir` (sandbox temp, cleared on exit).
2. JS calls `DocumentViewPicker.save()` with `DocumentSaveOptions`
   (`newFileNames = [<sanitized name>]`, `fileSuffixFilters`).
3. **Cancel:** user dismisses the save dialog → typed `CANCELLED`; staging file
   is removed.
4. **Success:** the system writes the staged file to the user location; native
   removes the staging copy. The URI's temporary grant expires immediately
   after.

### Cancellable TSFN bridge specification

Lifecycle: `napi_create_threadsafe_function` with max_queue_size 1,
`napi_tsfn_nonblocking`. A `napi_async_work` or a native job thread runs the
blocking operation (picker callback delivery on the JS side, or native copy).
The bridge owns the following states:

| State | Meaning |
|-------|---------|
| `PENDING` | job started; no result yet |
| `CALLING` | result enqueued, JS callback pending |
| `DONE` | JS callback delivered; job complete |
| `ABORTED` | job cancelled or bridge torn down |

Cancellation rules:

- If the UI cancels before a result exists, native flips `PENDING→ABORTED`
  and releases the TSFN with `napi_release_threadsafe_function(env, fn,
  napi_tsfn_abort)` — no callback fires, no dangling `napi_value` is held.
- If the UI cancels after enqueue (`CALLING`), the JS callback is still
  delivered once with the typed `CANCELLED` result and the bridge is released
  with `napi_tsfn_release`.
- On app background-kill / ability destroy, the ability's `onDestroy` runs
  `napi_tsfn_abort` for every outstanding bridge so no callback can fire on a
  dead JS thread and no `napi_ref` leaks.
- Exactly one of `CALLING→DONE` or `→ABORTED` occurs per job; the pending job
  map is cleaned in the same call. No `napi_release_threadsafe_function` is
  ever called twice for the same bridge.

### Typed result envelope

Every picker bridge and every write gate returns the same union, which is
serialized to ArkTS as a discriminated object (`{ kind, detail?, bytes? }`):

```
OK | CANCELLED | INVALID_URI | LOW_SPACE | IO_ERROR | PATH_ESCAPE
```

`OK` may carry `bytes` for export previews. All other kinds carry a
human-readable `detail`. None of them throw across the bridge; the ArkTS
caller branches on `kind`.

## Test matrix (host-side, `scripts/harmonyos/test-storage-contract.sh`)

| Test | Contract rule exercised |
|------|-------------------------|
| `escape` | path guard rejects `../`, absolute, `.`/`..` components, `\`, drive letters, `~`; joined path stays under root |
| `atomic` | interruption simulation leaves `.partial`; relaunch recovers; packaged checksums unchanged; dest checksums match manifest |
| `stale` | old `STORAGE_VERSION` / changed `RESOURCE_GEN` → re-materialize |
| `lowspace` | simulated free space below required → typed `LOW_SPACE`, zero files written |
| `manifest` | fixture generated-resource manifest is complete (every packaged file listed, no extras, sha256 correct); incomplete fixture rejected |
| `picker` | cancel → typed `CANCELLED`; expired/invalid URI → typed `INVALID_URI`; both nonfatal |

## Fixture layout

```
scripts/harmonyos/test-fixtures/storage/
├── manifest-expected.json     # complete generated-resource manifest (fixture)
├── packaged/                  # immutable packaged rawfile tree (small stand-ins)
│   ├── data/openttd.grf
│   ├── data/sample.cat
│   ├── baseset/opengfx/base.grf
│   └── lang/english.txt
└── bad/
    ├── path-names.txt         # malicious names the path guard must reject
    └── incomplete-manifest.json  # manifest missing one entry (negative fixture)
```

`manifest-expected.json` mirrors the build-generated `packaged-manifest.json`
format and is regenerated by `scripts/harmonyos/test-storage-contract.sh
--refresh-manifest`; CI asserts it is complete and checksum-correct.

## Non-goals

- No auto-sync, no backup of the whole sandbox, no `distributedFilesDir`
  usage in this contract.
- No external/removable storage access.
- No migration of upstream `$HOME/.openttd` data (never existed on device).
- No `SP_SHARED_DIR`/`SP_BINARY_DIR`/`SP_WORKING_DIR` support.
