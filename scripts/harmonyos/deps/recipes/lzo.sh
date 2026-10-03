#!/usr/bin/env bash
# Recipe for lzo (OpenTTD HarmonyOS port). See ../interface/dependency-recipe.sh
# for the interface contract this recipe implements.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../interface/dependency-recipe.sh
source "${SCRIPT_DIR}/../interface/dependency-recipe.sh"

RECIPE_ID="lzo"
# ARCHIVE is resolved from the manifest by the interface (recipe_resolve_archive).
ohos_dependency_recipe "$@"
