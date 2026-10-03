/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_input.cpp Implementation of the HarmonyOS desktop input bridge. */

#include "harmonyos_input.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iterator>
#include <utility>

#ifdef HARMONYOS
#	include "../stdafx.h"
#	include "../debug.h"
#	include "../gfx_func.h"
#	include "../openttd.h"
#	include "../settings_type.h"
#	include "video_driver.hpp"
#	include "harmonyos_textinput.h"
#	include "harmonyos_performance.h"

#	include <ace/xcomponent/native_interface_xcomponent.h>
#	include <ace/xcomponent/native_xcomponent_key_event.h>
#	include <arkui/ui_input_event.h>
#endif

#include "../safeguards.h"

/**
 * The raw key/mouse/hover/axis callbacks run on the HarmonyOS UI thread and do
 * NOT manipulate OpenTTD state. They only call the HarmonyOSHandle* functions
 * below, which push an event into the process-wide queue. The OpenTTD main
 * loop drains that queue with HarmonyOSInputDrain() (single-threaded), which
 * applies each event to the OpenTTD input surface through the installed sink.
 *
 * This core mirrors the executed spec in scripts/harmonyos/test-input-matrix.sh
 * and the mapping contract docs/harmonyos/input-matrix.md, so the desktop
 * fixtures lock the real bridge (see test-desktop-input.sh).
 */

