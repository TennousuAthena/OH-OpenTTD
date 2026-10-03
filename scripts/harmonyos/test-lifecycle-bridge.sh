#!/usr/bin/env bash
# test-lifecycle-bridge.sh — host-side Catch2 unit tests for the OpenTTD
# HarmonyOS lifecycle + thread-ownership contract.
#
# The bridge core (entry/src/main/cpp/lifecycle_bridge.{h,cpp}) is a PURE C++
# state machine with NO XComponent / NAPI dependency, so it can be compiled
# and exercised on the host (macOS / Linux) with the system C++ compiler.
#
# Test source: scripts/harmonyos/lifecycle_bridge_test.cpp (Catch2). It covers
# every legal app/surface transition plus duplicate, reordered, stale-generation,
# teardown-with-request, engine-thread pause/resume/join and TSFN-queue cases.
#
# A second build adds -fsanitize=thread when the compiler supports it; the
# ThreadSanitizer run must report zero data races for the engine thread and
# callback queue.
#
# Usage: scripts/harmonyos/test-lifecycle-bridge.sh
# Exit:  0 = all scenarios pass (incl. TSan-clean when available),
#        1 = any scenario fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BRIDGE_SRC="${REPO_ROOT}/harmonyos/entry/src/main/cpp/lifecycle_bridge.cpp"
BRIDGE_HDR="${REPO_ROOT}/harmonyos/entry/src/main/cpp/lifecycle_bridge.h"
TEST_SRC="${SCRIPT_DIR}/lifecycle_bridge_test.cpp"
CATCH_HDR="${REPO_ROOT}/src/3rdparty/catch2/catch.hpp"

CXX="${CXX:-c++}"
WORKDIR="${TMPDIR:-/tmp}/openttd-ohos-lifecycle-bridge-test"
BIN="${WORKDIR}/test-lifecycle-bridge"
BIN_TSAN="${WORKDIR}/test-lifecycle-bridge-tsan"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
for f in "${BRIDGE_SRC}" "${BRIDGE_HDR}" "${TEST_SRC}" "${CATCH_HDR}"; do
  if [ ! -f "$f" ]; then
    fail "required file not found: $f"
  fi
done

mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# Build the host test binary (no sanitizer)
# ---------------------------------------------------------------------------
printf '[test] building host test binary: %s\n' "${BIN}"
if ! "${CXX}" -std=c++17 -Wall -Wextra -pthread \
    -I"$(dirname "${BRIDGE_HDR}")" -I"$(dirname "${CATCH_HDR}")" \
    "${TEST_SRC}" "${BRIDGE_SRC}" -o "${BIN}" 2>"${WORKDIR}/build.log"; then
  printf 'FAIL: host build of lifecycle_bridge tests failed\n' >&2
  cat "${WORKDIR}/build.log" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run the Catch2 test suite
# ---------------------------------------------------------------------------
printf '\n== Catch2 lifecycle/thread-ownership suite ==\n'
if ! "${BIN}" --reporter compact >"${WORKDIR}/run.log" 2>&1; then
  cat "${WORKDIR}/run.log" >&2
  printf 'FAIL: lifecycle bridge Catch2 suite failed\n' >&2
  exit 1
fi
cat "${WORKDIR}/run.log"
printf '[test] lifecycle bridge Catch2 suite: PASS\n'

# ---------------------------------------------------------------------------
# ThreadSanitizer variant (compile with -fsanitize=thread when supported)
# ---------------------------------------------------------------------------
TSAN_SUPPORTED=0
if "${CXX}" -std=c++17 -fsanitize=thread -x c++ -o "${WORKDIR}/tsan-probe" - <<'EOF' 2>/dev/null
int main() { return 0; }
EOF
then
  TSAN_SUPPORTED=1
fi

if [ "$TSAN_SUPPORTED" -eq 1 ]; then
  printf '\n== ThreadSanitizer variant ==\n'
  if ! "${CXX}" -std=c++17 -Wall -Wextra -pthread -fsanitize=thread -g \
      -I"$(dirname "${BRIDGE_HDR}")" -I"$(dirname "${CATCH_HDR}")" \
      "${TEST_SRC}" "${BRIDGE_SRC}" -o "${BIN_TSAN}" 2>"${WORKDIR}/build-tsan.log"; then
    printf 'FAIL: TSan build of lifecycle_bridge tests failed\n' >&2
    cat "${WORKDIR}/build-tsan.log" >&2
    exit 1
  fi
  # Run only the thread-heavy cases under TSan (faster) and require no races.
  if ! "${BIN_TSAN}" "[thread]","[queue]" --reporter compact >"${WORKDIR}/run-tsan.log" 2>&1; then
    cat "${WORKDIR}/run-tsan.log" >&2
    printf 'FAIL: lifecycle bridge TSan run failed\n' >&2
    exit 1
  fi
  cat "${WORKDIR}/run-tsan.log"
  if grep -q "WARNING: ThreadSanitizer" "${WORKDIR}/run-tsan.log"; then
    printf 'FAIL: ThreadSanitizer reported data races\n' >&2
    exit 1
  fi
  printf '[test] lifecycle bridge TSan run: PASS (no races)\n'
else
  printf '\n== ThreadSanitizer variant: SKIPPED (compiler lacks -fsanitize=thread) ==\n'
fi

printf '\n[test] lifecycle bridge: ALL PASS\n'
exit 0
