// bridge_textinput.cpp — implementation of the edit-box + IME state machine.
// See bridge_textinput.h for the contract. Insertion semantics mirror
// src/textbuf.cpp Textbuf::InsertString / DiscardMarkedText / DeleteText so the
// produced buffer text matches what an OpenTTD edit box would hold for the same
// TextInput-overlay events.

#include "bridge_textinput.h"

#include <algorithm>

namespace openttd {

// -- BridgeEditBuffer -------------------------------------------------------

BridgeEditBuffer::BridgeEditBuffer(uint16_t max_bytes, uint16_t max_chars)
    : max_bytes_(max_bytes), max_chars_(max_chars), caret_(0), mark_pos_(0), mark_end_(0)
{
}

size_t BridgeEditBuffer::utf8Len(const std::string& s)
{
    size_t n = 0;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if ((c & 0x80) == 0) {
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            i += 4;
        } else {
            i += 1; // stray continuation byte; treat as 1 char
        }
        n++;
    }
    return n;
}

size_t BridgeEditBuffer::fitUtf8Prefix(const std::string& str, size_t max_bytes) const
{
    size_t bytes = 0;
    size_t chars = 0;
    size_t i = 0;
    while (i < str.size()) {
        unsigned char c = static_cast<unsigned char>(str[i]);
        size_t inc = 1;
        if ((c & 0x80) == 0) {
            inc = 1;
        } else if ((c & 0xE0) == 0xC0) {
            inc = 2;
        } else if ((c & 0xF0) == 0xE0) {
            inc = 3;
        } else if ((c & 0xF8) == 0xF0) {
            inc = 4;
        }
        if (i + inc > str.size()) break; // truncated trailing sequence
        if (bytes + inc > max_bytes) break;
        if (max_chars_ != 0 && chars + 1 > max_chars_) break;
        bytes += inc;
        chars += 1;
        i += inc;
    }
    return bytes;
}

void BridgeEditBuffer::clampCaret()
{
    if (caret_ > buffer_.size()) caret_ = buffer_.size();
    // Step caret back to a UTF-8 boundary.
    while (caret_ > 0 && caret_ < buffer_.size() &&
           (static_cast<unsigned char>(buffer_[caret_]) & 0xC0) == 0x80) {
        caret_--;
    }
}

bool BridgeEditBuffer::canDelChar(bool backspace) const
{
    if (hasMark()) return true;
    return backspace ? caret_ != 0 : caret_ < buffer_.size();
}

void BridgeEditBuffer::deleteText(size_t from, size_t to, bool update)
{
    if (from > buffer_.size()) from = buffer_.size();
    if (to > buffer_.size()) to = buffer_.size();
    if (from >= to) return;
    buffer_.erase(from, to - from);

    auto fixup = [&](size_t& pos) {
        if (pos <= from) return;
        if (pos <= to) {
            pos = from;
        } else {
            pos -= (to - from);
        }
    };
    fixup(caret_);
    fixup(mark_pos_);
    fixup(mark_end_);
    if (update) {
        mark_pos_ = 0;
        mark_end_ = 0;
    }
}

void BridgeEditBuffer::discardMarkedText(bool update)
{
    if (mark_end_ == 0) return;
    deleteText(mark_pos_, mark_end_, update);
    mark_pos_ = 0;
    mark_end_ = 0;
}

bool BridgeEditBuffer::deleteChar(bool backspace)
{
    if (hasMark()) {
        size_t from = mark_pos_;
        size_t to = mark_end_;
        mark_pos_ = 0;
        mark_end_ = 0;
        if (from >= to) return false;
        deleteText(from, to, false);
        caret_ = from;
        clampCaret();
        return true;
    }

    if (!canDelChar(backspace)) return false;
    if (backspace) {
        if (caret_ == 0) return false;
        // Walk back to the previous UTF-8 boundary.
        size_t start = caret_;
        while (start > 0 && (static_cast<unsigned char>(buffer_[start - 1]) & 0xC0) == 0x80) {
            start--;
        }
        if (start == caret_) start = caret_ - 1;
        deleteText(start, caret_, false);
        caret_ = start;
        clampCaret();
        return true;
    }
    // forward delete
    if (caret_ >= buffer_.size()) return false;
    size_t end = caret_ + 1;
    while (end < buffer_.size() && (static_cast<unsigned char>(buffer_[end]) & 0xC0) == 0x80) {
        end++;
    }
    deleteText(caret_, end, false);
    clampCaret();
    return true;
}