namespace {

/* WindowKeyCodes modifier bits (src/gfx_type.h). */
constexpr int INPUT_WKC_SHIFT = 0x8000;
constexpr int INPUT_WKC_CTRL  = 0x4000;
constexpr int INPUT_WKC_ALT   = 0x2000;
constexpr int INPUT_WKC_META  = 0x1000;
constexpr int INPUT_WKC_NONE  = 0;

/* Touchpad pinch -> wheel zoom notch scale ratio (input-matrix.md §6). */
constexpr float PINCH_NOTCH_RATIO = 1.15f;

/* OH_NativeXComponent_MouseEventAction values (native_interface_xcomponent.h). */
enum MouseAction {
	MOUSE_NONE    = 0,
	MOUSE_PRESS   = 1,
	MOUSE_RELEASE = 2,
	MOUSE_MOVE    = 3,
	MOUSE_CANCEL  = 4,
};

/* OH_NativeXComponent_MouseEventButton bits. */
enum MouseButtonBit {
	BTN_NONE   = 0,
	BTN_LEFT   = 0x01,
	BTN_RIGHT  = 0x02,
	BTN_MIDDLE = 0x04,
};

/* HarmonyOS keycode -> {openTTD WKC base, printable?}. Values from
 * @ohos.multimodalInput.keyCode (SDK 6.1.0.105, API 23). */
struct KeyMap { int code; int wkc; bool printable; };
const KeyMap kKeyMap[] = {
	{2070, 1,   false},  // ESCAPE         -> WKC_ESC
	{2055, 2,   false},  // DEL(Backspace) -> WKC_BACKSPACE
	{2083, 3,   false},  // INSERT         -> WKC_INSERT
	{2071, 4,   false},  // FORWARD_DEL    -> WKC_DELETE
	{2068, 5,   false},  // PAGE_UP        -> WKC_PAGEUP
	{2069, 6,   false},  // PAGE_DOWN      -> WKC_PAGEDOWN
	{2082, 7,   false},  // MOVE_END       -> WKC_END
	{2081, 8,   false},  // MOVE_HOME      -> WKC_HOME
	{2014, 9,   false},  // DPAD_LEFT      -> WKC_LEFT
	{2012, 10,  false},  // DPAD_UP        -> WKC_UP
	{2015, 11,  false},  // DPAD_RIGHT     -> WKC_RIGHT
	{2013, 12,  false},  // DPAD_DOWN      -> WKC_DOWN
	{2054, 13,  true },  // ENTER          -> WKC_RETURN
	{2049, 14,  true },  // TAB            -> WKC_TAB
	{2050, 32,  true },  // SPACE          -> WKC_SPACE
	{2056, 45,  true },  // GRAVE          -> WKC_BACKQUOTE
	{2113, 138, false},  // NUMPAD_DIVIDE  -> WKC_NUM_DIV
	{2114, 139, false},  // NUMPAD_MULTIPLY-> WKC_NUM_MUL
	{2115, 140, false},  // NUMPAD_SUBTRACT-> WKC_NUM_MINUS
	{2116, 141, false},  // NUMPAD_ADD     -> WKC_NUM_PLUS
	{2119, 142, false},  // NUMPAD_ENTER   -> WKC_NUM_ENTER
	{2117, 143, false},  // NUMPAD_DOT     -> WKC_NUM_DECIMAL
	{2064, 144, true },  // SLASH          -> WKC_SLASH
	{2062, 145, true },  // SEMICOLON      -> WKC_SEMICOLON
	{2058, 146, true },  // EQUALS         -> WKC_EQUALS
	{2059, 147, true },  // LEFT_BRACKET   -> WKC_L_BRACKET
	{2061, 148, true },  // BACKSLASH      -> WKC_BACKSLASH
	{2060, 149, true },  // RIGHT_BRACKET  -> WKC_R_BRACKET
	{2063, 150, true },  // APOSTROPHE     -> WKC_SINGLEQUOTE
	{2043, 151, true },  // COMMA          -> WKC_COMMA
	{2044, 152, true },  // PERIOD         -> WKC_PERIOD
	{2057, 153, true },  // MINUS          -> WKC_MINUS
};
bool IsShiftKey(int c) { return c == 2047 || c == 2048; }
bool IsCtrlKey(int c)  { return c == 2072 || c == 2073; }
bool IsAltKey(int c)   { return c == 2045 || c == 2046; }
bool IsMetaKey(int c)  { return c == 2076 || c == 2077; }

int FindWkc(int code)
{
	for (const auto &m : kKeyMap) {
		if (m.code == code) return m.wkc;
	}
	if (code >= 2000 && code <= 2009) return '0' + (code - 2000);   // 0..9
	if (code >= 2017 && code <= 2042) return 'A' + (code - 2017);   // A..Z
	if (code >= 2090 && code <= 2101) return 33 + (code - 2090);    // F1..F12
	if (code >= 2103 && code <= 2112) return '0' + (code - 2103);   // NUMPAD 0..9
	return 0;
}

bool IsPrintableCode(int code)
{
	for (const auto &m : kKeyMap) {
		if (m.code == code) return m.printable;
	}
	return (code >= 2000 && code <= 2009) || (code >= 2017 && code <= 2042) ||
	       (code >= 2103 && code <= 2112);
}

/* The character produced by a key, given the current modifier state. */
int KeyChar(int code, int mods)
{
	if ((mods & (INPUT_WKC_CTRL | INPUT_WKC_ALT | INPUT_WKC_META)) != 0 || !IsPrintableCode(code)) return INPUT_WKC_NONE;
	if (code >= 2000 && code <= 2009) return (mods & INPUT_WKC_SHIFT) ? ")!@#$%^&*("[code - 2000] : '0' + (code - 2000);
	if (code >= 2103 && code <= 2112) return '0' + (code - 2103);
	if (code >= 2017 && code <= 2042) {
		char base = static_cast<char>('a' + (code - 2017));
		return (mods & INPUT_WKC_SHIFT) != 0 ? static_cast<int>(base - 'a' + 'A') : static_cast<int>(base);
	}
	const bool shift = (mods & INPUT_WKC_SHIFT) != 0;
	switch (code) {
		case 2054: case 2119: return '\r';
		case 2049: return '\t';
		case 2050: return ' ';
		case 2056: return shift ? '~' : '`';
		case 2113: return '/';
		case 2114: return '*';
		case 2115: return '-';
		case 2116: return '+';
		case 2117: return '.';
		case 2064: return shift ? '?' : '/';
		case 2062: return shift ? ':' : ';';
		case 2058: return shift ? '+' : '=';
		case 2059: return shift ? '{' : '[';
		case 2061: return shift ? '|' : '\\';
		case 2060: return shift ? '}' : ']';
		case 2063: return shift ? '"' : '\'';
		case 2043: return shift ? '<' : ',';
		case 2044: return shift ? '>' : '.';
		case 2057: return shift ? '_' : '-';
	}
	return INPUT_WKC_NONE;
}

/** Held/derived input state, mutated only on the main thread during drain. */
struct InputState {
	int mods = 0;          ///< currently held modifier bits
	bool ctrl_was = false; ///< previous CTRL state (per-frame scan toggle)
	bool emulate_rclick = true; ///< Ctrl+Left -> right-click emulation
	bool mouse_left = false;
	bool mouse_right = false;
	bool mouse_middle = false;
	float cursor_x = 0.0f;
	float cursor_y = 0.0f;
	int surface_w = 0;     ///< 0 = unbounded (unknown size)
	int surface_h = 0;
	bool directions[4]{};
	bool tab = false;
};

InputState g_state;
HarmonyOSInputSink g_sink;

int ClampX(float x)
{
	return g_state.surface_w > 0 ? std::min(std::max(static_cast<int>(x), 0), g_state.surface_w - 1) : static_cast<int>(x);
}

int ClampY(float y)
{
	return g_state.surface_h > 0 ? std::min(std::max(static_cast<int>(y), 0), g_state.surface_h - 1) : static_cast<int>(y);
}

/* ---- event application (main thread) ---- */

#ifdef HARMONYOS
void ResetTouchState();
#endif

void DoReset()
{
	if (g_state.mouse_left) {
		g_state.mouse_left = false;
		if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_LEFT, false, false);
	}
	if (g_state.mouse_right) {
		g_state.mouse_right = false;
		if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_RIGHT, false, false);
	}
	g_state.mouse_middle = false;
	g_state.mods = 0;
	if (g_state.ctrl_was && g_sink.ctrl_changed) g_sink.ctrl_changed(false);
	g_state.ctrl_was = false;
	std::fill(std::begin(g_state.directions), std::end(g_state.directions), false);
	g_state.tab = false;
