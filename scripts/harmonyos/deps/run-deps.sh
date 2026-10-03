#!/usr/bin/env bash
# deps/run-deps.sh — driver over the dependency recipe interface.
#
# Builds (prepares) one or all pinned dependencies for arm64-v8a and x86_64
# under <outdir>/<abi>/<recipe-id>/. The recipe interface is allowed to report
# pending artifacts instead of compiling every large dependency today; this
# driver exercises the deterministic interface deterministically.
#
# Usage:
#   scripts/harmonyos/deps/run-deps.sh build --cache DIR --out DIR [--dep ID|--all]
#   scripts/harmonyos/deps/run-deps.sh status --cache DIR --out DIR [--dep ID|--all]
#   scripts/harmonyos/deps/run-deps.sh describe --dep ID
#   scripts/harmonyos/deps/run-deps.sh -h
#
# Environment:
#   HARMONY_DEPS_CACHE   required for build/status (archive source, sha-gated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MANIFEST="${REPO_ROOT}/harmonyos/dependencies/manifest.json"
RECIPES_DIR="${SCRIPT_DIR}/recipes"

CMD=""
CACHE=""
OUT=""
DEP=""
ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    build|status|describe|clean) CMD="$1"; shift ;;
    --cache) CACHE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dep) DEP="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: ${1} (see -h)" >&2; exit 2 ;;
  esac
done

[ -n "$CMD" ] || { echo "ERROR: missing command (build|status|describe|clean)" >&2; exit 2; }
[ -n "$DEP" ] || [ "$ALL" -eq 1 ] || { echo "ERROR: --dep ID or --all is required" >&2; exit 2; }

if [ "$CMD" = "build" ] || [ "$CMD" = "status" ] || [ "$CMD" = "clean" ]; then
  [ -n "$CACHE" ] || { echo "ERROR: --cache DIR is required for ${CMD}" >&2; exit 2; }
  [ -n "$OUT" ] || { echo "ERROR: --out DIR is required for ${CMD}" >&2; exit 2; }
  export HARMONY_DEPS_CACHE="$CACHE"
fi

recipe_list() {
  if [ "$ALL" -eq 1 ]; then
    python3 - "$MANIFEST" <<'PYEOF'
import json, sys
manifest = json.load(open(sys.argv[1]))
for dep in manifest["dependencies"]:
    print(dep["id"])
PYEOF
  else
    printf '%s\n' "$DEP"
  fi
}

rc=0
for rid in $(recipe_list); do
  recipe="${RECIPES_DIR}/${rid}.sh"
  if [ ! -f "$recipe" ]; then
    echo "ERROR: no recipe for dependency '${rid}': ${recipe}" >&2
    rc=1
    continue
  fi
  echo "=== ${rid} ==="
  case "$CMD" in
    describe)
      bash "$recipe" describe
      ;;
    build)
      for abi in arm64-v8a x86_64; do
        bash "$recipe" build "$abi" "$OUT" || rc=1
      done
      ;;
    status)
      bash "$recipe" status "$OUT"
      ;;
    clean)
      for abi in arm64-v8a x86_64; do
        bash "$recipe" clean "$abi" "$OUT"
      done
      ;;
  esac
done
exit "$rc"