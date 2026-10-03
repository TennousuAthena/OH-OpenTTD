/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_log.cpp HiLog back-end for OpenTTD's diagnostic output. */

#include "../../stdafx.h"
#include "../../debug.h"

#include <hilog/log.h>

#include <cstring>

#include "../../safeguards.h"

#ifdef HARMONYOS

/** Reserved OpenTTD application domain in the application log domain space. */
static constexpr unsigned int ENGINE_LOG_DOMAIN = 0x0F00;
/** Fixed, non-localised HiLog tag for OpenTTD diagnostics. */
static constexpr const char *ENGINE_LOG_TAG = "OpenTTD_Engine";

/**
 * Map an OpenTTD debug level (0..10) to a HiLog severity level.
 *
 * @param level The OpenTTD debug level.
 * @return The corresponding HiLog LogLevel.
 */
static LogLevel MapLevelToHiLog(int level)
{
	if (level <= 0) return LOG_ERROR;    /* errors / severe warnings */
	if (level == 1) return LOG_WARN;     /* non-fatal warnings */
	if (level <= 2) return LOG_INFO;     /* progress indicators */
	return LOG_DEBUG;                    /* detailed debugging */
}

/**
 * Emit a diagnostic record to HiLog with an explicit text level.
 *
 * This is the generic entry point the NAPI translation unit and other native
 * code use to surface OpenTTD diagnostics through the platform logger. Every
 * payload is emitted with an explicit privacy marker (`%{public}`) so no bare
 * format specifier leaks into the shared HiLog stream.
 *
 * @param level "debug", "info", "warn", "error" or "fatal".
 * @param msg The fully formatted message to log.
 */
void HarmonyOSLog(const char *level, const char *msg)
{
	LogLevel lvl = LOG_INFO;
	if (level != nullptr) {
		const std::string_view severity{level};
		if (severity == "debug") {
			lvl = LOG_DEBUG;
		} else if (severity == "warn") {
			lvl = LOG_WARN;
		} else if (severity == "error") {
			lvl = LOG_ERROR;
		} else if (severity == "fatal") {
			lvl = LOG_FATAL;
		}
	}

	OH_LOG_Print(LOG_APP, lvl, ENGINE_LOG_DOMAIN, ENGINE_LOG_TAG, "%{public}s", msg != nullptr ? msg : "");
}

/**
 * Route an OpenTTD ShowInfo() message to HiLog.
 *
 * Replaces the stderr fallback used on desktop platforms so informational
 * output surfaces in the platform log with the reserved OpenTTD domain.
 *
 * @param str The information message.
 */
void ShowInfoI(std::string_view str)
{
	OH_LOG_Print(LOG_APP, LOG_INFO, ENGINE_LOG_DOMAIN, ENGINE_LOG_TAG, "%{public}s", std::string(str).c_str());
}

/**
 * Route an OpenTTD Debug() record to HiLog, preserving its category in text.
 *
 * @param category The OpenTTD debug category.
 * @param level The OpenTTD debug level.
 * @param message The fully formatted debug message.
 */
void HarmonyOSDebugPrint(std::string_view category, int level, std::string &&message)
{
	const std::string record = fmt::format("[{}:{}] {}", category, level, message);
	OH_LOG_Print(LOG_APP, MapLevelToHiLog(level), ENGINE_LOG_DOMAIN, ENGINE_LOG_TAG, "%{public}s", record.c_str());
}

#endif /* HARMONYOS */
