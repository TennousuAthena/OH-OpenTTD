// bridge_textinput.h — pure C++ edit-box + IME composition state machine for
// the OpenTTD HarmonyOS port.
//
// DESIGN CONTRACT
// ---------------
// This header and its implementation are DELIBERATELY free of any XComponent /
// NAPI / OHOS SDK dependency, so the full contract can be compiled and
// exercised on the host (see scripts/harmonyos/test-bridges.sh). It models the
// OpenTTD edit-box + IME surface that the ArkTS TextInput overlay drives:
//
//   * An ArkTS TextInput overlay is synchronized with the OpenTTD edit-box
//     focus (VideoDriver::EditBoxGainedFocus / EditBoxLostFocus). The overlay
//     reports composition updates, commits, cancels, plain-text commits,
//     selections and deletions; this machine turns those into the exact
//     OpenTTD HandleTextInput call sequence and, crucially, reproduces the
//     resulting edit-box buffer text.
//
//   * The insertion semantics mirror src/textbuf.cpp Textbuf::InsertString /
//     DiscardMarkedText (lines 157-215, 272-278) so the produced text matches
//     what OpenTTD's text buffer would contain for the same events.
//
//   * The machine is single-threaded (UI thread only) and never blocks: every
//     method returns immediately. Cross-thread delivery (engine -> UI) is the
//     responsibility of the TSFN-style CallbackQueue in the NAPI glue, which
//     this file does not contain.
//
// THREAD OWNERSHIP
// ----------------
// All methods MUST be called from the UI (main) thread only, matching the
// HarmonyOS guarantee for TextInput callbacks. No internal synchronization.

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace openttd {

// A UTF-8 byte-oriented edit buffer. Reproduces the essential semantics of
// OpenTTD's Textbuf for the subset of operations the TextInput overlay uses:
// marked-composition insert, commit, cancel, selection, plain insert, and
// backspace/delete. Byte positions (caret/mark) match Textbuf, which indexes
// its buffer by bytes and re-validates caret on update.
class BridgeEditBuffer {
public:
    // max_chars == 0 means "unbounded character count".
    explicit BridgeEditBuffer(uint16_t max_bytes, uint16_t max_chars = 0);

    BridgeEditBuffer(const BridgeEditBuffer&) = delete;
    BridgeEditBuffer& operator=(const BridgeEditBuffer&) = delete;

    // Returns true if a character can be deleted before (backspace) or after
    // (delete) the caret.
    bool canDelChar(bool backspace) const;

    // Deletes a character before (backspace=true) or after (backspace=false)
    // the caret, honouring the current selection if the caret is inside one.
    // Returns true on a buffer change.
    bool deleteChar(bool backspace);

    // Core insertion entry point, mirroring Textbuf::InsertString.
    //   str     — UTF-8 text to insert (may be empty for cancel/selection).
    //   marked  — true when str is an IME composition string.
    //   caret   — optional caret offset within the inserted str.
    //   insert_location — optional byte offset at which to insert.
    //   replacement_end — optional byte offset of the end of a span to replace.
    // Returns true if the buffer changed.
    bool insertString(const std::string& str, bool marked,
                      std::optional<size_t> caret = std::nullopt,
                      std::optional<size_t> insert_location = std::nullopt,
                      std::optional<size_t> replacement_end = std::nullopt);

    // Deletes the byte span [from, to) and clamps any caret/mark inside it.
    // update=true also clears any active mark (used by DiscardMarkedText).
    void deleteText(size_t from, size_t to, bool update);

    // Discards the currently marked (composition) span. update controls whether
    // the marks are also reset (always reset regardless per OpenTTD).
    void discardMarkedText(bool update);

    // Direct UTF-8 buffer text (the edit-box's current visible text).
    const std::string& text() const { return buffer_; }

    size_t caret() const { return caret_; }
    size_t markPos() const { return mark_pos_; }
    size_t markEnd() const { return mark_end_; }
    bool hasMark() const { return mark_end_ != 0; }

    // Sets an active selection [start, end) (end==start clears it), moving the
    // caret to start.
    void setSelection(size_t start, size_t end);

    void clear();

private:
    // Trims `str` to the UTF-8 prefix that fits max_bytes/max_chars and the
    // (filterless) valid-character set; returns the valid byte count.
    size_t fitUtf8Prefix(const std::string& str, size_t max_bytes) const;
    static size_t utf8Len(const std::string& s);
    // Clamps a byte position to a valid UTF-8 boundary.
    void clampCaret();

    std::string buffer_;
    uint16_t max_bytes_;
    uint16_t max_chars_;
    size_t caret_;     // byte offset
    size_t mark_pos_;  // byte offset of marked start (0 == none)
    size_t mark_end_;  // byte offset of marked end (0 == none)
};

// High-level IME bridge. Consumes TextInput-overlay events and drives the
// BridgeEditBuffer, producing the exact text an OpenTTD edit box would hold.
// The overlay-to-OpenTTD mapping is the same one a real native video driver
// uses (see src/video/sdl2_v.cpp EditBoxGainedFocus/LostFocus, src/video/
// win32_v.cpp WM_IME_COMPOSITION handling, and src/gfx_func.h HandleTextInput).
class BridgeTextInput {
public:
    explicit BridgeTextInput(uint16_t max_bytes, uint16_t max_chars = 0);
    ~BridgeTextInput();

    BridgeTextInput(const BridgeTextInput&) = delete;
    BridgeTextInput& operator=(const BridgeTextInput&) = delete;

    // -- Focus -------------------------------------------------------------
    // EditBoxGainedFocus / EditBoxLostFocus: the ArkTS overlay is shown /
    // hidden. Losing focus or switching focus while composing DISCARDS the
    // composition (no partial marked text survives a focus switch).
    void editBoxGainedFocus();
    void editBoxLostFocus();

    // -- Overlay events (all UI thread, never block) ------------------------
    // IME composition update: replaces the current marked span with `str`.
    // `caret` is the byte offset of the IME cursor within `str`.
    void imeComposition(const std::string& str, size_t caret);

    // IME commit: `str` is committed as final text (no mark).
    void imeCommit(const std::string& str);

    // IME cancel: discard the in-progress composition, restoring the text
    // that was present before composition began.
    void imeCancel();

    // Plain-text commit (ASCII or any non-composed input).
    void textCommit(const std::string& str);

    // Selection active over the byte span [start, end): future inserts /
    // deletion act on this span. start/end are byte offsets in the buffer.
    void selectRange(size_t start, size_t end);

    // Backspace (before caret) or forward-delete (after caret).
    void deleteChar(bool backspace);

    // -- Accessors ----------------------------------------------------------
    bool isFocused() const { return focused_; }
    const BridgeEditBuffer& buffer() const { return buf_; }
    const std::string& text() const { return buf_.text(); }

private:
    BridgeEditBuffer buf_;
    bool focused_;
};

} // namespace openttd
