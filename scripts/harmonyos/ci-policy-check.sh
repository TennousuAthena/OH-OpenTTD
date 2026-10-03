#!/usr/bin/env bash
# ci-policy-check.sh — structural policy gate over the HarmonyOS CI workflows.
#
# Asserts that .github/workflows/harmonyos-build.yml contains every required
# lane and that the physical-device release gates are correctly configured:
#
#   R1. arm64-v8a build lane exists (build-target.sh arm64-v8a ...)
#   R2. x86_64 build lane exists    (build-target.sh x86_64 ...)
#   R3. license/SBOM lane exists    (check-licenses.sh)
#   R4. secret-scan lane exists     (grep-based mac-home/keystore/key-material scan)
#   R5. physical device jobs exist  (runs-on [self-hosted, harmonyos-device])
#   R6. both device jobs are REQUIRED — no continue-on-error
#   R7. both device jobs are release-gated (event_name == 'release' or tags)
#
# Uses python3 yaml when importable (precise), otherwise falls back to
# documented grep-based structural checks. Exits nonzero with a precise
# message on the first violation (all violations listed before exit).
#
# Usage:
#   scripts/harmonyos/ci-policy-check.sh [path-to-workflow.yml]
#   default workflow: <repo>/.github/workflows/harmonyos-build.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKFLOW="${1:-${REPO_ROOT}/.github/workflows/harmonyos-build.yml}"

[ -f "$WORKFLOW" ] || { echo "ERROR: workflow not found: ${WORKFLOW}" >&2; exit 2; }

violations=0
violation() {
  violations=$((violations + 1))
  echo "VIOLATION ${violations}: $*" >&2
}

