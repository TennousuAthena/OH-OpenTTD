# OpenTTD HarmonyOS — Release Guide (AppGallery)

How to build, validate and publish the OpenTTD HarmonyOS port as a
dual-ABI (arm64-v8a + x86_64) AppGallery release.

All release tooling is scripted and CI-gated:

| Tool | Purpose |
|---|---|
| `scripts/harmonyos/package.sh <Debug\|Release>` | assemble the dual-ABI HAP + symbols, source archive, SBOM/notices, source offer, checksums, manifest |
| `scripts/harmonyos/inspect-release.sh <dir-or-hap> [--self-test]` | validate bundle/version/deviceTypes/permissions/ABIs/rawfile/SBOM/secrets |
| `.github/workflows/harmonyos-build.yml` | CI: build both ABIs → package → inspect → license/SBOM → secret scan → device gates |

## 1. Prerequisites

- macOS with DevEco Studio (API 23, SDK 6.1.0.105) — the exact SDK contract is
  validated by `scripts/harmonyos/bootstrap.sh`.
- `scripts/harmonyos/build-host-tools.sh` has been run at least once (package.sh
  builds it automatically if `build/host-tools/strgen` is absent).
- Both ABI sysroots present (`arm64-v8a` + `x86_64`); the SDK validates them.
- Product identity is fixed in `harmonyos/product.json5`:
  `bundleName: 'org.openttd.openttd'`, `versionName: '15.3'`,
  `versionCode: 15000300` (MAJOR*1e6 + MINOR*1e4 + PATCH*100), and
  `deviceTypes: ['tablet', '2in1']`.

## 2. Build the release

```bash
bash scripts/harmonyos/package.sh Release
```

What it does:

1. Runs the bootstrap contract and loads `build/harmonyos/toolchain-manifest.json`.
2. Generates the packaged game data (baseset assets from `media/baseset/` and
   every language via `strgen`) and stages it as HAP rawfile.
3. Invokes hvigor to assemble the dual-ABI HAP:

   ```bash
   node <DevEcoStudio>/Contents/tools/hvigor/bin/hvigorw.js assembleHap \
        --mode module -p product=default -p buildMode=release
   ```

   Both ABIs are packed into one HAP because `harmonyos/entry/build-profile.json5`
   sets `abiFilters: ["arm64-v8a", "x86_64"]`. The result is written to
   `harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap`.
4. Collects every release artifact into `build/harmonyos/release/Release/`:

   | Artifact | Description |
   |---|---|
   | `openttd-15.3-<git>.hap` | dual-ABI HAP (arm64-v8a + x86_64) |
   | `symbols/arm64-v8a/*.so`, `symbols/x86_64/*.so` | unstripped native libraries |
   | `symbols/buildid-map.json` | ELF BuildID → library map (crash symbolication) |
   | `source/openttd-15.3-<git>-src.tar.gz` | `git archive` of the port branch |
   | `sbom/sbom.spdx.json`, `sbom/sbom.cyclonedx.json` | SBOMs (SPDX 2.3 / CycloneDX) |
   | `sbom/manifest.json`, `sbom/NOTICES.md`, `NOTICES.md` | dependency manifest + third-party notices |
   | `SOURCE_OFFER.txt` | GPLv2 source offer (see §6) |
   | `SHA256SUMS` | sha256 of every artifact |
   | `release-manifest.json` | machine-readable release description |

## 3. Validate the release

```bash
bash scripts/harmonyos/inspect-release.sh build/harmonyos/release/Release
```

The inspector **fails** with a precise message on any of:

- bundle name is not `org.openttd.openttd`
- versionName is not `15.3`, versionCode is not `15000300`
- deviceTypes missing `tablet` or `2in1`
- `ohos.permission.INTERNET` not declared
- either ABI (`arm64-v8a` / `x86_64`) missing from `libs/`
- required rawfile resources missing (`baseset/openttd.grf`, `lang/english.lng`,
  at least one `lang/*.lng`)
- any undeclared shared library shipped in `libs/`
- SBOM / license / source-offer / checksum / manifest files missing
- secrets or machine-specific paths (`[/]Users/`, `.p1[2]`, `PRIVATE KEY`)

Run the self-test to prove the gate actually fires when an ABI is removed:

