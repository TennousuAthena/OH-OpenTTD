#!/usr/bin/env bash
#
# Host test for the HarmonyOS storage / font / locale helpers.
#
# Compiles the platform sources with OPENTTD_HARMONYOS_HOST_TEST defined and
# runs a small C++ program that asserts path safety, path composition, font
# discovery and locale handling. Exits non-zero on any failure.
#
set -euo pipefail

BUILD_DIR="/tmp/sfl_harmonyos"
BIN="/tmp/sfl"
PASS=0
FAIL=0

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# The platform sources include "harmonyos.h"; provide a minimal header for the
# host test build.
cat > "$BUILD_DIR/harmonyos.h" <<'EOF'
#ifndef HARMONYOS_H
#define HARMONYOS_H

#include <cstddef>
#include <string>

#if defined(HARMONYOS) || defined(OPENTTD_HARMONYOS_HOST_TEST)
std::string HarmonyOSFilesDir();
std::string HarmonyOSCacheDir();
const char *HarmonyOSPersonalDir();
std::string HarmonyOSGetPersonalPath();
std::string HarmonyOSGetSavePath();
std::string HarmonyOSGetConfigPath();
bool HarmonyOSIsPathAllowed(const std::string &path);
int HarmonyOSFindFont(const char *faceName, void *out_face_ptr, const char *bundledFontPath);
const char *HarmonyOSDefaultFontPath();
const char *HarmonyOSGetSystemLanguage();
void HarmonyOSApplyLocale(char *out, size_t len);
#endif

#endif
EOF

# Provide a fake bundled fonts directory so the font discovery path is exercised.
mkdir -p "$BUILD_DIR/fonts"
touch "$BUILD_DIR/fonts/OpenTTD-Sans.ttf"
export OHOS_BUNDLED_FONT_DIR="$BUILD_DIR/fonts"

cat > "$BUILD_DIR/main.cpp" <<'CPP'
#include <cstdio>
#include <cstring>
#include <string>

#include "harmonyos.h"

static int g_pass = 0;
static int g_fail = 0;

static void check(const char *name, bool cond)
{
	if (cond) {
		printf("PASS: %s\n", name);
		g_pass++;
	} else {
		printf("FAIL: %s\n", name);
		g_fail++;
	}
}

int main()
{
	/* (a) path traversal and escape rejection */
	check("IsPathAllowed rejects '../escape'", !HarmonyOSIsPathAllowed("../escape"));
	check("IsPathAllowed rejects '/etc/passwd'", !HarmonyOSIsPathAllowed("/etc/passwd"));
	check("IsPathAllowed rejects '..\\x'", !HarmonyOSIsPathAllowed("..\\x"));
	check("IsPathAllowed rejects '../dir'", !HarmonyOSIsPathAllowed("save/../dir"));
	check("IsPathAllowed accepts sandbox-relative", HarmonyOSIsPathAllowed("save/autosave.sav"));

	/* (b) personal / save / config paths end in expected subdirs */
	std::string personal = HarmonyOSGetPersonalPath();
	std::string save = HarmonyOSGetSavePath();
	std::string config = HarmonyOSGetConfigPath();
	check("personal path ends in /OpenTTD", personal.size() > 8 && personal.compare(personal.size() - 8, 8, "/OpenTTD") == 0);
	check("save path ends in /save", save.size() > 5 && save.compare(save.size() - 5, 5, "/save") == 0);
	check("config path ends in /config", config.size() > 7 && config.compare(config.size() - 7, 7, "/config") == 0);
	check("personal dir non-empty", HarmonyOSPersonalDir() != nullptr && HarmonyOSPersonalDir()[0] != '\0');

	/* (c) font default path non-empty */
	const char *font = HarmonyOSDefaultFontPath();
	check("default font path non-empty", font != nullptr && font[0] != '\0');

	/* (d) locale returns en-US in host test */
	check("locale returns en-US", strcmp(HarmonyOSGetSystemLanguage(), "en-US") == 0);
	char locale_buf[64];
	HarmonyOSApplyLocale(locale_buf, sizeof(locale_buf));
	check("applied locale starts with LANGUAGE=", strncmp(locale_buf, "LANGUAGE=", 9) == 0);

	/* (e) negative: path escape rejected */
	check("absolute sandbox escape rejected", !HarmonyOSIsPathAllowed("/data/other/place"));
	check("empty path rejected", !HarmonyOSIsPathAllowed(""));

	printf("\nTotal: %d passed, %d failed\n", g_pass, g_fail);
	return g_fail == 0 ? 0 : 1;
}
CPP

echo "== Compiling HarmonyOS host test =="
FT_CFLAGS=""
FT_LIBS=""
if command -v pkg-config >/dev/null 2>&1; then
	FT_CFLAGS="$(pkg-config --cflags freetype2 2>/dev/null || true)"
	FT_LIBS="$(pkg-config --libs freetype2 2>/dev/null || true)"
fi
c++ -std=c++17 \
	-DHARMONYOS \
	-DOPENTTD_HARMONYOS_HOST_TEST \
	$FT_CFLAGS \
	-I"$BUILD_DIR" \
	"$BUILD_DIR/main.cpp" \
	"$(dirname "$0")/../../src/os/harmonyos/harmonyos_paths.cpp" \
	"$(dirname "$0")/../../src/os/harmonyos/harmonyos_font.cpp" \
	"$(dirname "$0")/../../src/os/harmonyos/harmonyos_locale.cpp" \
	$FT_LIBS \
	-o "$BIN" || {
	echo "COMPILE FAILED" >&2
	exit 1
}

echo "== Running HarmonyOS host test =="
"$BIN"
RESULT=$?

echo "== Done (exit $RESULT) =="
exit "$RESULT"
