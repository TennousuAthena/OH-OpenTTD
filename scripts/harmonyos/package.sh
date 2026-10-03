#!/usr/bin/env bash
# package.sh — assemble AppGallery-ready release artifacts for the OpenTTD
# HarmonyOS port.
#
# Runs the hvigor `assembleHap` build (single HAP carrying BOTH configured
# ABIs — arm64-v8a + x86_64 — because entry/build-profile.json5 lists both in
# `abiFilters`), stages the packaged immutable game data (baseset + generated
# language files) as HAP rawfile, then collects every artifact AppGallery
# expects into a release directory:
#
#   build/harmonyos/release/<Mode>/
#     openttd-<ver>.<git>.hap            the dual-ABI (unsigned-staged) HAP
#     symbols/                           unstripped per-ABI .so + buildid-map.json
#     source/openttd-<ver>-<git>.tar.gz  git source archive of the port branch
#     sbom/                              SPDX + CycloneDX SBOMs + dep manifest
#     NOTICES.md                         third-party notices (from dependencies/)
#     SOURCE_OFFER.txt                   GPL source offer
#     SHA256SUMS                         sha256 of every artifact (self-contained)
#     release-manifest.json              machine-readable release description
#
# The orchestrated hvigor build is:
#   node <DevEco>/.../hvigorw.js assembleHap --mode module \
#        -p product=default -p buildMode=<debug|release>
# where buildMode maps from the <Debug|Release> argument. Both ABIs are packed
# because abiFilters are already [arm64-v8a, x86_64] in the module build profile.
#
# Usage:
#   scripts/harmonyos/package.sh <Debug|Release> [--perf] [--unoptimized-debug] [--verbose-native]
#   scripts/harmonyos/package.sh -h
#
# Exit codes: 0 = release packed + verified, 2 = bad args,
#   3 = toolchain/source-cycle failed, 4 = assembly failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

MODE=""
NATIVE_OPTIMIZE="${OPENTTD_HARMONYOS_OPTIMIZE:-ON}"
NATIVE_PERF="${OPENTTD_HARMONYOS_PERF:-OFF}"
NATIVE_VERBOSE="${OPENTTD_HARMONYOS_VERBOSE_LOG:-OFF}"
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } /^$/ { print; next } { exit }' "$0"
      exit 0
      ;;
    Debug|Release)
      MODE="$arg"
      ;;
    --perf) NATIVE_PERF=ON ;;
    --unoptimized-debug) NATIVE_OPTIMIZE=OFF ;;
    --verbose-native) NATIVE_VERBOSE=ON ;;
    *)
      ohos_error "unknown argument: ${arg} (expected Debug|Release)"
      exit 2
      ;;
  esac
done

if [ -z "$MODE" ]; then
  ohos_error "missing build mode: <Debug|Release>"
  exit 2
fi

BUILD_MODE="debug"
[ "$MODE" = "Release" ] && BUILD_MODE="release"

# ---------------------------------------------------------------------------
# Product identity (single source of truth = harmonyos/product.json5)
# ---------------------------------------------------------------------------
PRODUCT_JSON="${REPO_ROOT}/harmonyos/product.json5"
ohos_check_file "$PRODUCT_JSON" "product identity file" || exit 3

# product.json5 uses single-quoted strings for bundleName/versionName but a
# bare number for versionCode; match either form on the same key line.
read_config() { # <key-without-quotes>
  awk -F: -v k="$1" '
    $1 ~ ("[[:space:]]*" k "[[:space:]]*$") {
      v=$2; sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]*,?[[:space:]]*$/, "", v);
      gsub(/^'"'"'|'"'"'$/, "", v); print v; exit
    }' "$PRODUCT_JSON"
}
BUNDLE_NAME="$(read_config "bundleName")"
VERSION_NAME="$(read_config "versionName")"
VERSION_CODE="$(read_config "versionCode")"
TARGET_API="$(read_config "targetAPIVersion")"
COMPATIBLE_API="$(read_config "compatibleAPIVersion")"
[ -n "$BUNDLE_NAME" ] && [ -n "$VERSION_NAME" ] && [ -n "$VERSION_CODE" ] \
  || ohos_die "product.json5 is missing bundleName/versionName/versionCode" 3
[ -n "$TARGET_API" ] && [ -n "$COMPATIBLE_API" ] \
  || ohos_die "product.json5 is missing targetAPIVersion/compatibleAPIVersion" 3

SHORT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
RELEASE_NAME="openttd-${VERSION_NAME}-${SHORT_SHA}"

RELEASE_DIR="${REPO_ROOT}/build/harmonyos/release/${MODE}"
STAGE_DIR="${REPO_ROOT}/build/harmonyos/stage-${MODE}"
RAWFILE_SRC="${REPO_ROOT}/harmonyos/entry/src/main/resources/rawfile"
HAP_OUT=""

