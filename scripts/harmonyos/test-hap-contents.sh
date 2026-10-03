#!/usr/bin/env bash
# test-hap-contents.sh — post-assembly structural validation of the debug HAP.
#
# After `assembleHap`, unzips the produced HAP and asserts the presence of the
# native host library, the split game-core stub, the compiled ArkTS ability,
# the main_pages route table and the packaged module manifest.
#
# Usage: scripts/harmonyos/test-hap-contents.sh [path/to/entry-default-unsigned.hap]
#   Default HAP: harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap
# Exit: 0 = all assertions pass, 1 = any assertion fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_HAP="${REPO_ROOT}/harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap"
HAP="${1:-${DEFAULT_HAP}}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "${HAP}" ]; then
  fail "HAP not found: ${HAP} (run assembleHap first, or pass the HAP path)"
fi

printf '[test] validating HAP: %s\n' "${HAP}"
LISTING="$(unzip -l "${HAP}")" || fail "unzip -l failed on ${HAP}"

# ---------------------------------------------------------------------------
# Required entries (substrings, match against the unzip listing)
# ---------------------------------------------------------------------------
assert_present() {
  local needle="$1"
  if ! printf '%s\n' "${LISTING}" | grep -Fq "${needle}"; then
    printf 'FAIL: missing entry: %s\n' "${needle}" >&2
    return 1
  fi
  printf '  present: %s\n' "${needle}"
}

rc=0
# Native host library (per-ABI; we accept either of the configured ABIs).
printf '%s\n' "${LISTING}" | grep -Eq 'libs/arm64-v8a/libentry\.so|libs/x86_64/libentry\.so' \
  || { printf 'FAIL: libentry.so missing for arm64-v8a/x86_64\n' >&2; rc=1; }
printf '  present: libentry.so (lib/arm64-v8a or lib/x86_64)\n'

printf '%s\n' "${LISTING}" | grep -Eq 'libs/arm64-v8a/libopenttd\.so|libs/x86_64/libopenttd\.so' \
  || { printf 'FAIL: libopenttd.so missing for arm64-v8a/x86_64\n' >&2; rc=1; }
printf '  present: libopenttd.so (lib/arm64-v8a or lib/x86_64)\n'

# Compiled ArkTS: the ability is compiled to ets/modules.abc whose source map
# references the EntryAbility source file.
printf '%s\n' "${LISTING}" | grep -Fq 'ets/modules.abc' \
  || { printf 'FAIL: ets/modules.abc (compiled ArkTS) missing\n' >&2; rc=1; }
printf '  present: ets/modules.abc (compiled ArkTS)\n'

if ! unzip -p "${HAP}" ets/sourceMaps.map 2>/dev/null | grep -Fq 'entryability/EntryAbility'; then
  printf 'FAIL: EntryAbility.ets not compiled into HAP\n' >&2
  rc=1
else
  printf '  present: EntryAbility.ets (compiled, in sourceMaps.map)\n'
fi

# Route table + module manifest.
assert_present 'resources/base/profile/main_pages.json' || rc=1
assert_present 'module.json' || rc=1

# ---------------------------------------------------------------------------
# module.json contract assertions (from the packaged manifest)
# ---------------------------------------------------------------------------
MODULE_JSON="$(unzip -p "${HAP}" module.json 2>/dev/null)" || MODULE_JSON=""

if [ -z "${MODULE_JSON}" ]; then
  printf 'FAIL: could not read packaged module.json\n' >&2
  rc=1
else
  if ! printf '%s' "${MODULE_JSON}" | grep -Fq '"tablet"'; then
    printf 'FAIL: deviceTypes does not contain tablet\n' >&2; rc=1
  else
    printf '  present: deviceTypes contains tablet\n'
  fi
  if ! printf '%s' "${MODULE_JSON}" | grep -Fq '"2in1"'; then
    printf 'FAIL: deviceTypes does not contain 2in1\n' >&2; rc=1
  else
    printf '  present: deviceTypes contains 2in1\n'
  fi
  if ! printf '%s' "${MODULE_JSON}" | grep -Fq '"ohos.permission.INTERNET"'; then
    printf 'FAIL: INTERNET permission missing\n' >&2; rc=1
  else
    printf '  present: ohos.permission.INTERNET\n'
  fi
  if ! printf '%s' "${MODULE_JSON}" | grep -Fq '"mainElement":"EntryAbility"'; then
    printf 'FAIL: mainElement is not EntryAbility\n' >&2; rc=1
  else
    printf '  present: mainElement=EntryAbility\n'
  fi
fi

if [ "$rc" -eq 0 ]; then
  printf '\n[test] HAP contents: ALL PASS\n'
else
  printf '\n[test] HAP contents: FAILED\n' >&2
fi
exit "$rc"
