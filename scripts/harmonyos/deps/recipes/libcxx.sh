#!/usr/bin/env bash
# Recipe for libcxx (OpenTTD HarmonyOS port, NDK-provided).
# See ../interface/dependency-recipe.sh for the interface contract. This
# component ships in the API 23 NDK sysroot (pinned by bootstrap.sh), so it
# has no archive, url or sha256 — the interface skips archive resolution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../interface/dependency-recipe.sh
source "${SCRIPT_DIR}/../interface/dependency-recipe.sh"

RECIPE_ID="libcxx"
ohos_dependency_recipe "$@"
