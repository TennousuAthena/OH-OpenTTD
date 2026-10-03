#!/usr/bin/env bash
# build-host-tools.sh — build the OpenTTD host generators (strgen, settingsgen)
# natively on macOS for the HarmonyOS cross-build.
#
# These tools run on the build host (this macOS machine), NOT on the HarmonyOS
# target. They must therefore be compiled natively with the host toolchain —
# never with the OHOS cross toolchain — and validated as Mach-O executables.
# The generated strgen.cmake / settingsgen.cmake exports are then consumed by
# the later HarmonyOS target build via -DHOST_BINARY_DIR=<this dir>.
#
# Usage:
#   scripts/harmonyos/build-host-tools.sh            # build + validate + manifest
#   scripts/harmonyos/build-host-tools.sh --repro-check  # rebuild fresh + compare checksums
#   scripts/harmonyos/build-host-tools.sh -h
#
# On success it writes build/host-tools/manifest.json and exports HOST_BINARY_DIR
# to the caller's environment. No user-specific absolute paths are emitted.

set -euo pipefail

# Resolve REPO_ROOT from this script's location (scripts/harmonyos/..).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MODE="build"        # build | repro-check
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
build-host-tools.sh — build OpenTTD host generators (strgen, settingsgen) natively

Usage:
  scripts/harmonyos/build-host-tools.sh               # build tools + manifest
  scripts/harmonyos/build-host-tools.sh --repro-check # rebuild fresh dir + compare hashes
  scripts/harmonyos/build-host-tools.sh -h

The host generators run on the build host, so they are always compiled with the
host toolchain (never the OHOS cross toolchain) and are validated to be Mach-O
executables. The exported strgen.cmake/settingsgen.cmake are consumed by the
target build via: cmake .. -DHOST_BINARY_DIR=$REPO_ROOT/build/host-tools
EOF
      exit 0
      ;;
    --repro-check)
      MODE="repro-check"
      ;;
    *)
      ohos_error "unknown argument: ${arg} (see -h)"
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve cmake / ninja (same logic as bootstrap.sh): DevEco-bundled first,
# then PATH. These are host tools, so the DevEco cmake/ninja (universal
# macOS binaries) are fine to use to drive a native host build.
# ---------------------------------------------------------------------------
SDK="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default}"
if [ -d "${SDK}/default/openharmony/native" ]; then SDK="${SDK}/default"; fi
NATIVE_SDK="${SDK}/openharmony/native"
CMAKE_BIN="${DEVECO_CMAKE_BIN:-}"
NINJA_BIN="${DEVECO_NINJA_BIN:-}"
if [ -n "$CMAKE_BIN" ] && [ -x "$CMAKE_BIN" ]; then
  : # already resolved
elif [ -x "${NATIVE_SDK}/build-tools/cmake/bin/cmake" ]; then
  CMAKE_BIN="${NATIVE_SDK}/build-tools/cmake/bin/cmake"
elif command -v cmake >/dev/null 2>&1; then
  CMAKE_BIN="$(command -v cmake)"
else
  ohos_die "no cmake found (tried ${NATIVE_SDK}/build-tools/cmake/bin/cmake and PATH)"
fi
if [ -n "$NINJA_BIN" ] && [ -x "$NINJA_BIN" ]; then
  : # already resolved
elif [ -x "${NATIVE_SDK}/build-tools/cmake/bin/ninja" ]; then
  NINJA_BIN="${NATIVE_SDK}/build-tools/cmake/bin/ninja"
elif command -v ninja >/dev/null 2>&1; then
  NINJA_BIN="$(command -v ninja)"
else
  ohos_die "no ninja found (tried ${NATIVE_SDK}/build-tools/cmake/bin/ninja and PATH)"
fi

cmake_version="$("$CMAKE_BIN" --version 2>/dev/null | head -n1 || true)"
ninja_version="$("$NINJA_BIN" --version 2>/dev/null || true)"
ohos_info "cmake: ${CMAKE_BIN} (${cmake_version})"
ohos_info "ninja: ${NINJA_BIN} (${ninja_version})"

# ---------------------------------------------------------------------------
# Paths. Primary build dir: build/host-tools; repro dir: build/host-tools-repro.
# ---------------------------------------------------------------------------
HOST_BINARY_DIR="${REPO_ROOT}/build/host-tools"
REPRO_BINARY_DIR="${REPO_ROOT}/build/host-tools-repro"

