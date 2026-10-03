/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos.cpp Implementation of HarmonyOS specific file handling. */

#include "../../stdafx.h"
#include "../../debug.h"
#include "../../string_func.h"
#include "../../fios.h"

#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <signal.h>
#include <pthread.h>
#include <filesystem>
#include <atomic>

#include "../../safeguards.h"

extern void HarmonyOSLog(const char *level, const char *message);

using BrowserCallback = void (*)(const char *);
static std::atomic<BrowserCallback> _browser_callback{nullptr};

extern "C" __attribute__((visibility("default"))) void openttd_native_set_browser_callback(BrowserCallback callback)
{
	_browser_callback.store(callback);
}

bool FiosIsRoot(const std::string &path)
{
	return path == PATHSEP;
}

void FiosGetDrives(FileList &)
{
	return;
}

std::optional<uint64_t> FiosGetDiskFreeSpace(const std::string &path)
{
	struct statvfs s;

	if (statvfs(path.c_str(), &s) == 0) return static_cast<uint64_t>(s.f_frsize) * s.f_bavail;
	return std::nullopt;
}

bool FiosIsHiddenFile(const std::filesystem::path &path)
{
	return path.filename().string().starts_with(".");
}

void ShowOSErrorBox(std::string_view buf, bool)
{
	HarmonyOSLog("error", std::string(buf).c_str());
	fmt::print(stderr, "Error: {}\n", buf);
}

std::optional<std::string> GetClipboardContents()
{
	/* No clipboard access without a platform driver; report none. */
	return std::nullopt;
}

void OSOpenBrowser(const std::string &url)
{
	if (auto callback = _browser_callback.load(); callback != nullptr) {
		callback(url.c_str());
	}
}

void SetCurrentThreadName([[maybe_unused]] const std::string &thread_name)
{
	/* pthread_setname_np is a GNU libc extension not available on the
	 * HarmonyOS libc; the thread name is left unchanged. */
}
