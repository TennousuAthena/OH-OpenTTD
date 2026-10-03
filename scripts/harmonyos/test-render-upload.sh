#!/usr/bin/env bash
# Compile and exercise the exact pure helpers used by harmonyos_v.cpp.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openttd-render-upload.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
  "${SCRIPT_DIR}/render_upload_test.cpp" -o "${TEST_DIR}/render-upload"
"${TEST_DIR}/render-upload"