```bash
bash scripts/harmonyos/inspect-release.sh build/harmonyos/release/Release --self-test
```

## 4. Signing

Debug signing (ephemeral local key + AGC debug profile) is documented in
[`docs/harmonyos/debug-signing.md`](./debug-signing.md). Summary:

1. Generate a throwaway key outside the repo: `/tmp/openttd-ohos-debug-signing/`.
2. Create the matching debug certificate in AGC and download `profile.p7b`.
3. Wire the `signingConfigs` block in `harmonyos/build-profile.json5` (never
   commit it) and reference it from the product.

**Release signing requires the AGC manual flow** (release certificate + release
profile issued for the exact `org.openttd.openttd` bundle and the release key
fingerprint). There is no self-serve release profile. The signed artifact is
`entry-default-signed.hap` (contains the `EBBG` signature block); only the
signed HAP may be uploaded to AppGallery.

`package.sh` deliberately produces the **unsigned** staged HAP so the build is
green in CI without any credentials; signing happens in a gated, manual step.

## 5. Privacy & data declaration

AppGallery asks for a privacy policy and a data-safety declaration. For this port:

- **Network**: `ohos.permission.INTERNET` — OpenTTD multiplayer (host/join
  games, content download). Multiplayer is opt-in; no data is transmitted unless
  the player joins a server.
- **Local data**: saves, scenarios and downloaded NewGRFs are stored in the app
  sandbox (`filesDir`); nothing is collected by the port.
- **No** location, camera, microphone, contacts, or media-library permissions.
- Recommend: "This app connects to third-party game servers only when you join a
  multiplayer game or download content. All game data stays on your device."

## 6. GPL source offer

OpenTTD is GPLv2. `package.sh` ships `SOURCE_OFFER.txt` in the release directory
with the standard GPLv2 source-offer text, pointing to the upstream repository,
the shipped source archive and the port repository. The full license text is in
`COPYING.md` at the repository root.

## 7. Store metadata template

AppGallery listing (placeholders marked `<>`):

```text
Name:          OpenTTD 15.3
Category:      Simulation / Strategy
Description:
  <EN> OpenTTD is a transport simulation game based on Transport Tycoon Deluxe.
  Build railways, roads, airports and seaports, manage your fleet and economy,
  and grow a transport empire. Free and open source (GPLv2), with hundreds of
  languages, NewGRF mods and scenarios. Optimized for touch, keyboard and
  mouse on tablets and 2-in-1 devices.
  <ZH> 运输大亨风格的模拟经营游戏。建造铁路、公路、机场和港口，管理车队与
  经济，建立你的运输帝国。开源免费（GPLv2），支持上百种语言与模组。

Short description (≤ 80 chars):
  Free open-source transport simulation game (OpenTTD 15.3).

Screenshots:  <upload 2× landscape 1080×1920+ and 1× portrait; tablet + 2-in-1>
Icon:         <512×512 PNG from harmonyos/AppScope/resources/base/media/app_icon.png>
Promotional text: <optional>

Version:      15.3 (versionCode 15000300)
Supported devices: tablets and 2-in-1 computers (HarmonyOS NEXT, API 23)
ABIs:         arm64-v8a, x86_64
Bundle:       org.openttd.openttd
```

## 8. Install on a device (local)

After signing with the AGC debug profile (§4), install via `hdc`:

```bash
hdc list targets                              # find the device serial
hdc install -r <signed>.hap                   # install (replace existing)
hdc shell aa start -a EntryAbility -b org.openttd.openttd
```

For a quick unsigned sanity check on an emulator, the debug HAP produced by
`package.sh Debug` can be installed on an emulator with local debugging only.

## 9. Release checklist

- [ ] `package.sh Release` exits 0
- [ ] `inspect-release.sh <dir> --self-test` shows `RELEASE VALID` and
      `SELF-TEST PASS`
- [ ] Signed with the AGC **release** profile (manual AGC flow)
- [ ] SBOM/notices regenerated and consistent (`check-licenses.sh` passes)
- [ ] Secret scan green (`ci-local.sh` / CI `secret-scan` job)
- [ ] Device gates passed on a physical tablet and a 2-in-1 (release-only CI jobs)
- [ ] Privacy policy + store metadata drafted from §5 / §7
