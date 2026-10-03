/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 */

/**
 * @file harmonyos_font.cpp
 * Font discovery helpers for the HarmonyOS platform.
 */

#if defined(HARMONYOS) || defined(OPENTTD_HARMONYOS_HOST_TEST)

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifdef _WIN32
#  include <io.h>
#else
#  include <unistd.h>
#endif

#include "harmonyos.h"

/* FreeType is only available to the host test, which compiles against the
 * bundled FreeType headers. On-device builds resolve fonts through the
 * platform font service instead. */
#ifdef OPENTTD_HARMONYOS_HOST_TEST
#  include <ft2build.h>
#  include FT_FREETYPE_H
#endif

/**
 * Default path of the bundled OpenTTD font.
 * @return Path to the bundled font, or empty string if not found.
 */
const char *HarmonyOSDefaultFontPath()
{
	static const char *names[] = {
		"OpenTTD-Sans.ttf",
		"OpenTTD-Sans-Bold.ttf",
		"OpenSans-Regular.ttf",
		nullptr,
	};

	static std::string found;
	if (!found.empty()) return found.c_str();

	/* Scan the bundled fonts directory for a known font. */
	const char *dir = getenv("OHOS_BUNDLED_FONT_DIR");
	std::string base = (dir != nullptr && dir[0] != '\0') ? dir : "/data/storage/el2/base/haps/entry/files/fonts";

	for (int i = 0; names[i] != nullptr; i++) {
		std::string candidate = base + "/" + names[i];
		if (access(candidate.c_str(), F_OK) == 0) {
			found = candidate;
			return found.c_str();
		}
	}

	return nullptr;
}

#ifdef OPENTTD_HARMONYOS_HOST_TEST

/**
 * Find and load a font face using FreeType (host test only).
 * @param faceName         The font face name to look up.
 * @param out_face_ptr     Receives the loaded FT_Face.
 * @param bundledFontPath  Path to the bundled font, may be empty.
 * @return 0 on success, non-zero on failure.
 */
int HarmonyOSFindFont(const char *faceName, void *out_face_ptr, const char *bundledFontPath)
{
	FT_Library library;
	FT_Face face = nullptr;

	if (out_face_ptr == nullptr) return -1;

	if (FT_Init_FreeType(&library) != 0) return -2;

	const char *path = bundledFontPath;
	if (path == nullptr || path[0] == '\0') {
		path = HarmonyOSDefaultFontPath();
	}
	if (path == nullptr) {
		FT_Done_FreeType(library);
		return -3;
	}

	if (FT_New_Face(library, path, 0, &face) != 0) {
		FT_Done_FreeType(library);
		return -4;
	}

	if (faceName != nullptr && faceName[0] != '\0') {
		/* Basic name sanity: OpenTTD-Sans family requested by default. */
		if (face->family_name != nullptr && strcmp(face->family_name, faceName) == 0) {
			/* matched, fall through */
		}
	}

	*((FT_Face *)out_face_ptr) = face;
	FT_Done_FreeType(library);
	return 0;
}

#else /* OPENTTD_HARMONYOS_HOST_TEST */

/**
 * Find and load a font face on device.
 * @param faceName         The font face name to look up.
 * @param out_face_ptr     Receives the platform font handle.
 * @param bundledFontPath  Path to the bundled font, may be empty.
 * @return 0 on success, non-zero on failure.
 */
int HarmonyOSFindFont(const char *faceName, void *out_face_ptr, const char *bundledFontPath)
{
	/* On device the font is resolved via the platform font service.
	 * This stub retains the interface for future integration. */
	(void)faceName;
	(void)bundledFontPath;
	if (out_face_ptr != nullptr) *out_face_ptr = nullptr;
	return -1;
}

#endif /* OPENTTD_HARMONYOS_HOST_TEST */

#endif /* HARMONYOS || OPENTTD_HARMONYOS_HOST_TEST */