# ---------------------------------------------------------------------------
# Python yaml path (precise)
# ---------------------------------------------------------------------------
check_with_python() {
  python3 - "$WORKFLOW" <<'PYEOF'
import sys
import yaml

path = sys.argv[1]
with open(path) as f:
    doc = yaml.safe_load(f)

v = []
def violation(msg):
    v.append(msg)

jobs = doc.get("jobs") or {}
job_names = set(jobs.keys())

# R1 / R2: dual-ABI build lanes
def build_lane_has(abi):
    for jn in ("build-arm64", "build-x86_64", "build_arm64", "build_x86_64"):
        j = jobs.get(jn)
        if not j:
            continue
        steps = j.get("steps") or []
        for s in steps:
            run = s.get("run") or ""
            if "build-target.sh" in run and abi in run:
                return True
    return False

if not build_lane_has("arm64-v8a"):
    violation("arm64-v8a build lane missing: no step runs 'build-target.sh arm64-v8a'")
if not build_lane_has("x86_64"):
    violation("x86_64 build lane missing: no step runs 'build-target.sh x86_64'")

# R3: license/SBOM lane
if not any("check-licenses.sh" in (s.get("run") or "") for j in jobs.values() for s in (j.get("steps") or [])):
    violation("license/SBOM lane missing: no step runs 'check-licenses.sh'")

# R4: secret-scan lane
secret_lanes = [jn for jn, j in jobs.items()
                if any("secret" in (s.get("name") or "").lower() or "secret" in (s.get("run") or "").lower()
                       for s in (j.get("steps") or []))]
if not secret_lanes:
    violation("secret-scan lane missing: no job runs the secret scan")

# R5-R7: physical device jobs
device_jobs = {}
for jn, j in jobs.items():
    runs_on = j.get("runs-on") or []
    if isinstance(runs_on, str):
        runs_on = [runs_on]
    if any("harmonyos-device" in str(r) for r in runs_on):
        device_jobs[jn] = j

if len(device_jobs) < 2:
    violation(f"expected 2 physical device jobs (tablet + 2-in-1), found {len(device_jobs)}")

for jn, j in device_jobs.items():
    # self-hosted requirement
    runs_on = j.get("runs-on") or []
    if isinstance(runs_on, str):
        runs_on = [runs_on]
    if not any("self-hosted" in str(r) for r in runs_on):
        violation(f"device job '{jn}' is not self-hosted (runs-on: {runs_on})")
    # required: no continue-on-error
    if j.get("continue-on-error") is True or str(j.get("continue-on-error", "false")).lower() == "true":
        violation(f"device job '{jn}' uses continue-on-error: true — device gates must be required")
    # release-gated
    gate = j.get("if") or ""
    if "github.event_name == 'release'" not in gate and "github.event_name == \"release\"" not in gate:
        violation(f"device job '{jn}' is not gated on release events: if: {gate or '(none)'}")
    if "refs/tags/" not in gate:
        violation(f"device job '{jn}' is not gated on tag pushes (refs/tags/): if: {gate or '(none)'}")

if v:
    print("POLICY VIOLATIONS:", file=sys.stderr)
    for msg in v:
        print(f"  - {msg}", file=sys.stderr)
    sys.exit(1)
print("policy check PASS: dual-ABI, license/SBOM, secret-scan and required release-gated device jobs all present")
sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# grep fallback path (documented structural checks)
# ---------------------------------------------------------------------------
check_with_grep() {
  local content
  content=$(cat "$WORKFLOW")

  # R1/R2: build-target.sh invocations per ABI
  if ! grep -qE 'build-target\.sh[[:space:]]+arm64-v8a' "$WORKFLOW"; then
    violation "arm64-v8a build lane missing: no 'build-target.sh arm64-v8a' step"
  fi
  if ! grep -qE 'build-target\.sh[[:space:]]+x86_64' "$WORKFLOW"; then
    violation "x86_64 build lane missing: no 'build-target.sh x86_64' step"
  fi

  # R3: license/SBOM lane
  if ! grep -qE 'check-licenses\.sh' "$WORKFLOW"; then
    violation "license/SBOM lane missing: no 'check-licenses.sh' step"
  fi

  # R4: secret-scan lane
  if ! grep -qE 'secret' "$WORKFLOW"; then
    violation "secret-scan lane missing: no secret scan job"
  fi

  # R5: two self-hosted harmonyos-device jobs
  device_job_lines=$(grep -nE 'harmonyos-device' "$WORKFLOW")
  device_job_count=$(printf '%s\n' "$device_job_lines" | grep -c . || true)
  if [ "$device_job_count" -lt 2 ]; then
    violation "expected 2 physical device jobs (runs-on [self-hosted, harmonyos-device]), found ${device_job_count}"
  fi

  # R6/R7: device jobs required and release-gated. Structural checks:
  # - the two device job blocks (device-tablet / device-2in1) must each contain
  #   an `if:` release gate and must NOT set continue-on-error.
  for job in device-tablet device-2in1; do
    if ! grep -qE "^[[:space:]]*${job}:" "$WORKFLOW"; then
      violation "device job '${job}' missing"
      continue
    fi
    # extract the job block (up to the next ^  job: at same indent)
    block=$(awk -v job="${job}:" '
      $0 ~ ("^  " job) { inblock=1 }
      inblock && $0 ~ /^  [a-zA-Z0-9_-]+:/ && $0 !~ ("^  " job) { inblock=0 }
      inblock { print }
    ' "$WORKFLOW")
    if ! printf '%s\n' "$block" | grep -qE "github.event_name == ['\"]release['\"]|github\.event_name == \"release\""; then
      violation "device job '${job}' is not gated on release events"
    fi
    if ! printf '%s\n' "$block" | grep -q "refs/tags/"; then
      violation "device job '${job}' is not gated on tag pushes (refs/tags/)"
    fi
    if printf '%s\n' "$block" | grep -qE 'continue-on-error:[[:space:]]*true'; then
      violation "device job '${job}' uses continue-on-error: true — device gates must be required"
    fi
    if ! printf '%s\n' "$block" | grep -qE 'runs-on:[[:space:]]*\['; then
      violation "device job '${job}' missing runs-on list"
    fi
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if python3 -c 'import yaml' 2>/dev/null; then
  if ! out=$(check_with_python 2>&1); then
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out"
else
  echo "WARN: python3 yaml unavailable; using grep-based structural checks" >&2
  check_with_grep
  if [ "$violations" -ne 0 ]; then
    exit 1
  fi
  echo "policy check PASS (grep): required lanes and device gates present"
fi

exit 0
