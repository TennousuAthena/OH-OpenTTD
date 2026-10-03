#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INC_DIR="${SCRIPT_DIR}/../../src/video"

c++ -std=c++17 -x c++ -I"${INC_DIR}" - -o /tmp/tg <<'EOF'
#include "harmonyos_touch.h"
#include "harmonyos_touch.cpp"
#include <cstdio>
#include <cstring>
#include <vector>
#include <thread>
#include <chrono>

static int g_fail = 0;

struct Recorder : InputSink {
	std::vector<GestureType> gestures;
	std::vector<int> clicks;
	std::vector<float> drags;
	std::vector<float> scrolls;
	std::vector<float> zooms;

	void onGesture(GestureType g) override { gestures.push_back(g); }
	void onClick(int b) override { clicks.push_back(b); }
	void onDrag(float dx, float dy) override { drags.push_back(dx); drags.push_back(dy); }
	void onScroll(float dx, float dy) override { scrolls.push_back(dx); scrolls.push_back(dy); }
	void onZoom(float s) override { zooms.push_back(s); }
};

static void check(bool ok, const char *name, const char *what)
{
	if (ok) {
		std::printf("PASS %s\n", what);
	} else {
		std::printf("FAIL %s (%s)\n", what, name);
		g_fail = 1;
	}
}

static bool hasGesture(const Recorder &r, GestureType g)
{
	for (auto x : r.gestures) if (x == g) return true;
	return false;
}

static void sleepMs(int ms)
{
	std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

int main()
{
	// (a) tap: down + up quick -> TAP then click 0
	{
		Recorder r;
		TouchPoint pts[1];
		pts[0] = {1, 10.f, 10.f, true};
		dispatchTouch(pts, 1, &r);
		pts[0].active = false;
		dispatchTouch(pts, 1, &r);
		check(hasGesture(r, GestureType::TAP) && r.clicks.size() == 1 && r.clicks[0] == 0,
		      "tap", "a: tap -> TAP + click(0)");
	}

	// (b) long-press: down, sleep 600ms, up -> LONG_PRESS then click 1
	{
		Recorder r;
		TouchPoint pts[1];
		pts[0] = {2, 10.f, 10.f, true};
		dispatchTouch(pts, 1, &r);
		sleepMs(600);
		dispatchTouch(pts, 1, &r); // move frame (same pos) to allow time check
		pts[0].active = false;
		dispatchTouch(pts, 1, &r);
		check(hasGesture(r, GestureType::LONG_PRESS) && r.clicks.size() == 1 && r.clicks[0] == 1,
		      "longpress", "b: long-press -> LONG_PRESS + click(1)");
	}

	// (c) two-finger horizontal move -> SCROLL + onScroll
	{
		Recorder r;
		TouchPoint pts[2];
		pts[0] = {3, 10.f, 10.f, true};
		pts[1] = {4, 20.f, 10.f, true};
		dispatchTouch(pts, 2, &r); // begin both
		pts[0].x = 16.f; pts[1].x = 26.f;
		dispatchTouch(pts, 2, &r); // move (parallel)
		pts[0].active = false; pts[1].active = false;
		dispatchTouch(pts, 2, &r);
		check(hasGesture(r, GestureType::SCROLL) && r.scrolls.size() >= 2 && r.scrolls[0] > 0.f,
		      "scroll", "c: two-finger move -> SCROLL + onScroll(dx>0)");
	}

	// (d) pinch spread -> PINCH + onZoom>1
	{
		Recorder r;
		TouchPoint pts[2];
		pts[0] = {5, 10.f, 10.f, true};
		pts[1] = {6, 20.f, 10.f, true};
		dispatchTouch(pts, 2, &r); // begin both
		pts[0].x = 5.f;  pts[1].x = 25.f; // spread apart
		dispatchTouch(pts, 2, &r);
		pts[0].active = false; pts[1].active = false;
		dispatchTouch(pts, 2, &r);
		bool zoomOk = hasGesture(r, GestureType::PINCH) && r.zooms.size() >= 1 && r.zooms[0] > 1.f;
		check(zoomOk, "pinch", "d: pinch spread -> PINCH + onZoom>1");
	}

	// (e) mid-drag cancelAll -> no phantom events after
	{
		Recorder r;
		TouchPoint pts[1];
		pts[0] = {7, 10.f, 10.f, true};
		dispatchTouch(pts, 1, &r);
		pts[0].x = 50.f;
		dispatchTouch(pts, 1, &r); // starts drag
		int before = (int)r.gestures.size();
		cancelAllTouch();
		pts[0].x = 90.f;
		dispatchTouch(pts, 1, &r); // should be ignored (contact gone)
		check((int)r.gestures.size() == before, "cancel", "e: cancelAll -> no phantom events");
	}

	// (f) mouse present -> nothing emitted
	{
		Recorder r;
		setMousePresent(true);
		TouchPoint pts[1];
		pts[0] = {8, 10.f, 10.f, true};
		dispatchTouch(pts, 1, &r);
		pts[0].active = false;
		dispatchTouch(pts, 1, &r);
		setMousePresent(false);
		check(r.gestures.empty() && r.clicks.empty() && r.zooms.empty(),
		      "mouse", "f: mouse present -> nothing emitted");
	}

	std::printf("%s\n", g_fail ? "SOME FAILURES" : "ALL PASS");
	return g_fail;
}
EOF

/tmp/tg
