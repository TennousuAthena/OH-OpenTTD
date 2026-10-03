/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 */

/**
 * @file harmonyos_locale.cpp
 * Locale helpers for the HarmonyOS platform.
 */

#if defined(HARMONYOS) || defined(OPENTTD_HARMONYOS_HOST_TEST)

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>

#include "harmonyos.h"

/**
 * Get the system language as an OpenTTD-compatible language code.
 * @return "zh-CN", "en-US", "ar", etc.
 */
const char *HarmonyOSGetSystemLanguage()
{
#if defined(OPENTTD_HARMONYOS_HOST_TEST)
	/* The host test environment has no HarmonyOS locale service. */
	return "en-US";
#else
	const char *lang = getenv("OHOS_APP_LANGUAGE");
	if (lang != nullptr && lang[0] != '\0') return lang;

	/* HarmonyOS resource manager returns BCP-47 tags such as "zh-CN". */
	const char *syslang = getenv("LOCALE");
	if (syslang != nullptr && syslang[0] != '\0') {
		/* "zh_CN.UTF-8" -> "zh-CN" */
		static std::string code;
		code = syslang;
		size_t pos = code.find('_');
		if (pos != std::string::npos) code[pos] = '-';
		pos = code.find('.');
		if (pos != std::string::npos) code.resize(pos);
		return code.c_str();
	}

	return "en-US";
#endif
}

/**
 * Apply the system locale to OpenTTD.
 * @param out  Output buffer.
 * @param len  Size of the output buffer.
 */
void HarmonyOSApplyLocale(char *out, size_t len)
{
	if (out == nullptr || len == 0) return;

	const char *code = HarmonyOSGetSystemLanguage();
	if (code == nullptr || code[0] == '\0') code = "en-US";

	snprintf(out, len, "LANGUAGE=%s", code);
}

#endif /* HARMONYOS || OPENTTD_HARMONYOS_HOST_TEST */
