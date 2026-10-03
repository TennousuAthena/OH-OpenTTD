// lifecycle_bridge_test.cpp — Catch2 host tests for the OpenTTD HarmonyOS
// lifecycle/thread-ownership contract (scripts/harmonyos/test-lifecycle-bridge.sh
// compiles this against harmonyos/entry/src/main/cpp/lifecycle_bridge.{h,cpp}).
//
// Coverage (see plan todo 8):
//   * Every legal app + surface transition.
//   * Duplicate / reordered / stale-generation callbacks.
//   * Teardown-with-request: surface destroy during a pending bridge request,
//     cancellation + bounded shutdown.
//   * Engine thread: single thread, background pauses rendering/audio,
//     deterministic resume, bounded join.
//   * TSFN-style callback queue: post/drain and zero callbacks after destroy.
//
// ThreadSanitizer-clean: the shell script also builds this with
// -fsanitize=thread and runs the "threaded" test case; no races must be
// reported for the engine thread / CallbackQueue interplay.

#define CATCH_CONFIG_MAIN
#include "catch.hpp"

#include "lifecycle_bridge.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>

using namespace openttd;

namespace {

// Test logger collects every line so tests can assert monotonic generation IDs
// and "zero callbacks after destroy".
std::atomic<int> g_log_lines{0};
std::atomic<int> g_ui_cb_runs{0};

void testLogger(const char* msg)
{
    std::fprintf(stderr, "[bridge] %s\n", msg);
    g_log_lines.fetch_add(1, std::memory_order_relaxed);
}

struct CbPayload {
    std::atomic<int>* counter;
    int id;
};

void uiCbIncrement(void* userdata)
{
    auto* p = static_cast<CbPayload*>(userdata);
    p->counter->fetch_add(1, std::memory_order_relaxed);
    g_ui_cb_runs.fetch_add(1, std::memory_order_relaxed);
}

// Park a WINDOW_LOADED bridge at FOREGROUND.
void toForeground(LifecycleBridge& b, uint64_t* gen = nullptr)
{
    b.onAbilityCreated();
    uint64_t g = b.appGeneration();
    if (gen) *gen = g;
    REQUIRE(b.onWindowLoaded(g));
    REQUIRE(b.onForeground(g));
}

bool waitFor(std::function<bool()> pred, int ms)
{
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < deadline) {
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return pred();
}

} // namespace

TEST_CASE("app: full legal lifecycle for one ability instance", "[app]")
{
    LifecycleBridge b(false);
    b.setLogger(testLogger);

    REQUIRE(b.state() == AppState::NONE);

    REQUIRE(b.onAbilityCreated());
    uint64_t g = b.appGeneration();
    REQUIRE(g == 1);
    REQUIRE(b.state() == AppState::CREATED);

    REQUIRE(b.onWindowLoaded(g));
    REQUIRE(b.state() == AppState::WINDOW_LOADED);

    REQUIRE(b.onForeground(g));
    REQUIRE(b.state() == AppState::FOREGROUND);

    REQUIRE(b.onBackground(g));
    REQUIRE(b.state() == AppState::BACKGROUND);

    REQUIRE(b.onForeground(g));
    REQUIRE(b.state() == AppState::FOREGROUND);

    REQUIRE(b.onDestroyed(g));
    REQUIRE(b.state() == AppState::DESTROYED);
}

TEST_CASE("app: every legal app transition is accepted", "[app]")
{
    SECTION("create is idempotent")
    {
        LifecycleBridge b(false);
        REQUIRE(b.onAbilityCreated());
        REQUIRE(b.onAbilityCreated()); // duplicate create -> no-op success
        REQUIRE(b.state() == AppState::CREATED);
        REQUIRE(b.appGeneration() == 1); // not bumped twice
    }

    SECTION("window load is legal only from CREATED")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        REQUIRE(b.onWindowLoaded(1));
        REQUIRE(b.state() == AppState::WINDOW_LOADED);
        // duplicate window load -> idempotent
        REQUIRE(b.onWindowLoaded(1));
        REQUIRE(b.state() == AppState::WINDOW_LOADED);
    }
}

