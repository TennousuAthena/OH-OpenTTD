#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_HAP="${REPO_ROOT}/harmonyos/entry/build/default/outputs/default/entry-default-signed.hap"
MIN_CORE_SIZE=$((1024 * 1024))
HAP="${1:-${DEFAULT_HAP}}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

find_nm() {
  local candidate
  for candidate in \
    "${OHOS_LLVM_NM:-}" \
    "${DEVECO_SDK_HOME:-}/default/openharmony/native/llvm/bin/llvm-nm" \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/llvm-nm"; do
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  command -v llvm-nm 2>/dev/null || command -v nm 2>/dev/null || return 1
}

[ -f "${HAP}" ] || fail "HAP not found: ${HAP}"
NM="$(find_nm)" || fail "llvm-nm/nm not found; set OHOS_LLVM_NM"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openttd-real-core.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

LISTING="$(unzip -Z1 "${HAP}")" || fail "cannot list HAP: ${HAP}"
mapfile_supported=0
if help mapfile >/dev/null 2>&1; then mapfile_supported=1; fi
if [ "${mapfile_supported}" -eq 1 ]; then
  mapfile -t CORE_ENTRIES < <(printf '%s\n' "${LISTING}" | grep -E '^libs/(arm64-v8a|x86_64)/libopenttd\.so$' || true)
else
  CORE_ENTRIES=()
  while IFS= read -r entry; do CORE_ENTRIES+=("${entry}"); done < <(printf '%s\n' "${LISTING}" | grep -E '^libs/(arm64-v8a|x86_64)/libopenttd\.so$' || true)
fi
[ "${#CORE_ENTRIES[@]}" -gt 0 ] || fail "no packaged libopenttd.so for a configured ABI"

required_c_abi=(
  openttd_native_init
  openttd_native_set_window
  openttd_native_clear_window
  openttd_native_pause
  openttd_native_resume
  openttd_native_shutdown
)

for entry in "${CORE_ENTRIES[@]}"; do
  abi="${entry#libs/}"
  abi="${abi%%/*}"
  core="${TMP_DIR}/libopenttd-${abi}.so"
  unzip -p "${HAP}" "${entry}" >"${core}" || fail "cannot extract ${entry}"
  size="$(wc -c <"${core}" | tr -d '[:space:]')"
  [ "${size}" -ge "${MIN_CORE_SIZE}" ] || fail "${entry} is ${size} bytes (< ${MIN_CORE_SIZE}); stub/core truncation detected"

  if strings "${core}" | grep -Fq 'OpenTTD game-core stub'; then
    fail "${entry} contains the test-stub marker"
  fi
  if strings "${core}" | grep -Fq 'return-42'; then
    fail "${entry} contains the return-42 stub marker"
  fi

  symbols="${TMP_DIR}/symbols-${abi}.txt"
  "${NM}" -g "${core}" >"${symbols}" 2>/dev/null || fail "${NM} could not inspect ${entry}"
  for symbol in "${required_c_abi[@]}"; do
    grep -Eq "(^|[[:space:]])${symbol}$" "${symbols}" || fail "${entry} is missing exported C ABI symbol ${symbol}"
  done
  grep -Eq 'openttd_main|_Z.*openttd_main' "${symbols}" || fail "${entry} is missing the real openttd_main engine symbol"
  grep -Eq 'VideoDriver_HarmonyOS|FSoundDriver_HarmonyOS|SoundDriver_HarmonyOS' "${symbols}" || \
    fail "${entry} is missing HarmonyOS video/audio driver symbols"

  printf 'PASS: %s size=%s bytes; real engine and HarmonyOS driver symbols present\n' "${entry}" "${size}"
done

printf 'PASS: real OpenTTD core package inspection succeeded: %s\n' "${HAP}"
