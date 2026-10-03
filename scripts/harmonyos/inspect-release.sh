#!/usr/bin/env bash
# inspect-release.sh — validate an AppGallery-ready OpenTTD HarmonyOS release
# artifact (a dual-ABI HAP produced by scripts/harmonyos/package.sh).
#
# Checks, and FAILS with a precise message on any violation:
#   R1. bundle name   == org.openttd.openttd
#   R2. versionName   == 15.3
#   R3. versionCode   == 15000300
#   R4. deviceTypes   contains tablet AND 2in1
#   R5. permission    ohos.permission.INTERNET declared
#   R6. both ABIs present in libs/ (arm64-v8a AND x86_64)
#   R7. required rawfile resources present (baseset/openttd.grf, lang/english.lng,
#       lang/*.lng, and no undeclared shared libraries beyond the HAP's own libs/)
#   R8. SBOM + license files present (SPDX, CycloneDX, manifest, NOTICES, SOURCE_OFFER)
#   R9. no secrets: no [/]Users/, .p1[2], PRIVATE KEY anywhere in the artifact tree
#
# `--self-test` runs the negative case (remove one ABI -> inspector MUST block
# the release) against a scratch copy, proving the gate actually fires.
#
# Usage:
#   scripts/harmonyos/inspect-release.sh <release-dir-or-hap> [--self-test]
#   scripts/harmonyos/inspect-release.sh -h
#
# Exit: 0 = release valid, 1 = any check failed (or self-test proved the gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SELF_TEST=0
INPUT=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --self-test)
      SELF_TEST=1
      ;;
    *)
      INPUT="$arg"
      ;;
  esac
done

[ -n "$INPUT" ] || { echo "ERROR: missing release artifact path" >&2; exit 2; }
# Resolve to an absolute path: the self-test extracts into a scratch dir and
# must keep the HAP path valid across the cd.
case "$INPUT" in
  /*) : ;;
  *) INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")" ;;
esac

failures=0
err() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# ---------------------------------------------------------------------------
# Resolve the input: either a release directory or a single HAP file.
# ---------------------------------------------------------------------------
RELEASE_DIR=""
HAP=""
if [ -d "$INPUT" ]; then
  RELEASE_DIR="$INPUT"
  HAP="$(find "$RELEASE_DIR" -maxdepth 1 -name '*.hap' | head -n1 || true)"
  [ -n "$HAP" ] || { echo "ERROR: no .hap found in release dir ${RELEASE_DIR}" >&2; exit 2; }
elif [ -f "$INPUT" ]; then
  case "$INPUT" in
    *.hap) HAP="$INPUT"; RELEASE_DIR="$(dirname "$INPUT")" ;;
    *) echo "ERROR: expected a .hap or a release directory, got: ${INPUT}" >&2; exit 2 ;;
  esac
else
  echo "ERROR: not found: ${INPUT}" >&2
  exit 2
fi

printf '[inspect] release: %s\n' "$HAP"
LISTING="$(unzip -l "$HAP")"

# ---------------------------------------------------------------------------
# R6: both ABIs present (checked first so --self-test can strip one ABI)
# ---------------------------------------------------------------------------
printf '%s\n' "$LISTING" | grep -q 'libs/arm64-v8a/' || err "ABI arm64-v8a missing from HAP (no libs/arm64-v8a/ entries)"
printf '%s\n' "$LISTING" | grep -q 'libs/x86_64/'    || err "ABI x86_64 missing from HAP (no libs/x86_64/ entries)"

# R6b: every ABI must carry the expected native libs.
for abi in arm64-v8a x86_64; do
  for lib in libentry.so libopenttd.so; do
    printf '%s\n' "$LISTING" | grep -q "libs/${abi}/${lib}" \
      || err "missing ${abi}/${lib} in HAP"
  done
done

# ---------------------------------------------------------------------------
# module.json assertions (bundle, version, deviceTypes, permission)
# ---------------------------------------------------------------------------
MODULE_JSON="$(unzip -p "$HAP" module.json 2>/dev/null)" || MODULE_JSON=""
[ -n "$MODULE_JSON" ] || err "module.json missing from HAP"

if [ -n "$MODULE_JSON" ]; then
  printf '%s' "$MODULE_JSON" | grep -q '"bundleName":"org.openttd.openttd"' \
    || printf '%s' "$MODULE_JSON" | grep -q '"bundleName": "org.openttd.openttd"' \
    || err "R1: bundleName is not org.openttd.openttd"

  printf '%s' "$MODULE_JSON" | grep -qE '"versionName"[[:space:]]*:[[:space:]]*"15\.3"' \
    || err "R2: versionName is not 15.3"

  printf '%s' "$MODULE_JSON" | grep -qE '"versionCode"[[:space:]]*:[[:space:]]*15000300' \
    || err "R3: versionCode is not 15000300"

  printf '%s' "$MODULE_JSON" | grep -q '"tablet"' || err "R4: deviceTypes missing tablet"
  printf '%s' "$MODULE_JSON" | grep -q '"2in1"'   || err "R4: deviceTypes missing 2in1"

  printf '%s' "$MODULE_JSON" | grep -q '"ohos.permission.INTERNET"' \
    || err "R5: INTERNET permission not declared"
fi

# ---------------------------------------------------------------------------
# R7: required rawfile resources present
# ---------------------------------------------------------------------------
rawfile_present() {
  printf '%s\n' "$LISTING" | grep -q "$1"
}
rawfile_present 'resources/rawfile/baseset/openttd.grf' || err "R7: baseset/openttd.grf not in rawfile"
rawfile_present 'resources/rawfile/lang/english.lng'    || err "R7: lang/english.lng not in rawfile"
LNG_COUNT="$(printf '%s\n' "$LISTING" | grep -c 'resources/rawfile/lang/.*\.lng' || true)"
[ "$LNG_COUNT" -ge 1 ] || err "R7: no .lng files packaged in rawfile"

# R7b: no undeclared shared libraries. Every .so under libs/ must be one of the
# native libs the HAP is built from (libentry, libopenttd, libc++_shared) OR be
# a known runtime system lib. Flag anything else.
SHARED_LIBS="$(printf '%s\n' "$LISTING" | grep -oE 'libs/[^ ]+\.so' | sed 's#libs/[^/]*/##' | sort -u || true)"
for lib in $SHARED_LIBS; do
  case "$lib" in
    libentry.so|libopenttd.so|libc++_shared.so) : ;;  # expected
    *) err "R7: undeclared shared library shipped: ${lib}" ;;
  esac
