// lifecycle_bridge.h — pure C++ app/surface lifecycle + thread-ownership
// state machine for the OpenTTD HarmonyOS port.
//
// DESIGN CONTRACT
// --------------
// This header and its implementation are DELIBERATELY free of any
// XComponent / NAPI / OHOS SDK dependency. The full lifecycle contract can be
// compiled and unit-tested on the host (Catch2, see
// scripts/harmonyos/test-lifecycle-bridge.sh). The XComponent glue that feeds
// this machine lives in napi_init.cpp, which is the ONLY translation unit
// allowed to include OHOS headers.
//
// THREAD OWNERSHIP CONTRACT
// -------------------------
//   * ONE native engine thread. The bridge owns a single std::thread that runs
//     the engine loop (simulation / rendering tick). It is started on the
//     first FOREGROUND transition and stopped + joined on DESTROYED.
//   * UI-THREAD-ONLY operations. Every lifecycle transition method
//     (onAbilityCreated/onWindowLoaded/onForeground/onBackground/onDestroyed
//     and the surface family) MUST be called from the UI (main) thread only,
//     which is what the HarmonyOS runtime guarantees for UIAbility and
//     XComponent callbacks. The bridge is NOT internally synchronized for
//     these: concurrent UI-thread mutation is a contract violation.
//   * The engine thread NEVER touches the lifecycle state machine. It only
//     runs the user-supplied engine tick and may post UI callbacks through the
//     TSFN-style CallbackQueue. That queue is internally synchronized and is
//     the only cross-thread channel.
//   * TSFN CALLBACK QUEUE. postUiCallback() models a NAPI ThreadSafeFunction:
//     the engine thread posts, the UI thread drains via drainUiCallbacks().
//     After DESTROYED the queue is closed and cancelled: postUiCallback()
//     returns false and drainUiCallbacks() runs nothing (zero callbacks after
//     destroy).
//   * GENERATION GUARDS. App lifecycle transitions carry the app generation
//     the caller observed (appGeneration()); stale generations are rejected.
//     Surface callbacks carry the surface generation; stale generations are
//     ignored. onAbilityCreated() bumps the app generation for each ability
//     instance; onSurfaceCreated() bumps the surface generation.
//   * BACKGROUND SAFETY. onBackground() pauses the engine thread before the
//     state is published, so rendering/audio driven by the tick stops while
//     the simulation state is preserved untouched. onForeground() resumes.
//   * BOUNDED TEARDOWN. onDestroyed()/shutdown() request engine stop and wait
//     at most budgetMs for the thread to exit before detaching; the UI thread
//     is never blocked beyond the budget.
//   * IDEMPOTENCY. Re-delivery of the same transition in the same state is a
//     no-op success (returns true, no state change).

#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

namespace openttd {

// Application lifecycle state (HarmonyOS UIAbility lifecycle).
//   NONE          — bridge constructed, ability not yet created
//   CREATED       — onAbilityCreated accepted
//   WINDOW_LOADED — window stage created and content loaded
//   FOREGROUND    — ability foregrounded / interactive
//   BACKGROUND    — ability backgrounded (no focus); engine paused
//   DESTROYED     — terminal
enum class AppState {
    NONE,
    CREATED,
    WINDOW_LOADED,
    FOREGROUND,
    BACKGROUND,
    DESTROYED,
};

// Native surface state reported by the XComponent callbacks.
enum class SurfaceState {
    SURFACE_NONE,       // no surface attached
    SURFACE_CREATED,    // surface (re)created; carries a fresh generation
    SURFACE_CHANGED,    // surface geometry changed
    SURFACE_DESTROYED,  // surface torn down
};

// Geometry + generation of the currently attached surface.
struct SurfaceInfo {
    uint64_t generation = 0; // monotonic; 0 == no surface
    uint64_t width = 0;      // in pixels
    uint64_t height = 0;     // in pixels
};

// -- NativeWindowProvider -----------------------------------------------------
// Thread-safe holder of the current native window handle plus a monotonic
// generation counter. This is the handoff contract the EGL video driver
// consumes: the XComponent glue (napi_init.cpp) calls set() on surface-created
// and clear() on surface-destroyed; VideoDriver_HarmonyOS reads snapshot()
// every frame and recreates its EGL surface when the generation moves on.
//
//   * set()  attaches/replaces the handle and monotonically bumps the
//            generation (0 == never attached; each attach gets a fresh number).
//   * clear() detaches the handle and monotonically bumps the generation, so
//            a consumer that bound an older generation can tell the surface is
//            gone (snapshot().window == nullptr).
//
// The handle is deliberately opaque (void*) so this file stays free of OHOS
// SDK types and remains host-testable; the XComponent glue casts
// OH_NativeWindow* <-> void* at the boundary.
struct NativeWindowSnapshot {
    void*    window = nullptr; ///< Opaque native window handle; null == none.
    uint64_t generation = 0;   ///< Monotonic generation; 0 == never attached.
    uint64_t width = 0;        ///< Surface width in pixels (informational).
    uint64_t height = 0;       ///< Surface height in pixels (informational).
};

class NativeWindowProvider {
public:
    NativeWindowProvider() = default;