#ifdef HARMONYOS
	ResetTouchState();
#endif
	if (g_sink.focus) g_sink.focus(false);
}

void DoMouseMove(float x, float y)
{
	g_state.cursor_x = ClampX(x);
	g_state.cursor_y = ClampY(y);
	if (g_sink.mouse_move) g_sink.mouse_move(static_cast<int>(g_state.cursor_x), static_cast<int>(g_state.cursor_y));
}

void DoMouseButton(const HarmonyOSInputEvent &ev)
{
	const bool down = (ev.mouse_action == MOUSE_PRESS);
	const int btn = ev.mouse_button;

	if (ev.mouse_action == MOUSE_CANCEL) { // cancel -> release everything
		DoReset();
		return;
	}

	if (down) {
		if (btn == BTN_LEFT) {
			if (g_state.emulate_rclick && (g_state.mods & INPUT_WKC_CTRL)) {
				g_state.mouse_right = true;
				if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_RIGHT, true, true);
			} else {
				g_state.mouse_left = true;
				if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_LEFT, true, false);
			}
		} else if (btn == BTN_RIGHT) {
			g_state.mouse_right = true;
			if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_RIGHT, true, true);
		} else if (btn == BTN_MIDDLE) {
			g_state.mouse_middle = true;
		}
	} else {
		if (btn == BTN_LEFT) {
			if (g_state.mouse_right) { // Ctrl+Left was emulating right
				g_state.mouse_right = false;
				if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_RIGHT, false, false);
			} else if (g_state.mouse_left) {
				g_state.mouse_left = false;
				if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_LEFT, false, false);
			}
		} else if (btn == BTN_RIGHT) {
			if (g_state.mouse_right) {
				g_state.mouse_right = false;
				if (g_sink.mouse_button) g_sink.mouse_button(HARMONYOS_MOUSE_BUTTON_RIGHT, false, false);
			}
		} else if (btn == BTN_MIDDLE) {
			g_state.mouse_middle = false;
		}
	}
}

void DoWheel(float v, float h)
{
	if (g_sink.wheel) g_sink.wheel(static_cast<int>(v), static_cast<int>(h));
}

void DoKeyEvent(const HarmonyOSInputEvent &ev)
{
	const int code = ev.key_code;
	if (code == 2014) g_state.directions[0] = ev.key_down;
	if (code == 2012) g_state.directions[1] = ev.key_down;
	if (code == 2015) g_state.directions[2] = ev.key_down;
	if (code == 2013) g_state.directions[3] = ev.key_down;
	if (code == 2049) g_state.tab = ev.key_down;
	if (code == 2) { // KEYCODE_BACK -> exit, not a keycode (input-matrix.md §1)
		if (ev.key_down && g_sink.exit_request) g_sink.exit_request();
		return;
	}
	if (ev.key_down) {
		if (IsShiftKey(code)) g_state.mods |= INPUT_WKC_SHIFT;
		if (IsCtrlKey(code))  g_state.mods |= INPUT_WKC_CTRL;
		if (IsAltKey(code))   g_state.mods |= INPUT_WKC_ALT;
		if (IsMetaKey(code))  g_state.mods |= INPUT_WKC_META;
		int kc = FindWkc(code);
		if (kc != 0 && g_sink.keypress) {
			g_sink.keypress(kc | g_state.mods, KeyChar(code, g_state.mods), ev.key_repeat);
		}
	} else {
		if (IsShiftKey(code)) g_state.mods &= ~INPUT_WKC_SHIFT;
		if (IsCtrlKey(code))  g_state.mods &= ~INPUT_WKC_CTRL;
		if (IsAltKey(code))   g_state.mods &= ~INPUT_WKC_ALT;
		if (IsMetaKey(code))  g_state.mods &= ~INPUT_WKC_META;
	}
}