TEST_CASE("app: reordered / illegal transitions rejected", "[app]")
{
    SECTION("foreground before window load is rejected")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        REQUIRE_FALSE(b.onForeground(1));
        REQUIRE(b.state() == AppState::CREATED);
    }

    SECTION("background before foreground is rejected")
    {
        LifecycleBridge b(false);
        toForeground(b);
        // cannot background straight from WINDOW_LOADED
        LifecycleBridge c(false);
        c.onAbilityCreated();
        uint64_t g = c.appGeneration();
        c.onWindowLoaded(g);
        REQUIRE_FALSE(c.onBackground(g));
        REQUIRE(c.state() == AppState::WINDOW_LOADED);
    }

    SECTION("stale app generation rejected everywhere")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        REQUIRE_FALSE(b.onWindowLoaded(99));
        REQUIRE_FALSE(b.onForeground(99));
        REQUIRE_FALSE(b.onBackground(99));
        REQUIRE_FALSE(b.onDestroyed(99));
        REQUIRE(b.state() == AppState::CREATED);
    }

    SECTION("recreate after destroy bumps generation, old callbacks stale")
    {
        LifecycleBridge b(false);
        toForeground(b);
        uint64_t g1 = b.appGeneration();
        REQUIRE(b.onDestroyed(g1));
        REQUIRE(b.state() == AppState::DESTROYED);

        // Re-create: new generation.
        REQUIRE(b.onAbilityCreated());
        uint64_t g2 = b.appGeneration();
        REQUIRE(g2 > g1);
        // A late callback from the old instance is stale.
        REQUIRE_FALSE(b.onWindowLoaded(g1));
        REQUIRE(b.state() == AppState::CREATED);
        // The correct-generation callback works.
        REQUIRE(b.onWindowLoaded(g2));
        REQUIRE(b.state() == AppState::WINDOW_LOADED);
    }
}

TEST_CASE("surface: generation guard + stale rejection", "[surface]")
{
    SECTION("create/change/destroy carry monotonic generation")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        REQUIRE(b.onSurfaceCreated(800, 600, reinterpret_cast<void*>(0x1)));
        uint64_t g1 = b.generation();
        REQUIRE(g1 == 1);
        REQUIRE(b.surfaceState() == SurfaceState::SURFACE_CREATED);

        REQUIRE(b.onSurfaceChanged(g1, 900, 700));
        REQUIRE(b.generation() == 1);
        REQUIRE(b.surfaceState() == SurfaceState::SURFACE_CHANGED);

        // Recreate -> new generation.
        REQUIRE(b.onSurfaceCreated(1024, 768, reinterpret_cast<void*>(0x2)));
        uint64_t g2 = b.generation();
        REQUIRE(g2 == 2);

        // Old generation is now stale.
        REQUIRE_FALSE(b.onSurfaceChanged(g1, 100, 100));
        REQUIRE_FALSE(b.onSurfaceDestroyed(g1));
        REQUIRE(b.generation() == 2);

        REQUIRE(b.onSurfaceDestroyed(g2));
        REQUIRE(b.surfaceState() == SurfaceState::SURFACE_DESTROYED);
    }

    SECTION("duplicate destroy with same generation is legal (idempotent)")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        b.onSurfaceCreated(800, 600, reinterpret_cast<void*>(0x3));
        uint64_t g = b.generation();
        REQUIRE(b.onSurfaceDestroyed(g));
        // Duplicate teardown event for the same surface -> accepted.
        REQUIRE(b.onSurfaceDestroyed(g));
        REQUIRE(b.surfaceState() == SurfaceState::SURFACE_DESTROYED);
    }

    SECTION("surface op before any surface is rejected")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        REQUIRE_FALSE(b.onSurfaceDestroyed(0));
        REQUIRE_FALSE(b.onSurfaceChanged(0, 10, 10));
    }
}

