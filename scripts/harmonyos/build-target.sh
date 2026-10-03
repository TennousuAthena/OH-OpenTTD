#!/usr/bin/env bash
# build-target.sh — configure (and later build) the OpenTTD game target for a
# HarmonyOS ABI using the DevEco OHOS CMake toolchain.
#
# The script reuses the deterministic bootstrap contract (scripts/harmonyos/
# bootstrap.sh) to validate the DevEco SDK and emits the toolchain manifest; it
# then configures a per-ABI/per-mode build directory with:
#   - the API 26 HarmonyOS toolchain through HarmonyOSNativeToolchain.cmake
#   - the ABI/arch                         -DOHOS_ARCH=<arm64-v8a|x86_64>
#   - the native host generators from Todo 3  -DHOST_BINARY_DIR=$REPO_ROOT/build/host-tools
#   - a compile database                    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
#
# The platform guard (cmake/HarmonyOS.cmake) makes HARMONYOS a first-class
# platform: generic-Unix sources (unix_main.cpp, crashlog_unix.cpp, extmidi.cpp,
# unix.cpp, library_loader_unix.cpp, survey_unix.cpp) are rejected at configure
# time, and -rdynamic / fork / exec / execinfo paths are disabled.
#
# Usage:
#   scripts/harmonyos/build-target.sh <arm64-v8a|x86_64> <Debug|Release> [--configure-only]
#   scripts/harmonyos/build-target.sh -h
#
# Exit codes:
#   0  requested configure/build completed successfully
#   2  argument error
#   3  bootstrap/toolchain environment failed
#   4  forbidden-source / platform guard triggered (configure-time platform error)

set -euo pipefail

# Resolve REPO_ROOT from this script's location (scripts/harmonyos/..).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

CONFIGURE_ONLY=0
ABI=""
BUILD_TYPE=""
NATIVE_OPTIMIZE="${OPENTTD_HARMONYOS_OPTIMIZE:-ON}"
NATIVE_PERF="${OPENTTD_HARMONYOS_PERF:-OFF}"
NATIVE_VERBOSE="${OPENTTD_HARMONYOS_VERBOSE_LOG:-OFF}"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
build-target.sh — configure/build OpenTTD for HarmonyOS with the OHOS toolchain

Usage:
  scripts/harmonyos/build-target.sh <arm64-v8a|x86_64> <Debug|Release> [--configure-only] [--perf] [--unoptimized-debug]
  scripts/harmonyos/build-target.sh -h

Arguments:
  ABI      arm64-v8a (aarch64-linux-ohos) or x86_64 (x86_64-linux-ohos)
  MODE     Debug or Release
  --configure-only   configure only; stop before compiling
  --perf             collect bounded per-second native performance diagnostics
  --unoptimized-debug  deliberately use -O0 (Debug only); normal builds use -O2 -g
  --verbose-native   enable verbose driver/startup logs

Environment:
  DEVECO_SDK_HOME   DevEco Studio SDK root (default: /Applications/DevEco-Studio.app/Contents/sdk/default)

Exit codes: 0 = requested configure/build succeeded, 2 = bad args,
3 = environment/bootstrap failed, 4 = platform guard triggered.
EOF
      exit 0
      ;;
    arm64-v8a|x86_64)
      ABI="$arg"
      ;;
    Debug|Release)
      BUILD_TYPE="$arg"
      ;;
    --configure-only)
      CONFIGURE_ONLY=1
      ;;
    --perf) NATIVE_PERF=ON ;;
    --unoptimized-debug) NATIVE_OPTIMIZE=OFF ;;
    --verbose-native) NATIVE_VERBOSE=ON ;;
    *)
      ohos_error "unknown argument: ${arg} (see -h)"
      exit 2
      ;;
  esac
done

if [ -z "$ABI" ]; then
  ohos_error "missing required ABI argument: <arm64-v8a|x86_64> (see -h)"
  exit 2
