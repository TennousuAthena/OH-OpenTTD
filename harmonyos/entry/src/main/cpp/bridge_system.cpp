// bridge_system.cpp — implementation of the clipboard + browser policy bridge.
// See bridge_system.h for the contract.

#include "bridge_system.h"

#include <cctype>

namespace openttd {

void BridgeSystem::clipboardResult(bool available, const std::string& value)
{
    last_clipboard_.available = available;
    last_clipboard_.value = available ? value : "";
}

BrowserLaunch BridgeSystem::validateUrl(const std::string& url) const
{
    if (url.empty()) return BrowserLaunch::EMPTY;

    auto schemeIs = [&](const char* scheme) -> bool {
        size_t n = 0;
        while (scheme[n] != '\0') n++;
        if (url.size() < n + 3) return false; // "://" after scheme
        for (size_t i = 0; i < n; i++) {
            if (std::tolower(static_cast<unsigned char>(url[i])) != scheme[i]) return false;
        }
        return url[n] == ':' && url[n + 1] == '/' && url[n + 2] == '/';
    };

    if (schemeIs("http") || schemeIs("https")) return BrowserLaunch::ACCEPTED;
    return BrowserLaunch::DISALLOWED;
}

BrowserLaunch BridgeSystem::openBrowser(const std::string& url)
{
    BrowserLaunch verdict = validateUrl(url);
    if (verdict == BrowserLaunch::ACCEPTED) {
        last_url_ = url;
        accepted_count_++;
    } else {
        rejected_count_++;
    }
    return verdict;
}

void BridgeSystem::reset()
{
    last_clipboard_ = ClipboardReadResult{};
    last_url_.clear();
    accepted_count_ = 0;
    rejected_count_ = 0;
}

} // namespace openttd
