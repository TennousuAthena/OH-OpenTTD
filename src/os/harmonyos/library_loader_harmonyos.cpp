/*
 * This file is part of OpenTTD.
 * OpenTTD is free software under the GNU General Public License, version 2.
 * See COPYING for details.
 */

/** @file library_loader_harmonyos.cpp Load shared libraries in the app sandbox. */

#include "../../stdafx.h"
#include "../../library_loader.h"
#include <dlfcn.h>

#include "../../safeguards.h"

void *LibraryLoader::OpenLibrary(const std::string &filename)
{
	dlerror();
	void *library = dlopen(filename.c_str(), RTLD_NOW | RTLD_LOCAL);
	if (library == nullptr) {
		const char *message = dlerror();
		this->error = message != nullptr ? message : "Unable to load shared library";
	}
	return library;
}

void LibraryLoader::CloseLibrary()
{
	dlclose(this->handle);
}

void *LibraryLoader::GetSymbol(const std::string &symbol_name)
{
	dlerror();
	void *symbol = dlsym(this->handle, symbol_name.c_str());
	if (const char *message = dlerror(); message != nullptr) this->error = message;
	return symbol;
}