fi
if [ -z "$BUILD_TYPE" ]; then
  ohos_error "missing required build-mode argument: <Debug|Release> (see -h)"
  exit 2
fi

# ---------------------------------------------------------------------------
# Bootstrap contract: validate the DevEco SDK and load the toolchain manifest.
# bootstrap.sh exits nonzero on any validation failure, and it never mutates
# build/ on failure except the manifest itself after full success.
# ---------------------------------------------------------------------------
ohos_info "running bootstrap contract (${SCRIPT_DIR}/bootstrap.sh)"
"${SCRIPT_DIR}/bootstrap.sh" >/dev/null

MANIFEST="${REPO_ROOT}/build/harmonyos/toolchain-manifest.json"
ohos_check_file "$MANIFEST" "toolchain manifest from bootstrap.sh" || exit 3

extract_manifest_field() {
  local manifest="$1"
  local field="$2"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$manifest" | head -n1
}

SDK="$(extract_manifest_field "$MANIFEST" "sdkPath")"
NATIVE_SDK="$(extract_manifest_field "$MANIFEST" "ndkPath")"
HMOS_SDK="$(extract_manifest_field "$MANIFEST" "hmosSdkPath")"
TOOLCHAIN_FILE="$(extract_manifest_field "$MANIFEST" "toolchainFile")"
if [ -z "$SDK" ] || [ -z "$TOOLCHAIN_FILE" ]; then
  ohos_error "manifest ${MANIFEST} is missing sdkPath/toolchainFile; rebuild it with bootstrap.sh"
  exit 3
fi
ohos_check_file "$TOOLCHAIN_FILE" "OHOS CMake toolchain file" || exit 3

# ---------------------------------------------------------------------------
# Resolve cmake / ninja (same host-tool logic as build-host-tools.sh).
# ---------------------------------------------------------------------------
CMAKE_BIN="${DEVECO_CMAKE_BIN:-}"
NINJA_BIN="${DEVECO_NINJA_BIN:-}"
if [ -n "$CMAKE_BIN" ] && [ -x "$CMAKE_BIN" ]; then
  : # already resolved
elif [ -x "${NATIVE_SDK}/build-tools/cmake/bin/cmake" ]; then
  CMAKE_BIN="${NATIVE_SDK}/build-tools/cmake/bin/cmake"
elif command -v cmake >/dev/null 2>&1; then
  CMAKE_BIN="$(command -v cmake)"
else
  ohos_die "no cmake found (tried ${NATIVE_SDK}/build-tools/cmake/bin/cmake and PATH)" 3
fi
if [ -n "$NINJA_BIN" ] && [ -x "$NINJA_BIN" ]; then
  : # already resolved
elif [ -x "${NATIVE_SDK}/build-tools/cmake/bin/ninja" ]; then
  NINJA_BIN="${NATIVE_SDK}/build-tools/cmake/bin/ninja"
elif command -v ninja >/dev/null 2>&1; then
  NINJA_BIN="$(command -v ninja)"
else
  ohos_die "no ninja found (tried ${NATIVE_SDK}/build-tools/cmake/bin/ninja and PATH)" 3
fi

# ---------------------------------------------------------------------------
# Host-generator contract (Todo 3): strgen.cmake / settingsgen.cmake must exist.
# ---------------------------------------------------------------------------
HOST_BINARY_DIR="${REPO_ROOT}/build/host-tools"
ohos_check_file "${HOST_BINARY_DIR}/strgen.cmake" "host export (strgen.cmake); run scripts/harmonyos/build-host-tools.sh first" || exit 3
ohos_check_file "${HOST_BINARY_DIR}/settingsgen.cmake" "host export (settingsgen.cmake); run scripts/harmonyos/build-host-tools.sh first" || exit 3

