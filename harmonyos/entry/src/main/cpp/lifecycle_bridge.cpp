// lifecycle_bridge.cpp — pure C++ implementation of the OpenTTD HarmonyOS
// lifecycle + thread-ownership state machine. No OHOS SDK / XComponent / NAPI
// dependency. See lifecycle_bridge.h for the design contract.

#include "lifecycle_bridge.h"

#include <cstdarg>
#include <cstdio>

namespace openttd {

// NativeWindowProvider and ReconcileWindow are defined inline in the header so
// the video driver and the host driver test consume the exact same decision
// logic (see lifecycle_bridge.h).

// -- CallbackQueue (TSFN model) ---------------------------------------------

bool CallbackQueue::post(UiCallback cb, void* userdata)
{
    std::lock_guard<std::mutex> lock(mu_);
    if (closed_) {
        return false;
    }
    queue_.emplace_back(cb, userdata);
    return true;
}

size_t CallbackQueue::drain()
{
    std::deque<std::pair<UiCallback, void*>> to_run;
    {
        std::lock_guard<std::mutex> lock(mu_);
        to_run.swap(queue_);
    }
    // Run outside the lock so a callback may safely post() more work.
    for (const auto& item : to_run) {
        item.first(item.second);
    }
    return to_run.size();
}

void CallbackQueue::cancel()
{
    std::lock_guard<std::mutex> lock(mu_);
    queue_.clear();
    closed_ = true;
}

size_t CallbackQueue::pending() const
{
    std::lock_guard<std::mutex> lock(mu_);
    return queue_.size();
}

// -- EngineThread -----------------------------------------------------------

void EngineThread::setTick(EngineTickFn fn, void* userdata)
{
    std::lock_guard<std::mutex> lock(mu_);
    tick_ = fn;
    userdata_ = userdata;
}

void EngineThread::start()
{
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (started_) {
            return; // idempotent
        }
        started_ = true;
    }
    thread_ = std::thread(&EngineThread::loop, this);
}

void EngineThread::requestPause()
{
    {
        std::lock_guard<std::mutex> lock(mu_);
        paused_ = true;
    }
    cv_.notify_all();
}

void EngineThread::requestResume()
{
    {
        std::lock_guard<std::mutex> lock(mu_);
        paused_ = false;
    }
    cv_.notify_all();
}

void EngineThread::requestStop()
{
    {
        std::lock_guard<std::mutex> lock(mu_);
        stop_ = true;
    }
    cv_.notify_all();
}

bool EngineThread::joinWithin(std::chrono::milliseconds budget)
{
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!started_) {
            return true; // nothing running
        }
    }
    // Wait (bounded) for the loop to set running_=false at exit.
    bool exited = false;
    {
        std::unique_lock<std::mutex> lock(mu_);
        exited = cv_.wait_for(lock, budget,
                              [this] { return !running_.load(std::memory_order_acquire); });
    }
    std::thread t;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!thread_.joinable()) {
            return true; // already joined / detached
        }
        t = std::move(thread_);
    }
    if (exited) {
        if (t.joinable()) {
            t.join();
        }
        return true;
    }
    // Budget exceeded: never block the UI thread any longer. Detach instead.
    if (t.joinable()) {
        t.detach();
    }
    return false;
}

