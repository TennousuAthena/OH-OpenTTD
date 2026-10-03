// napi_init.cpp — NAPI module "entry": ArkTS <-> native lifecycle bridge glue.
//
// This is the ONLY translation unit that includes OHOS XComponent / NAPI
// headers. The lifecycle state machine itself (lifecycle_bridge.{h,cpp}) is
// pure C++ and host-testable. On surface creation this module also dlopen()s
// the complete game core libopenttd.so after ArkTS prepares its resources.

#include "napi/native_api.h"
#include "ace/xcomponent/native_interface_xcomponent.h"
#include "hilog/log.h"

#include <cstdint>
#include <dlfcn.h>
#include <string_view>
#include <string>
#include <memory>
#include <mutex>

#include "lifecycle_bridge.h"
#include "game_textinput.h"

#undef LOG_TAG
#ifndef LOG_DOMAIN
#define LOG_DOMAIN 0x0F00
#endif
#define LOG_TAG "OpenTTD_Native"

napi_value InitSystemBridgeExports(napi_env env, napi_value exports);

namespace {

// The real engine owns its threads; this bridge tracks UI lifecycle only.
openttd::LifecycleBridge g_bridge(false);
void* g_engine_handle = nullptr;
bool g_foreground = true;
std::mutex g_exit_mutex;
napi_threadsafe_function g_exit_callback = nullptr;
std::mutex g_browser_mutex;
napi_threadsafe_function g_browser_callback = nullptr;

void ClearBrowserCallback(void*)
{
    std::lock_guard<std::mutex> lock(g_browser_mutex);
    if (g_browser_callback == nullptr) return;
    napi_release_threadsafe_function(g_browser_callback, napi_tsfn_abort);
    g_browser_callback = nullptr;
}

void NotifyBrowserRequest(const char* url)
{
    std::lock_guard<std::mutex> lock(g_browser_mutex);
    if (g_browser_callback == nullptr || url == nullptr) return;
    auto request = std::make_unique<std::string>(url);
    if (napi_call_threadsafe_function(g_browser_callback, request.get(), napi_tsfn_nonblocking) == napi_ok) {
        request.release();
    } else {
        OH_LOG_WARN(LOG_APP, "could not queue browser request");
    }
}

void ClearExitCallback(void*)
{
    std::lock_guard<std::mutex> lock(g_exit_mutex);
    if (g_exit_callback == nullptr) return;
    napi_release_threadsafe_function(g_exit_callback, napi_tsfn_abort);
    g_exit_callback = nullptr;
}

void NotifyEngineExit(int code)
{
    std::lock_guard<std::mutex> lock(g_exit_mutex);
    if (g_exit_callback == nullptr) return;
    auto result = std::make_unique<int>(code);
    if (napi_call_threadsafe_function(g_exit_callback, result.get(), napi_tsfn_nonblocking) == napi_ok) {
        result.release();
    } else {
        OH_LOG_ERROR(LOG_APP, "could not notify ArkTS of engine exit");
    }
}

void* GetEngineHandle()
{
    if (g_engine_handle == nullptr) g_engine_handle = dlopen("libopenttd.so", RTLD_NOW | RTLD_LOCAL);
    return g_engine_handle;
}

template <typename Function>
Function GetEngineFunction(const char* name)
{
    void* handle = GetEngineHandle();
    if (handle == nullptr) {
        OH_LOG_WARN(LOG_APP, "dlopen(libopenttd.so) failed: %{public}s", dlerror());
        return nullptr;
    }
    Function function = reinterpret_cast<Function>(dlsym(handle, name));
    if (function == nullptr) OH_LOG_WARN(LOG_APP, "dlsym(%{public}s) failed: %{public}s", name, dlerror());
    return function;
}

// --- XComponent surface lifecycle glue -----------------------------------

void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window)
{
    OH_LOG_INFO(LOG_APP, "OnSurfaceCreated");
    uint64_t width = 0;
    uint64_t height = 0;
    if (OH_NativeXComponent_GetXComponentSize(component, window, &width, &height) !=
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "OnSurfaceCreated: GetXComponentSize failed");
        return;
    }
    g_bridge.onSurfaceCreated(width, height, window);

    // dlsym the exported native-window provider entry points (do not
    // direct-link against libopenttd.so) and set the freshly created surface.
    using SetWindowFn = void (*)(void*, uint64_t, uint64_t);
    SetWindowFn set_window = GetEngineFunction<SetWindowFn>("openttd_native_set_window");
    if (set_window == nullptr) {
        return;
    }
    set_window(window, width, height);
    using RegisterInputFn = void (*)(OH_NativeXComponent*);
    RegisterInputFn register_input = GetEngineFunction<RegisterInputFn>("openttd_native_register_input");
    if (register_input == nullptr) return;
    register_input(component);

    // The video driver reads the provider as soon as the engine thread starts.
    using InitFn = int (*)();
    InitFn initialize = GetEngineFunction<InitFn>("openttd_native_init");
    if (initialize != nullptr) OH_LOG_INFO(LOG_APP, "engine thread start result=%{public}d", initialize());
}

