#!/usr/bin/env bash
# test-platform-guards.sh — configure/policy tests for the first-class HarmonyOS
# CMake platform selection (Todo 4).
#
# Tests:
#   (a) arm64-v8a + x86_64 Debug configure-only succeed with C++20 + HARMONYOS,
#       HarmonyOS sources present, forbidden Unix sources / -rdynamic / -DUNIX absent.
#   (b) negative: a fixture that force-includes a forbidden Unix source must fail
#       configure with a FATAL_ERROR naming the forbidden file.
#   (c) control: the same fixture WITHOUT HARMONYOS must configure fine, proving
#       existing (non-HarmonyOS) platforms are unaffected by the guard.
#
# Usage:
#   scripts/harmonyos/test-platform-guards.sh
#   scripts/harmonyos/test-platform-guards.sh -v   # verbose (print configure logs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

FIXTURE_DIR="${TMPDIR:-/tmp}/openttd-ohos-guard-fixture"
rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"

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

show_log_if_needed() {
  if [ "$VERBOSE" -eq 1 ]; then
    ohos_info "--- $1 ---"
    tail -n 30 "$1" 2>/dev/null | sed 's/^/  /'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# (a) Happy path: both ABIs configure-only through build-target.sh
# ---------------------------------------------------------------------------
ohos_info "=== (a) happy path: build-target.sh configure-only, both ABIs ==="

for ABI in arm64-v8a x86_64; do
  NAME="a-${ABI}-Debug configure-only"
  LOG="${FIXTURE_DIR}/happy-${ABI}.log"
  if "${SCRIPT_DIR}/build-target.sh" "$ABI" Debug --configure-only >"$LOG" 2>&1; then
    record "$NAME (configure exit 0)" 0
  else
    record "$NAME (configure exit 0)" 1
    show_log_if_needed "$LOG"
    continue
  fi

  BUILD_DIR="${REPO_ROOT}/build/target-${ABI}-Debug"
  CACHE="${BUILD_DIR}/CMakeCache.txt"
  DB="${BUILD_DIR}/compile_commands.json"
  CONFIG_LOG="${BUILD_DIR}/configure.log"

  grep -q -- "-std=c++20" "$DB" \
    && record "$NAME (C++20 in compile database)" 0 \
    || { record "$NAME (C++20 in compile database)" 1; show_log_if_needed "$LOG"; }

  # HARMONYOS is detected by the OHOS toolchain (CMAKE_SYSTEM_NAME=OHOS). The
  # top-level CMakeLists.txt prints a STATUS line on detection; it lands in the
  # configure log, not on build-target.sh's stdout.
  grep -q "HarmonyOS platform detected" "$CONFIG_LOG" \
    && record "$NAME (HARMONYOS detection message)" 0 \
    || { record "$NAME (HARMONYOS detection message)" 1; show_log_if_needed "$CONFIG_LOG"; }

  # HARMONYOS is a plain (non-cache) variable; its effect is visible in the
  # compile database: harmonyos sources in, unix sources out.
  for src in "src/os/harmonyos/harmonyos.cpp" "src/os/harmonyos/crashlog_harmonyos.cpp" "src/os/harmonyos/harmonyos_main.cpp"; do
    grep -q "$src" "$DB" \
      && record "$NAME (includes $src)" 0 \
      || { record "$NAME (includes $src)" 1; show_log_if_needed "$LOG"; }
  done

  for forbidden in "unix_main.cpp" "crashlog_unix.cpp" "extmidi.cpp" "src/os/unix/unix.cpp" "library_loader_unix.cpp" "survey_unix.cpp"; do
    if grep -q "$forbidden" "$DB"; then
      record "$NAME (excludes $forbidden)" 1
    else
      record "$NAME (excludes $forbidden)" 0
    fi
  done

  grep -q -- "-rdynamic" "$DB" \
    && { record "$NAME (no -rdynamic)" 1; show_log_if_needed "$LOG"; } \
    || record "$NAME (no -rdynamic)" 0

  grep -q -- "-DUNIX" "$DB" \
    && { record "$NAME (no -DUNIX impersonation)" 1; show_log_if_needed "$LOG"; } \
    || record "$NAME (no -DUNIX impersonation)" 0
done

# ---------------------------------------------------------------------------
# (b) Negative: forbidden source force-included must be rejected by the guard
# ---------------------------------------------------------------------------
ohos_info "=== (b) negative: forbidden source triggers platform guard ==="

NEG_DIR="${FIXTURE_DIR}/negative"
mkdir -p "$NEG_DIR"
# The fixture emulates a Unix-only source that leaked into the HarmonyOS build.
printf 'int leaked_unix_symbol() { return 0; }\n' > "${NEG_DIR}/unix_main.cpp"
printf 'int leaked_crash_symbol() { return 0; }\n' > "${NEG_DIR}/crashlog_unix.cpp"
cat > "${NEG_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.17)
project(guard_negative LANGUAGES CXX)
include(${REPO_ROOT}/cmake/HarmonyOS.cmake)
add_library(fake_lib STATIC unix_main.cpp crashlog_unix.cpp)
assert_no_forbidden_harmonyos_sources(fake_lib)
EOF

NEG_LOG="${FIXTURE_DIR}/negative.log"
if "${DEVECO_CMAKE_BIN:-cmake}" -S "$NEG_DIR" -B "${NEG_DIR}/build" \
    -DREPO_ROOT="$REPO_ROOT" -DOHOS=OHOS -G Ninja >"$NEG_LOG" 2>&1; then
  record "b: configure unexpectedly succeeded with forbidden source" 1
else
  record "b: configure rejected forbidden source (nonzero exit)" 0
fi
if grep -q "forbidden Unix-only source" "$NEG_LOG" && grep -q "unix_main.cpp" "$NEG_LOG"; then
  record "b: FATAL_ERROR names the forbidden source" 0
else
  record "b: FATAL_ERROR names the forbidden source" 1
fi
show_log_if_needed "$NEG_LOG"

# ---------------------------------------------------------------------------
# (c) Control: identical fixture WITHOUT HARMONYOS must pass the guard,
#     proving generic-Unix platforms are unaffected.
# ---------------------------------------------------------------------------
ohos_info "=== (c) control: non-HarmonyOS configure unaffected ==="

CTL_DIR="${FIXTURE_DIR}/control"
mkdir -p "$CTL_DIR"
cp "${NEG_DIR}/unix_main.cpp" "${NEG_DIR}/crashlog_unix.cpp" "$CTL_DIR/"
cat > "${CTL_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.17)
project(guard_control LANGUAGES CXX)
include(${REPO_ROOT}/cmake/HarmonyOS.cmake)
add_library(fake_lib STATIC unix_main.cpp crashlog_unix.cpp)
assert_no_forbidden_harmonyos_sources(fake_lib)
EOF

CTL_LOG="${FIXTURE_DIR}/control.log"
if "${DEVECO_CMAKE_BIN:-cmake}" -S "$CTL_DIR" -B "${CTL_DIR}/build" \
    -DREPO_ROOT="$REPO_ROOT" -G Ninja >"$CTL_LOG" 2>&1; then
  record "c: non-HARMONYOS configure succeeds (guard inactive)" 0
  record "c: unix_main.cpp allowed when not HARMONYOS" 0
else
  record "c: non-HARMONYOS configure succeeds (guard inactive)" 1
  show_log_if_needed "$CTL_LOG"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ohos_info "=== summary: ${PASS} passed, ${FAIL} failed ==="
if [ "$FAIL" -ne 0 ]; then
  for t in "${FAILED_TESTS[@]}"; do
    ohos_error "  FAILED: $t"
  done
  exit 1
fi
ohos_info "test-platform-guards.sh: ALL TESTS PASSED"