# ---------------------------------------------------------------------------
# Mach-O validation.
# Rejects ELF (i.e. a HarmonyOS target binary accidentally placed in the host
# slot), naming the offending file and the platform mismatch precisely.
# ---------------------------------------------------------------------------
macos_is_macho() {
  local path="$1"
  local file_out
  file_out="$(file "$path")" || return 1
  if [[ "$file_out" == *"Mach-O"* ]]; then
    return 0
  fi
  if [[ "$file_out" == *"ELF"* ]]; then
    ohos_error "architecture mismatch: ${path} is an ELF (target/OHOS) binary, not a host Mach-O executable — a target binary leaked into the host slot"
    return 1
  fi
  ohos_error "architecture mismatch: ${path} is neither a Mach-O host executable nor a known ELF target binary ('${file_out}')"
  return 1
}

validate_host_binaries() {
  local dir="$1"
  local ok=0
  for tool in strgen settingsgen; do
    if [ ! -f "${dir}/${tool}" ]; then
      ohos_error "missing host tool binary: ${dir}/${tool}"
      ok=1
      continue
    fi
    if ! macos_is_macho "${dir}/${tool}"; then
      ok=1
    fi
  done
  return "$ok"
}

# ---------------------------------------------------------------------------
# sha256 helper
# ---------------------------------------------------------------------------
sha256_of() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    grep "[[:space:]]" < <(sha256sum "$path") | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Build host tools into <dir> using the host toolchain only (OPTION_TOOLS_ONLY).
# The generated binaries + exported cmake files land in <dir>.
# ---------------------------------------------------------------------------
build_host_tools() {
  local dir="$1"
  ohos_info "configuring host-only build in ${dir}"
  rm -rf "$dir"
  mkdir -p "$dir"
  pushd "$dir" >/dev/null
  "$CMAKE_BIN" "$REPO_ROOT" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DOPTION_TOOLS_ONLY=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$dir"
  "$CMAKE_BIN" --build . --target tools
  popd >/dev/null
  rm -f "${dir}/src/strgen/strgen" "${dir}/src/settingsgen/settingsgen"
}

# ---------------------------------------------------------------------------
# Verify export contract: the produced tools have exported their cmake files.
# ---------------------------------------------------------------------------
verify_exports() {
  local dir="$1"
  local ok=0
  ohos_check_file "${dir}/strgen.cmake"     "host export (strgen.cmake)"     || ok=1
  ohos_check_file "${dir}/settingsgen.cmake" "host export (settingsgen.cmake)" || ok=1
  return "$ok"
}

# ---------------------------------------------------------------------------
# Write manifest.json into <dir>: sha256 of each tool binary + each exported
# cmake file, tool versions, and timestamp.
# ---------------------------------------------------------------------------
write_manifest() {
  local dir="$1"
  local manifest_json
  local generated_at
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  manifest_json=$(
    printf '{\n'
    printf '  %s,\n' "$(ohos_json_string_field "hostBinaryDir" "$dir")"
    printf '  %s,\n' "$(ohos_json_string_field "generatedAt" "$generated_at")"
    printf '  %s,\n' "$(ohos_json_string_field "cmake" "$cmake_version")"
    printf '  %s,\n' "$(ohos_json_string_field "ninja" "$ninja_version")"
    printf '  "tools": {\n'
    printf '    "strgen": {%s},\n' "$(ohos_json_string_field "sha256" "$(sha256_of "${dir}/strgen")")"
    printf '    "settingsgen": {%s}\n' "$(ohos_json_string_field "sha256" "$(sha256_of "${dir}/settingsgen")")"
    printf '  },\n'
    printf '  "exports": {\n'
    printf '    "strgen.cmake": {%s},\n' "$(ohos_json_string_field "sha256" "$(sha256_of "${dir}/strgen.cmake")")"
    printf '    "settingsgen.cmake": {%s}\n' "$(ohos_json_string_field "sha256" "$(sha256_of "${dir}/settingsgen.cmake")")"
    printf '  }\n'
    printf '}\n'
  )
  # Atomic write: temp in same dir, then rename.
  tmp_file="${dir}/manifest.json.tmp.$$"
  printf '%s\n' "$manifest_json" > "$tmp_file"
  mv "$tmp_file" "${dir}/manifest.json"
  ohos_info "wrote ${dir}/manifest.json"
}