bool BridgeEditBuffer::insertString(const std::string& str, bool marked,
                                    std::optional<size_t> caret,
                                    std::optional<size_t> insert_location,
                                    std::optional<size_t> replacement_end)
{
    size_t insertpos = (marked && hasMark()) ? mark_pos_ : caret_;
    if (insert_location.has_value()) {
        insertpos = *insert_location;
        if (insertpos >= buffer_.size()) return false;
        if (replacement_end.has_value()) {
            deleteText(insertpos, *replacement_end, str.empty());
        }
    } else if (marked) {
        discardMarkedText(str.empty());
    }

    if (str.empty()) return false;

    size_t fit = fitUtf8Prefix(str, max_bytes_);
    if (fit == 0) return false;

    if (caret.has_value()) caret_ = insertpos + *caret;

    if (marked) {
        mark_pos_ = insertpos;
        mark_end_ = insertpos + fit;
    }

    buffer_.insert(insertpos, str, 0, fit);

    if (!marked && !caret.has_value()) caret_ += fit;
    clampCaret();
    return true;
}

void BridgeEditBuffer::setSelection(size_t start, size_t end)
{
    if (end > buffer_.size()) end = buffer_.size();
    if (start > end) start = end;
    if (end == start) {
        mark_pos_ = 0;
        mark_end_ = 0;
        caret_ = start;
    } else {
        mark_pos_ = start;
        mark_end_ = end;
        caret_ = start;
    }
}

void BridgeEditBuffer::clear()
{
    buffer_.clear();
    caret_ = 0;
    mark_pos_ = 0;
    mark_end_ = 0;
}

// -- BridgeTextInput --------------------------------------------------------

BridgeTextInput::BridgeTextInput(uint16_t max_bytes, uint16_t max_chars)
    : buf_(max_bytes, max_chars), focused_(false)
{
}

BridgeTextInput::~BridgeTextInput() = default;

void BridgeTextInput::editBoxGainedFocus()
{
    // A focus switch while another edit box was focused cancels any
    // in-progress composition so no partial marked text survives.
    if (!focused_) {
        focused_ = true;
    } else {
        imeCancel();
    }
}

void BridgeTextInput::editBoxLostFocus()
{
    if (focused_) {
        // Focus loss cancels an in-progress composition (matches IME
        // behaviour when focus moves away mid-composition).
        imeCancel();
        focused_ = false;
    }
}

void BridgeTextInput::imeComposition(const std::string& str, size_t caret)
{
    if (!focused_) return;
    buf_.insertString(str, true, caret);
}

void BridgeTextInput::imeCommit(const std::string& str)
{
    if (!focused_) return;
    if (buf_.hasMark()) {
        // Commit replaces the composed span with the final text, clearing the mark.
        buf_.insertString(str, false, std::nullopt, buf_.markPos(), buf_.markEnd());
    } else {
        buf_.insertString(str, false);
    }
}

void BridgeTextInput::imeCancel()
{
    if (!focused_) return;
    // Empty marked insert discards the composed span, restoring the text that
    // was present before composition began (Textbuf semantics).
    buf_.insertString("", true);
}

void BridgeTextInput::textCommit(const std::string& str)
{
    if (!focused_) return;
    if (buf_.hasMark()) {
        // An active selection is replaced by the committed text.
        buf_.insertString(str, false, std::nullopt, buf_.markPos(), buf_.markEnd());
    } else {
        buf_.insertString(str, false);
    }
}

void BridgeTextInput::selectRange(size_t start, size_t end)
{
    if (!focused_) return;
    buf_.setSelection(start, end);
}

void BridgeTextInput::deleteChar(bool backspace)
{
    if (!focused_) return;
    buf_.deleteChar(backspace);
}

} // namespace openttd