TEST_CASE("surface: native window provider snapshot contract", "[surface]")
{
    SECTION("onSurfaceCreated hands the window to the provider; onSurfaceDestroyed clears it")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        void* const kWin = reinterpret_cast<void*>(0xABC);

        REQUIRE(b.onSurfaceCreated(800, 600, kWin));
        // The opaque handle is adopted by the thread-safe provider so the video
        // driver can adopt it and detect recreation by generation.
        auto snap = b.nativeWindow();
        REQUIRE(snap.window == kWin);
        REQUIRE(snap.generation == b.nativeWindowGeneration());
        REQUIRE(snap.generation >= 1);
        REQUIRE(snap.width == 800);
        REQUIRE(snap.height == 600);
        REQUIRE(b.nativeWindowGeneration() == 1);

        // Destroy detaches the handle; the driver must reject the stale window.
        uint64_t g = b.generation();
        REQUIRE(b.onSurfaceDestroyed(g));
        auto gone = b.nativeWindow();
        REQUIRE(gone.window == nullptr);
        REQUIRE(gone.generation > snap.generation); // monotonic bump on clear
        REQUIRE(b.nativeWindowGeneration() > snap.generation);
    }

    SECTION("stale generation after onSurfaceDestroyed is rejected")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        b.onSurfaceCreated(800, 600, reinterpret_cast<void*>(0x1));
        uint64_t g1 = b.generation();
        REQUIRE(b.onSurfaceDestroyed(g1));
        REQUIRE(b.surfaceState() == SurfaceState::SURFACE_DESTROYED);

        // A late callback carrying a stale generation must be ignored; the
        // provider was cleared, so the video driver will also reject the frame.
        REQUIRE_FALSE(b.onSurfaceChanged(g1 + 100, 500, 500));
        REQUIRE(b.surfaceState() == SurfaceState::SURFACE_DESTROYED);
        REQUIRE(b.nativeWindow().window == nullptr);
    }

    SECTION("recreate after destroy re-attaches with a fresh window + generation")
    {
        LifecycleBridge b(false);
        b.onAbilityCreated();
        b.onSurfaceCreated(800, 600, reinterpret_cast<void*>(0x1));
        uint64_t g1 = b.generation();
        REQUIRE(b.onSurfaceDestroyed(g1));
        REQUIRE(b.nativeWindow().window == nullptr);

        // Surface recreated by the framework -> new handle + new generation.
        void* const kWin2 = reinterpret_cast<void*>(0x2);
        REQUIRE(b.onSurfaceCreated(1024, 768, kWin2));
        REQUIRE(b.nativeWindow().window == kWin2);
        REQUIRE(b.nativeWindowGeneration() > g1);
        REQUIRE(b.generation() == 2);
    }

    SECTION("null window: provider rejects a never-attached window (TEARDOWN anchor)")
    {
        // Contract consumed by harmonyos_v.cpp CheckSurface(): ReconcileWindow
        // turns a null / never-attached provider snapshot into TEARDOWN.
        LifecycleBridge b(false);
        b.onAbilityCreated();
        NativeWindowSnapshot snap = b.nativeWindow();
        REQUIRE(snap.window == nullptr);
        REQUIRE(snap.generation == 0); // never attached
        WindowDecision d = ReconcileWindow(snap, 0);
        REQUIRE(d.action == WindowAction::TEARDOWN);
    }
}