void DoFrameScan(bool left, bool up, bool right, bool down)
{
	const int mask = (left ? 1 : 0) | (up ? 2 : 0) | (right ? 4 : 0) | (down ? 8 : 0);
	if (g_sink.dirkeys) g_sink.dirkeys(mask);
	const bool ctrl = (g_state.mods & INPUT_WKC_CTRL) != 0;
	if (ctrl != g_state.ctrl_was) {
		g_state.ctrl_was = ctrl;
		if (g_sink.ctrl_changed) g_sink.ctrl_changed(ctrl);
	}
}

#ifdef HARMONYOS
std::vector<TouchPoint> g_touches;
float g_touch_start_x = 0, g_touch_start_y = 0;

class GameTouchSink : public InputSink {
public:
	bool dragging = false;
	void releaseDrag()
	{
		if (!dragging) return;
		Debug(driver, 2, "harmonyos input: touch drag released");
		HarmonyOSInputEvent event;
		event.mouse_action = MOUSE_RELEASE;
		event.mouse_button = BTN_LEFT;
		DoMouseButton(event);
		dragging = false;
	}
	void onGesture(GestureType type) override
	{
		if (type == GestureType::DRAG && !dragging) {
			Debug(driver, 2, "harmonyos input: touch drag started at {}, {}", g_touch_start_x, g_touch_start_y);
			DoMouseMove(g_touch_start_x, g_touch_start_y);
			HarmonyOSInputEvent event;
			event.mouse_action = MOUSE_PRESS;
			event.mouse_button = BTN_LEFT;
			DoMouseButton(event);
			dragging = true;
		} else if (type == GestureType::SCROLL || type == GestureType::PINCH) {
			releaseDrag();
		}
	}
	void onClick(int button) override
	{
		Debug(driver, 2, "harmonyos input: touch click button {}", button);
		HarmonyOSInputEvent event;
		event.mouse_button = button == 0 ? BTN_LEFT : BTN_RIGHT;
		event.mouse_action = MOUSE_PRESS;
		DoMouseButton(event);
		/* Placement tools initialise their selection on the held-button pass.
		 * A touch tap can press and release within the same input drain. */
		if (button == 0) DoMouseMove(g_state.cursor_x, g_state.cursor_y);
		event.mouse_action = MOUSE_RELEASE;
		DoMouseButton(event);
	}
	void onDrag(float, float) override
	{
		if (!g_touches.empty()) DoMouseMove(g_touches.front().x, g_touches.front().y);
	}
	void onScroll(float dx, float dy) override { DoWheel(-dy, dx); }
	void onZoom(float scale) override
	{
		if (scale > 1.0f) DoWheel(-1, 0);
		else if (scale < 1.0f) DoWheel(1, 0);
	}
};
GameTouchSink g_touch_sink;

void ResetTouchState()
{
	g_touch_sink.releaseDrag();
	g_touches.clear();
	cancelAllTouch();
}

void DoTouch(const HarmonyOSInputEvent &event)
{
	if (event.touch_cancel) {
		ResetTouchState();
		return;
	}
	if (g_touches.empty() && !event.touches.empty()) {
		g_touch_start_x = event.touches.front().x;
		g_touch_start_y = event.touches.front().y;
	}
	g_touches = event.touches;
	if (g_touches.size() == 1 && !g_touch_sink.dragging) DoMouseMove(g_touches.front().x, g_touches.front().y);
	dispatchTouch(g_touches.data(), g_touches.size(), &g_touch_sink);
	std::erase_if(g_touches, [](const TouchPoint &point) { return !point.active; });
	if (g_touches.empty()) g_touch_sink.releaseDrag();
}
#endif

} // namespace

/* ---------------------------------------------------------------------- */
/* Queue                                                                  */
/* ---------------------------------------------------------------------- */

void HarmonyOSInputQueue::Push(HarmonyOSInputEvent ev)
{
#ifdef HARMONYOS
	ev.enqueue_time_ns = HarmonyOSPerformance::Now();
#else
	ev.enqueue_time_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count();
#endif
	std::lock_guard<std::mutex> lock(mutex_);
	queue_.push_back(std::move(ev));
}

bool HarmonyOSInputQueue::Pop(HarmonyOSInputEvent &out)
{
	std::lock_guard<std::mutex> lock(mutex_);
	if (queue_.empty()) return false;
	out = std::move(queue_.front());
	queue_.pop_front();
	return true;
}