extract_manifest_field() {
  local manifest="$1"
  local field="$2"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$manifest" | head -n1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
START_TIME="$(date +%s)"

if [ "$MODE" = "repro-check" ]; then
  ohos_info "repro-check: rebuilding into ${REPRO_BINARY_DIR}"
  build_host_tools "$REPRO_BINARY_DIR"
  validate_host_binaries "$REPRO_BINARY_DIR" \
    || ohos_die "repro build produced non-Mach-O host tools"
  write_manifest "$REPRO_BINARY_DIR"

  primary_manifest="${HOST_BINARY_DIR}/manifest.json"
  if [ ! -f "$primary_manifest" ]; then
    ohos_die "cannot repro-check: primary manifest missing (${primary_manifest}); run without --repro-check first"
  fi
  repro_manifest="${REPRO_BINARY_DIR}/manifest.json"

  mismatch=0
  for key in "strgen" "settingsgen"; do
    primary_sha="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*{[[:space:]]*\"sha256\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$primary_manifest" | head -n1)"
    repro_sha="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*{[[:space:]]*\"sha256\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$repro_manifest" | head -n1)"
    if [ -z "$primary_sha" ] || [ -z "$repro_sha" ]; then
      ohos_error "could not extract sha256 for ${key}"
      mismatch=1
      continue
    fi
    if [ "$primary_sha" != "$repro_sha" ]; then
      ohos_warn "${key}: primary=${primary_sha} repro=${repro_sha} (MISMATCH)"
      mismatch=1
    else
      ohos_info "${key}: sha256 matches (${primary_sha})"
    fi
  done
  # Upstream export(TARGETS ...) embeds the build dir path, so normalize it.
  for key in "strgen.cmake" "settingsgen.cmake"; do
    primary_sha="$(sha256_of <(sed "s|${HOST_BINARY_DIR}|HOST_BINARY_DIR|g" "${HOST_BINARY_DIR}/${key}") 2>/dev/null || true)"
    repro_sha="$(sha256_of <(sed "s|${REPRO_BINARY_DIR}|HOST_BINARY_DIR|g" "${REPRO_BINARY_DIR}/${key}") 2>/dev/null || true)"
    if [ -z "$primary_sha" ] || [ -z "$repro_sha" ]; then
      ohos_error "could not hash normalized export for ${key}"
      mismatch=1
      continue
    fi
    if [ "$primary_sha" != "$repro_sha" ]; then
      ohos_warn "${key}: normalized content differs (primary=${primary_sha} repro=${repro_sha})"
      mismatch=1
    else
      ohos_info "${key}: normalized content matches (embedded dir path only difference)"
    fi
  done

  if [ "$mismatch" -ne 0 ]; then
    ohos_die "repro-check FAILED: checksums differ between ${HOST_BINARY_DIR} and ${REPRO_BINARY_DIR}"
  fi
  ohos_info "repro-check PASSED: byte-identical host tool artifacts across independent rebuilds"
else
  ohos_info "building host tools (native macOS, OPTION_TOOLS_ONLY=ON)"
  build_host_tools "$HOST_BINARY_DIR"
  validate_host_binaries "$HOST_BINARY_DIR" \
    || ohos_die "host tools are not valid Mach-O executables — aborting"
  verify_exports "$HOST_BINARY_DIR" \
    || ohos_die "host tool export contract not satisfied"
  write_manifest "$HOST_BINARY_DIR"
fi

END_TIME="$(date +%s)"
ohos_info "build took $((END_TIME - START_TIME))s"

# Export contract: make the host binary dir available to the target configure step.
# shellcheck disable=SC2034  # HOST_BINARY_DIR is exported for consuming scripts.
export HOST_BINARY_DIR
ohos_info "HOST_BINARY_DIR=${HOST_BINARY_DIR}"

# Quick sanity run of the host tools (they run natively on macOS).
"$HOST_BINARY_DIR/strgen" -h 2>&1 | head -n1 | ohos_info "strgen: $(cat)" || true
"$HOST_BINARY_DIR/settingsgen" -h 2>&1 | head -n1 | ohos_info "settingsgen: $(cat)" || true

ohos_info "done. host tools ready; consume with -DHOST_BINARY_DIR=${HOST_BINARY_DIR}"