# ---------------------------------------------------------------------------
# Configure
# ---------------------------------------------------------------------------
BUILD_DIR="${REPO_ROOT}/build/target-${ABI}-${BUILD_TYPE}"
CONFIGURE_LOG="${BUILD_DIR}/configure.log"
ohos_info "ABI:           ${ABI}"
ohos_info "Build mode:    ${BUILD_TYPE}"
ohos_info "Build dir:     ${BUILD_DIR}"
ohos_info "Toolchain:     ${TOOLCHAIN_FILE}"
ohos_info "Host binary:   ${HOST_BINARY_DIR}"
ohos_info "CMake:         ${CMAKE_BIN}"
ohos_info "Ninja:         ${NINJA_BIN}"

mkdir -p "$BUILD_DIR"
CONFIGURE_COMMAND=("$CMAKE_BIN")
if [ -f "${BUILD_DIR}/CMakeCache.txt" ] && ! grep -Fq "$TOOLCHAIN_FILE" "${BUILD_DIR}/CMakeCache.txt"; then
  CONFIGURE_COMMAND+=(--fresh)
fi
RUNTIME_DEPS="${REPO_ROOT}/build/harmonyos/runtime-deps/${ABI}"
ohos_check_file "${RUNTIME_DEPS}/lib/liblzma.a" "liblzma; run scripts/harmonyos/build-runtime-deps.py first" || exit 3
ohos_check_file "${RUNTIME_DEPS}/lib/libfreetype.a" "FreeType; run scripts/harmonyos/build-runtime-deps.py --dep freetype first" || exit 3

START_TIME="$(date +%s)"
set +e
(
  cd "$BUILD_DIR" || exit 99
  "${CONFIGURE_COMMAND[@]}" "$REPO_ROOT" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_TOOLCHAIN_FILE="${REPO_ROOT}/cmake/HarmonyOSNativeToolchain.cmake" \
    -DHARMONYOS_SDK_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_POLICY_DEFAULT_CMP0137=NEW \
    -DOHOS_SDK_NATIVE="$NATIVE_SDK" \
    -DHMOS_SDK_NATIVE="$HMOS_SDK" \
    -DOHOS_ARCH="$ABI" \
    -DOHOS_PLATFORM_LEVEL=1 \
    -DOHOS_SDK_NATIVE_PLATFORM=ohos-1 \
    -DOHOS_STL=c++_shared \
    -DLIBLZMA_LIBRARY="${RUNTIME_DEPS}/lib/liblzma.a" \
    -DLIBLZMA_INCLUDE_DIR="${RUNTIME_DEPS}/include" \
    -DFREETYPE_LIBRARY_RELEASE="${RUNTIME_DEPS}/lib/libfreetype.a" \
    -DFREETYPE_INCLUDE_DIR_ft2build="${RUNTIME_DEPS}/include/freetype2" \
    -DFREETYPE_INCLUDE_DIR_freetype2="${RUNTIME_DEPS}/include/freetype2" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DOPENTTD_HARMONYOS_OPTIMIZE="$NATIVE_OPTIMIZE" \
    -DOPENTTD_HARMONYOS_PERF="$NATIVE_PERF" \
    -DOPENTTD_HARMONYOS_VERBOSE_LOG="$NATIVE_VERBOSE" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DHOST_BINARY_DIR="$HOST_BINARY_DIR"
) >"$CONFIGURE_LOG" 2>&1
CONFIGURE_RC=$?
set -e
END_TIME="$(date +%s)"
ohos_info "configure took $((END_TIME - START_TIME))s (exit ${CONFIGURE_RC}); log at ${CONFIGURE_LOG}"

