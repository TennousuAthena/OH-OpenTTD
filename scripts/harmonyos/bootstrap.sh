#!/usr/bin/env bash
# bootstrap.sh — deterministic DevEco SDK discovery and toolchain validation
# for the OpenTTD HarmonyOS port.
#
# Discovers the DevEco Studio SDK (via DEVECO_SDK_HOME, with the verified
# local app path only as a non-committed fallback), validates the API 26
# native sysroots / Clang / CMake / Ninja / Node / Hvigor / ohpm, and on
# full success atomically writes build/harmonyos/toolchain-manifest.json.
#
# Usage:
#   scripts/harmonyos/bootstrap.sh [--check-only]   # default
#   scripts/harmonyos/bootstrap.sh -h
#
# On any validation failure the script exits nonzero and NEVER creates or
# mutates build/. No user-specific absolute paths are embedded in output.

set -euo pipefail

# Resolve REPO_ROOT from this script's location (scripts/harmonyos/..).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
CHECK_ONLY=1   # default (and only) operational mode: validate, emit manifest
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
bootstrap.sh — deterministic DevEco SDK discovery and toolchain validation

Usage:
  scripts/harmonyos/bootstrap.sh [--check-only]   # default
  scripts/harmonyos/bootstrap.sh -h

Environment:
  DEVECO_SDK_HOME   DevEco Studio SDK root (default: /Applications/DevEco-Studio.app/Contents/sdk/default)
  DEVECO_HOME       DevEco Studio tools root (default: /Applications/DevEco-Studio.app/Contents/tools)

On successful validation (default and only mode, --check-only) it atomically
writes build/harmonyos/toolchain-manifest.json and prints the manifest to stdout.
On any validation failure it exits nonzero and never creates or mutates build/.
EOF
      exit 0
      ;;
    --check-only)
      CHECK_ONLY=1
      ;;
    *)
      ohos_error "unknown argument: ${arg} (see -h)"
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
SDK="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default}"
TOOLS="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents/tools}"
if [ -d "${SDK}/default/openharmony/native" ]; then
  SDK="${SDK}/default"
fi
ndk_path="${SDK}/openharmony/native"
hmos_sdk_path="${SDK}/hms/native"

ohos_info "SDK:   ${SDK}"
ohos_info "Tools: ${TOOLS}"

# ---------------------------------------------------------------------------
# Validation (collect ALL errors, print each precisely, exit 1 if any)
# ---------------------------------------------------------------------------
errors=0

# --- API 26 component metadata (DevEco 26 SDK layout) ------------------------
sdk_pkg="${ndk_path}/oh-uni-package.json"
if [ -f "$sdk_pkg" ]; then
  api_version="$(sed -n 's/.*"apiVersion"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$sdk_pkg" | head -n1 || true)"
  sdk_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sdk_pkg" | head -n1 || true)"
  if [ "$api_version" != "26" ]; then
    ohos_error "native SDK apiVersion is '${api_version}', expected '26': ${sdk_pkg}"
    errors=$((errors + 1))
  fi
  case "$sdk_version" in
    26.0.*) ;;
    *)
      ohos_error "native SDK version '${sdk_version}' does not start with '26.0.': ${sdk_pkg}"
      errors=$((errors + 1))
      ;;
  esac
else
  ohos_error "missing API 26 native SDK metadata: ${sdk_pkg}"
  errors=$((errors + 1))
  api_version=""
  sdk_version=""
fi

# --- toolchain file ---------------------------------------------------------
toolchain_file="${hmos_sdk_path}/build/cmake/hmos.toolchain.cmake"
ohos_check_file "$toolchain_file" "HarmonyOS CMake toolchain file" || errors=$((errors + 1))

# --- clang ------------------------------------------------------------------
clang_bin="${ndk_path}/llvm/bin/clang"
clang_version=""
if [ -x "$clang_bin" ]; then
  clang_version="$("$clang_bin" --version 2>/dev/null | head -n1 || true)"
  if [ -z "$clang_version" ]; then
    ohos_error "clang --version produced no output: ${clang_bin}"
    errors=$((errors + 1))
  fi
else
  ohos_error "missing required clang (not executable): ${clang_bin}"
  errors=$((errors + 1))
fi

# --- sysroots ---------------------------------------------------------------
# Required triples: aarch64-linux-ohos, x86_64-linux-ohos (error names the triple)
# arm-linux-ohos is warn-only.
sysroot_base="${ndk_path}/sysroot/usr/lib"
for triple in aarch64-linux-ohos x86_64-linux-ohos; do
  if [ ! -d "${sysroot_base}/${triple}" ]; then
    ohos_error "missing required sysroot for target triple '${triple}': ${sysroot_base}/${triple}"
    errors=$((errors + 1))
  fi
done
if [ ! -d "${sysroot_base}/arm-linux-ohos" ]; then
  ohos_warn "arm-linux-ohos sysroot not present (warn-only): ${sysroot_base}/arm-linux-ohos"
fi

# --- cmake + ninja ----------------------------------------------------------
cmake_bin="${ndk_path}/build-tools/cmake/bin/cmake"
ninja_bin="${ndk_path}/build-tools/cmake/bin/ninja"
cmake_version=""
ninja_version=""
if [ -x "$cmake_bin" ]; then
  cmake_version="$("$cmake_bin" --version 2>/dev/null | head -n1 || true)"
  if [ -z "$cmake_version" ]; then
    ohos_error "cmake --version produced no output: ${cmake_bin}"
    errors=$((errors + 1))
  fi
elif command -v cmake >/dev/null 2>&1; then
  cmake_bin="$(command -v cmake)"
  cmake_version="$("$cmake_bin" --version 2>/dev/null | head -n1 || true)"