ohos_info "mode:      ${MODE} (hvigor buildMode=${BUILD_MODE})"
ohos_info "identity:  ${BUNDLE_NAME} ${VERSION_NAME} (code ${VERSION_CODE})"
ohos_info "branch:    $(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo detach) @ ${SHORT_SHA}"
ohos_info "release:   ${RELEASE_NAME}"
ohos_info "output:    ${RELEASE_DIR}"

# ---------------------------------------------------------------------------
# 1. Bootstrap contract (validates DevEco SDK, emits toolchain-manifest.json)
# ---------------------------------------------------------------------------
ohos_info "running bootstrap contract"
"${SCRIPT_DIR}/bootstrap.sh" >/dev/null
MANIFEST="${REPO_ROOT}/build/harmonyos/toolchain-manifest.json"
ohos_check_file "$MANIFEST" "toolchain manifest (bootstrap.sh)" || exit 3

extract_manifest_field() {
  sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$MANIFEST" | head -n1
}
SDK_RAW="$(extract_manifest_field "sdkPath")"     # .../Contents/sdk/default
[ -n "$SDK_RAW" ] || ohos_die "toolchain manifest missing sdkPath" 3
# hvigor requires the PARENT of default (Contents/sdk), not default itself.
DEVECO_SDK_ROOT="$(dirname "$SDK_RAW")"
DEVECO_HOME="$(extract_manifest_field "toolsPath")"

ohos_info "DevEco SDK root: ${DEVECO_SDK_ROOT}"
ohos_info "DevEco tools:    ${DEVECO_HOME}"

# Node from the DevEco bundle (must be on PATH for hvigor).
NODE_BIN="${DEVECO_HOME}/node/bin"
HVIGORW="${DEVECO_HOME}/hvigor/bin/hvigorw.js"
ohos_check_file "$HVIGORW" "hvigor CLI (hvigorw.js)" || exit 3
ohos_check_file "${NODE_BIN}/node" "DevEco node" || exit 3

# ---------------------------------------------------------------------------
# 2. Host generators (strgen) — needed for language rawfile assets.
# ---------------------------------------------------------------------------
HOST_TOOLS="${REPO_ROOT}/build/host-tools"
STRGEN="${HOST_TOOLS}/strgen"
if [ ! -x "$STRGEN" ]; then
  ohos_info "strgen missing; building host tools"
  "${SCRIPT_DIR}/build-host-tools.sh" >/dev/null
fi
ohos_check_file "$STRGEN" "strgen host tool (build-host-tools.sh)" || exit 3

# ---------------------------------------------------------------------------
# 3. Build runtime dependencies and prepare the complete official free basesets
# ---------------------------------------------------------------------------
python3 "${SCRIPT_DIR}/build-runtime-deps.py" --sdk-root "$SDK_RAW" --dep liblzma
python3 "${SCRIPT_DIR}/build-runtime-deps.py" --sdk-root "$SDK_RAW" --dep freetype
python3 "${SCRIPT_DIR}/stage-assets.py" --strgen "$STRGEN" --cmake "$(extract_manifest_field "cmakePath")"

# ---------------------------------------------------------------------------
# 4. assembleHap (dual-ABI, because abiFilters = [arm64-v8a, x86_64])
# ---------------------------------------------------------------------------
export DEVECO_SDK_HOME="$DEVECO_SDK_ROOT"
export DEVECO_HOME="$DEVECO_HOME"
export PATH="${NODE_BIN}:${PATH}"
export NODE_HOME="$DEVECO_HOME/node"
export OPENTTD_HARMONYOS_OPTIMIZE="$NATIVE_OPTIMIZE"
export OPENTTD_HARMONYOS_PERF="$NATIVE_PERF"
export OPENTTD_HARMONYOS_VERBOSE_LOG="$NATIVE_VERBOSE"

cd "$REPO_ROOT/harmonyos"
if ! node hvigor/hvigor-wrapper.js assembleHap --mode module \
    -p module=entry@default -p product=default -p buildMode="$BUILD_MODE" -p requiredDeviceType=2in1 --parallel --no-daemon --no-incremental; then
  ohos_error "assembleHap failed (mode ${BUILD_MODE})"
  exit 4
fi

# Locate the unsigned HAP produced by assembleHap.
HAP_OUT="$(ls "${REPO_ROOT}/harmonyos/entry/build/default/outputs/default/"*unsigned.hap 2>/dev/null | head -n1 || true)"
if [ -z "$HAP_OUT" ] || [ ! -f "$HAP_OUT" ]; then
  ohos_error "assembleHap produced no unsigned HAP under harmonyos/entry/build/default/outputs/default/"
  exit 4
fi
ohos_info "assembled HAP: ${HAP_OUT} ($(du -h "$HAP_OUT" | cut -f1))"

# ---------------------------------------------------------------------------
# 5. Collect artifacts
# ---------------------------------------------------------------------------
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR/symbols" "$RELEASE_DIR/source" "$RELEASE_DIR/sbom"

# 5a. the HAP
cp "$HAP_OUT" "${RELEASE_DIR}/${RELEASE_NAME}.hap"