    // Attach (or replace) a native window. Returns the new generation.
    uint64_t set(void* window, uint64_t width, uint64_t height)
    {
        std::lock_guard<std::mutex> lock(mu_);
        window_ = window;
        width_ = width;
        height_ = height;
        generation_ = next_generation_++;
        return generation_;
    }

    // Detach the current native window. Returns the new generation.
    uint64_t clear()
    {
        std::lock_guard<std::mutex> lock(mu_);
        window_ = nullptr;
        generation_ = next_generation_++;
        return generation_;
    }

    // Consistent, thread-safe snapshot for consumers (the video driver).
    NativeWindowSnapshot snapshot() const
    {
        std::lock_guard<std::mutex> lock(mu_);
        return NativeWindowSnapshot{window_, generation_, width_, height_};
    }

    // Thread-safe current generation (0 == no surface attached).
    uint64_t generation() const
    {
        std::lock_guard<std::mutex> lock(mu_);
        return generation_;
    }

    // Thread-safe: true while a non-null window is attached.
    bool valid() const
    {
        std::lock_guard<std::mutex> lock(mu_);
        return window_ != nullptr;
    }

private:
    mutable std::mutex mu_;
    void* window_ = nullptr;
    uint64_t generation_ = 0;      ///< Last assigned monotonic generation.
    uint64_t next_generation_ = 1; ///< Next generation to hand out.
    uint64_t width_ = 0;
    uint64_t height_ = 0;
};

// -- Window reconciliation (video-driver handoff) ----------------------------
// Decides what the EGL driver must do given the provider's current snapshot
// and the generation the driver already bound. Shared verbatim by
// VideoDriver_HarmonyOS::CheckSurface and the host driver test, so the
// decision logic is exercised against the real provider, not a replica.
enum class WindowAction {
    KEEP,     // same generation, window present: surface still valid
    RECREATE, // new generation supersedes the bound surface
    TEARDOWN, // null / stale window: reject frame and release EGL resources
};

struct WindowDecision {
    WindowAction action = WindowAction::TEARDOWN;
    void*    window = nullptr;   ///< Handle to adopt (RECREATE) or keep (KEEP).
    uint64_t generation = 0;     ///< Provider generation to bind.
};

// Pure decision helper. Null window or a never-attached generation ->
// TEARDOWN. Generation change -> RECREATE with the new handle. Otherwise KEEP.
// Implemented inline so the video driver (a separate TU/library) and the host
// driver test consume the exact same decision logic as the bridge.
inline WindowDecision ReconcileWindow(const NativeWindowSnapshot& snap, uint64_t boundGeneration)
{
    if (snap.window == nullptr || snap.generation == 0) {
        return WindowDecision{WindowAction::TEARDOWN, nullptr, snap.generation};
    }
    if (snap.generation != boundGeneration) {
        return WindowDecision{WindowAction::RECREATE, snap.window, snap.generation};
    }
    return WindowDecision{WindowAction::KEEP, snap.window, snap.generation};
}

// Simple log sink: receives a NUL-terminated, single-line message.
using LogSink = void (*)(const char* message);

// Engine tick callback, invoked by the engine thread while FOREGROUND.
// May post UI callbacks via LifecycleBridge::postUiCallback().
using EngineTickFn = void (*)(void* userdata);

// TSFN-style UI callback: runs on the UI thread when drained.
using UiCallback = void (*)(void* userdata);

// -- EngineThread -----------------------------------------------------------
// The single native engine thread. Owned by LifecycleBridge. Its loop is:
//   wait until not paused and not stopped -> run one tick -> repeat.
// requestPause() blocks the loop (rendering/audio paused, simulation state
// preserved); requestResume() unblocks it; requestStop() makes the loop exit.
// joinWithin() performs a BOUNDED join: it waits at most `budget` for the
// thread to exit, and detaches if the budget is exceeded so the caller (UI
// thread) is never blocked indefinitely.
class EngineThread {
public:
    EngineThread() = default;
    ~EngineThread() { this->requestStop(); this->joinWithin(std::chrono::milliseconds(200)); }

    EngineThread(const EngineThread&) = delete;
    EngineThread& operator=(const EngineThread&) = delete;

    // Set the tick callback (must be called before start(); guarded by mutex).
    void setTick(EngineTickFn fn, void* userdata);

    // Spawn the engine thread. Idempotent: a running thread is left alone.
    void start();

    void requestPause();
    void requestResume();
    void requestStop();

    // Bounded join. Returns true if the thread exited and was joined within
    // budget, false if it had to be detached (budget exceeded).
    bool joinWithin(std::chrono::milliseconds budget);

    bool running() const { return running_.load(std::memory_order_acquire); }
    uint64_t tickCount() const { return tick_count_.load(std::memory_order_acquire); }

private:
    void loop();