void EngineThread::loop()
{
    running_.store(true, std::memory_order_release);
    while (true) {
        EngineTickFn fn = nullptr;
        void* userdata = nullptr;
        {
            std::unique_lock<std::mutex> lock(mu_);
            cv_.wait(lock, [this] { return stop_ || !paused_; });
            if (stop_) {
                break;
            }
            fn = tick_;
            userdata = userdata_;
        }
        if (fn != nullptr) {
            fn(userdata);
        }
        tick_count_.fetch_add(1, std::memory_order_relaxed);
        // Frame pacing: keep the loop healthy without a hot spin. The real
        // OpenTTD loop synchronises on its own game interval.
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    running_.store(false, std::memory_order_release);
    cv_.notify_all();
}

// -- LifecycleBridge --------------------------------------------------------

LifecycleBridge::LifecycleBridge(bool withEngine)
    : state_(AppState::NONE),
      surface_state_(SurfaceState::SURFACE_NONE),
      surface_(),
      app_generation_(0),
      next_surface_generation_(1),
      with_engine_(withEngine),
      engine_(),
      queue_(),
      sink_(nullptr)
{
}

LifecycleBridge::~LifecycleBridge()
{
    // Bounded teardown so the UI thread is never blocked by a runaway engine.
    this->shutdown(200);
}

void LifecycleBridge::log(const char* fmt, ...)
{
    if (sink_ == nullptr) {
        return;
    }
    char buf[512];
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    sink_(buf);
}

void LifecycleBridge::setState(AppState next)
{
    state_ = next;
    log("lifecycle: state -> %s", [](AppState s) -> const char* {
        switch (s) {
            case AppState::NONE: return "NONE";
            case AppState::CREATED: return "CREATED";
            case AppState::WINDOW_LOADED: return "WINDOW_LOADED";
            case AppState::FOREGROUND: return "FOREGROUND";
            case AppState::BACKGROUND: return "BACKGROUND";
            case AppState::DESTROYED: return "DESTROYED";
        }
        return "?";
    }(next));
}

bool LifecycleBridge::onAbilityCreated()
{
    // Idempotent while already CREATED; recreating a destroyed ability bumps
    // the app generation so late callers from the old instance are stale.
    if (state_ == AppState::CREATED || state_ == AppState::NONE) {
        if (state_ == AppState::NONE) {
            app_generation_ = 1;
        }
        setState(AppState::CREATED);
        log("lifecycle: ability CREATED appgen %llu",
            static_cast<unsigned long long>(app_generation_));
        return true;
    }
    if (state_ == AppState::DESTROYED) {
        app_generation_++;
        setState(AppState::CREATED);
        log("lifecycle: ability RE-CREATED appgen %llu",
            static_cast<unsigned long long>(app_generation_));
        return true;
    }
    log("lifecycle: reject onAbilityCreated in state %d", static_cast<int>(state_));
    return false;
}

bool LifecycleBridge::onWindowLoaded(uint64_t expectedAppGen)
{
    if (expectedAppGen != app_generation_) {
        log("lifecycle: REJECT stale onWindowLoaded(appgen %llu) current %llu",
            static_cast<unsigned long long>(expectedAppGen),
            static_cast<unsigned long long>(app_generation_));
        return false;
    }
    switch (state_) {
        case AppState::CREATED:
            setState(AppState::WINDOW_LOADED);
            return true;
        case AppState::WINDOW_LOADED:
            log("lifecycle: onWindowLoaded idempotent (already WINDOW_LOADED)");
            return true;
        default:
            log("lifecycle: reject onWindowLoaded in state %d", static_cast<int>(state_));
            return false;
    }
}

bool LifecycleBridge::onForeground(uint64_t expectedAppGen)
{
    if (expectedAppGen != app_generation_) {
        log("lifecycle: REJECT stale onForeground(appgen %llu) current %llu",
            static_cast<unsigned long long>(expectedAppGen),
            static_cast<unsigned long long>(app_generation_));
        return false;
    }
    switch (state_) {
        case AppState::WINDOW_LOADED:
        case AppState::BACKGROUND:
            this->enterForeground();
            return true;
        case AppState::FOREGROUND:
            log("lifecycle: onForeground idempotent (already FOREGROUND)");
            return true;
        default:
            log("lifecycle: reject onForeground in state %d", static_cast<int>(state_));
            return false;
    }
}

void LifecycleBridge::enterForeground()
{
    if (with_engine_) {
        engine_.start(); // idempotent
        engine_.requestResume();
    }
    setState(AppState::FOREGROUND);
    log("lifecycle: FOREGROUND (engine %s)",
        with_engine_ && engine_.running() ? "running" : "disabled");
}

bool LifecycleBridge::onBackground(uint64_t expectedAppGen)
{
    if (expectedAppGen != app_generation_) {
        log("lifecycle: REJECT stale onBackground(appgen %llu) current %llu",
            static_cast<unsigned long long>(expectedAppGen),
            static_cast<unsigned long long>(app_generation_));
        return false;
    }
    switch (state_) {
        case AppState::FOREGROUND:
            this->enterBackground();
            return true;
        case AppState::BACKGROUND:
            log("lifecycle: onBackground idempotent (already BACKGROUND)");
            return true;
        default:
            log("lifecycle: reject onBackground in state %d", static_cast<int>(state_));
            return false;
    }
}

void LifecycleBridge::enterBackground()
{
    // Pause the engine thread BEFORE publishing the state: rendering/audio
    // driven by the tick stops while simulation state is preserved.
    if (with_engine_) {
        engine_.requestPause();
    }
    setState(AppState::BACKGROUND);
    log("lifecycle: BACKGROUND (engine paused)");
}

bool LifecycleBridge::onDestroyed(uint64_t expectedAppGen)
{
    if (expectedAppGen != app_generation_) {
        log("lifecycle: REJECT stale onDestroyed(appgen %llu) current %llu",
            static_cast<unsigned long long>(expectedAppGen),
            static_cast<unsigned long long>(app_generation_));
        return false;
    }
    switch (state_) {
        case AppState::NONE:
        case AppState::DESTROYED:
            log("lifecycle: onDestroyed idempotent/no-op in state %d", static_cast<int>(state_));
            return true;
        default:
            this->enterDestroyed(200);
            return true;
    }
}

void LifecycleBridge::enterDestroyed(uint32_t budgetMs)
{
    if (with_engine_) {
        engine_.requestStop();
        engine_.joinWithin(std::chrono::milliseconds(budgetMs));
    }
    queue_.cancel(); // zero callbacks after destroy
    setState(AppState::DESTROYED);
    log("lifecycle: DESTROYED (engine joined, queue cancelled)");
}

bool LifecycleBridge::onSurfaceCreated(uint64_t width, uint64_t height, void* window)
{
    if (state_ == AppState::DESTROYED) {
        log("lifecycle: reject onSurfaceCreated after DESTROYED");
        return false;
    }
    surface_.generation = next_surface_generation_++;
    surface_.width = width;
    surface_.height = height;
    surface_state_ = SurfaceState::SURFACE_CREATED;
    // Hand the opaque native window handle to the thread-safe provider so the
    // video driver can adopt it and detect surface recreation via generation.
    window_provider_.set(window, width, height);
    log("lifecycle: surface CREATED gen %llu %llux%llu window=%p",
        static_cast<unsigned long long>(surface_.generation),
        static_cast<unsigned long long>(width),
        static_cast<unsigned long long>(height),
        window);
    return true;
}

bool LifecycleBridge::onSurfaceChanged(uint64_t generation, uint64_t width, uint64_t height)
{
    if (surface_state_ == SurfaceState::SURFACE_NONE) {
        log("lifecycle: reject onSurfaceChanged with no surface attached");
        return false;
    }
    if (generation != surface_.generation) {
        log("lifecycle: IGNORE stale onSurfaceChanged(gen %llu), current %llu",
            static_cast<unsigned long long>(generation),
            static_cast<unsigned long long>(surface_.generation));
        return false;
    }
    surface_.width = width;
    surface_.height = height;
    surface_state_ = SurfaceState::SURFACE_CHANGED;
    log("lifecycle: surface CHANGED gen %llu %llux%llu",
        static_cast<unsigned long long>(generation),
        static_cast<unsigned long long>(width),
        static_cast<unsigned long long>(height));
    return true;
}

bool LifecycleBridge::onSurfaceDestroyed(uint64_t generation)
{
    if (surface_state_ == SurfaceState::SURFACE_NONE) {
        log("lifecycle: reject onSurfaceDestroyed with no surface attached");
        return false;
    }
    if (generation != surface_.generation) {
        log("lifecycle: IGNORE stale onSurfaceDestroyed(gen %llu), current %llu",
            static_cast<unsigned long long>(generation),
            static_cast<unsigned long long>(surface_.generation));
        return false;
    }
    surface_state_ = SurfaceState::SURFACE_DESTROYED;
    window_provider_.clear(); // detach the native window so the video driver rejects it as stale
    log("lifecycle: surface DESTROYED gen %llu", static_cast<unsigned long long>(generation));
    return true;
}

bool LifecycleBridge::shutdown(uint32_t budgetMs)
{
    this->enterDestroyed(budgetMs);
    return !with_engine_ || !engine_.running();
}

} // namespace openttd
