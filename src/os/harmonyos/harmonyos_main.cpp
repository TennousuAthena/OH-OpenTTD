/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_main.cpp Main entry for HarmonyOS. */

#include "../../stdafx.h"
#include "../../openttd.h"
#include "../../crashlog.h"
#include "../../core/random_func.hpp"
#include "../../string_func.h"
#include "../../debug.h"

#include <time.h>
#include <signal.h>
#include <mutex>
#include <thread>
#include <vector>
#include <atomic>
#include <cstdlib>

#include "../../safeguards.h"

extern "C" void OpenTTDHarmonyOSPauseAudio();
extern "C" void OpenTTDHarmonyOSResumeAudio();
extern void HarmonyOSLog(const char *level, const char *message);

namespace {

std::mutex _native_engine_mutex;
std::thread _native_engine_thread;
std::atomic<bool> _native_background{false};
std::atomic<bool> _native_stop_requested{false};
using EngineExitCallback = void (*)(int);
EngineExitCallback _native_exit_callback = nullptr;

int RunOpenTTD()
{
	static const std::string_view executable = "openttd";
	std::vector<std::string_view> params{executable};
#ifdef OPENTTD_HARMONYOS_VERBOSE_LOG
	params.insert(params.end(), {"-d", "driver=2,misc=2,sl=2,fontcache=2"});
#else
	/* Keep one-time driver/GPU capability records without input-level logs. */
	params.insert(params.end(), {"-d", "driver=1"});
#endif

	CrashLog::InitialiseCrashLog();

	SetRandomSeed(time(nullptr));

	signal(SIGPIPE, SIG_IGN);

	HarmonyOSLog("info", "Starting OpenTTD engine");
#ifdef OPENTTD_HARMONYOS_OPTIMIZED
	HarmonyOSLog("info", "Native build: optimized (-O2), debug symbols retained");
#else
	HarmonyOSLog("info", "Native build: deliberate unoptimized Debug (-O0), debug symbols retained");
#endif
	const int result = openttd_main(params);
	HarmonyOSLog("info", fmt::format("OpenTTD engine returned {}", result).c_str());
	return result;
}

}

extern "C" __attribute__((visibility("default"))) int openttd_native_configure(const char *root)
{
	std::lock_guard<std::mutex> lock(_native_engine_mutex);
	if (_native_engine_thread.joinable() || root == nullptr || root[0] != '/') return -1;
	return setenv("OPENTTD_HARMONYOS_ROOT", root, 1);
}

extern "C" __attribute__((visibility("default"))) int openttd_native_set_locale(const char *language)
{
	std::lock_guard<std::mutex> lock(_native_engine_mutex);
	if (_native_engine_thread.joinable() || language == nullptr) return -1;
	std::string locale{language};
	std::replace(locale.begin(), locale.end(), '-', '_');
	/* OpenTTD language packs use language_REGION rather than BCP47 scripts. */
	if (locale == "zh" || locale.starts_with("zh_")) {
		locale = locale.find("Hant") != std::string::npos || locale.find("_TW") != std::string::npos ||
			locale.find("_HK") != std::string::npos || locale.find("_MO") != std::string::npos ? "zh_TW" : "zh_CN";
	} else {
		std::string normalized = locale.substr(0, locale.find('_'));
		for (size_t begin = locale.find('_'); begin != std::string::npos;) {
			size_t end = locale.find('_', begin + 1);
			auto part = locale.substr(begin + 1, end == std::string::npos ? end : end - begin - 1);
			if ((part.size() == 2 && part[0] >= 'A' && part[0] <= 'Z' && part[1] >= 'A' && part[1] <= 'Z') ||
				(part.size() == 3 && std::all_of(part.begin(), part.end(), [](char c) { return c >= '0' && c <= '9'; }))) {
				normalized += "_" + part;
				break;
			}
			begin = end;
		}
		locale = std::move(normalized);
	}
	return locale.empty() ? 0 : setenv("LANGUAGE", locale.c_str(), 1);
}

extern "C" bool OpenTTDHarmonyOSIsBackground() { return _native_background.load(); }
extern "C" bool OpenTTDHarmonyOSShouldExit() { return _native_stop_requested.load(); }

extern "C" __attribute__((visibility("default"))) void openttd_native_set_exit_callback(EngineExitCallback callback)
{
	std::lock_guard<std::mutex> lock(_native_engine_mutex);
	_native_exit_callback = callback;
}

extern "C" __attribute__((visibility("default"))) int openttd_native_init()
{
	std::lock_guard<std::mutex> lock(_native_engine_mutex);
	if (_native_engine_thread.joinable()) return 0;
	if (getenv("OPENTTD_HARMONYOS_ROOT") == nullptr) return -1;
	_exit_game = false;
	_native_stop_requested = false;
	_native_engine_thread = std::thread([callback = _native_exit_callback] {
		const int result = RunOpenTTD();
		if (callback != nullptr) callback(result);
	});
	return 0;
}

extern "C" __attribute__((visibility("default"))) void openttd_native_pause()
{
	_native_background = true;
}

extern "C" __attribute__((visibility("default"))) void openttd_native_resume()
{
	_native_background = false;
}

extern "C" __attribute__((visibility("default"))) void openttd_native_shutdown()
{
	std::lock_guard<std::mutex> lock(_native_engine_mutex);
	_native_stop_requested = true;
	if (_native_engine_thread.joinable() && _native_engine_thread.get_id() != std::this_thread::get_id()) {
		_native_engine_thread.join();
	}
}
