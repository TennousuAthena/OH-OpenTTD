#!/usr/bin/env bash
# Exercise the real 40bpp blitter copy method bodies with packed odd-width rows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openttd-animation-backup.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Only the surrounding core/driver declarations are stubbed. The copy routines
# compiled below are extracted verbatim from the production source, not replicas.
"${PYTHON:-python3}" - "${REPO_ROOT}/src/blitter/40bpp_anim.cpp" "${TEST_DIR}/animation-backup.cpp" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
begin = source.index('void Blitter_40bppAnim::CopyFromBuffer(')
end = source.index('void Blitter_40bppAnim::CopyImageToBuffer(', begin)
methods = source[begin:end]
prefix = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
struct { void *dst_ptr; int width, height, pitch; } _screen{};
bool _screen_disable_anim = false;
std::vector<uint8_t> animation;
class VideoDriver {
public:
 static VideoDriver *GetInstance() { static VideoDriver instance; return &instance; }
 uint8_t *GetAnimBuffer() { return animation.data(); }
};
class Blitter_40bppAnim {
public:
 void CopyFromBuffer(void *, const void *, int, int);
 void CopyToBuffer(const void *, void *, int, int);
};
'''
suffix = r'''
int main() {
 Blitter_40bppAnim blitter;
 for (int width : {1, 3, 7, 16, 19, 25, 31}) {
  const int pitch = width + 4, height = 6, rows = 3;
  std::vector<uint32_t> pixels(pitch * height);
  animation.resize(pitch * height);
  for (size_t i = 0; i < pixels.size(); ++i) {
   pixels[i] = static_cast<uint32_t>(0xF0302010 + i * 19);
   animation[i] = static_cast<uint8_t>(i * 7);
  }
  _screen = {pixels.data(), pitch, height, pitch};
  const auto original_pixels = pixels;
  const auto original_animation = animation;
  std::vector<uint8_t> backup(width * rows * 5 + 2, 0xCD);
  // Deliberately unaligned start, plus odd-width subsequent packed rows.
  uint8_t *packed = backup.data() + 1;
  uint32_t *video = pixels.data() + pitch + 2;
  blitter.CopyToBuffer(video, packed, width, rows);
  for (int y = 0; y < rows; ++y) {
   size_t offset = (y + 1) * pitch + 2;
   assert(std::memcmp(packed + y * width * 5, pixels.data() + offset, width * 4) == 0);
   assert(std::equal(animation.begin() + offset, animation.begin() + offset + width, packed + y * width * 5 + width * 4));
   std::fill_n(pixels.begin() + offset, width, 0);
   std::fill_n(animation.begin() + offset, width, 0);
  }
  blitter.CopyFromBuffer(video, packed, width, rows);
  assert(pixels == original_pixels);
  assert(animation == original_animation);
  assert(backup.front() == 0xCD && backup.back() == 0xCD);
 }
 std::cout << "PASS: production 40bpp cursor backup colour/mask round trips, odd widths and unaligned packed storage\n";
}
'''
pathlib.Path(sys.argv[2]).write_text(prefix + methods + suffix)
PY

"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
  "${TEST_DIR}/animation-backup.cpp" -o "${TEST_DIR}/animation-backup"
"${TEST_DIR}/animation-backup"
