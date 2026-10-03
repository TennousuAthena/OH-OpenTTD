#!/usr/bin/env bash
# Run the actual GLES shader with local ANGLE; no installs or game/device changes.
# Set EGL_LIBRARY, GLES_LIBRARY and OHOS_INCLUDE_DIR for a different local runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openttd-render-shader.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
OHOS_INCLUDE_DIR="${OHOS_INCLUDE_DIR:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/sysroot/usr/include}"
if [ -z "${EGL_LIBRARY:-}" ]; then
  EGL_LIBRARY="$("${PYTHON:-python3}" - <<'PY'
import glob
paths = glob.glob('/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/*/Libraries/libEGL.dylib')
print(paths[-1] if paths else '')
PY
)"
fi
GLES_LIBRARY="${GLES_LIBRARY:-$(dirname "$EGL_LIBRARY")/libGLESv2.dylib}"
if [ ! -f "$EGL_LIBRARY" ] || [ ! -f "$GLES_LIBRARY" ] || [ ! -f "$OHOS_INCLUDE_DIR/EGL/egl.h" ]; then
  printf 'SKIP: local ANGLE libraries and EGL headers are required for offscreen GPU tests\n'
  exit 0
fi

# Compile the real production CPU function as the independent pixel oracle.
"${PYTHON:-python3}" - "$REPO_ROOT/src/palette.cpp" "$TEST_DIR/brightness_reference.h" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
begin = source.index('Colour ReallyAdjustBrightness(')
end = source.index('\nvoid DoPaletteAnimations();', begin)
prefix = '''
struct Colour {
 uint8_t b, g, r, a;
 Colour(uint8_t red = 0, uint8_t green = 0, uint8_t blue = 0, uint8_t alpha = 255) : b(blue), g(green), r(red), a(alpha) {}
};
static constexpr int DEFAULT_BRIGHTNESS = 128;
template <typename T> T GB(T value, unsigned shift, unsigned bits) { return (value >> shift) & ((T(1) << bits) - 1); }
'''
pathlib.Path(sys.argv[2]).write_text(prefix + source[begin:end])
PY

"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -idirafter "$OHOS_INCLUDE_DIR" -I "$TEST_DIR" \
  "$SCRIPT_DIR/render_shader_test.cpp" -o "$TEST_DIR/render-shader"
"$TEST_DIR/render-shader" "$EGL_LIBRARY" "$GLES_LIBRARY"