std::deque<HarmonyOSInputEvent> HarmonyOSInputQueue::TakeBatch()
{
	std::deque<HarmonyOSInputEvent> batch;
	std::lock_guard<std::mutex> lock(mutex_);
	batch.swap(queue_);
	return batch;
}

void HarmonyOSInputQueue::Clear()
{
	std::lock_guard<std::mutex> lock(mutex_);
	queue_.clear();
}

bool HarmonyOSInputQueue::Empty() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	return queue_.empty();
}

HarmonyOSInputQueue &HarmonyOSInputQueueInstance()
{
	static HarmonyOSInputQueue instance;
	return instance;
}

void HarmonyOSInputSetSink(const HarmonyOSInputSink &sink)
{
	g_sink = sink;
}

/* ---------------------------------------------------------------------- */
/* Raw callback entry points (UI thread): enqueue only.                   */
/* ---------------------------------------------------------------------- */

void HarmonyOSHandleKeyEvent(int keyCode, bool down, int repeat)
{
	HarmonyOSInputEvent ev;
	ev.type = HarmonyOSInputEventType::Key;
	ev.key_code = keyCode;
	ev.key_down = down;
	ev.key_repeat = repeat;
	HarmonyOSInputQueueInstance().Push(ev);
}

void HarmonyOSHandleMouseEvent(int action, int button, float x, float y, float vAxis, float hAxis)
{
	HarmonyOSInputEvent ev;
	if (action == HARMONYOS_MOUSE_ACTION_WHEEL) {
		ev.type = HarmonyOSInputEventType::Wheel;
		ev.v_axis = vAxis;
		ev.h_axis = hAxis;
	} else if (action == MOUSE_MOVE) {
		ev.type = HarmonyOSInputEventType::MouseMove;
		ev.x = x;
		ev.y = y;
	} else if (action == MOUSE_PRESS || action == MOUSE_RELEASE || action == MOUSE_CANCEL) {
		/* Button events carry the latest pointer position, even without a move. */
		HarmonyOSInputEvent move;
		move.type = HarmonyOSInputEventType::MouseMove;
		move.x = x;
		move.y = y;
		HarmonyOSInputQueueInstance().Push(move);
		ev.type = HarmonyOSInputEventType::MouseButton;
		ev.mouse_action = action;
		ev.mouse_button = button;
	} else { // MOUSE_NONE or unknown
		return;
	}
	HarmonyOSInputQueueInstance().Push(ev);
}

void HarmonyOSHandleHoverEvent(bool inWindow, float x, float y)
{
	HarmonyOSInputEvent ev;
	ev.type = HarmonyOSInputEventType::Hover;
	ev.in_window = inWindow;
	ev.x = x;
	ev.y = y;
	HarmonyOSInputQueueInstance().Push(ev);
}

void HarmonyOSHandleAxisEvent(float dy, float dx, float scale)
{
	HarmonyOSInputEvent ev;
	ev.type = HarmonyOSInputEventType::Wheel;
	int zoom = 0;
	/* Ordinary mouse-wheel events have no pinch scale (0). Treating that
	 * as an inward pinch discards both scroll axes and forces every event
	 * to the same direction, including empty/end events. */
	if (std::isfinite(scale) && scale > 0.0f) {
		if (scale >= PINCH_NOTCH_RATIO) {
			zoom = -1;                   // spread = zoom in
		} else if (scale <= 1.0f / PINCH_NOTCH_RATIO) {
			zoom = 1;                    // pinch = zoom out
		}
	}
	if (zoom != 0) {
		ev.v_axis = zoom;
		ev.h_axis = 0.0f;
	} else if (dy != 0.0f || dx != 0.0f) {
		ev.v_axis = -dy;
		ev.h_axis = dx;
	} else {
		return;
	}
	HarmonyOSInputQueueInstance().Push(ev);
}

void HarmonyOSResetInputState()
{
	HarmonyOSInputEvent ev;
	ev.type = HarmonyOSInputEventType::Reset;
	HarmonyOSInputQueueInstance().Push(ev);
}

/* ---------------------------------------------------------------------- */
/* Main-thread drains                                                     */
/* ---------------------------------------------------------------------- */

