/* This file is part of OpenTTD. Licensed under GNU GPL version 2. */

/** @file font_harmonyos.cpp Finds a system font that covers the active language. */

#include "../../stdafx.h"
#include "../../debug.h"
#include "../../fontcache.h"
#include "../../strings_func.h"
#include "font_harmonyos.h"

#include <filesystem>
#include <native_drawing/drawing_text_typography.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include "../../safeguards.h"

extern FT_Library _ft_library;

namespace {

struct FontCandidate {
	std::string path;
	int weight_distance;
};

int FontPreference(const FontCandidate &candidate, bool monospace, std::string_view language)
{
	auto name = std::filesystem::path(candidate.path).stem().string();
	if (monospace) return name.starts_with("NotoSansMono") ? 0 : 10;
	/* Prefer the platform's UI family, including the appropriate Chinese
	 * variant. Enumeration order otherwise picks decorative/serif fonts. */
	const bool chinese = language.starts_with("zh");
	const bool traditional = language == "zh_TW" || language == "zh_HK";
	if (name == (traditional ? "HarmonyOS_Sans_TC" : "HarmonyOS_Sans_SC")) return chinese ? 0 : 1;
	if (name == "HarmonyOS_Sans") return chinese ? 1 : 0;
	if (name == "NotoSansCJK-Regular") return 2;
	if (name.starts_with("NotoSans") && !name.starts_with("NotoSansMono")) return 3;
	return 10;
}

std::vector<FontCandidate> GetSystemFonts(bool monospace)
{
	std::vector<FontCandidate> candidates;
	auto parser = std::unique_ptr<OH_Drawing_FontParser, decltype(&OH_Drawing_DestroyFontParser)>(
		OH_Drawing_CreateFontParser(), OH_Drawing_DestroyFontParser);
	if (parser != nullptr) {
		size_t count = 0;
		char **names = OH_Drawing_FontParserGetSystemFontList(parser.get(), &count);
		if (names != nullptr) {
			for (size_t i = 0; i < count; ++i) {
				if (names[i] == nullptr) continue;
				auto descriptor = std::unique_ptr<OH_Drawing_FontDescriptor, decltype(&OH_Drawing_DestroyFontDescriptor)>(
					OH_Drawing_FontParserGetFontByName(parser.get(), names[i]), OH_Drawing_DestroyFontDescriptor);
				if (descriptor == nullptr || descriptor->path == nullptr || descriptor->italic != 0) continue;
				if (monospace && !descriptor->monoSpace) continue;
				candidates.push_back({descriptor->path, std::abs(descriptor->weight - 400)});
			}
			OH_Drawing_DestroySystemFontList(names, count);
		}
	}

	/* The font-name parser is limited to phones and PCs. The system font
	 * configuration also supplies directories on other device types. */
	OH_Drawing_FontConfigInfoErrorCode error;
	auto config = std::unique_ptr<OH_Drawing_FontConfigInfo, decltype(&OH_Drawing_DestroySystemFontConfigInfo)>(
		OH_Drawing_GetSystemFontConfigInfo(&error), OH_Drawing_DestroySystemFontConfigInfo);
	if (config != nullptr && error == SUCCESS_FONT_CONFIG_INFO && config->fontDirSet != nullptr) {
		for (size_t i = 0; i < config->fontDirSize; ++i) {
			if (config->fontDirSet[i] == nullptr) continue;
			std::error_code ec;
			std::filesystem::directory_iterator it(config->fontDirSet[i], ec), end;
			while (!ec && it != end) {
				if (it->is_regular_file(ec)) {
					auto extension = it->path().extension().string();
					if (extension == ".ttf" || extension == ".otf" || extension == ".ttc") {
						candidates.push_back({it->path().string(), 1000});
					}
				}
				it.increment(ec);
			}
		}
	}
	return candidates;
}

std::vector<FontCandidate> GetPreferredFonts(bool monospace, std::string_view language)
{
	/* Native font enumeration is expensive; only the ordering changes when
	 * the user switches language or opens a document. */
	static const auto system_fonts = GetSystemFonts(false);
	auto candidates = system_fonts;
	std::stable_sort(candidates.begin(), candidates.end(), [&](const auto &a, const auto &b) {
		int a_preference = FontPreference(a, monospace, language);
		int b_preference = FontPreference(b, monospace, language);
		if (a_preference != b_preference) return a_preference < b_preference;
		return a.weight_distance < b.weight_distance;
	});
	return candidates;
}

} // namespace

std::string HarmonyOSGetDefaultFont(bool monospace, std::string_view language_isocode)
{
	for (const auto &candidate : GetPreferredFonts(monospace, language_isocode)) {
		if (FontPreference(candidate, monospace, language_isocode) < 10) return candidate.path;
	}
	return {};
}

bool HarmonyOSFindFallbackFont(FontCacheSettings *settings, const std::string &language_isocode, MissingGlyphSearcher *callback)
{
	if (_ft_library == nullptr && FT_Init_FreeType(&_ft_library) != FT_Err_Ok) return false;
	const auto candidates = GetPreferredFonts(callback->Monospace(), language_isocode);
	std::set<std::string> visited;
	for (const auto &candidate : candidates) {
		if (!visited.insert(candidate.path).second) continue;
		FT_Long faces = 1;
		for (int32_t index = 0; index < faces; ++index) {
			FT_Face face = nullptr;
			if (FT_New_Face(_ft_library, candidate.path.c_str(), index, &face) != FT_Err_Ok) continue;
			faces = face->num_faces;
			bool usable = (face->style_flags & FT_STYLE_FLAG_ITALIC) == 0 &&
				(!callback->Monospace() || FT_IS_FIXED_WIDTH(face));
			FT_Done_Face(face);
			if (!usable) continue;
			/* The callback loads the face synchronously, including collection
			 * index. Clear the temporary pointer before leaving this scope. */
			callback->SetFontNames(settings, candidate.path, &index);
			bool missing = callback->FindMissingGlyphs();
			callback->SetFontNames(settings, candidate.path, nullptr);
			if (!missing) {
				Debug(fontcache, 1, "HarmonyOS fallback font: {} (face {})", candidate.path, index);
				return true;
			}
		}
	}
	return false;
}
