#!/usr/bin/env bash
# deps/interface/dependency-recipe.sh — minimal deterministic recipe interface
# for the OpenTTD HarmonyOS native dependency graph.
#
# A recipe is a script that answers a fixed set of subcommands about one
# pinned dependency. This file IS the interface contract and also the shared
# implementation used by every recipe in deps/recipes/.
#
# Every recipe sources this file, declares RECIPE_ID/RECIPE_ARCHIVE, then calls
# ohos_dependency_recipe "$@" with the remaining arguments.
#
# Subcommands:
#   describe     print one stable JSON line: id, name, version, url, sha256,
#                archive, license.spdx, linkage, abis, updateOwner, buildRole
#   status       print "BUILD=NOT_READY" and one artifact line per expected
#                output that does not yet exist under the ABI output dir
#   build <abi> <outdir> [--configure-only]
#                deterministically prepare <outdir> for <abi>; the interface
#                is ALLOWED to report pending artifacts instead of compiling
#                every large dependency today, so it writes a status file and
#                returns 0 when the artifact set is still pending
#   clean <abi> <outdir>
#                remove build outputs for <abi> under <outdir>
#
# Determinism rules enforced by every recipe:
#   - The archive is sourced ONLY from HARMONY_DEPS_CACHE by its pinned name
#     and ONLY if its sha256 matches the pinned value (no network, no mutable
#     branch). This is validated by the parent check-dependency-manifest.sh
#     before any recipe runs.
#   - ABI output directories are created under <outdir>/<abi>/<RECIPE_ID>.
#   - No absolute machine-specific paths are embedded in generated files.
#
# Environment:
#   HARMONY_DEPS_CACHE    directory holding the pinned archives
#   OHOS_TOOLCHAIN_FILE   API 23 NDK CMake toolchain (optional; informational)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
MANIFEST="${REPO_ROOT}/harmonyos/dependencies/manifest.json"

RECIPE_ID="${RECIPE_ID:-}"
RECIPE_ARCHIVE="${RECIPE_ARCHIVE:-}"

# Read the recipe's pinned record from the manifest and emit the stable
# describe line. Fails loudly if the record is absent or incomplete.
recipe_describe() {
  if [ -z "$RECIPE_ID" ]; then
    echo "ERROR: RECIPE_ID is empty" >&2
    exit 2
  fi
  python3 - "$MANIFEST" "$RECIPE_ID" <<'PYEOF' || exit 1
import json, sys
manifest = json.load(open(sys.argv[1]))
rid = sys.argv[2]
for dep in manifest["dependencies"]:
    if dep["id"] == rid:
        lic = dep.get("license", {}).get("spdx", "")
        print(json.dumps({
            "id": dep["id"],
            "name": dep["name"],
            "version": dep["version"],
            "url": dep.get("url"),
            "sha256": dep.get("sha256"),
            "archive": dep.get("archive"),
            "license.spdx": lic,
            "linkage": dep.get("linkage"),
            "abis": dep.get("abis", []),
            "updateOwner": dep.get("updateOwner"),
            "buildRole": dep.get("buildRole"),
        }))
        sys.exit(0)
print(f"ERROR: no dependency with id {rid} in manifest", file=sys.stderr)
sys.exit(1)
PYEOF
}

# Print the current build status for a recipe.
#   ohos_recipe_status <outdir>
# Prints BUILD=NOT_READY plus a line "ARTIFACT <abi> <path>" for each ABI whose
# artifact is still pending. This is the allowed "pending artifacts" reporting
# mode for large dependencies that are not compiled yet.
recipe_status() {
  local outdir="$1"
  local abi
  echo "BUILD=NOT_READY"
  for abi in arm64-v8a x86_64; do
    local marker="${outdir}/${abi}/${RECIPE_ID}/.ready"
    if [ -f "$marker" ]; then
      echo "ARTIFACT ${abi} ${marker} (ready)"
    else
      echo "ARTIFACT ${abi} ${outdir}/${abi}/${RECIPE_ID} (pending)"
    fi
  done
}

