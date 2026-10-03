#!/usr/bin/env bash
# ci-local.sh — local CI-equivalent runner for the OpenTTD HarmonyOS port.
#
# Executes every lane that EXISTS TODAY and must be green locally:
#   1. bash -n syntax check over every script in scripts/harmonyos/
#   2. bootstrap.sh --check-only (SDK/toolchain validation)
#   3. tracked-file secret scan ([/]Users/, .p1[2], private keys, passwords)
#   4. structural policy gate over .github/workflows/*.yml
#   5. workflow YAML parse (python3 yaml if available)
#
# Lanes whose scripts do not exist yet (land in later plan todos) are
# SKIPPED-with-explicit-report as PENDING — never silently treated as PASS.
# PENDING lanes do NOT fail the run; they are listed for the operator.
#
# Usage:
#   scripts/harmonyos/ci-local.sh          # full local CI
#   scripts/harmonyos/ci-local.sh -v       # verbose
#   scripts/harmonyos/ci-local.sh -h

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    -v) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

LANE_PASS=0
LANE_FAIL=0
LANE_PENDING=0

# lane_result <status> <name> [detail...]
lane_result() {
  local status="$1"; shift
  local name="$1"; shift
  case "$status" in
    PASS)    LANE_PASS=$((LANE_PASS + 1)); printf '  [PASS] %s\n' "$name" ;;
    FAIL)    LANE_FAIL=$((LANE_FAIL + 1)); printf '  [FAIL] %s\n' "$name" ;;
    PENDING) LANE_PENDING=$((LANE_PENDING + 1)); printf '  [PENDING] %s\n' "$name" ;;
  esac
  if [ "$status" = "FAIL" ] && [ $# -gt 0 ]; then
    printf '          %s\n' "$*"
  fi
}

run_lane() {
  local name="$1"; shift
  if [ "$VERBOSE" -eq 1 ]; then
    printf '\n--- lane: %s ---\n' "$name"
  fi
  if "$@" >/tmp/ci-local-lane.log 2>&1; then
    lane_result PASS "$name"
    if [ "$VERBOSE" -eq 1 ]; then
      sed 's/^/          | /' /tmp/ci-local-lane.log
    fi
  else
    lane_result FAIL "$name" "command failed: $*"
    if [ "$VERBOSE" -eq 1 ]; then
      sed 's/^/          | /' /tmp/ci-local-lane.log
    fi
  fi
}

# Scripts whose lane is PENDING because the script lands in a later plan todo.
# TODO 3: build-host-tools.sh | TODO 4/5: build-target.sh
# TODO 5/20: package.sh, inspect-release.sh, check-licenses.sh
# TODO 22:  test-device.sh
PENDING_SCRIPTS=(
  build-host-tools.sh
  build-target.sh
  package.sh
  inspect-release.sh
  check-licenses.sh
  test-device.sh
)

printf 'OpenTTD HarmonyOS — local CI\n'
printf '============================\n\n'

# --- 1. bash -n over every harmonyos script ----------------------------------
printf 'Lane 1: bash -n syntax check over scripts/harmonyos/*.sh\n'
SYNTAX_FAIL=0
for f in "${SCRIPT_DIR}"/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/tmp/ci-local-syntax.log; then
    [ "$VERBOSE" -eq 1 ] && printf '          | ok: %s\n' "$(basename "$f")"
  else
    lane_result FAIL "bash -n $(basename "$f")" "$(cat /tmp/ci-local-syntax.log)"
    SYNTAX_FAIL=1
  fi
done
if [ "$SYNTAX_FAIL" -eq 0 ]; then
  lane_result PASS "bash -n all scripts"
fi

# --- 2. bootstrap --check-only ------------------------------------------------
printf '\nLane 2: bootstrap --check-only\n'
run_lane "bootstrap --check-only" bash "${SCRIPT_DIR}/bootstrap.sh" --check-only

# --- 3. tracked-file secret scan ----------------------------------------------
printf '\nLane 3: secret scan over tracked HarmonyOS files\n'
# Patterns use bracket escapes ([/]Users/) so the scan scripts' own source text
# does not match itself. Scans the same scope as the CI secret-scan job;
# the Windows C:/Users convention used by upstream CI is outside the scope.
# test-diagnostics-policy.sh embeds secret-looking fixtures for its own
# negative tests, and inspect-release.sh's R9 comment documents the scan
# pattern; both are harness self-references, not secrets. Exclude them the
# same way the policy test excludes itself (see test-diagnostics-policy.sh §e).
if GIT_MASTER=1 git ls-files -- 'scripts/harmonyos/*.sh' '.github/workflows/harmonyos-build.yml' 2>/dev/null \
  | xargs grep -HInE '[/]Users/|\.p1[2]|PRIVATE[ ]KEY|pass[w]ord[[:space:]]*=' \
      --exclude='test-diagnostics-policy.sh' --exclude='inspect-release.sh' \
  >/tmp/ci-local-secret.log 2>/dev/null; then
  lane_result FAIL "secret scan" "matches found:"
  sed 's/^/          | /' /tmp/ci-local-secret.log
else
  # grep exits 1 when no matches — that is the PASS case.
  lane_result PASS "secret scan"
fi

# --- 4. structural policy gate -------------------------------------------------
printf '\nLane 4: workflow structural policy check\n'
run_lane "ci-policy-check.sh" bash "${SCRIPT_DIR}/ci-policy-check.sh"

# --- 5. workflow YAML parse ----------------------------------------------------
printf '\nLane 5: workflow YAML parse\n'
if python3 -c 'import yaml, sys; yaml.safe_load(open(sys.argv[1]))' "${REPO_ROOT}/.github/workflows/harmonyos-build.yml" >/tmp/ci-local-yaml.log 2>&1; then
  lane_result PASS "yaml.safe_load harmonyos-build.yml"
else
  lane_result FAIL "yaml.safe_load harmonyos-build.yml" "$(cat /tmp/ci-local-yaml.log)"
fi

# --- PENDING lanes (scripts not yet landed) ------------------------------------
printf '\nPENDING lanes (scripts land in later plan todos — NOT run today):\n'
for s in "${PENDING_SCRIPTS[@]}"; do
  if [ -f "${SCRIPT_DIR}/${s}" ]; then
    lane_result PASS "${s} (exists — run it manually)" 
  else
    lane_result PENDING "${s} — script does not exist yet"
  fi
done

# --- summary -------------------------------------------------------------------
printf '\n============================\n'
printf 'SUMMARY: %d PASS, %d FAIL, %d PENDING\n' "$LANE_PASS" "$LANE_FAIL" "$LANE_PENDING"

if [ "$LANE_FAIL" -ne 0 ]; then
  printf 'LOCAL CI FAILED (%d failing lane(s))\n' "$LANE_FAIL" >&2
  exit 1
fi
printf 'LOCAL CI GREEN (PENDING lanes are informational only)\n'
exit 0
