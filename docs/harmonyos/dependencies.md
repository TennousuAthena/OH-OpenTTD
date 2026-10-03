# HarmonyOS Native Dependency Governance

The OpenTTD HarmonyOS port pins every third-party native dependency to an
**immutable release URL + verified SHA-256**. This document explains the
governance model, the artifacts that encode it, and the scripts that enforce
it in CI.

## Scope

Required (pinned) dependencies:

| Dependency | Version | SPDX license | Linkage | Role |
|-----------|---------|-------------|---------|------|
| Threads (std::thread) | NDK API 23 | Apache-2.0 | system | C++ threading runtime |
| libc++ | NDK API 23 | Apache-2.0 | static | C++20 runtime |
| zlib | 1.3.1 | Zlib | static | savegame/baseset compression |
| liblzma (XZ Utils) | 5.6.3 | 0BSD | static | .tar.xz baseset decompression |
| libpng | 1.6.45 | libpng-2.0 | static | sprite/PNG decoding |
| FreeType | 2.13.3 | FTL | static | vector font rendering |
| HarfBuzz | 10.1.0 | MIT | static | complex text shaping |
| ICU (ICU4C) | 75.1 | ICU | static | Unicode normalization / script run |
| libcurl | 8.11.1 | curl | static | HTTP(S) content download |
| libopus | 1.5.2 | BSD-3-Clause | static | Opus decode for packaged sound assets |
| opusfile | 0.12 | BSD-3-Clause | static | Ogg Opus demuxing for sound assets |
| LZO (liblzo2) — optional | 2.10 | GPL-2.0-only | static | compatibility only |

Threads and libc++ are **NDK-provided**: they are pinned by the API 23
toolchain manifest produced by `scripts/harmonyos/bootstrap.sh`, not fetched as
archives, so they carry no SHA-256.

### Explicitly excluded

The port does **not** use SDL, Allegro, FluidSynth, Fontconfig or Breakpad.
Reasons are recorded per library in `harmonyos/dependencies/manifest.json`
(`exclusions`) and enforced by `check-licenses.sh`.

## Governance artifacts (`harmonyos/dependencies/`)

- `manifest.json` — single source of truth. One entry per dependency with
  `id`, `name`, `version`, immutable `url`, verified `sha256`, `archive`,
  `license.spdx` + `licenseFile`, `linkage`, `abis`, `updateOwner`,
  `buildRole`, optional `dependsOn` graph, and `exclusions`.
- `manifest.schema.json` — JSON Schema (draft-07). Archive deps must have a
  `https://` url that does not reference a mutable branch and a 64-lowercase
  hex `sha256`; NDK deps must have null url/sha256.
- `sbom.cyclonedx.json` — CycloneDX 1.5 SBOM (components + dependency graph).
- `sbom.spdx.json` — SPDX 2.3 SBOM (packages + licenses + DEPENDS_ON).
- `NOTICES.md` — human-readable notices for every pinned, NDK-provided and
  upstream-bundled component, including the OpenTTD GPL-2.0 license itself.

The upstream-bundled third-party licenses documented in `README.md` §3.0
(squirrel Zlib, md5 Zlib, fmt MIT, nlohmann MIT, opengl MIT, catch2 BSL-1.0,
icu-scriptrun Unicode-DFS-2016, monocypher BSD-2-Clause+CC0, social integration
API MIT, llvm CheckAtomic Apache-2.0) are listed in `upstreamBundled` and
mirrored into both SBOMs and NOTICES.md.

## Verifier: `scripts/harmonyos/check-dependency-manifest.sh`

| Mode | Behavior |
|------|----------|
| default | Manifest JSON + schema + semantic validation (no network) |
| `--offline` | + every archive must be cached with matching SHA-256; a cache miss is a **precise hard failure with no network fallback** |
| `--verify-cache` | + verify SHA-256 of every cached archive (altered-byte detection) |
| `--fetch-missing` | + download cache misses via curl and SHA-verify before caching |

`HARMONY_DEPS_OFFLINE=1` forces offline semantics. `HARMONY_DEPS_CACHE` names
the cache directory. The verifier rejects a mutated cached archive **before any
extraction** with `SHA-256 mismatch for <id>`.

## Recipe interface: `scripts/harmonyos/deps/`

Minimal deterministic recipe interface for `arm64-v8a` / `x86_64`:

```
scripts/harmonyos/deps/run-deps.sh build --cache DIR --out DIR --dep zlib
scripts/harmonyos/deps/run-deps.sh build --cache DIR --out DIR --all
scripts/harmonyos/deps/run-deps.sh status  --cache DIR --out DIR --dep zlib
scripts/harmonyos/deps/run-deps.sh describe --dep zlib
```

Each `recipes/<id>.sh` implements `describe`, `status`, `build <abi> <outdir>`
and `clean <abi> <outdir>` via the shared interface
`deps/interface/dependency-recipe.sh`. The archive source is ONLY the pinned
file in `HARMONY_DEPS_CACHE`, and ONLY after its SHA-256 matches the manifest —
no network, no mutable branch. The interface is today allowed to report
**pending artifacts** rather than cross-compile every large dependency; the
`build` command prepares the deterministic per-ABI output directory and archive
provenance record, so the graph is governed and reproducible even before full
cross-compilation lands.

## CI license gate: `scripts/harmonyos/check-licenses.sh`

Validates, for every manifest dependency, that it appears in both SBOMs with a
matching license and that its SPDX id is listed in NOTICES.md; also asserts the
excluded libraries never appear as dependencies, and that every
`upstreamBundled` component is mentioned in NOTICES.md. Run in CI as the
`license-sbom` job.

## Update policy

To bump a dependency: change the manifest entry (new immutable release URL,
new SHA-256 computed from the official archive and cross-checked against an
independent published checksum, license re-check, `updateOwner`), then refresh
SBOMs and NOTICES.md. Do not use mutable branches (`master`, `main`, `latest`)
as fetch sources; the schema and verifier reject them.