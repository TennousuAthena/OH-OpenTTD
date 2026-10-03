#include "harmonyos_touch.h"
#include <cmath>
#include <vector>
#include <utility>

namespace {

float distance2(float x1, float y1, float x2, float y2)
{
	float dx = x1 - x2;
	float dy = y1 - y2;
	return dx * dx + dy * dy;
}

} // namespace

void GestureArbiter::beginTouch(int id, float x, float y, float density)
{
	(void)density;
	if (mousePresent_) return;
	Contact c;
	c.startX = x;
	c.startY = y;
	c.lastX = x;
	c.lastY = y;
	c.startTime = std::chrono::steady_clock::now();
	contacts_[id] = c;
	state_ = (contacts_.size() >= 2) ? State::PINCH : State::TAP_DRAG_SCROLL;
}

void GestureArbiter::moveTouch(int id, float x, float y)
{
	if (mousePresent_) return;
	auto it = contacts_.find(id);
	if (it == contacts_.end()) return;
	it->second.lastX = x;
	it->second.lastY = y;
}

void GestureArbiter::endTouch(int id)
{
	if (mousePresent_) return;
	auto it = contacts_.find(id);
	if (it == contacts_.end()) return;
	contacts_.erase(it);
	if (contacts_.empty()) {
		state_ = State::IDLE;
	} else if (contacts_.size() == 1) {
		state_ = State::TAP_DRAG_SCROLL;
	}
}

void GestureArbiter::cancelAll()
{
	contacts_.clear();
	state_ = State::IDLE;
}

static GestureArbiter g_arb;

void setMousePresent(bool present)
{
	g_arb.setMousePresent(present);
}

void cancelAllTouch()
{
	g_arb.cancelAll();
}

void dispatchTouch(TouchPoint *pts, int n, InputSink *sink)
{
	if (sink == nullptr) return;
	if (g_arb.isMousePresent()) return;

	auto &contacts = g_arb.contacts();

	// Frame-level gesture state that persists across dispatch calls.
	static bool dragEmitted = false;
	static bool longPressEmitted = false;
	static bool twoFinger = false;
	static bool pinchEmitted = false;
	static bool suppressTap = false;
	static float prevDist = 0.0f;
	static std::unordered_map<int, std::pair<float, float>> prevPos;

	// Snapshot the previous frame's positions before we mutate them.
	prevPos.clear();
	for (auto &kv : contacts) prevPos[kv.first] = {kv.second.lastX, kv.second.lastY};

	// ---- 1. Detect and process ended contacts (id present but no longer active). ----
	std::vector<int> ended;
	for (auto &kv : contacts) {
		bool active = false;
		for (int i = 0; i < n; i++) {
			if (pts[i].active && pts[i].id == kv.first) { active = true; break; }
		}
		if (!active) ended.push_back(kv.first);
	}
	for (int id : ended) {
		bool wasTapCandidate = !suppressTap && (g_arb.state() == GestureArbiter::State::TAP_DRAG_SCROLL);
		g_arb.endTouch(id);
		prevPos.erase(id);
		if (contacts.empty() && wasTapCandidate) {
			sink->onGesture(GestureType::TAP);
			sink->onClick(0);
		}
	}
	if (contacts.empty()) {
		dragEmitted = false;
		longPressEmitted = false;
		twoFinger = false;
		pinchEmitted = false;
		prevDist = 0.0f;
		suppressTap = false;
	} else if (contacts.size() == 1) {
		twoFinger = false;
		pinchEmitted = false;
		prevDist = 0.0f;
	}

	// ---- 2. Process begins and moves. ----
	for (int i = 0; i < n; i++) {
		TouchPoint &p = pts[i];
		if (!p.active) continue;
		auto it = contacts.find(p.id);
		if (it == contacts.end()) {
			size_t before = contacts.size();
			g_arb.beginTouch(p.id, p.x, p.y, 1.0f);
			prevPos[p.id] = {p.x, p.y};
			if (before == 0) {
				dragEmitted = false;
				longPressEmitted = false;
				suppressTap = false;
			} else if (before == 1) {
				suppressTap = true;
				twoFinger = true;
				pinchEmitted = false;
				prevDist = 0.0f;
			}
		} else {
			g_arb.moveTouch(p.id, p.x, p.y);
		}
	}

	// ---- 3. Single finger: long-press / drag classification. ----
	if (contacts.size() == 1 && g_arb.state() != GestureArbiter::State::PINCH) {
		int soleId = contacts.begin()->first;
		const GestureArbiter::Contact &c = contacts.begin()->second;
		auto now = std::chrono::steady_clock::now();
		auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - c.startTime);
		float moved = std::sqrt(distance2(c.lastX, c.lastY, c.startX, c.startY));

		if (longPressEmitted || dragEmitted) {
			if (dragEmitted) {
				float dx = c.lastX - prevPos[soleId].first;
				float dy = c.lastY - prevPos[soleId].second;
				sink->onDrag(dx, dy);
			}
		} else if (elapsed >= g_arb.longPress() && moved <= g_arb.tapThresholdVp()) {
			sink->onGesture(GestureType::LONG_PRESS);
			sink->onClick(1);
			longPressEmitted = true;
			suppressTap = true;
			g_arb.setState(GestureArbiter::State::LONG_PRESS);
		} else if (moved > g_arb.tapThresholdVp()) {
			sink->onGesture(GestureType::DRAG);
			float dx = c.lastX - prevPos[soleId].first;
			float dy = c.lastY - prevPos[soleId].second;
			sink->onDrag(dx, dy);
			dragEmitted = true;
			suppressTap = true;
			g_arb.setState(GestureArbiter::State::LONG_PRESS);
		}
	}

	// ---- 4. Two fingers: scroll vs pinch. ----
	if (contacts.size() == 2 && twoFinger) {
		auto it = contacts.begin();
		int id0 = it->first;
		const GestureArbiter::Contact &c0 = it->second;
		++it;
		int id1 = it->first;
		const GestureArbiter::Contact &c1 = it->second;

		float curDist = std::sqrt(distance2(c0.lastX, c0.lastY, c1.lastX, c1.lastY));
		if (prevDist > 0.0f) {
			float dChange = std::fabs(curDist - prevDist);
			if (dChange > 4.0f) {
				sink->onGesture(GestureType::PINCH);
				sink->onZoom(curDist / prevDist);
				pinchEmitted = true;
			} else {
				float avgDx = ((c0.lastX - prevPos[id0].first) + (c1.lastX - prevPos[id1].first)) * 0.5f;
				float avgDy = ((c0.lastY - prevPos[id0].second) + (c1.lastY - prevPos[id1].second)) * 0.5f;
				sink->onGesture(GestureType::SCROLL);
				sink->onScroll(avgDx, avgDy);
			}
		}
		prevDist = curDist;
	}
}