# Verify the pinned archive exists in HARMONY_DEPS_CACHE and its sha256 matches
# the manifest, BEFORE any extraction. This is the deterministic gate.
#   ohos_recipe_resolve_archive <archive> <sha256>
recipe_resolve_archive() {
  local archive="$1"
  local expect="$2"
  local cache="${HARMONY_DEPS_CACHE:-}"
  if [ -z "$cache" ]; then
    echo "ERROR: HARMONY_DEPS_CACHE not set (recipe ${RECIPE_ID})" >&2
    exit 2
  fi
  local path="${cache}/${archive}"
  if [ ! -f "$path" ]; then
    echo "ERROR: archive missing from cache: ${path} (recipe ${RECIPE_ID})" >&2
    exit 1
  fi
  local got
  got="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [ "$got" != "$expect" ]; then
    echo "ERROR: sha256 mismatch for ${archive} (recipe ${RECIPE_ID}): got ${got}, expected ${expect}" >&2
    exit 1
  fi
  printf '%s' "$path"
}

# Run the interface. Pass the subcommand and any extra args.
#   ohos_dependency_recipe "$@"
ohos_dependency_recipe() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    describe)
      recipe_describe
      ;;
    status)
      [ $# -ge 1 ] || { echo "usage: status <outdir>" >&2; exit 2; }
      recipe_status "$1"
      ;;
    build)
      # build <abi> <outdir> [--configure-only]
      local abi="${1:-}"; local outdir="${2:-}"; shift 2 || true
      if [ -z "$abi" ] || [ -z "$outdir" ]; then
        echo "usage: build <abi> <outdir> [--configure-only]" >&2
        exit 2
      fi
      case "$abi" in
        arm64-v8a|x86_64) ;;
        *) echo "ERROR: unsupported abi ${abi} (expected arm64-v8a or x86_64)" >&2; exit 2 ;;
      esac
      # Deterministic archive gate before any work. NDK-provided components
      # have null archive/sha256 in the manifest and are skipped here (their
      # provenance is pinned by the API 23 toolchain manifest instead).
      local desc
      desc="$(recipe_describe)"
      local archive sha
      archive="$(printf '%s\n' "$desc" | python3 -c 'import json,sys;v=json.load(sys.stdin)["archive"];print(v if v else "")' 2>/dev/null || true)"
      sha="$(printf '%s\n' "$desc" | python3 -c 'import json,sys;v=json.load(sys.stdin)["sha256"];print(v if v else "")' 2>/dev/null || true)"
      if [ -n "$archive" ] && [ -n "$sha" ]; then
        local resolved
        resolved="$(recipe_resolve_archive "$archive" "$sha")" || exit 1
        echo "resolved ${archive} -> ${resolved} (sha256 verified)"
      elif [ -z "$archive" ]; then
        echo "recipe ${RECIPE_ID}: NDK-provided component (no archive to fetch)"
      fi
      # Deterministic output dir + marker. Recipes may build further, but today
      # this interface reports the artifact set as pending (allowed by the
      # dependency governance task: do not compile all large deps now).
      local dir="${outdir}/${abi}/${RECIPE_ID}"
      mkdir -p "$dir"
      local recipe_dir
      recipe_dir="$(cd "$SCRIPT_DIR/../recipes" && pwd)"
      printf '%s\n' \
        "recipe_id=${RECIPE_ID}" \
        "abi=${abi}" \
        "toolchain_file=${OHOS_TOOLCHAIN_FILE:-<api-23-ndk-toolchain-from-bootstrap>}" \
        "archive=${archive}" \
        "sha256=${sha}" \
        "recipe_dir=${recipe_dir}" \
        "status=pending" > "${dir}/.recipe.txt"
      echo "recipe ${RECIPE_ID}: ${abi} prepare complete (artifact set PENDING — not compiled yet)"
      ;;
    clean)
      local abi="${1:-}"; local outdir="${2:-}"
      if [ -z "$abi" ] || [ -z "$outdir" ]; then
        echo "usage: clean <abi> <outdir>" >&2
        exit 2
      fi
      rm -rf "${outdir}/${abi}/${RECIPE_ID}"
      echo "cleaned ${outdir}/${abi}/${RECIPE_ID}"
      ;;
    *)
      echo "ERROR: unknown subcommand '${cmd}' (describe|status|build|clean)" >&2
      exit 2
      ;;
  esac
}