# 5b. prove native optimization and matching unstripped per-ABI Build IDs.
OBJ_ROOT="${REPO_ROOT}/harmonyos/entry/build/default/intermediates/cmake/default/obj"
NATIVE_CHECK_COMMAND=(python3 "${SCRIPT_DIR}/inspect-native-artifacts.py" \
  --hap "${RELEASE_DIR}/${RELEASE_NAME}.hap" \
  --native-build-root "${REPO_ROOT}/harmonyos/entry/.cxx/default/default/${BUILD_MODE}" \
  --native-objects "$OBJ_ROOT" --symbols-dir "${RELEASE_DIR}/symbols" \
  --output "${RELEASE_DIR}/native-build-manifest.json")
[ "$NATIVE_OPTIMIZE" = OFF ] && NATIVE_CHECK_COMMAND+=(--allow-unoptimized)
"${NATIVE_CHECK_COMMAND[@]}"

# 5c. source archive (git archive of the current/port branch)
git -C "$REPO_ROOT" archive --format=tar.gz -o "${RELEASE_DIR}/source/${RELEASE_NAME}-src.tar.gz" --prefix="${RELEASE_NAME}/" HEAD

# 5d. SBOM / notices / dependency manifest (from harmonyos/dependencies/)
for f in sbom.spdx.json sbom.cyclonedx.json manifest.json NOTICES.md; do
  if [ -f "${REPO_ROOT}/harmonyos/dependencies/$f" ]; then
    cp "${REPO_ROOT}/harmonyos/dependencies/$f" "${RELEASE_DIR}/sbom/"
  fi
done
# top-level NOTICES.md copy too (AppGallery licensing review reads it here)
cp "${REPO_ROOT}/harmonyos/dependencies/NOTICES.md" "${RELEASE_DIR}/NOTICES.md"

# 5e. GPL source offer
SOURCE_OFFER="${RELEASE_DIR}/SOURCE_OFFER.txt"
cat > "$SOURCE_OFFER" <<EOF
OpenTTD $(echo "$VERSION_NAME") — HarmonyOS port
GNU GPL v2 Source Code Offer

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License (COPYING.md) for more
details.

The complete, corresponding source code for this binary distribution is
available free of charge at:

  https://github.com/OpenTTD/OpenTTD  (upstream repository)

This port's complete source code is also shipped alongside this release as a
source archive and is browsable at the project's HarmonyOS port repository:
${RELEASE_NAME}-src.tar.gz
(git revision ${SHORT_SHA} of the harmonyos-port branch).

You may also request a copy by writing to the OpenTTD team (see COPYING.md and
CREDITS.md in the source for current contact details).
EOF

# 5f. checksums (SHA256SUMS references every artifact, self-checkable by path)
(
  cd "$RELEASE_DIR"
  shasum -a 256 "${RELEASE_NAME}.hap" \
    symbols/arm64-v8a/*.so symbols/x86_64/*.so \
    symbols/buildid-map.json \
    native-build-manifest.json \
    source/*.tar.gz \
    sbom/sbom.spdx.json sbom/sbom.cyclonedx.json sbom/manifest.json sbom/NOTICES.md \
    NOTICES.md SOURCE_OFFER.txt 2>/dev/null > SHA256SUMS
)

# 5g. release manifest
RELEASE_SHA="$(shasum -a 256 "${RELEASE_DIR}/${RELEASE_NAME}.hap" | cut -d' ' -f1)"
cat > "${RELEASE_DIR}/release-manifest.json" <<JSON
{
  "bundleName": "$BUNDLE_NAME",
  "versionName": "$VERSION_NAME",
  "versionCode": $VERSION_CODE,
  "deviceTypes": ["tablet", "2in1"],
  "targetAPIVersion": $TARGET_API,
  "compatibleAPIVersion": $COMPATIBLE_API,
  "runtimeOS": "HarmonyOS",
  "buildMode": "$MODE",
  "gitRevision": "$SHORT_SHA",
  "artifacts": {
    "hap": "${RELEASE_NAME}.hap",
    "hapSha256": "$RELEASE_SHA",
    "symbols": "symbols/",
    "nativeBuildManifest": "native-build-manifest.json",
    "sourceArchive": "source/${RELEASE_NAME}-src.tar.gz",
    "sbom": "sbom/",
    "notices": "NOTICES.md",
    "sourceOffer": "SOURCE_OFFER.txt",
    "checksums": "SHA256SUMS"
  }
}
JSON

# ---------------------------------------------------------------------------
# 6. Clean staged rawfile, report
# ---------------------------------------------------------------------------
rm -rf "${RAWFILE_SRC}/baseset" "${RAWFILE_SRC}/lang" "$STAGE_DIR"

ohos_info "release packed: ${RELEASE_DIR}"
echo "RELEASE_DIR=${RELEASE_DIR}"
echo "RELEASE_HAP=${RELEASE_DIR}/${RELEASE_NAME}.hap"
exit 0
