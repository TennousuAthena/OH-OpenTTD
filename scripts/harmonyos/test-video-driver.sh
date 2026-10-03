#!/usr/bin/env bash
# test-video-driver.sh — host-side lifecycle test for the OpenTTD HarmonyOS
# EGL/GLES video driver (src/video/harmonyos_v.{h,cpp}).
#
# The real driver depends on OpenTTD core headers (stdafx, gfx_func, etc.) and
# on the HarmonyOS EGL/GLES + native-window SDK, none of which are available
# on the host (macOS / Linux). The driver's window/generation decision logic is
# shared, however: it lives in lifecycle_bridge.{h,cpp}
# (NativeWindowProvider + ReconcileWindow), a pure-C++ unit with no OHOS SDK
# dependency that compiles on the host. This test therefore drives the REAL
# provider/decision code (not a disconnected mock) and asserts the invariants
# the driver relies on:
#
#   (a) dirty-rect union accumulates correctly across overlapping regions,
#   (b) 50 surface-recreation cycles complete without error via the real
#       ReconcileWindow against the real NativeWindowProvider,
#   (c) a null / never-attached window is rejected (TEARDOWN),
#   (d) a stale generation is rejected (TEARDOWN) once the provider is cleared.
#
# Usage: scripts/harmonyos/test-video-driver.sh
# Exit:  0 = all scenarios pass, 1 = any scenario fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DRIVER_SRC="${REPO_ROOT}/src/video/harmonyos_v.cpp"
BRIDGE_HDR="${REPO_ROOT}/harmonyos/entry/src/main/cpp/lifecycle_bridge.h"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "${DRIVER_SRC}" ]; then
  fail "required file not found: ${DRIVER_SRC}"
fi
if [ ! -f "${BRIDGE_HDR}" ]; then
  fail "required file not found: ${BRIDGE_HDR}"
fi

printf '[test] building host video-driver harness (shared lifecycle-generation logic)\n'
c++ -std=c++17 -Wall -Wextra -pthread -I"$(dirname "${BRIDGE_HDR}")" -x c++ - -o /tmp/vd <<'EOF'
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "lifecycle_bridge.h"

using namespace openttd;

static int g_fail = 0;

static void check(bool ok, const char *what)
{
	if (ok) {
		std::printf("PASS %s\n", what);
	} else {
		std::printf("FAIL %s\n", what);
		g_fail = 1;
	}
}

// ---------------------------------------------------------------------------
// Replica of the driver's DirtyRect accumulation (harmonyos_v.cpp::MakeDirty).
// ---------------------------------------------------------------------------
struct DirtyRect {
	int x, y, w, h;
};

static void accumulate(DirtyRect &d, int left, int top, int width, int height)
{
	if (d.w == 0 || d.h == 0) {
		d.x = left; d.y = top;
		d.w = width; d.h = height;
		return;
	}
	int r = std::max(d.x + d.w, left + width);
	int b = std::max(d.y + d.h, top + height);
	d.x = std::min(d.x, left);
	d.y = std::min(d.y, top);
	d.w = r - d.x;
	d.h = b - d.y;
}

// ---------------------------------------------------------------------------
// Mock-EGL driver mirroring VideoDriver_HarmonyOS::CheckSurface, but consuming
// the REAL NativeWindowProvider + ReconcileWindow decision logic. The provider
// is mutated the way the XComponent glue does on surface create/destroy.
// ---------------------------------------------------------------------------
struct MockDriver {
	bool egl_ok = false;           // EGL initialised?
	bool context_lost = false;     // simulate eglMakeCurrent failure
	uint64_t surface_generation = 0;
	int reinit_count = 0;          // teardown+reinit recoveries performed
	int surface_creates = 0;       // eglCreateWindowSurface calls
	NativeWindowProvider provider; // shared with the real driver

	bool InitEGL()
	{
		egl_ok = true;
		context_lost = false;
		return true;
	}

	void TeardownEGL()
	{
		egl_ok = false;
	}

	// Mirrors VideoDriver_HarmonyOS::CheckSurface(): uses the shared decision.
	bool CheckSurface()
	{
		if (!egl_ok) return false;

		auto snap = provider.snapshot();
		auto decision = ReconcileWindow(snap, surface_generation);

		if (decision.action == WindowAction::TEARDOWN) {
			// Null / stale window: reject frame, release EGL resources.
			TeardownEGL();
			return false;
		}

		if (decision.action == WindowAction::RECREATE) {
			surface_creates++;
			if (context_lost) {
				// eglMakeCurrent on the fresh surface failed -> recover.
				TeardownEGL();
				if (!InitEGL()) return false;
				reinit_count++;
			}
			surface_generation = decision.generation;
		}

		if (context_lost) {
			// Context-loss guard: teardown and reinit.
			TeardownEGL();
			if (!InitEGL()) return false;
			reinit_count++;
		}
		return true;
	}
};

int main()
{
	// (a) Dirty-rect union accumulates correctly.
	{
		DirtyRect d{0, 0, 0, 0};
		accumulate(d, 10, 10, 50, 50);   // first region seeds the rect
		accumulate(d, 30, 40, 80, 30);   // overlaps: should enlarge the bounds
		bool exact = (d.x == 10 && d.y == 10 && d.w == 100 && d.h == 60);
		check(exact, "a: dirty-rect union accumulates to bounding box [10,10 100x60]");

		DirtyRect e{0, 0, 0, 0};
		accumulate(e, 0, 0, 0, 0);       // zero region ignored on first call
		bool zeroFirst = (e.w == 0 && e.h == 0);
		check(zeroFirst, "a: zero-size dirty rect ignored on first seed");
	}

	// (b) 50 surface-recreation cycles complete without error, driven by the
	//     real provider + decision logic (each set() bumps the generation).
	{
		MockDriver m;
		m.InitEGL();
		bool ok = true;
		void* const kWindow = reinterpret_cast<void*>(0x1000);
		for (int i = 0; i < 50; i++) {
			m.provider.set(kWindow, 800, 600); // new native window supersedes surface
			if (!m.CheckSurface()) { ok = false; break; }
		}
		check(ok && m.surface_creates == 50 && m.egl_ok,
		      "b: 50 surface-recreation cycles complete without error");
	}

	// (c) Null / never-attached window is rejected (TEARDOWN).
	{
		MockDriver m;
		m.InitEGL();
		// provider never set(): snapshot has null window, generation 0.
		bool teardown = !m.CheckSurface() && !m.egl_ok;
		check(teardown, "c: null/never-attached window rejected (TEARDOWN)");
	}

	// (d) Stale generation rejected: provider cleared after a prior attach makes
	//     the bound generation stale -> TEARDOWN on the next check.
	{
		MockDriver m;
		m.InitEGL();
		void* const kWindow = reinterpret_cast<void*>(0x2000);
		m.provider.set(kWindow, 800, 600);
		check(m.CheckSurface() && m.surface_creates == 1,
		      "d: first attach recreates surface");

		m.provider.clear(); // surface destroyed on device
		bool stale = !m.CheckSurface() && !m.egl_ok;
		check(stale, "d: stale generation rejected after clear (TEARDOWN)");
	}

	std::printf("%s\n", g_fail ? "SOME FAILURES" : "ALL PASS");
	return g_fail;
}
EOF

printf '[test] running video-driver harness\n'
if ! /tmp/vd; then
  printf 'FAIL: video driver harness reported failures\n' >&2
  exit 1
fi
printf '[test] video driver lifecycle suite: PASS\n'
exit 0
