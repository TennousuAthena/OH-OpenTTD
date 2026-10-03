#!/usr/bin/env bash
# test-network-diagnostics.sh — static assertions for the HarmonyOS network
# and diagnostics shims. Runs entirely on the host; no device required.
#
# Checks:
#   (a) src/network/core/config.h keeps the pinned network protocol constants
#       (game-info v7, default port 3979, coordinator/stun/turn unchanged).
#   (b) docs/harmonyos/diagnostics-policy.md exists and pins an http/https
#       URL allowlist.
#   (c) src/os/harmonyos/crashlog_harmonyos.cpp registers the HiAppEvent
#       crash/freeze watcher (alongside the signal-based handler).
#   (d) src/os/harmonyos/harmonyos_log.cpp emits HiLog records with explicit
#       %{public}s / %{private}s privacy markers.
#
# Usage: scripts/harmonyos/test-network-diagnostics.sh [-v]
# Exit:  0 = all sections pass, 1 = any assertion failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0
FAIL=0
FAILED_TESTS=()

record() { # record <name> <0|1>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
    ohos_info "PASS: $1"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$1")
    ohos_error "FAIL: $1"
  fi
}

# grep_json <file> <python-expr> — run a python3 one-liner over <file>; prints
# "0" if the expression evaluates truthy, "1" otherwise. Used for both plain
# grep-style checks and JSON-aware validation, per the port's "python3 for
# checks" convention.
grep_json() { # grep_json <file> <python-expr>
  local file="$1" expr="$2"
  python3 -c '
import re, sys
file, expr = sys.argv[1], sys.argv[2]
text = open(file, encoding="utf-8").read()
print(0 if eval(expr, {"text": text, "re": re}) else 1)
' "$file" "$expr"
}

# ---------------------------------------------------------------------------
# (a) Network protocol constants in src/network/core/config.h
# ---------------------------------------------------------------------------

CONFIG_H="${REPO_ROOT}/src/network/core/config.h"
ohos_check_file "src/network/core/config.h" "${CONFIG_H}" \
  || ohos_die "missing ${CONFIG_H}"

record "NETWORK_GAME_INFO_VERSION == 7" \
  "$(grep_json "${CONFIG_H}" "re.search(r'NETWORK_GAME_INFO_VERSION\s*=\s*7\b', text)")"

record "NETWORK_DEFAULT_PORT == 3979" \
  "$(grep_json "${CONFIG_H}" "re.search(r'NETWORK_DEFAULT_PORT\s*=\s*3979\b', text)")"

record "NETWORK_COORDINATOR_SERVER_PORT unchanged (3976)" \
  "$(grep_json "${CONFIG_H}" "re.search(r'NETWORK_COORDINATOR_SERVER_PORT\s*=\s*3976\b', text)")"

record "NETWORK_STUN_SERVER_PORT unchanged (3975)" \
  "$(grep_json "${CONFIG_H}" "re.search(r'NETWORK_STUN_SERVER_PORT\s*=\s*3975\b', text)")"

record "NETWORK_TURN_SERVER_PORT unchanged (3974)" \
  "$(grep_json "${CONFIG_H}" "re.search(r'NETWORK_TURN_SERVER_PORT\s*=\s*3974\b', text)")"

record "NETWORK_CONTENT_SERVER_PORT unchanged (3978)" \
  "$(grep_json "${CONFIG_H}" "re.search(r'NETWORK_CONTENT_SERVER_PORT\s*=\s*3978\b', text)")"

# ---------------------------------------------------------------------------
# (b) Diagnostics policy + URL allowlist
# ---------------------------------------------------------------------------

POLICY="${REPO_ROOT}/docs/harmonyos/diagnostics-policy.md"
ohos_check_file "docs/harmonyos/diagnostics-policy.md" "${POLICY}" \
  || ohos_die "missing ${POLICY}"

record "policy document exists" \
  "$([ -f "${POLICY}" ]; echo $?)"

record "policy allows https:// URLs" \
  "$(grep_json "${POLICY}" "re.search(r'https://', text)")"

record "policy allows http:// URLs" \
  "$(grep_json "${POLICY}" "re.search(r'http://', text)")"

record "policy forbids non-http(s) schemes" \
  "$(grep_json "${POLICY}" "re.search(r'non-\(http\|https\)', text)")"

# ---------------------------------------------------------------------------
# (c) HiAppEvent crash watcher registration
# ---------------------------------------------------------------------------

CRASHLOG="${REPO_ROOT}/src/os/harmonyos/crashlog_harmonyos.cpp"
ohos_check_file "src/os/harmonyos/crashlog_harmonyos.cpp" "${CRASHLOG}" \
  || ohos_die "missing ${CRASHLOG}"

record "crashlog registers OH_HiAppEvent_CreateWatcher" \
  "$(grep_json "${CRASHLOG}" "re.search(r'OH_HiAppEvent_CreateWatcher', text)")"

record "crashlog sets app event filter" \
  "$(grep_json "${CRASHLOG}" "re.search(r'OH_HiAppEvent_SetAppEventFilter', text)")"

record "crashlog sets watcher on-receive" \
  "$(grep_json "${CRASHLOG}" "re.search(r'OH_HiAppEvent_SetWatcherOnReceive', text)")"

record "crashlog adds watcher" \
  "$(grep_json "${CRASHLOG}" "re.search(r'OH_HiAppEvent_AddWatcher', text)")"

record "crashlog keeps signal-based handler (SetSignals)" \
  "$(grep_json "${CRASHLOG}" "re.search(r'SetSignals\(', text)")"

record "crashlog writes symbol archive (BuildID + .symtab)" \
  "$(grep_json "${CRASHLOG}" "re.search(r'WriteSymbolArchive|symbols-index|build-id|\.symtab', text)")"

# ---------------------------------------------------------------------------
# (d) HiLog privacy markers in harmonyos_log.cpp
# ---------------------------------------------------------------------------

HILOG="${REPO_ROOT}/src/os/harmonyos/harmonyos_log.cpp"
ohos_check_file "src/os/harmonyos/harmonyos_log.cpp" "${HILOG}" \
  || ohos_die "missing ${HILOG}"

record "HiLog uses %{public}s privacy marker" \
  "$(grep_json "${HILOG}" "re.search(r'%\{public\}s', text)")"

record "HiLog has no bare %s specifiers" \
  "$(grep_json "${HILOG}" "re.search(r'\"[^\"]*%s[^\"]*\"', text) is None")"

record "ShowInfoI maps to OH_LOG_Print" \
  "$(grep_json "${HILOG}" "re.search(r'OH_LOG_Print', text) and re.search(r'ShowInfoI', text)")"

record "HiLog log-domain is the OpenTTD application domain" \
  "$(grep_json "${HILOG}" "re.search(r'LOG_DOMAIN\s*=\s*0xD002F00', text)")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

ohos_info "----------------------------------------"
ohos_info "network-diagnostics: ${PASS} passed, ${FAIL} failed"

if [ "${FAIL}" -gt 0 ]; then
  for t in "${FAILED_TESTS[@]}"; do
    ohos_error "  - ${t}"
  done
  exit 1
fi

exit 0
