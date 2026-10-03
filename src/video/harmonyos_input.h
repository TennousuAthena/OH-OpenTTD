/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_input.h HarmonyOS keyboard/mouse/trackpad input bridge (Todo 14). */

#ifndef VIDEO_HARMONYOS_INPUT_H
#define VIDEO_HARMONYOS_INPUT_H

#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>
#include <string>
#include "harmonyos_touch.h"

/**
 * HarmonyOS desktop input bridge.
 *
 * The raw HarmonyOS XComponent keyboard/mouse/hover/axis callbacks arrive on
 * the UI thread. They must NOT manipulate OpenTTD state directly (input-matrix
 * docs/harmonyos/input-matrix.md §9 invariant): each handler below only pushes
 * a @ref HarmonyOSInputEvent into a process-wide queue. The OpenTTD main loop
 * calls HarmonyOSInputDrain(), which takes a finite batch on the main thread
 * and applies events to the OpenTTD input surface through a
 * @ref HarmonyOSInputSink.
 *
 * The key→WKC_*, mouse→_cursor, wheel/axis→_cursor.v_wheel/h_wheel and
 * modifier→_ctrl_pressed/_shift_pressed mappings follow the tested matrix. The
 * sink indirection keeps this header (and the mapping core in
 * harmonyos_input.cpp) host-compilable so the data-driven test
 * (scripts/harmonyos/test-desktop-input.sh) can replay the Todo 10 fixtures and
 * compare the exact OpenTTD-call sequence byte-for-byte.
 */

/** Event kinds queued by the raw callbacks and drained on the main loop. */
enum class HarmonyOSInputEventType : uint8_t {
	Key,         ///< key down/up/repeat
	MouseMove,   ///< cursor position update
	MouseButton, ///< mouse button press/release
	Wheel,       ///< mouse wheel / touchpad axis deltas
	Hover,       ///< window enter/leave
	FrameScan,   ///< per-frame held-state scan
	Reset,       ///< blur/focus loss: release all held state
	Touch,       ///< snapshot of contacts, processed on the game thread
	TextInput,   ///< ArkUI edit/IME snapshot for the focused game edit box
	TextKey,     ///< Submit/cancel keys from the system text client
};

/** A single queued input event. */
struct HarmonyOSInputEvent {
	HarmonyOSInputEventType type = HarmonyOSInputEventType::Reset;
	uint64_t enqueue_time_ns = 0; ///< Monotonic queue-entry time; zero when target profiling is disabled.

	/* Keyboard. */
	int key_code = 0;    ///< logical HarmonyOS key code
	bool key_down = false; ///< true = down, false = up
	int key_repeat = 0;  ///< auto-repeat count (0 = first press)

	/* Mouse. */
	int mouse_action = 0; ///< OH_NativeXComponent_MouseEventAction
	int mouse_button = 0; ///< OH_NativeXComponent_MouseEventButton
	float x = 0.0f;       ///< horizontal position (relative to element)
	float y = 0.0f;       ///< vertical position (relative to element)
	float v_axis = 0.0f;  ///< vertical wheel / axis delta
	float h_axis = 0.0f;  ///< horizontal wheel / tilt delta

	/* Hover: true = window entered, false = window left. */
	bool in_window = false;

	/* Frame scan. */
	bool dir_left = false;  ///< direction key left held
	bool dir_up = false;    ///< direction key up held
	bool dir_right = false; ///< direction key right held
	bool dir_down = false;  ///< direction key down held
	std::vector<TouchPoint> touches;
	bool touch_cancel = false;
	uint32_t text_session = 0;
	uint32_t text_sequence = 0;
	std::string text_value;
	int selection_start = 0;
	int selection_end = 0;
	int preview_start = -1;
	int preview_end = -1;
};

/**
 * Sink through which the drain applies events to the OpenTTD input surface.
 *
 * The default sink (harmonyos_input.cpp, built with HARMONYOS) calls the real
 * OpenTTD entry points (HandleKeypress, HandleMouseEvents, HandleCtrlChanged,
 * HandleExitGameRequest and the _cursor/_left_button_down/... globals). The host
 * test installs a recording sink that prints the same canonical sequence the
 * Todo 10 reference mapper emits, so the fixtures lock the real bridge.
 */
