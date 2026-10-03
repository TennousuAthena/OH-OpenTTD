/* This file is part of OpenTTD. Licensed under GNU GPL version 2. */

/** @file font_harmonyos.h HarmonyOS system font fallback. */

#ifndef FONT_HARMONYOS_H
#define FONT_HARMONYOS_H

#include <string>
#include <string_view>

struct FontCacheSettings;
class MissingGlyphSearcher;

std::string HarmonyOSGetDefaultFont(bool monospace, std::string_view language_isocode);
bool HarmonyOSFindFallbackFont(FontCacheSettings *settings, const std::string &language_isocode, MissingGlyphSearcher *callback);

#endif