if [ "$CONFIGURE_RC" -ne 0 ]; then
  # Classify the failure: is it a platform guard (our own FATAL_ERROR with the
  # forbidden-source marker) or an environment/dependency-resolution boundary
  # (find_package of a not-yet-built third-party dependency)?
  if grep -q "forbidden Unix-only source" "$CONFIGURE_LOG"; then
    ohos_error "PLATFORM GUARD triggered — a forbidden Unix-only source leaked into the HarmonyOS build:"
    grep -m1 "forbidden Unix-only source" "$CONFIGURE_LOG" >&2 || true
    exit 4
  fi
  if grep -Eq "Could not find|find_package.*(required|REQUIRED)|Please include the required|No such file or directory" "$CONFIGURE_LOG"; then
    ohos_error "configure failed at dependency resolution"
    ohos_info "configure log excerpt:"
    tail -n 20 "$CONFIGURE_LOG" | sed 's/^/  /'
    exit "$CONFIGURE_RC"
  fi
  ohos_error "configure failed with a platform/environment error (exit ${CONFIGURE_RC}):"
  tail -n 40 "$CONFIGURE_LOG" | sed 's/^/  /' >&2
  exit "$CONFIGURE_RC"
fi

# ---------------------------------------------------------------------------
# Post-configure verification (shared by --configure-only and full builds)
# ---------------------------------------------------------------------------
COMPILE_DB="${BUILD_DIR}/compile_commands.json"
if [ ! -f "$COMPILE_DB" ]; then
  ohos_error "CMAKE_EXPORT_COMPILE_COMMANDS=ON did not produce ${COMPILE_DB}"
  exit 1
fi

verify_source_selection() {
  local db="$1"
  local abi="$2"
  local ok=0

  # HarmonyOS sources must be present...
  for src in "src/os/harmonyos/harmonyos.cpp" "src/os/harmonyos/crashlog_harmonyos.cpp" "src/os/harmonyos/harmonyos_main.cpp"; do
    if ! grep -q "$src" "$db"; then
      ohos_error "HarmonyOS source missing from compile database: $src"
      ok=1
    fi
  done

  # ...and the forbidden Unix-only sources must be absent.
  for forbidden in "unix_main.cpp" "crashlog_unix.cpp" "extmidi.cpp" "src/os/unix/unix.cpp" "library_loader_unix.cpp" "survey_unix.cpp"; do
    if grep -q "$forbidden" "$db"; then
      ohos_error "forbidden source leaked into ${abi} compile database: $forbidden"
      ok=1
    fi
  done

  # Our own platform guard must be absent from the compile options of every entry
  # (no -rdynamic, no -DUNIX impersonation).
  if grep -q -- "-rdynamic" "$db"; then
    ohos_error "forbidden -rdynamic leaked into ${abi} compile database"
    ok=1
  fi
  if grep -q -- "-DUNIX" "$db"; then
    ohos_error "forbidden -DUNIX impersonation leaked into ${abi} compile database"
    ok=1
  fi

  return "$ok"
}

if ! verify_source_selection "$COMPILE_DB" "$ABI"; then
  ohos_error "compile database for ${ABI}/${BUILD_TYPE} violates the HarmonyOS platform guard"
  exit 1
fi

ohos_info "compile database verified: ${COMPILE_DB} ($(wc -l < "$COMPILE_DB" | tr -d ' ') entries)"

if [ "$CONFIGURE_ONLY" -eq 1 ]; then
  ohos_info "CONFIGURE_OK ${ABI}/${BUILD_TYPE}"
  # Emit a compact JSON result for evidence capture.
  printf '{"abi": "%s", "buildType": "%s", "toolchain": "%s", "status": "CONFIGURE_OK", "compileDb": "%s"}\n' \
    "$ABI" "$BUILD_TYPE" "$TOOLCHAIN_FILE" "$COMPILE_DB"
  exit 0
fi

# ---------------------------------------------------------------------------
# Full build path (Todo 11+ owns per-driver gates; here we just build).
# ---------------------------------------------------------------------------
ohos_info "building ${BUILD_DIR}"
"$CMAKE_BIN" --build "$BUILD_DIR" --target openttd --parallel 4 2>&1 | tee "${BUILD_DIR}/build.log"
ohos_info "BUILD_DONE ${ABI}/${BUILD_TYPE}"
