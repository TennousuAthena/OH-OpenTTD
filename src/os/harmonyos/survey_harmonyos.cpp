/*
 * This file is part of OpenTTD.
 * OpenTTD is free software under the GNU General Public License, version 2.
 * See COPYING for details.
 */

/** @file survey_harmonyos.cpp OS information for diagnostics and optional surveys. */

#include "../../stdafx.h"
#include "../../survey.h"
#include <sys/utsname.h>
#include <thread>
#include <unistd.h>

#include "../../safeguards.h"

void SurveyOS(nlohmann::json &json)
{
	json["os"] = "HarmonyOS";
	struct utsname name;
	if (uname(&name) == 0) {
		json["release"] = name.release;
		json["machine"] = name.machine;
		json["version"] = name.version;
	}
	long pages = sysconf(_SC_PHYS_PAGES);
	long page_size = sysconf(_SC_PAGE_SIZE);
	if (pages > 0 && page_size > 0) json["memory"] = SurveyMemoryToText(static_cast<uint64_t>(pages) * page_size);
	json["hardware_concurrency"] = std::thread::hardware_concurrency();
}