void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window)
{
    uint64_t width = 0;
    uint64_t height = 0;
    if (OH_NativeXComponent_GetXComponentSize(component, window, &width, &height) ==
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        g_bridge.onSurfaceChanged(g_bridge.generation(), width, height);
        using SetWindowFn = void (*)(void*, uint64_t, uint64_t);
        SetWindowFn update = GetEngineFunction<SetWindowFn>("openttd_native_set_window");
        if (update != nullptr) update(window, width, height);
    }
}

void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window)
{
    g_bridge.onSurfaceDestroyed(g_bridge.generation());

    // dlsym the exported native-window clear entry point (do not direct-link
    // against libopenttd.so) and detach the destroyed surface.
    using ClearWindowFn = void (*)();
    ClearWindowFn clear_window = GetEngineFunction<ClearWindowFn>("openttd_native_clear_window");
    if (clear_window == nullptr) {
        return;
    }
    clear_window();
}

void OnTouchEventCB(OH_NativeXComponent* component, void* window)
{
    using TouchFn = void (*)(OH_NativeXComponent*, void*);
    TouchFn dispatch = GetEngineFunction<TouchFn>("openttd_native_dispatch_touch");
    if (dispatch != nullptr) dispatch(component, window);
}

// --- NAPI exports ----------------------------------------------------------

napi_value GetTextInputState(napi_env env, napi_callback_info)
{
    using GetFn = void (*)(HarmonyOSTextInputState*);
    static GetFn get = GetEngineFunction<GetFn>("openttd_native_get_text_input_state");
    HarmonyOSTextInputState state;
    if (get != nullptr) get(&state);
    napi_value result;
    napi_create_object(env, &result);
    auto number = [&](const char* name, int64_t value) {
        napi_value property;
        napi_create_int64(env, value, &property);
        napi_set_named_property(env, result, name, property);
    };
    number("session", state.session);
    number("sequence", state.sequence);
    number("left", state.left);
    number("top", state.top);
    number("width", state.width);
    number("height", state.height);
    number("caret", state.caret);
    number("maxChars", state.max_chars);
    napi_value active;
    napi_get_boolean(env, state.active, &active);
    napi_set_named_property(env, result, "active", active);
    napi_value text;
    napi_create_string_utf8(env, state.text, NAPI_AUTO_LENGTH, &text);
    napi_set_named_property(env, result, "text", text);
    return result;
}

