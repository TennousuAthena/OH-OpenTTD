// bridge_system.h — pure C++ clipboard + browser-launch policy bridge for the
// OpenTTD HarmonyOS port.
//
// DESIGN CONTRACT
// ---------------
// This header and its implementation are DELIBERATELY free of any XComponent /
// NAPI / OHOS SDK dependency so the full contract can be compiled and exercised
// on the host (see scripts/harmonyos/test-bridges.sh).
//
//   * CLIPBOARD. Models reading the system pasteboard. Reading is ASYNC on the
//     device (pasteboard.getData returns a Promise); the ArkTS side resolves it
//     and calls clipboardResult(). When the clipboard is unavailable (no text,
//     permission, or platform failure) the result is null, matching the
//     GetClipboardContents contract (src/textbuf.cpp:29,223-229) which returns
//     std::nullopt. The bridge never returns a placeholder string.
//
//   * BROWSER. OSOpenBrowser is implemented by launching a system browser via
//     startAbilityByType. URLs are STRICTLY restricted to http/https (plan line
//     224 / diagnostics-policy.md http/https allowlist). Any other scheme
//     (file:, ftp:, javascript:, intent:, etc.) is REJECTED and the browser is
//     NOT launched. The allowlist check is pure and host-testable.
//
// THREAD OWNERSHIP
// ----------------
// All methods MUST be called from the UI (main) thread. No method blocks.

#pragma once

#include <cstdint>
#include <string>

namespace openttd {

// Clipboard read result. value.has_value() is false (null) when the clipboard
// is unavailable — the exact "returns null" acceptance criterion.
struct ClipboardReadResult {
    bool available = false;
    std::string value; // only meaningful when available == true
};

enum class BrowserLaunch {
    ACCEPTED,       // URL is http/https and launch was requested
    DISALLOWED,     // URL scheme is not http/https; launch rejected
    EMPTY,          // empty URL rejected
};

class BridgeSystem {
public:
    BridgeSystem() = default;

    // Records an async clipboard read result. When the platform reports no
    // text (unavailable), the result is null (available=false).
    void clipboardResult(bool available, const std::string& value);

    // The last delivered clipboard result. available()==false means null.
    const ClipboardReadResult& clipboard() const { return last_clipboard_; }
    bool clipboardAvailable() const { return last_clipboard_.available; }

    // Validates `url` against the http/https allowlist. Returns ACCEPTED iff
    // url is non-empty and starts with "http://" or "https://" (case-insensitive
    // scheme). A disallowed scheme is REJECTED and MUST NOT launch a browser.
    BrowserLaunch validateUrl(const std::string& url) const;

    // Requests a browser launch for `url`. Returns ACCEPTED and records the
    // last launched URL only when validateUrl() passes; otherwise returns
    // DISALLOWED/EMPTY and records nothing.
    BrowserLaunch openBrowser(const std::string& url);

    // The last accepted browser URL (empty if none).
    const std::string& lastLaunchedUrl() const { return last_url_; }

    // Total accepted / rejected launch counts (diagnostics).
    uint64_t browserAcceptedCount() const { return accepted_count_; }
    uint64_t browserRejectedCount() const { return rejected_count_; }

    // Resets recorded state (used between test scenarios).
    void reset();

private:
    ClipboardReadResult last_clipboard_;
    std::string last_url_;
    uint64_t accepted_count_ = 0;
    uint64_t rejected_count_ = 0;
};

} // namespace openttd