else
  ohos_error "missing required cmake (not in SDK and not on PATH)"
  errors=$((errors + 1))
fi
if [ -x "$ninja_bin" ]; then
  ninja_version="$("$ninja_bin" --version 2>/dev/null || true)"
  if [ -z "$ninja_version" ]; then
    ohos_error "ninja --version produced no output: ${ninja_bin}"
    errors=$((errors + 1))
  fi
elif command -v ninja >/dev/null 2>&1; then
  ninja_bin="$(command -v ninja)"
  ninja_version="$("$ninja_bin" --version 2>/dev/null || true)"
else
  ohos_error "missing required ninja (not in SDK and not on PATH)"
  errors=$((errors + 1))
fi

# --- node -------------------------------------------------------------------
node_bin="${TOOLS}/node/bin/node"
export PATH="${TOOLS}/node/bin:$PATH"
node_version=""
if [ -x "$node_bin" ]; then
  node_version="$("$node_bin" --version 2>/dev/null || true)"
  if [ -z "$node_version" ]; then
    ohos_error "node --version produced no output: ${node_bin}"
    errors=$((errors + 1))
  fi
elif command -v node >/dev/null 2>&1; then
  node_bin="$(command -v node)"
  node_version="$("$node_bin" --version 2>/dev/null || true)"
else
  ohos_error "missing required node (not in tools and not on PATH)"
  errors=$((errors + 1))
fi

# --- hvigor -----------------------------------------------------------------
hvigorw_js="${TOOLS}/hvigor/bin/hvigorw.js"
hvigor_version=""
if [ -f "$hvigorw_js" ] && [ -n "$node_bin" ] && [ -x "$node_bin" ]; then
  hvigor_version="$("$node_bin" "$hvigorw_js" --version 2>/dev/null | head -n1 || true)"
  if [ -z "$hvigor_version" ]; then
    ohos_error "hvigorw.js --version produced no output: ${hvigorw_js}"
    errors=$((errors + 1))
  fi
else
  ohos_error "missing required hvigorw.js: ${hvigorw_js}"
  errors=$((errors + 1))
fi

# --- ohpm -------------------------------------------------------------------
ohpm_bin="${TOOLS}/ohpm/bin/ohpm"
ohpm_version=""
if [ -x "$ohpm_bin" ]; then
  ohpm_version="$("$ohpm_bin" --version 2>/dev/null | head -n1 || true)"
  if [ -z "$ohpm_version" ]; then
    ohos_error "ohpm --version produced no output: ${ohpm_bin}"
    errors=$((errors + 1))
  fi
else
  ohos_error "missing required ohpm (not executable): ${ohpm_bin}"
  errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# Abort on any validation failure — never create/mutate build/
# ---------------------------------------------------------------------------
if [ "$errors" -ne 0 ]; then
  ohos_error "toolchain validation failed with ${errors} error(s); build/ left untouched"
  exit 1
fi

# ---------------------------------------------------------------------------
# Build manifest
# ---------------------------------------------------------------------------
target_triples=(aarch64-linux-ohos x86_64-linux-ohos)
abi_filters=(arm64-v8a x86_64)
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

manifest=$(
  printf '{\n'
  printf '  %s,\n' "$(ohos_json_string_field "sdkPath" "$SDK")"
  printf '  %s,\n' "$(ohos_json_number_field "apiVersion" "$api_version")"
  printf '  %s,\n' "$(ohos_json_string_field "sdkVersion" "$sdk_version")"
  printf '  %s,\n' "$(ohos_json_string_field "ndkPath" "$ndk_path")"
  printf '  %s,\n' "$(ohos_json_string_field "hmosSdkPath" "$hmos_sdk_path")"
  printf '  %s,\n' "$(ohos_json_string_field "toolsPath" "$TOOLS")"
  printf '  %s,\n' "$(ohos_json_string_field "cmakePath" "$cmake_bin")"
  printf '  %s,\n' "$(ohos_json_string_field "ninjaPath" "$ninja_bin")"
  printf '  %s,\n' "$(ohos_json_string_field "toolchainFile" "$toolchain_file")"
  printf '  %s,\n' "$(ohos_json_string_field "clangVersion" "$clang_version")"
  printf '  %s,\n' "$(ohos_json_string_field "cmakeVersion" "$cmake_version")"
  printf '  %s,\n' "$(ohos_json_string_field "ninjaVersion" "$ninja_version")"
  printf '  %s,\n' "$(ohos_json_string_field "nodeVersion" "$node_version")"
  printf '  %s,\n' "$(ohos_json_string_field "hvigorVersion" "$hvigor_version")"
  printf '  %s,\n' "$(ohos_json_string_field "ohpmVersion" "$ohpm_version")"
  printf '  "targetTriples": %s,\n' "$(ohos_json_string_array "${target_triples[@]}")"
  printf '  "abiFilters": %s,\n' "$(ohos_json_string_array "${abi_filters[@]}")"
  printf '  %s\n' "$(ohos_json_string_field "generatedAt" "$generated_at")"
  printf '}\n'
)

# ---------------------------------------------------------------------------
# Emit / write. --check-only is the default and only operational mode; it still
# atomically emits the manifest (the deliverable) on full success.
# ---------------------------------------------------------------------------
manifest_dir="${REPO_ROOT}/build/harmonyos"
manifest_file="${manifest_dir}/toolchain-manifest.json"
mkdir -p "$manifest_dir"
# Atomic write: write to temp in same dir, then rename over target.
tmp_file="${manifest_file}.tmp.$$"
printf '%s\n' "$manifest" > "$tmp_file"
mv "$tmp_file" "$manifest_file"
ohos_info "wrote ${manifest_file}"
printf '%s\n' "$manifest"
