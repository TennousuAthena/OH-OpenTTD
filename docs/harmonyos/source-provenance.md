# Source Provenance — OpenTTD 15.3 HarmonyOS Port Baseline

This document records the exact upstream origin of the `harmonyos-port` branch,
so that every later change can be traced back to a verified OpenTTD release.

## Upstream remote

| Field | Value |
|-------|-------|
| Remote name | `origin` |
| Remote URL | `https://github.com/OpenTTD/OpenTTD.git` |
| Upstream tag | `15.3` |
| Tag commit SHA | `14ec60f248547d4d062a1160f0fc26d742319888` |
| Local branch | `harmonyos-port` (checked out from tag `15.3`) |

## Setup date

`Tue Aug 11 00:44:31 CST 2026`

## Verification commands and outputs

All commands were run from the workspace root
(`/Users/takuenn/Workspace/DevEco/openttd-ohos/`) on the above date.

### 1. `git rev-parse HEAD`

Output:

```
14ec60f248547d4d062a1160f0fc26d742319888
```

This matches the expected SHA for tag `15.3` exactly.

### 2. `git fsck --full`

Output (empty — repository object database is healthy, exit code 0):

```
```

No dangling or corrupt objects were reported.

### 3. `git fetch origin --tags` (timing)

Full, non-shallow fetch of complete history with all tags
(`--depth` was NOT used; full ancestry is required for future rebases
onto newer OpenTTD releases).

Real time: `11:39.40` (wall clock).

### 4. Ancestor check

```
git merge-base --is-ancestor 14ec60f248547d4d062a1160f0fc26d742319888 HEAD
```

Exit code 0 (`ANCESTOR_OK`) — the tag commit is the direct ancestor of HEAD.

## Licensing and data policy

- OpenTTD source is licensed under GPLv2 (see `COPYING.md` in the repo root).
- **No binaries or assets from `/Applications/OpenTTD.app` may ever be
  imported into this repository.**
- **No proprietary Transport Tycoon Deluxe data files** (original graphics,
  sounds, or music, e.g. `sample.cat`, `trg1r.grf`, `TRG1.GRF`, TTD music)
  **may ever be imported into this repository.**
- The free data sets (OpenGFX / OpenSFX / OpenMSX) are distributed separately
  and are not part of this source tree.