done

# ---------------------------------------------------------------------------
# R8: SBOM / license files present in the release directory
# ---------------------------------------------------------------------------
sbom_or_hap() {
  # Accept the file in the release dir, or embedded rawfile for HAP-only checks.
  [ -f "$RELEASE_DIR/$1" ] || printf '%s\n' "$LISTING" | grep -q "resources/rawfile/$1" \
    || err "R8: missing $1 (expected in release dir or rawfile)"
}
sbom_or_hap "sbom/sbom.spdx.json"
sbom_or_hap "sbom/sbom.cyclonedx.json"
sbom_or_hap "sbom/manifest.json"
sbom_or_hap "NOTICES.md"
[ -f "$RELEASE_DIR/SOURCE_OFFER.txt" ] || err "R8: SOURCE_OFFER.txt missing in release dir"
[ -f "$RELEASE_DIR/SHA256SUMS" ]        || err "R8: SHA256SUMS missing in release dir"
[ -f "$RELEASE_DIR/release-manifest.json" ] || err "R8: release-manifest.json missing in release dir"
[ -f "$RELEASE_DIR/symbols/buildid-map.json" ] || err "R8: symbols/buildid-map.json missing"

# ---------------------------------------------------------------------------
# R9: no secrets / machine-specific paths in the release tree
# ---------------------------------------------------------------------------
SECRET_HITS="$(grep -RIlE '[/]Users/|\.p1[2]|PRIVATE[ ]KEY|BEGIN[ ]RSA[ ]PRIVATE[ ]KEY' \
  "$RELEASE_DIR" 2>/dev/null || true)"
if [ -n "$SECRET_HITS" ]; then
  err "R9: secret/machine-path found in release tree:"
  printf '%s\n' "$SECRET_HITS" | sed 's/^/       /' >&2
fi
# Also scan the HAP payload itself (concatenated; -a treats binary as text).
if unzip -p "$HAP" 2>/dev/null | grep -aqE '[/]Users/|\.p1[2]|PRIVATE[ ]KEY'; then
  err "R9: secret/machine-path pattern found inside HAP payload"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
  printf '\n[inspect] RELEASE VALID: bundle/version/deviceTypes/permissions, both ABIs, rawfile resources, SBOM/licenses present, no secrets.\n'
  VALID=0
else
  printf '\n[inspect] RELEASE REJECTED (%d violation(s))\n' "$failures" >&2
  VALID=1
fi

# ---------------------------------------------------------------------------
# --self-test: the negative case — remove one ABI, the inspector MUST block.
# ---------------------------------------------------------------------------
if [ "$SELF_TEST" -eq 1 ]; then
  printf '\n[inspect] --self-test: proving one-ABI removal is blocked...\n'
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/openttd-inspect-selftest.XXXXXX")"
  trap 'rm -rf "$SCRATCH"' EXIT

  # Extract a single ABI out of the HAP into a scratch dir, keep the other checks.
  mkdir -p "$SCRATCH/single"
  (cd "$SCRATCH/single" && unzip -q "$HAP" 'libs/arm64-v8a/*' 'libs/x86_64/*')
  # Remove every x86_64 lib -> the HAP is now single-ABI.
  rm -rf "$SCRATCH/single/libs/x86_64"

  # Rebuild a synthetic HAP without x86_64 so unzip -l sees only arm64-v8a.
  SINGLE_HAP="$SCRATCH/one-abi.hap"
  (cd "$SCRATCH/single" && zip -qr "$SINGLE_HAP" .)

  if printf '%s\n' "$(unzip -l "$SINGLE_HAP")" | grep -q 'libs/x86_64/'; then
    echo "[inspect] SELF-TEST ERROR: scratch HAP still contains x86_64; cannot run negative case" >&2
    exit 1
  fi

  # Run the inspector on the single-ABI HAP; it MUST fail.
  set +e
  out="$(bash "$0" "$SINGLE_HAP" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    echo "[inspect] SELF-TEST FAIL: single-ABI artifact was NOT blocked" >&2
    exit 1
  fi
  printf '%s\n' "$out" | grep -q 'ABI x86_64 missing' || {
    echo "[inspect] SELF-TEST FAIL: inspector blocked for the wrong reason" >&2
    exit 1
  }
  echo "[inspect] SELF-TEST PASS: removing one ABI blocks the release (exit ${rc})"
fi

exit "$VALID"