struct HarmonyOSInputSink {
	void (*keypress)(int keycode, char32_t character, int repeat) = nullptr;
	void (*mouse_move)(int x, int y) = nullptr;
	void (*mouse_button)(int button, bool down, bool clicked) = nullptr;
	void (*wheel)(int v, int h) = nullptr;
	void (*focus)(bool in_window) = nullptr;
	void (*ctrl_changed)(bool ctrl) = nullptr;
	void (*dirkeys)(int mask) = nullptr;
	void (*exit_request)() = nullptr;
	bool (*cursor_fixed)() = nullptr; ///< Whether movement is relative to a fixed game cursor.
};

/** Mouse button ids passed to HarmonyOSInputSink::mouse_button. */
enum HarmonyOSMouseButton : int {
	HARMONYOS_MOUSE_BUTTON_LEFT = 0,
	HARMONYOS_MOUSE_BUTTON_RIGHT = 1,
};

/** Custom mouse action used to encode wheel events (XComponent has no wheel action). */
constexpr int HARMONYOS_MOUSE_ACTION_WHEEL = 100;

/**
 * Process-wide input queue. Single producer (UI-thread raw callbacks) and a
 * single consumer (the OpenTTD main loop draining in HarmonyOSInputDrain).
 */
class HarmonyOSInputQueue {
public:
	/** Push an event; safe to call from any thread. */
	void Push(HarmonyOSInputEvent ev);
	/** Pop the front event. @return false if empty. */
	bool Pop(HarmonyOSInputEvent &out);
	/** Take the current events in one lock; later arrivals remain for the next drain. */
	std::deque<HarmonyOSInputEvent> TakeBatch();
	/** Discard all queued events. */
	void Clear();
	/** @return true if the queue is empty. */
	bool Empty() const;

private:
	std::deque<HarmonyOSInputEvent> queue_;
	mutable std::mutex mutex_;
};

/** Access the process-wide input queue. */
HarmonyOSInputQueue &HarmonyOSInputQueueInstance();

/** Install the sink used by HarmonyOSInputDrain(). */
void HarmonyOSInputSetSink(const HarmonyOSInputSink &sink);

/* ---------------------------------------------------------------------- */
/* Raw callback entry points (UI thread). They only enqueue; they never   */
/* touch OpenTTD state.                                                   */
/* ---------------------------------------------------------------------- */

/** Handle a raw XComponent key event. */
void HarmonyOSHandleKeyEvent(int keyCode, bool down, int repeat);

/** Handle a raw XComponent mouse event (move/button/wheel). */
void HarmonyOSHandleMouseEvent(int action, int button, float x, float y, float vAxis, float hAxis);

/** Handle a raw XComponent hover (window enter/leave) event. */
void HarmonyOSHandleHoverEvent(bool inWindow, float x, float y);

/** Handle a raw XComponent touchpad axis event (scroll deltas + pinch scale). */
void HarmonyOSHandleAxisEvent(float dy, float dx, float scale);

/** Reset all held input state (blur / focus loss). */
void HarmonyOSResetInputState();

/* ---------------------------------------------------------------------- */
/* Main-thread drains (called from the OpenTTD video driver main loop).   */
/* ---------------------------------------------------------------------- */

/** Apply one queued batch, merging only consecutive free-pointer moves. */
void HarmonyOSInputDrain();

/** Per-frame held-state scan (mirrors VideoDriver_SDL_Base::InputLoop). */
void HarmonyOSInputFrameScan(bool left, bool up, bool right, bool down);

/**
 * Bitmask of still-held buttons (test/leak hook). @see HarmonyOSMouseButton
 * values; any held button reports a non-zero mask.
 */
int HarmonyOSInputHeldStateMask();

bool HarmonyOSInputFastForwardHeld();

#ifdef HARMONYOS
struct OH_NativeXComponent;
/** Register the XComponent key/mouse/hover/axis callbacks that feed the queue. */
void HarmonyOSInputRegisterCallbacks(OH_NativeXComponent *component);
#endif

#endif /* VIDEO_HARMONYOS_INPUT_H */