void HarmonyOSInputDrain()
{
#ifdef HARMONYOS
	HarmonyOSPerformance::Scope input_time(HarmonyOSPerformance::Stage::Input);
#endif
	auto batch = HarmonyOSInputQueueInstance().TakeBatch();
#ifdef HARMONYOS
	HarmonyOSPerformance::SetQueueDepth(batch.size());
#endif
	for (auto it = batch.begin(); it != batch.end(); ++it) {
		/* Only the consumer knows whether previous button/wheel events changed
		 * the game's drag or fixed-cursor state. Never merge across an event
		 * barrier, and preserve every movement while any button is held. */
		if (it->type == HarmonyOSInputEventType::MouseMove &&
				!g_state.mouse_left && !g_state.mouse_right && !g_state.mouse_middle &&
				(g_sink.cursor_fixed == nullptr || !g_sink.cursor_fixed())) {
			size_t merged = 0;
			auto next = std::next(it);
			while (next != batch.end() && next->type == HarmonyOSInputEventType::MouseMove) {
				it = next++;
				++merged;
			}
#ifdef HARMONYOS
			HarmonyOSPerformance::AddCoalescedMoves(merged);
#else
			(void)merged;
#endif
		}
		const auto &ev = *it;
#ifdef HARMONYOS
		const uint64_t now = HarmonyOSPerformance::Now();
		if (ev.enqueue_time_ns != 0 && now >= ev.enqueue_time_ns) {
			HarmonyOSPerformance::Record(HarmonyOSPerformance::Stage::InputQueue, now - ev.enqueue_time_ns);
		}
#endif
		switch (ev.type) {
			case HarmonyOSInputEventType::Key:        DoKeyEvent(ev); break;
			case HarmonyOSInputEventType::MouseMove:  DoMouseMove(ev.x, ev.y); break;
			case HarmonyOSInputEventType::MouseButton:DoMouseButton(ev); break;
			case HarmonyOSInputEventType::Wheel:      DoWheel(ev.v_axis, ev.h_axis); break;
			case HarmonyOSInputEventType::Hover:
				if (ev.in_window) {
					if (g_sink.focus) g_sink.focus(true);
				} else {
					DoReset();
				}
				break;
			case HarmonyOSInputEventType::FrameScan:  DoFrameScan(ev.dir_left, ev.dir_up, ev.dir_right, ev.dir_down); break;
			case HarmonyOSInputEventType::Reset:      DoReset(); break;
			case HarmonyOSInputEventType::Touch:
#ifdef HARMONYOS
				DoTouch(ev);
#endif
				break;
			case HarmonyOSInputEventType::TextInput:
#ifdef HARMONYOS
				HarmonyOSApplyTextInput(ev);
#endif
				break;
			case HarmonyOSInputEventType::TextKey:
#ifdef HARMONYOS
				if (HarmonyOSTextInputSessionMatches(ev.text_session)) DoKeyEvent(ev);
#endif
				break;
		}
	}
#ifdef HARMONYOS
	/* Tick stationary contacts too, so long press works without movement. */
	if (!g_touches.empty()) dispatchTouch(g_touches.data(), g_touches.size(), &g_touch_sink);
	_shift_pressed = (g_state.mods & INPUT_WKC_SHIFT) != 0;
	DoFrameScan(g_state.directions[0], g_state.directions[1], g_state.directions[2], g_state.directions[3]);
#endif
}

bool HarmonyOSInputFastForwardHeld()
{
	return g_state.tab && (g_state.mods & INPUT_WKC_ALT) == 0;
}

void HarmonyOSInputFrameScan(bool left, bool up, bool right, bool down)
{
	/* Run after any queued events that precede this frame, then scan. */
	DoFrameScan(left, up, right, down);
}

int HarmonyOSInputHeldStateMask()
{
	int mask = 0;
	if (g_state.mouse_left)   mask |= 1 << HARMONYOS_MOUSE_BUTTON_LEFT;
	if (g_state.mouse_right)  mask |= 1 << HARMONYOS_MOUSE_BUTTON_RIGHT;
	if (g_state.mouse_middle) mask |= 1 << 2;
	return mask;
}

#ifdef HARMONYOS

/* ---------------------------------------------------------------------- */
/* Device glue: default sink mapping to real OpenTTD state.               */
/* ---------------------------------------------------------------------- */

static void SinkKeypress(int keycode, char32_t character, int repeat)
{
	/* Auto-repeat is forwarded as-is; the game decides whether to act. */
	(void)repeat;
	HandleKeypress(static_cast<uint>(keycode), character);
}

static void SinkMouseMove(int x, int y)
{
	if (_cursor.UpdateCursorPosition(x, y)) {
		/* Cursor clamped/warped by the game; position is authoritative. */
	}
	HandleMouseEvents();
}

static bool SinkCursorFixed()
{
	return _cursor.fix_at;
}

