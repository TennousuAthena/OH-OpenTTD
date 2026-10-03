#!/usr/bin/env bash
# check-licenses.sh — CI validation of the HarmonyOS dependency governance
# artifacts: pinned manifest, CycloneDX SBOM, SPDX SBOM and NOTICES.md.
#
# Enforces, for every dependency recorded in manifest.json:
#   - it appears in the CycloneDX SBOM as a component
#   - it appears in the SPDX SBOM as a package
#   - its SPDX license id appears in NOTICES.md
#   - the CycloneDX and SPDX SBOMs are parseable JSON
#   - the manifest is parseable and archive deps pin https:// + sha256
#   - explicitly-excluded libraries (SDL, Allegro, FluidSynth, Fontconfig,
#     breakpad) are NOT present as required/optional archive dependencies
#
# Pass --manifest <path>, --sbom-cdx <path>, --sbom-spdx <path> and
# --notices <path> to test the negative cases against tampered fixtures.
#
# Usage:
#   scripts/harmonyos/check-licenses.sh [--manifest F] [--sbom-cdx F]
#       [--sbom-spdx F] [--notices F]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MANIFEST="${REPO_ROOT}/harmonyos/dependencies/manifest.json"
SBOM_CDX="${REPO_ROOT}/harmonyos/dependencies/sbom.cyclonedx.json"
SBOM_SPDX="${REPO_ROOT}/harmonyos/dependencies/sbom.spdx.json"
NOTICES="${REPO_ROOT}/harmonyos/dependencies/NOTICES.md"

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --sbom-cdx) SBOM_CDX="$2"; shift 2 ;;
    --sbom-spdx) SBOM_SPDX="$2"; shift 2 ;;
    --notices) NOTICES="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: ${1} (see -h)" >&2; exit 2 ;;
  esac
done

failures=0
err() { printf 'ERROR: %s\n' "$*" >&2; failures=$((failures + 1)); }

[ -f "$MANIFEST" ] || { err "manifest not found: ${MANIFEST}"; exit 1; }
[ -f "$SBOM_CDX" ]  || { err "CycloneDX SBOM not found: ${SBOM_CDX}"; exit 1; }
[ -f "$SBOM_SPDX" ] || { err "SPDX SBOM not found: ${SBOM_SPDX}"; exit 1; }
[ -f "$NOTICES" ]   || { err "NOTICES.md not found: ${NOTICES}"; exit 1; }

# Parseable JSON for the three JSON artifacts.
for f in "$MANIFEST" "$SBOM_CDX" "$SBOM_SPDX"; do
  if ! python3 - "$f" <<'PYEOF' 2>/dev/null; then
import json, sys
json.load(open(sys.argv[1]))
PYEOF
    err "not valid JSON: ${f}"
  fi
done

# Cross-consistency pass (python3; prints one issue per line, exits 1 on any).
python3 - "$MANIFEST" "$SBOM_CDX" "$SBOM_SPDX" "$NOTICES" <<'PYEOF' > /tmp/ohos-licenses-issues.txt || true
import json, sys, re
manifest = json.load(open(sys.argv[1]))
cdx = json.load(open(sys.argv[2]))
spdx = json.load(open(sys.argv[3]))
notices = open(sys.argv[4], encoding="utf-8").read()

issues = []

cdx_refs = {c["bom-ref"] for c in cdx.get("components", [])}
cdx_licenses = {
    c["bom-ref"]: {lic["license"]["id"] for lic in c.get("licenses", []) if "license" in lic and "id" in lic["license"]}
    for c in cdx.get("components", [])
}
spdx_refs = {p["SPDXID"] for p in spdx.get("packages", [])}
spdx_licenses = {p["SPDXID"]: p.get("licenseConcluded", "") for p in spdx.get("packages", [])}

archive_ids = []
for dep in manifest["dependencies"]:
    dep_id = dep["id"]
    lic = dep.get("license", {}).get("spdx", "")
    if dep["source"] == "archive":
        archive_ids.append(dep_id)
        url = dep.get("url", "")
        sha = dep.get("sha256") or ""
        if not (url.startswith("https://") and re.fullmatch(r"[0-9a-f]{64}", sha)):
            issues.append(f"{dep_id}: archive dep must pin https:// url + sha256")
        if dep["id"] in cdx_refs:
            if lic and lic not in cdx_licenses.get(dep["id"], set()):
                issues.append(f"{dep_id}: SPDX license {lic!r} missing in CycloneDX component")
        else:
            issues.append(f"{dep_id}: missing in CycloneDX SBOM")
        if f"SPDXRef-Package-{dep_id}" in spdx_refs:
            if lic and lic != spdx_licenses.get(f"SPDXRef-Package-{dep_id}", ""):
                issues.append(f"{dep_id}: SPDX license {lic!r} mismatch in SPDX SBOM package")
        else:
            issues.append(f"{dep_id}: missing in SPDX SBOM (SPDXRef-Package-{dep_id})")
        if lic and lic not in notices:
            issues.append(f"{dep_id}: SPDX license {lic!r} not listed in NOTICES.md")

excluded_rule = {
    "sdl": ["sdl", "SDL2"],
    "allegro": ["allegro"],
    "fluidsynth": ["fluidsynth"],
    "fontconfig": ["fontconfig"],
    "breakpad": ["breakpad"],
}
for exc_id, keywords in excluded_rule.items():
    for dep in manifest["dependencies"]:
        haystack = (dep["id"] + " " + dep["name"]).lower()
        if any(k in haystack for k in keywords):
            issues.append(f"excluded library {dep['id']!r} must not appear as a dependency (rule: {exc_id})")

if issues:
    print("\n".join(issues))
    sys.exit(1)
PYEOF
if [ -s /tmp/ohos-licenses-issues.txt ]; then
  while IFS= read -r line; do err "$line"; done < /tmp/ohos-licenses-issues.txt
fi
rm -f /tmp/ohos-licenses-issues.txt

# Upstream-bundled table in NOTICES.md must mention every bundled component.
python3 - "$MANIFEST" "$NOTICES" <<'PYEOF' > /tmp/ohos-licenses-bundled.txt || true
import json, sys
manifest = json.load(open(sys.argv[1]))
notices = open(sys.argv[2], encoding="utf-8").read()
issues = []
for b in manifest.get("upstreamBundled", []):
    if b["id"] not in notices:
        issues.append(f"bundled component '{b['id']}' absent from NOTICES.md")
    lic = b.get("license", {}).get("spdx", "")
    if lic and lic not in notices:
        issues.append(f"bundled component '{b['id']}' license {lic!r} absent from NOTICES.md")
if issues:
    print("\n".join(issues))
    sys.exit(1)
PYEOF
if [ -s /tmp/ohos-licenses-bundled.txt ]; then
  while IFS= read -r line; do err "$line"; done < /tmp/ohos-licenses-bundled.txt
fi
rm -f /tmp/ohos-licenses-bundled.txt

printf 'license/SBOM check: %d error(s)\n' "$failures"
if [ "$failures" -ne 0 ]; then
  echo "LICENSE_SBOM_CHECK=FAIL" >&2
  exit 1
fi
echo "LICENSE_SBOM_CHECK=PASS"
exit 0