    std::thread thread_;
    std::mutex mu_;
    std::condition_variable cv_;
    EngineTickFn tick_ = nullptr;
    void* userdata_ = nullptr;
    bool paused_ = false;
    bool stop_ = false;
    bool started_ = false;
    std::atomic<bool> running_{false};
    std::atomic<uint64_t> tick_count_{0};
};

// -- CallbackQueue (TSFN model) ---------------------------------------------
// Thread-safe FIFO of UI callbacks. post() may be called from any thread
// (engine); drain() is the UI-thread consumer. cancel() drops pending work and
// makes post() fail — used at teardown for "zero callbacks after destroy".
class CallbackQueue {
public:
    CallbackQueue() = default;

    // Returns false if the queue is closed (after DESTROYED).
    bool post(UiCallback cb, void* userdata);

    // Run every pending callback on the calling (UI) thread.
    // Returns the number of callbacks run.
    size_t drain();

    // Drop pending callbacks without running them and close the queue.
    void cancel();

    size_t pending() const;

private:
    mutable std::mutex mu_;
    std::deque<std::pair<UiCallback, void*>> queue_;
    bool closed_ = false;
};

// -- LifecycleBridge --------------------------------------------------------
class LifecycleBridge {
public:
    // withEngine=false disables the engine thread (pure state-machine tests).
    explicit LifecycleBridge(bool withEngine = true);
    ~LifecycleBridge();

    LifecycleBridge(const LifecycleBridge&) = delete;
    LifecycleBridge& operator=(const LifecycleBridge&) = delete;

    // -- Application lifecycle transitions (UI thread) ----------------------
    // onAbilityCreated starts a new ability instance: bumps appGeneration()
    // and moves NONE/DESTROYED -> CREATED. Idempotent while already CREATED.
    bool onAbilityCreated();

    // The remaining transitions carry the app generation the caller observed.
    // A mismatching (stale) generation is REJECTED.
    bool onWindowLoaded(uint64_t expectedAppGen);   // CREATED -> WINDOW_LOADED
    bool onForeground(uint64_t expectedAppGen);     // WINDOW_LOADED|BACKGROUND -> FOREGROUND
    bool onBackground(uint64_t expectedAppGen);     // FOREGROUND -> BACKGROUND
    bool onDestroyed(uint64_t expectedAppGen);      // any non-terminal -> DESTROYED

    // -- Surface transitions (UI thread) -------------------------------------
    // onSurfaceCreated bumps the surface generation and attaches the native
    // window handle (opaque; OH_NativeWindow* on device, passed by the
    // XComponent glue) to the thread-safe provider. onSurfaceChanged /
    // onSurfaceDestroyed carry the generation the caller observed; stale ones
    // are IGNORED (returns false). onSurfaceDestroyed detaches the provider
    // handle so the video driver rejects the now-stale window.
    bool onSurfaceCreated(uint64_t width, uint64_t height, void* window);
    bool onSurfaceChanged(uint64_t generation, uint64_t width, uint64_t height);
    bool onSurfaceDestroyed(uint64_t generation);

    // -- Engine thread configuration ----------------------------------------
    // Sets the tick callback the engine thread runs while FOREGROUND.
    void setEngineTick(EngineTickFn fn, void* userdata) { engine_.setTick(fn, userdata); }

    // -- TSFN-style UI callback queue ---------------------------------------
    // postUiCallback may be called from any thread. Returns false once the
    // bridge is DESTROYED (zero callbacks after destroy).
    bool postUiCallback(UiCallback cb, void* userdata) { return queue_.post(cb, userdata); }
    // UI-thread consumer; returns the number of callbacks run.
    size_t drainUiCallbacks() { return queue_.drain(); }

    // -- Accessors -----------------------------------------------------------
    AppState state() const { return state_; }
    SurfaceState surfaceState() const { return surface_state_; }
    const SurfaceInfo& surface() const { return surface_; }
    uint64_t generation() const { return surface_.generation; }
    uint64_t appGeneration() const { return app_generation_; }
    bool engineRunning() const { return engine_.running(); }
    uint64_t engineTickCount() const { return engine_.tickCount(); }
    size_t pendingCallbacks() const { return queue_.pending(); }

    // -- Native window provider (video-driver handoff) -----------------------
    // Thread-safe: may be read from the engine/video thread while the UI
    // thread mutates surface state. The video driver calls this each frame.
    NativeWindowSnapshot nativeWindow() const { return window_provider_.snapshot(); }
    uint64_t nativeWindowGeneration() const { return window_provider_.generation(); }

    // -- Diagnostics ---------------------------------------------------------
    void setLogger(LogSink sink) { sink_ = sink; }

    // -- Bounded teardown (idempotent) ---------------------------------------
    // Stops and joins the engine thread (bounded by budgetMs), then closes and
    // cancels the callback queue. Returns true if the engine thread exited
    // within budget. Safe to call from the UI thread.
    bool shutdown(uint32_t budgetMs);

private:
    void log(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void setState(AppState next);
    void enterForeground();
    void enterBackground();
    void enterDestroyed(uint32_t budgetMs);

    AppState state_;
    SurfaceState surface_state_;
    SurfaceInfo surface_;
    NativeWindowProvider window_provider_;
    uint64_t app_generation_;
    uint64_t next_surface_generation_;
    bool with_engine_;
    EngineThread engine_;
    CallbackQueue queue_;
    LogSink sink_;
};

} // namespace openttd
