/* This file is part of OpenTTD. SPDX-License-Identifier: GPL-2.0-only */
#include "../stdafx.h"
#include "../debug.h"
#include "../core/utf8.hpp"
#include "../gfx_func.h"
#include "../gfx_layout.h"
#include "../strings_func.h"
#include "../textbuf_type.h"
#include "../window_func.h"
#include "../window_gui.h"
#include "harmonyos_input.h"
#include "harmonyos_textinput.h"
#include "game_textinput.h"
#include <mutex>

#include "../safeguards.h"

namespace {
std::mutex state_mutex;
HarmonyOSTextInputState published_state;
Window *editor_window = nullptr; // Accessed only by the game thread.
const NWidgetCore *editor_widget = nullptr;
uint32_t editor_session = 0;
uint32_t edit_sequence = 0;
bool has_composition = false;

size_t Utf16ToByte(std::string_view text, size_t count)
{
	Utf8View view(text);
	auto it = view.begin();
	for (size_t units = 0; it != view.end() && units < count; ++it) units += *it < 0x10000 ? 1 : 2;
	return it.GetByteOffset();
}

size_t ByteToUtf16(std::string_view text)
{
	size_t count = 0;
	for (char32_t c : Utf8View(text)) count += c < 0x10000 ? 1 : 2;
	return count;
}
} // namespace

bool HarmonyOSTextInputSessionMatches(uint32_t session)
{
	return session != 0 && session == editor_session && EditBoxInGlobalFocus() &&
		_focused_window == editor_window && _focused_window->nested_focus == editor_widget;
}

void HarmonyOSUpdateTextInputState()
{
	HarmonyOSTextInputState next;
	Window *window = EditBoxInGlobalFocus() ? _focused_window : nullptr;
	const NWidgetCore *widget = window != nullptr ? window->nested_focus : nullptr;
	if (window != editor_window || widget != editor_widget) {
		editor_window = window;
		editor_widget = widget;
		++editor_session;
		if (editor_session == 0) ++editor_session;
		edit_sequence = 0;
		has_composition = false;
		Debug(driver, 2, "harmonyos text input: session={} active={}", editor_session, window != nullptr);
	}
	next.session = editor_session;
	next.sequence = edit_sequence;
	const Textbuf *buffer = window != nullptr ? window->GetFocusedTextbuf() : nullptr;
	if (buffer != nullptr) {
		next.active = true;
		std::string_view text = buffer->GetText();
		std::copy(text.begin(), text.end(), next.text);
		next.caret = ByteToUtf16(text.substr(0, buffer->caretpos));
		next.max_chars = buffer->max_chars - 1;
		if (widget != nullptr) {
			next.left = window->left + widget->pos_x;
			next.top = window->top + widget->pos_y;
			next.width = widget->current_x;
			next.height = widget->current_y;
		} else { // Console text uses the same client, without a nested edit widget.
			Rect rect = window->GetTextBoundingRect(0, text.size());
			next.left = window->left + rect.left;
			next.top = window->top + rect.top;
			next.width = std::max(32, window->width - rect.left);
			next.height = std::max(20, rect.Height());
		}
	}
	std::lock_guard<std::mutex> lock(state_mutex);
	published_state = next;
}

void HarmonyOSApplyTextInput(const HarmonyOSInputEvent &event)
{
	if (!HarmonyOSTextInputSessionMatches(event.text_session)) return;
	/* Apply to the actual edit buffer through its virtual window interface.
	 * marked=true also notifies the widget when deletion produces an empty value. */
	auto *buffer = const_cast<Textbuf *>(editor_window->GetFocusedTextbuf());
	if (buffer == nullptr) return;
	const size_t caret = Utf16ToByte(event.text_value, event.selection_end);
	const size_t old_size = buffer->GetText().size();
	HandleTextInput(event.text_value, true, caret,
		old_size == 0 ? std::nullopt : std::optional<size_t>(0),
		old_size == 0 ? std::nullopt : std::optional<size_t>(old_size));
	std::string_view accepted = buffer->GetText();
	buffer->caretpos = Utf16ToByte(accepted, event.selection_end);
	const auto caret_rect = GetCharPosInString(accepted, buffer->caretpos, FS_NORMAL);
	buffer->caretxoffs = _current_text_dir == TD_LTR ? caret_rect.left : caret_rect.right;
	buffer->markpos = buffer->markend = buffer->markxoffs = buffer->marklength = 0;
	has_composition = event.preview_start >= 0 && event.preview_end > event.preview_start;
	if (has_composition) {
		buffer->markpos = Utf16ToByte(accepted, event.preview_start);
		buffer->markend = Utf16ToByte(accepted, event.preview_end);
		const auto start = GetCharPosInString(accepted, buffer->markpos, FS_NORMAL);
		const auto end = GetCharPosInString(accepted, buffer->markend, FS_NORMAL);
		buffer->markxoffs = std::min(start.left, end.left);
		buffer->marklength = std::max(start.right, end.right) - buffer->markxoffs;
	}
	edit_sequence = event.text_sequence;
	editor_window->SetDirty();
	Debug(driver, 2, "harmonyos text input: applied session={} sequence={} bytes={} preview={}",
		editor_session, edit_sequence, accepted.size(), has_composition);
}

void HarmonyOSCancelTextComposition()
{
	if (has_composition && EditBoxInGlobalFocus()) HandleTextInput({}, true);
	has_composition = false;
}

extern "C" __attribute__((visibility("default"))) void openttd_native_get_text_input_state(HarmonyOSTextInputState *state)
{
	if (state == nullptr) return;
	std::lock_guard<std::mutex> lock(state_mutex);
	*state = published_state;
}

extern "C" __attribute__((visibility("default"))) void openttd_native_set_text_input(
	uint32_t session, uint32_t sequence, const char *value, int start, int end, int preview_start, int preview_end)
{
	HarmonyOSInputEvent event;
	event.type = HarmonyOSInputEventType::TextInput;
	event.text_session = session;
	event.text_sequence = sequence;
	event.text_value = value != nullptr ? value : "";
	event.selection_start = std::max(0, start);
	event.selection_end = std::max(0, end);
	event.preview_start = preview_start;
	event.preview_end = preview_end;
	HarmonyOSInputQueueInstance().Push(std::move(event));
}

extern "C" __attribute__((visibility("default"))) void openttd_native_text_input_key(uint32_t session, int key, bool down)
{
	HarmonyOSInputEvent event;
	event.type = HarmonyOSInputEventType::TextKey;
	event.text_session = session;
	event.key_code = key;
	event.key_down = down;
	HarmonyOSInputQueueInstance().Push(std::move(event));
}