napi_value SetTextInput(napi_env env, napi_callback_info info)
{
    size_t argc = 7;
    napi_value args[7];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t session = 0, sequence = 0;
    int32_t start = 0, end = 0, previewStart = -1, previewEnd = -1;
    size_t length = 0;
    if (argc != 7 || napi_get_value_uint32(env, args[0], &session) != napi_ok ||
        napi_get_value_uint32(env, args[1], &sequence) != napi_ok ||
        napi_get_value_string_utf8(env, args[2], nullptr, 0, &length) != napi_ok ||
        napi_get_value_int32(env, args[3], &start) != napi_ok ||
        napi_get_value_int32(env, args[4], &end) != napi_ok ||
        napi_get_value_int32(env, args[5], &previewStart) != napi_ok ||
        napi_get_value_int32(env, args[6], &previewEnd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "setTextInput requires a session, sequence, text and selection/preview ranges");
        return nullptr;
    }
    if (length > 65535) {
        napi_throw_range_error(env, nullptr, "Text exceeds the engine edit-buffer limit");
        return nullptr;
    }
    std::string text(length + 1, '\0');
    napi_get_value_string_utf8(env, args[2], text.data(), text.size(), &length);
    using SetFn = void (*)(uint32_t, uint32_t, const char*, int, int, int, int);
    static SetFn set = GetEngineFunction<SetFn>("openttd_native_set_text_input");
    if (set != nullptr) set(session, sequence, text.c_str(), start, end, previewStart, previewEnd);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value TextInputKey(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t session;
    int32_t key;
    bool down;
    if (argc != 3 || napi_get_value_uint32(env, args[0], &session) != napi_ok ||
        napi_get_value_int32(env, args[1], &key) != napi_ok ||
        napi_get_value_bool(env, args[2], &down) != napi_ok) {
        napi_throw_type_error(env, nullptr, "textInputKey requires session, key and down");
        return nullptr;
    }
    using KeyFn = void (*)(uint32_t, int, bool);
    static KeyFn send = GetEngineFunction<KeyFn>("openttd_native_text_input_key");
    if (send != nullptr) send(session, key, down);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value OnEngineExit(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value callback;
    napi_get_cb_info(env, info, &argc, &callback, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    if (argc != 1 || napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, nullptr, "onEngineExit requires a callback");
        return nullptr;
    }
    using RegisterFn = void (*)(void (*)(int));
    RegisterFn registerCallback = GetEngineFunction<RegisterFn>("openttd_native_set_exit_callback");
    if (registerCallback == nullptr) {
        napi_throw_error(env, nullptr, "Engine exit callback unavailable");
        return nullptr;
    }
    ClearExitCallback(nullptr);
    napi_value name;
    napi_create_string_utf8(env, "OpenTTDEngineExit", NAPI_AUTO_LENGTH, &name);
    {
        std::lock_guard<std::mutex> lock(g_exit_mutex);
        napi_status status = napi_create_threadsafe_function(env, callback, nullptr, name, 1, 1,
            nullptr, nullptr, nullptr,
            [](napi_env env, napi_value callback, void*, void* data) {
                std::unique_ptr<int> code(static_cast<int*>(data));
                if (env == nullptr || callback == nullptr || code == nullptr) return;
                napi_value argument;
                napi_value receiver;
                napi_value ignored;
                napi_create_int32(env, *code, &argument);
                napi_get_undefined(env, &receiver);
                napi_call_function(env, receiver, callback, 1, &argument, &ignored);
            }, &g_exit_callback);
        if (status != napi_ok) {
            g_exit_callback = nullptr;
            napi_throw_error(env, nullptr, "Could not create engine exit callback");
            return nullptr;
        }
        napi_unref_threadsafe_function(env, g_exit_callback);
    }
    registerCallback(NotifyEngineExit);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value OnOpenUrl(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value callback;
    napi_get_cb_info(env, info, &argc, &callback, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    if (argc != 1 || napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, nullptr, "onOpenUrl requires a callback");
        return nullptr;
    }
    using RegisterFn = void (*)(void (*)(const char*));
    RegisterFn registerCallback = GetEngineFunction<RegisterFn>("openttd_native_set_browser_callback");
    if (registerCallback == nullptr) {
        napi_throw_error(env, nullptr, "Engine browser callback unavailable");
        return nullptr;
    }
    ClearBrowserCallback(nullptr);
    napi_value name;
    napi_create_string_utf8(env, "OpenTTDBrowserRequest", NAPI_AUTO_LENGTH, &name);
    {
        std::lock_guard<std::mutex> lock(g_browser_mutex);
        napi_status status = napi_create_threadsafe_function(env, callback, nullptr, name, 8, 1,
            nullptr, nullptr, nullptr,
            [](napi_env env, napi_value callback, void*, void* data) {
                std::unique_ptr<std::string> url(static_cast<std::string*>(data));
                if (env == nullptr || callback == nullptr || url == nullptr) return;
                napi_value argument;
                napi_value receiver;
                napi_value ignored;
                napi_create_string_utf8(env, url->data(), url->size(), &argument);
                napi_get_undefined(env, &receiver);
                napi_call_function(env, receiver, callback, 1, &argument, &ignored);
            }, &g_browser_callback);
        if (status != napi_ok) {
            g_browser_callback = nullptr;
            napi_throw_error(env, nullptr, "Could not create browser callback");
            return nullptr;
        }
        napi_unref_threadsafe_function(env, g_browser_callback);
    }
    registerCallback(NotifyBrowserRequest);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value ConfigurePaths(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    size_t length = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "configurePaths requires the game data directory");
        return nullptr;
    }
    std::string root(length + 1, '\0');
    napi_get_value_string_utf8(env, argv[0], root.data(), root.size(), &length);
    root.resize(length);
    if (argc >= 2) {
        size_t localeLength = 0;
        if (napi_get_value_string_utf8(env, argv[1], nullptr, 0, &localeLength) != napi_ok) {
            napi_throw_type_error(env, nullptr, "configurePaths language must be a string");
            return nullptr;
        }
        std::string locale(localeLength + 1, '\0');
        napi_get_value_string_utf8(env, argv[1], locale.data(), locale.size(), &localeLength);
        locale.resize(localeLength);
        using LocaleFn = int (*)(const char*);
        LocaleFn setLocale = GetEngineFunction<LocaleFn>("openttd_native_set_locale");
        if (setLocale == nullptr || setLocale(locale.c_str()) != 0) {
            napi_throw_error(env, nullptr, "Native locale configuration failed");
            return nullptr;
        }
    }
    using ConfigureFn = int (*)(const char*);
    ConfigureFn configure = GetEngineFunction<ConfigureFn>("openttd_native_configure");
    int code = configure != nullptr ? configure(root.c_str()) : -1;
    if (code == 0) {
        using LifecycleFn = void (*)();
        LifecycleFn state = GetEngineFunction<LifecycleFn>(g_foreground ? "openttd_native_resume" : "openttd_native_pause");
        if (state != nullptr) state();
        g_bridge.onAbilityCreated();
        g_bridge.onWindowLoaded(g_bridge.appGeneration());
        if (g_foreground) g_bridge.onForeground(g_bridge.appGeneration());
    }
    napi_value result;
    napi_create_int32(env, code, &result);
    return result;
}

napi_value DrawPattern(napi_env env, napi_callback_info info)
{
    // Placeholder: draws a simple pattern into the native surface. No-op until
    // a rendering surface is wired up (later wave).
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

napi_value ChangeColor(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

napi_value GetLifecycleState(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(g_bridge.state()), &result);
    return result;
}

napi_value InvokeEngineLifecycle(napi_env env, const char* symbol)
{
    using LifecycleFn = void (*)();
    // Foreground/background can arrive before resource preparation finishes.
    LifecycleFn function = g_engine_handle != nullptr ? GetEngineFunction<LifecycleFn>(symbol) : nullptr;
    if (function != nullptr) function();
    if (symbol == std::string_view{"openttd_native_pause"}) {
        g_foreground = false;
        g_bridge.onBackground(g_bridge.appGeneration());
    }
    if (symbol == std::string_view{"openttd_native_resume"}) {
        g_foreground = true;
        g_bridge.onForeground(g_bridge.appGeneration());
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Pause(napi_env env, napi_callback_info info) { return InvokeEngineLifecycle(env, "openttd_native_pause"); }
napi_value Resume(napi_env env, napi_callback_info info) { return InvokeEngineLifecycle(env, "openttd_native_resume"); }
struct ShutdownWork {
    napi_async_work work = nullptr;
    void (*shutdown)() = nullptr;
};

napi_value Shutdown(napi_env env, napi_callback_info info)
{
    ClearBrowserCallback(nullptr);
    ClearExitCallback(nullptr);
    g_bridge.onDestroyed(g_bridge.appGeneration());
    using ShutdownFn = void (*)();
    ShutdownFn shutdown = g_engine_handle != nullptr ? GetEngineFunction<ShutdownFn>("openttd_native_shutdown") : nullptr;
    if (shutdown != nullptr) {
        auto* task = new ShutdownWork;
        task->shutdown = shutdown;
        napi_value name;
        napi_create_string_utf8(env, "OpenTTDShutdown", NAPI_AUTO_LENGTH, &name);
        napi_status status = napi_create_async_work(env, nullptr, name,
            [](napi_env, void* data) { static_cast<ShutdownWork*>(data)->shutdown(); },
            [](napi_env env, napi_status, void* data) {
                auto* task = static_cast<ShutdownWork*>(data);
                napi_delete_async_work(env, task->work);
                delete task;
            }, task, &task->work);
        if (status == napi_ok) status = napi_queue_async_work(env, task->work);
        if (status != napi_ok) {
            if (task->work != nullptr) napi_delete_async_work(env, task->work);
            delete task;
            OH_LOG_ERROR(LOG_APP, "could not schedule engine shutdown");
        }
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"configurePaths", nullptr, ConfigurePaths, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onEngineExit", nullptr, OnEngineExit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onOpenUrl", nullptr, OnOpenUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTextInputState", nullptr, GetTextInputState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTextInput", nullptr, SetTextInput, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"textInputKey", nullptr, TextInputKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"drawPattern", nullptr, DrawPattern, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"changeColor", nullptr, ChangeColor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLifecycleState", nullptr, GetLifecycleState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resume", nullptr, Resume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdown", nullptr, Shutdown, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    napi_add_env_cleanup_hook(env, ClearExitCallback, nullptr);
    napi_add_env_cleanup_hook(env, ClearBrowserCallback, nullptr);
    InitSystemBridgeExports(env, exports);

    // Retrieve the native XComponent instance injected by the framework and
    // register the surface lifecycle callbacks that feed the bridge.
    napi_value exportInstance = nullptr;
    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) == napi_ok &&
        napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) == napi_ok &&
        nativeXComponent != nullptr) {
        static OH_NativeXComponent_Callback callback;
        callback.OnSurfaceCreated = OnSurfaceCreatedCB;
        callback.OnSurfaceChanged = OnSurfaceChangedCB;
        callback.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
        callback.DispatchTouchEvent = OnTouchEventCB;
        OH_NativeXComponent_RegisterCallback(nativeXComponent, &callback);
        OH_LOG_INFO(LOG_APP, "registered XComponent callbacks");
    } else {
        OH_LOG_WARN(LOG_APP, "no native XComponent injected; callbacks not registered");
    }
    return exports;
}

} // namespace

extern "C" __attribute__((constructor)) void RegisterEntryModule()
{
    static napi_module module = {
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = nullptr,
        .nm_register_func = Init,
        .nm_modname = "entry",
        .nm_priv = nullptr,
        .reserved = {0},
    };
    napi_module_register(&module);
}