static void SinkMouseButton(int button, bool down, [[maybe_unused]] bool clicked)
{
	Debug(driver, 2, "harmonyos input: button {} down={} at {}, {}", button, down, _cursor.pos.x, _cursor.pos.y);
	if (button == HARMONYOS_MOUSE_BUTTON_LEFT) {
		if (down) {
			_left_button_down = true;
		} else {
			_left_button_down = false;
			_left_button_clicked = false;
		}
	} else { // right
		if (down) {
			_right_button_down = true;
			_right_button_clicked = true;
		} else {
			_right_button_down = false;
		}
	}
	HandleMouseEvents();
}

static void SinkWheel(int v, int h)
{
	if (v > 0) {
		_cursor.wheel--;
	} else if (v < 0) {
		_cursor.wheel++;
	}
	/* 2D scrolling, mirroring the SDL MOUSEWHEEL branch (sdl2_v.cpp). */
	constexpr float SCROLL_BUILTIN_MULTIPLIER = 14.0f;
	_cursor.v_wheel -= static_cast<float>(v) * SCROLL_BUILTIN_MULTIPLIER * _settings_client.gui.scrollwheel_multiplier;
	_cursor.h_wheel += static_cast<float>(h) * SCROLL_BUILTIN_MULTIPLIER * _settings_client.gui.scrollwheel_multiplier;
	_cursor.wheel_moved = true;
	HandleMouseEvents();
}

static void SinkFocus(bool in_window)
{
	_cursor.in_window = in_window;
}

static void SinkCtrlChanged(bool ctrl)
{
	_ctrl_pressed = ctrl;
	HandleCtrlChanged();
}

static void SinkDirkeys(int mask)
{
	_dirkeys = static_cast<uint8_t>(mask);
}

static void SinkExitRequest()
{
	HandleExitGameRequest();
}

/* ---------------------------------------------------------------------- */
/* Device glue: XComponent callbacks feeding the queue.                   */
/* ---------------------------------------------------------------------- */

static void OnKeyEvent(OH_NativeXComponent *component, [[maybe_unused]] void *window)
{
	OH_NativeXComponent_KeyEvent *keyEvent = nullptr;
	if (OH_NativeXComponent_GetKeyEvent(component, &keyEvent) != 0 || keyEvent == nullptr) return;

	OH_NativeXComponent_KeyAction action;
	OH_NativeXComponent_KeyCode code;
	if (OH_NativeXComponent_GetKeyEventAction(keyEvent, &action) != 0) return;
	if (OH_NativeXComponent_GetKeyEventCode(keyEvent, &code) != 0) return;

	HarmonyOSHandleKeyEvent(static_cast<int>(code), action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN, 0);
}

static void OnMouseEvent(OH_NativeXComponent *component, void *window)
{
	OH_NativeXComponent_MouseEvent mouseEvent;
	if (OH_NativeXComponent_GetMouseEvent(component, window, &mouseEvent) != 0) return;
	HarmonyOSHandleMouseEvent(static_cast<int>(mouseEvent.action), static_cast<int>(mouseEvent.button),
	                          mouseEvent.x, mouseEvent.y, 0.0f, 0.0f);
}

static void OnHoverEvent([[maybe_unused]] OH_NativeXComponent *component, bool isHover)
{
	HarmonyOSHandleHoverEvent(isHover, 0.0f, 0.0f);
}

static void OnFocusEvent(OH_NativeXComponent*, void*) { HarmonyOSHandleHoverEvent(true, 0, 0); }
static void OnBlurEvent(OH_NativeXComponent*, void*) { HarmonyOSResetInputState(); }

