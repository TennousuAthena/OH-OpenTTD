/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 */

/**
 * @file harmonyos_paths.cpp
 * Path resolution helpers for the HarmonyOS platform.
 */

#if defined(HARMONYOS)

#include <cstdlib>
#include <cstring>
#include <string>

#include "harmonyos.h"

/**
 * Files base directory inside the application sandbox.
 * @return The absolute path to the app's files directory.
 */
std::string HarmonyOSFilesDir()
{
	const char *files = getenv("OHOS_APP_FILES_DIR");
	if (files != nullptr && files[0] != '\0') return files;

	/* Fallback for sandboxed HarmonyOS applications. */
	return "/data/storage/el2/base/haps/entry/files";
}

/**
 * Cache directory inside the application sandbox.
 * @return The absolute path to the app's cache directory.
 */
std::string HarmonyOSCacheDir()
{
	const char *cache = getenv("OHOS_APP_CACHE_DIR");
	if (cache != nullptr && cache[0] != '\0') return cache;

	return HarmonyOSFilesDir() + "/cache";
}

/**
 * Personal (user data) directory inside the application sandbox.
 * @return The absolute path to the app's personal directory.
 */
const char *HarmonyOSPersonalDir()
{
	static std::string personal = HarmonyOSFilesDir() + "/personal";
	return personal.c_str();
}

/**
 * Compose the personal data path for OpenTTD.
 * @return Absolute path under the sandbox personal directory.
 */
std::string HarmonyOSGetPersonalPath()
{
	return std::string(HarmonyOSPersonalDir()) + "/OpenTTD";
}

/**
 * Compose the save game path.
 * @return Absolute path to the save directory.
 */
std::string HarmonyOSGetSavePath()
{
	return HarmonyOSGetPersonalPath() + "/save";
}

/**
 * Compose the configuration path.
 * @return Absolute path to the config directory.
 */
std::string HarmonyOSGetConfigPath()
{
	return HarmonyOSGetPersonalPath() + "/config";
}

/**
 * Check whether a path is allowed to be used inside the sandbox.
 * Rejects parent directory traversal ("..") and absolute escapes.
 * @param path The path to validate.
 * @return True if the path is sandbox-safe.
 */
bool HarmonyOSIsPathAllowed(const std::string &path)
{
	if (path.empty()) return false;

	/* Reject absolute paths that point outside the sandbox. */
	if (path[0] == '/') {
		const std::string sandbox = HarmonyOSFilesDir();
		/* "/etc/passwd" and friends escape the sandbox. */
		if (path.compare(0, sandbox.size(), sandbox) != 0) return false;
		/* Must be either the sandbox itself or a child of it. */
		if (path.size() > sandbox.size() && path[sandbox.size()] != '/') return false;
	}

	/* Reject parent-directory traversal. */
	if (path.find("..") != std::string::npos) return false;

	return true;
}

#endif /* HARMONYOS */
