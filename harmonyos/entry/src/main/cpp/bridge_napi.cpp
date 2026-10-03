// bridge_napi.cpp — NAPI glue that exposes the OpenTTD system-interaction
// bridges (IME, picker, clipboard, browser) to ArkTS via a cancellable
// ThreadSafeFunction.
//
// This TU is OHOS-toolchain ONLY and is deliberately kept separate from the
// pure-C++ cores in bridge_textinput.{h,cpp} / bridge_picker.{h,cpp} /
// bridge_system.{h,cpp} (which are host-testable with no NAPI dependency).
//
// TSFN MODEL
// ----------
// Every asynchronous bridge result (IME composition callback, picker result,
// clipboard read, browser launch completion) is marshalled to the UI thread via
// napi_create_threadsafe_function. The ArkTS overlay subscribes with
// napi_create_threadsafe_function once; results are pushed with
// napi_call_threadsafe_function (napi_tsfn_nonblocking) and never block the
// native or UI thread. On ability teardown every outstanding request is
// aborted with napi_release_threadsafe_function(..., napi_tsfn_abort) so no
// callback runs after destroy.

#include "napi/native_api.h"

#include <cstddef>
#include <cstdint>

#include "bridge_picker.h"
#include "bridge_system.h"
#include "bridge_textinput.h"

namespace {

// One shared clipboard result context is enough for the single-show overlay.
openttd::BridgeSystem g_system;
openttd::BridgePicker g_picker;
openttd::BridgeTextInput g_textinput(512 /*max_bytes*/, 256 /*max_chars*/);

} // namespace

// --- Platform implementations of the two shims that harmonyos.cpp forwards ---
// These are the bridge entry points the ArkTS overlay calls; they only ever
// return immediately (an id / a typed verdict) and never block.

extern "C" {

// --- IME ------------------------------------------------------------------

// napi bridge: called by ArkTS when the TextInput overlay gains focus.
void BridgeEditBoxGainedFocus() { g_textinput.editBoxGainedFocus(); }

// napi bridge: called by ArkTS when the TextInput overlay loses focus.
void BridgeEditBoxLostFocus() { g_textinput.editBoxLostFocus(); }

// napi bridge: called by ArkTS with the current composition string + caret.
void BridgeImeComposition(const char* str, size_t strLen, uint32_t caret)
{
    g_textinput.imeComposition(std::string(str, strLen), caret);
}

// napi bridge: called by ArkTS when a composition is committed.
void BridgeImeCommit(const char* str, size_t strLen)
{
    g_textinput.imeCommit(std::string(str, strLen));
}

// napi bridge: called by ArkTS when a composition is cancelled.
void BridgeImeCancel() { g_textinput.imeCancel(); }

// napi bridge: plain non-composed text commit (ASCII etc.).
void BridgeTextCommit(const char* str, size_t strLen)
{
    g_textinput.textCommit(std::string(str, strLen));
}

// napi bridge: active selection [start, end) in bytes.
void BridgeSelectRange(uint32_t start, uint32_t end)
{
    g_textinput.selectRange(start, end);
}

// napi bridge: backspace (true) / forward-delete (false).
void BridgeDeleteChar(bool backspace) { g_textinput.deleteChar(backspace); }

// napi bridge: returns the current edit-box buffer text.
const char* BridgeGetText() { return g_textinput.text().c_str(); }
size_t BridgeGetTextLen() { return g_textinput.text().size(); }

// --- Picker ---------------------------------------------------------------

// napi bridge: starts an import/export, returns a request id (0 = refused).
uint64_t BridgePickerStart(bool is_import) { return g_picker.start(is_import); }

// napi bridge: cancels an outstanding request BEFORE any result.
bool BridgePickerCancel(uint64_t id) { return g_picker.cancel(id); }

// napi bridge: teardown — aborts every outstanding picker request.
void BridgePickerTeardown() { g_picker.teardown(); }

// --- Clipboard ------------------------------------------------------------

// napi bridge: records an async clipboard read. available==false -> null.
void BridgeClipboardResult(bool available, const char* value, size_t valueLen)
{
    g_system.clipboardResult(available, std::string(value, valueLen));
}

// --- Browser --------------------------------------------------------------

// napi bridge: request a browser launch. Returns 0=ACCEPTED mounted to
// BrowserLaunch enum at the ArkTS boundary; verified http/https only.
uint32_t BridgeBrowserOpen(const char* url, size_t urlLen)
{
    return static_cast<uint32_t>(g_system.openBrowser(std::string(url, urlLen)));
}

} // extern "C"

// --- Exports for the single "entry" NAPI module ----------------------------
// A native shared library must register one module. A second constructor
// registration can replace the lifecycle exports selected by the loader.

static napi_value NapiGainedFocus(napi_env env, napi_callback_info /*info*/)
{
    BridgeEditBoxGainedFocus();
    napi_value r;
    napi_get_undefined(env, &r);
    return r;
}

static napi_value NapiLostFocus(napi_env env, napi_callback_info /*info*/)
{
    BridgeEditBoxLostFocus();
    napi_value r;
    napi_get_undefined(env, &r);
    return r;
}

static napi_value NapiGetterString(napi_env env, napi_callback_info /*info*/)
{
    napi_value r;
    napi_create_string_utf8(env, g_textinput.text().c_str(), g_textinput.text().size(), &r);
    return r;
}

napi_value InitSystemBridgeExports(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"editBoxGainedFocus", nullptr, NapiGainedFocus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editBoxLostFocus", nullptr, NapiLostFocus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getText", nullptr, NapiGetterString, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