extern "C" __attribute__((visibility("default"))) void openttd_native_dispatch_touch(OH_NativeXComponent *component, void *window)
{
	OH_NativeXComponent_TouchEvent touch{};
	if (OH_NativeXComponent_GetTouchEvent(component, window, &touch) != OH_NATIVEXCOMPONENT_RESULT_SUCCESS) return;
	OH_NativeXComponent_EventSourceType source = OH_NATIVEXCOMPONENT_SOURCE_TYPE_UNKNOWN;
	OH_NativeXComponent_GetTouchEventSourceType(component, touch.id, &source);
	/* PC mouse clicks also generate compatibility touch events. The native
	 * mouse callback already queues them; do not emulate a second click. */
	if (source == OH_NATIVEXCOMPONENT_SOURCE_TYPE_MOUSE) {
		Debug(driver, 2, "harmonyos input: ignoring mouse compatibility touch id={}", touch.id);
		return;
	}
	Debug(driver, touch.type == OH_NATIVEXCOMPONENT_MOVE ? 3 : 2,
		"harmonyos input: native touch type={} source={} points={} id={} point_type={} pressed={}",
		static_cast<int>(touch.type), static_cast<int>(source), touch.numPoints, touch.id,
		touch.numPoints > 0 ? static_cast<int>(touch.touchPoints[0].type) : -1,
		touch.numPoints > 0 && touch.touchPoints[0].isPressed);
	HarmonyOSInputEvent event;
	event.type = HarmonyOSInputEventType::Touch;
	event.touch_cancel = touch.type == OH_NATIVEXCOMPONENT_CANCEL;
	for (uint32_t i = 0; i < std::min(touch.numPoints, static_cast<uint32_t>(OH_NATIVE_XCOMPONENT_MAX_TOUCH_POINTS_NUMBER)); ++i) {
		const auto &point = touch.touchPoints[i];
		OH_NativeXComponent_TouchPointToolType tool = OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN;
		if (source == OH_NATIVEXCOMPONENT_SOURCE_TYPE_UNKNOWN &&
			OH_NativeXComponent_GetTouchPointToolType(component, i, &tool) == OH_NATIVEXCOMPONENT_RESULT_SUCCESS &&
			tool == OH_NATIVEXCOMPONENT_TOOL_TYPE_MOUSE) continue;
		/* API 26 MOVE events on the MateBook report isPressed=false while
		 * the finger is still down. The event type is authoritative. */
		const bool active = point.type == OH_NATIVEXCOMPONENT_DOWN || point.type == OH_NATIVEXCOMPONENT_MOVE ||
			(point.type == OH_NATIVEXCOMPONENT_UNKNOWN && point.isPressed);
		event.touches.push_back(TouchPoint{point.id, point.x, point.y, active});
	}
	if (touch.numPoints > 0 && event.touches.empty()) return;
	HarmonyOSInputQueueInstance().Push(std::move(event));
}

static void OnAxisEvent(OH_NativeXComponent *component, ArkUI_UIInputEvent *event, ArkUI_UIInputEvent_Type type)
{
	(void)component;
	if (type != ARKUI_UIINPUTEVENT_TYPE_AXIS) return;
	/* Touchpad scroll deltas + pinch scale (input-matrix.md §6). The bridge
	 * interprets them as wheel notches / zoom exactly like the reference mapper. */
	const double dy = OH_ArkUI_AxisEvent_GetVerticalAxisValue(event);
	const double dx = OH_ArkUI_AxisEvent_GetHorizontalAxisValue(event);
	const double scale = OH_ArkUI_AxisEvent_GetPinchAxisScaleValue(event);
	Debug(driver, 2, "harmonyos input: axis vertical {} horizontal {} pinch {}", dy, dx, scale);
	HarmonyOSHandleAxisEvent(static_cast<float>(dy), static_cast<float>(dx), static_cast<float>(scale));
}

void HarmonyOSInputRegisterCallbacks(OH_NativeXComponent *component)
{
	if (component == nullptr) return;

	OH_NativeXComponent_RegisterKeyEventCallback(component, OnKeyEvent);

	static OH_NativeXComponent_MouseEvent_Callback mouseCb = {};
	mouseCb.DispatchMouseEvent = OnMouseEvent;
	mouseCb.DispatchHoverEvent = OnHoverEvent;
	OH_NativeXComponent_RegisterMouseEventCallback(component, &mouseCb);

	OH_NativeXComponent_RegisterUIInputEventCallback(component, OnAxisEvent, ARKUI_UIINPUTEVENT_TYPE_AXIS);
	OH_NativeXComponent_RegisterFocusEventCallback(component, OnFocusEvent);
	OH_NativeXComponent_RegisterBlurEventCallback(component, OnBlurEvent);

	/* Install the default OpenTTD sink. */
	static std::once_flag sink_initialized;
	std::call_once(sink_initialized, [] {
	HarmonyOSInputSink sink;
	sink.keypress      = SinkKeypress;
	sink.mouse_move    = SinkMouseMove;
	sink.mouse_button  = SinkMouseButton;
	sink.wheel         = SinkWheel;
	sink.focus         = SinkFocus;
	sink.ctrl_changed  = SinkCtrlChanged;
	sink.dirkeys       = SinkDirkeys;
	sink.exit_request  = SinkExitRequest;
	sink.cursor_fixed  = SinkCursorFixed;
	HarmonyOSInputSetSink(sink);
	});
	HarmonyOSHandleHoverEvent(true, 0, 0);
}

extern "C" __attribute__((visibility("default"))) void openttd_native_register_input(OH_NativeXComponent *component)
{
	HarmonyOSInputRegisterCallbacks(component);
}

#endif /* HARMONYOS */