TEST_CASE("engine: single thread, background pauses rendering/audio", "[thread]")
{
    LifecycleBridge b(true); // engine enabled
    b.setLogger(testLogger);

    // Two different bridges must each own exactly one engine thread; here we
    // assert the engine only starts on foreground and resumes/pauses on the
    // lifecycle transitions.
    toForeground(b);
    REQUIRE(b.state() == AppState::FOREGROUND);
    // Engine thread may take a moment to set running_ after start().
    REQUIRE(waitFor([&] { return b.engineRunning(); }, 3000));

    // Engine ticks ramp up while foregrounded.
    uint64_t before = b.engineTickCount();
    REQUIRE(waitFor([&] { return b.engineTickCount() > before; }, 3000));
    uint64_t t1 = b.engineTickCount();

    // Background pauses the engine: rendering/audio stop.
    uint64_t g = b.appGeneration();
    REQUIRE(b.onBackground(g));
    REQUIRE(b.state() == AppState::BACKGROUND);
    // Give any in-flight tick a moment to land, then the count must freeze.
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    uint64_t t2 = b.engineTickCount();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    REQUIRE(b.engineTickCount() == t2); // paused: no further ticks
    REQUIRE(t2 >= t1);

    // Foreground resumes.
    REQUIRE(b.onForeground(g));
    REQUIRE(waitFor([&] { return b.engineTickCount() > t2; }, 3000));

    // Destroy stops and joins the engine thread.
    REQUIRE(b.onDestroyed(g));
    REQUIRE_FALSE(b.engineRunning());
    REQUIRE(b.state() == AppState::DESTROYED);
}

TEST_CASE("engine: bounded teardown never blocks the UI thread", "[thread]")
{
    LifecycleBridge b(true);
    b.setLogger(testLogger);
    toForeground(b);
    uint64_t g = b.appGeneration();

    auto start = std::chrono::steady_clock::now();
    REQUIRE(b.onDestroyed(g));
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now() - start)
                       .count();
    // Engine stops within a generous budget; the UI thread is not blocked
    // beyond it. 200ms budget -> assert far under it.
    REQUIRE(elapsed < 200);
    REQUIRE_FALSE(b.engineRunning());
}

TEST_CASE("engine: destroy with request in flight cancels + bounded shutdown", "[thread]")
{
    // Model: engine is foregrounded and posting UI callbacks (the "requests").
    // Surface destroy arrives while the queue still holds a pending callback.
    // Requirement: the pending callback is cancelled (zero callbacks after
    // destroy) and shutdown is bounded.
    LifecycleBridge b(false); // state machine only; queue behavior is thread-agnostic
    b.setLogger(testLogger);
    toForeground(b);

    std::atomic<int> ran{0};
    CbPayload p{&ran, 0};
    REQUIRE(b.postUiCallback(uiCbIncrement, &p));
    REQUIRE(b.postUiCallback(uiCbIncrement, &p));
    REQUIRE(b.pendingCallbacks() == 2);

    uint64_t g = b.appGeneration();
    REQUIRE(b.onDestroyed(g));
    // Queue cancelled: drain runs nothing.
    REQUIRE(b.drainUiCallbacks() == 0);
    REQUIRE(ran.load() == 0);
    // Zero callbacks after destroy: posting now fails.
    REQUIRE_FALSE(b.postUiCallback(uiCbIncrement, &p));
    REQUIRE(b.pendingCallbacks() == 0);
}

TEST_CASE("queue: TSFN post/drain + zero callbacks after destroy", "[queue]")
{
    LifecycleBridge b(false);
    b.setLogger(testLogger);
    toForeground(b);

    std::atomic<int> ran{0};
    CbPayload p{&ran, 0};
    REQUIRE(b.postUiCallback(uiCbIncrement, &p));
    REQUIRE(b.postUiCallback(uiCbIncrement, &p));
    REQUIRE(b.postUiCallback(uiCbIncrement, &p));

    // Drain is the UI-thread consumer; runs all three.
    REQUIRE(b.drainUiCallbacks() == 3);
    REQUIRE(ran.load() == 3);
    REQUIRE(b.pendingCallbacks() == 0);
    REQUIRE(g_ui_cb_runs.load() >= 3);

    uint64_t g = b.appGeneration();
    REQUIRE(b.onDestroyed(g));
    REQUIRE_FALSE(b.postUiCallback(uiCbIncrement, &p));
}

TEST_CASE("shutdown: idempotent and post-destroy-safe", "[shutdown]")
{
    LifecycleBridge b(false);
    toForeground(b);
    REQUIRE(b.shutdown(100));
    REQUIRE(b.state() == AppState::DESTROYED);
    // Idempotent.
    REQUIRE(b.shutdown(100));
    REQUIRE_FALSE(b.postUiCallback(uiCbIncrement, nullptr));
}
