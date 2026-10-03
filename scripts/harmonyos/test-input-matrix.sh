#!/usr/bin/env bash
# test-input-matrix.sh — data-driven lock for the HarmonyOS → OpenTTD
# input/IME compatibility matrix.
#
# The mapping contract is documented in docs/harmonyos/input-matrix.md. This
# test compiles a HOST-SIDE reference mapper (pure C++, no XComponent/NAPI
# dependency) that implements that contract, then replays canonical raw-input
# traces from scripts/harmonyos/test-fixtures/input/*-in and compares the
# mapper output byte-for-byte against the *-expected golden files.
#
# The reference mapper is the executable spec: the real native bridge
# (harmonyos/entry/src/main/cpp/, Todo 13-18) must produce the exact same
# OpenTTD-call sequence for these traces.
#
# Usage: scripts/harmonyos/test-input-matrix.sh
# Exit:  0 = all fixtures pass, 1 = any fixture fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/test-fixtures/input"

CXX="${CXX:-c++}"
WORKDIR="${TMPDIR:-/tmp}/openttd-ohos-input-matrix-test"
BIN="${WORKDIR}/input-matrix-ref"
DRIVER="${WORKDIR}/driver.cpp"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [ ! -d "${FIXTURE_DIR}" ]; then
  fail "fixture directory not found: ${FIXTURE_DIR}"
fi

mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# Reference mapper (embedded driver). Implements docs/harmonyos/input-matrix.md.
# Reads trace lines on stdin, prints the canonical OpenTTD-call sequence.
#
# Trace line grammar (input):
#   key <code> <down|up> <repeat>      raw Harmony keycode event
#   text <string>                      printable text commit (keyText path)
#   ime <comp|commit|cancel|select> <str> <caret> <repl>   IME lifecycle
#   mouse <x> <y>                      physical mouse move
#   enter | leave                      physical mouse window enter/leave
#   mbtn <left|right|middle> <down|up> physical mouse button
#   wheel <vy> <vx>                    physical mouse wheel (precise deltas)
#   touch <id> <down|move|up|cancel> <x> <y> <finger|pen>
#   tick <ms>                          advance virtual clock (long-press timing)
#   frame <left> <up> <right> <down>   per-frame InputLoop held-state scan
#   axis <dy> <dx> <scale>             touchpad axis (scroll deltas + pinch)
#   resize <w> <h>                     surface resize: clamp pointer into bounds
#   emulate <on|off>                   right-click emulation (ctrl+left=right)
#   leakcheck                          assert no held button remains
#   # comment
#
# Output line grammar:
#   keypress kc=<hex> char=<hex> rep=<n>
#   textinput "<str>" marked=<0|1> caret=<n|-> insert=<n|-> repl=<n|->
#   mouse x=<n> y=<n>
#   focus <0|1>
#   btndown <left|right>
#   btnup <left|right>
#   rightclick
#   wheel v=<n> h=<n>
#   ctrl <0|1>
#   dirkeys <mask>
#   exit
# ---------------------------------------------------------------------------
cat > "${DRIVER}" <<'CPPEOF'
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

constexpr int WKC_SHIFT = 0x8000;
constexpr int WKC_CTRL  = 0x4000;
constexpr int WKC_ALT   = 0x2000;
constexpr int WKC_META  = 0x1000;
constexpr int WKC_NONE  = 0;

constexpr int LONG_PRESS_MS = 500;
constexpr int SLOP_VP = 8;
constexpr int SCROLL_NOTCH_VP = 8;      // vp per two-finger scroll wheel tick
constexpr double PINCH_NOTCH_RATIO = 1.15; // distance ratio per zoom wheel tick

// HarmonyOS keycode -> {WKC base, printable?}. Values from
// @ohos.multimodalInput.keyCode (SDK 6.1.0.105, API 23).
struct KeyMap { int code; int wkc; bool printable; };
const KeyMap kKeyMap[] = {
    {2070, 1,  false},  // ESCAPE         -> WKC_ESC
    {2055, 2,  false},  // DEL(Backspace) -> WKC_BACKSPACE
    {2083, 3,  false},  // INSERT         -> WKC_INSERT
    {2071, 4,  false},  // FORWARD_DEL    -> WKC_DELETE
    {2068, 5,  false},  // PAGE_UP        -> WKC_PAGEUP
    {2069, 6,  false},  // PAGE_DOWN      -> WKC_PAGEDOWN
    {2082, 7,  false},  // MOVE_END       -> WKC_END
    {2081, 8,  false},  // MOVE_HOME      -> WKC_HOME
    {2014, 9,  false},  // DPAD_LEFT      -> WKC_LEFT
    {2012, 10, false},  // DPAD_UP        -> WKC_UP
    {2015, 11, false},  // DPAD_RIGHT     -> WKC_RIGHT
    {2013, 12, false},  // DPAD_DOWN      -> WKC_DOWN
    {2054, 13, true },  // ENTER          -> WKC_RETURN
    {2049, 14, true },  // TAB            -> WKC_TAB
    {2050, 32, true },  // SPACE          -> WKC_SPACE
    {2056, 45, false},  // GRAVE          -> WKC_BACKQUOTE
    {2113, 138, false}, // NUMPAD_DIVIDE  -> WKC_NUM_DIV
    {2114, 139, false}, // NUMPAD_MULTIPLY-> WKC_NUM_MUL
    {2115, 140, false}, // NUMPAD_SUBTRACT-> WKC_NUM_MINUS
    {2116, 141, false}, // NUMPAD_ADD     -> WKC_NUM_PLUS
    {2119, 142, false}, // NUMPAD_ENTER   -> WKC_NUM_ENTER
    {2117, 143, false}, // NUMPAD_DOT     -> WKC_NUM_DECIMAL
    {2064, 144, true }, // SLASH          -> WKC_SLASH
    {2062, 145, true }, // SEMICOLON      -> WKC_SEMICOLON
    {2058, 146, true }, // EQUALS         -> WKC_EQUALS
    {2059, 147, true }, // LEFT_BRACKET   -> WKC_L_BRACKET
    {2061, 148, true }, // BACKSLASH      -> WKC_BACKSLASH
    {2060, 149, true }, // RIGHT_BRACKET  -> WKC_R_BRACKET
    {2063, 150, true }, // APOSTROPHE     -> WKC_SINGLEQUOTE
    {2043, 151, true }, // COMMA          -> WKC_COMMA
    {2044, 152, true }, // PERIOD         -> WKC_PERIOD
    {2057, 153, true }, // MINUS          -> WKC_MINUS
    {2,    -1,  false}, // BACK           -> system exit, not a keycode
};
constexpr int kKeyMapLen = static_cast<int>(sizeof(kKeyMap) / sizeof(kKeyMap[0]));

bool isShiftKey(int c)   { return c == 2047 || c == 2048; }
bool isCtrlKey(int c)    { return c == 2072 || c == 2073; }
bool isAltKey(int c)     { return c == 2045 || c == 2046; }
bool isMetaKey(int c)    { return c == 2076 || c == 2077; }

int findWkc(int code)
{
    for (int i = 0; i < kKeyMapLen; ++i) {
        if (kKeyMap[i].code == code) return kKeyMap[i].wkc;
    }
    if (code >= 2000 && code <= 2009) return '0' + (code - 2000);   // 0..9
    if (code >= 2017 && code <= 2042) return 'A' + (code - 2017);   // A..Z
    if (code >= 2090 && code <= 2101) return 33 + (code - 2090);    // F1..F12
    if (code >= 2103 && code <= 2112) return '0' + (code - 2103);   // NUMPAD 0..9
    return 0;
}

bool isPrintableCode(int code)
{
    for (int i = 0; i < kKeyMapLen; ++i) {
        if (kKeyMap[i].code == code) return kKeyMap[i].printable;
    }
    return (code >= 2000 && code <= 2009) || (code >= 2017 && code <= 2042) ||
           (code >= 2103 && code <= 2112);
}

// The character produced by a key, given current modifier state.
int keyChar(int code, int mods)
{
    if ((mods & (WKC_CTRL | WKC_ALT | WKC_META)) != 0 || !isPrintableCode(code)) return WKC_NONE;
    if (code >= 2000 && code <= 2009) return '0' + (code - 2000);
    if (code >= 2103 && code <= 2112) return '0' + (code - 2103);
    if (code >= 2017 && code <= 2042) {
        char base = static_cast<char>('a' + (code - 2017));
        return (mods & WKC_SHIFT) != 0 ? static_cast<int>(base - 'a' + 'A') : static_cast<int>(base);
    }
    for (int i = 0; i < kKeyMapLen; ++i) {
        if (kKeyMap[i].code == code && kKeyMap[i].printable) return kKeyMap[i].wkc;
    }
    return WKC_NONE;
}

struct Contact {
    double x = 0, y = 0;
    double sx = 0, sy = 0;      // start position
    long   start_ms = 0;
    bool   moved = false;       // exceeded slop
    bool   longpress = false;   // right-click already synthesised
    bool   pen = false;         // stylus contact (pointer semantics)
    bool   suppress_up = false; // finger consumed by a two-finger gesture
};

struct Mapper {
    int  mods = 0;              // currently held modifier bits
    bool ctrl_was = false;
    int  dirkeys = 0;
    long clock_ms = 0;

    bool emulate_rclick = true; // ctrl+left => right click
    bool suppress_gestures = false;
    bool phys_mouse = false;    // a physical mouse produced an event

    bool mouse_left = false;    // physical mouse held buttons
    bool mouse_right = false;
    bool mouse_middle = false;

    bool touch_left = false;    // synthetic (gesture) held buttons
    bool touch_right = false;

    std::map<int, Contact> contacts;

    bool two_finger = false;
    double last_centroid_x = 0, last_centroid_y = 0;
    double last_dist = 0;
    double scroll_acc_v = 0, scroll_acc_h = 0;
    double pinch_acc = 0;

    int surface_w = 0, surface_h = 0;   // 0 = unbounded (unknown size)
    int cursor_x = 0, cursor_y = 0;

    // Clamp a pointer position into the current surface bounds.
    double clamp_x(double x) const { return surface_w > 0 ? std::min(std::max(x, 0.0), static_cast<double>(surface_w - 1)) : x; }
    double clamp_y(double y) const { return surface_h > 0 ? std::min(std::max(y, 0.0), static_cast<double>(surface_h - 1)) : y; }
    void update_cursor(double x, double y)
    {
        cursor_x = static_cast<int>(clamp_x(x));
        cursor_y = static_cast<int>(clamp_y(y));
        emit_mouse(cursor_x, cursor_y);
    }

    void emit_keypress(int kc, int ch, int rep)
    {
        std::printf("keypress kc=%04x char=%04x rep=%d\n", kc, ch, rep);
    }
    void emit_textinput(const std::string &s, bool marked, int caret, int insert, int repl)
    {
        std::string esc;
        for (char ch : s) {
            if (ch == '"' || ch == '\\') { esc += '\\'; }
            esc += ch;
        }
        std::printf("textinput \"%s\" marked=%d caret=%d insert=%d repl=%d\n",
                    esc.c_str(), marked ? 1 : 0, caret, insert, repl);
    }
    void emit_mouse(int x, int y) { std::printf("mouse x=%d y=%d\n", x, y); }
    void emit_focus(int f)        { std::printf("focus %d\n", f); }
    void emit_btn_down(const char *b) { std::printf("btndown %s\n", b); }
    void emit_btn_up(const char *b)   { std::printf("btnup %s\n", b); }
    void emit_rightclick()            { std::printf("rightclick\n"); }
    void emit_wheel(int v, int h)     { std::printf("wheel v=%d h=%d\n", v, h); }
    void emit_ctrl(int c)             { std::printf("ctrl %d\n", c); }
    void emit_dirkeys(int m)          { std::printf("dirkeys %d\n", m); }
    void emit_exit()                  { std::printf("exit\n"); }

    void note_physical_mouse() { phys_mouse = true; suppress_gestures = true; }

    // ---- physical mouse path --------------------------------------------
    void mouse_down(const char *btn)
    {
        if (std::strcmp(btn, "left") == 0) {
            if (emulate_rclick && (mods & WKC_CTRL) != 0) {
                mouse_right = true;
                emit_btn_down("right");
                emit_rightclick();
            } else {
                mouse_left = true;
                emit_btn_down("left");
            }
        } else if (std::strcmp(btn, "right") == 0) {
            mouse_right = true;
            emit_btn_down("right");
            emit_rightclick();
        } else if (std::strcmp(btn, "middle") == 0) {
            mouse_middle = true;
        }
    }
    void mouse_up(const char *btn)
    {
        if (std::strcmp(btn, "left") == 0) {
            if (mouse_right) {  // ctrl+left was emulating right
                mouse_right = false;
                emit_btn_up("right");
            } else if (mouse_left) {
                mouse_left = false;
                emit_btn_up("left");
            }
        } else if (std::strcmp(btn, "right") == 0) {
            if (mouse_right) {
                mouse_right = false;
                emit_btn_up("right");
            }
        } else if (std::strcmp(btn, "middle") == 0) {
            mouse_middle = false;
        }
    }

    // ---- keyboard path ---------------------------------------------------
    void key_event(int code, bool down, int rep)
    {
        if (code == 2) {  // KEYCODE_BACK exits rather than producing a keycode
            if (down) emit_exit();
            return;
        }
        if (down) {
            if (isShiftKey(code)) mods |= WKC_SHIFT;
            if (isCtrlKey(code))  mods |= WKC_CTRL;
            if (isAltKey(code))   mods |= WKC_ALT;
            if (isMetaKey(code))  mods |= WKC_META;
            int kc = findWkc(code);
            if (kc != 0) {
                emit_keypress(kc | mods, keyChar(code, mods), rep);
            }
        } else {
            if (isShiftKey(code)) mods &= ~WKC_SHIFT;
            if (isCtrlKey(code))  mods &= ~WKC_CTRL;
            if (isAltKey(code))   mods &= ~WKC_ALT;
            if (isMetaKey(code))  mods &= ~WKC_META;
        }
    }

    // ---- per-frame scan --------------------------------------------------
    void frame_scan(bool left, bool up, bool right, bool down)
    {
        dirkeys = (left ? 1 : 0) | (up ? 2 : 0) | (right ? 4 : 0) | (down ? 8 : 0);
        emit_dirkeys(dirkeys);
        bool ctrl = (mods & WKC_CTRL) != 0;
        if (ctrl != ctrl_was) {
            ctrl_was = ctrl;
            emit_ctrl(ctrl ? 1 : 0);
        }
    }

    // ---- gesture recognizer ----------------------------------------------
    void touch_event(int id, const std::string &action, double x, double y, bool pen)
    {
        if (action == "down") {
            if (suppress_gestures) return;
            if (contacts.count(id) != 0) return;
            if (pen) {
                // Stylus = pointer: contact presses left immediately.
                contacts[id] = {clamp_x(x), clamp_y(y), clamp_x(x), clamp_y(y), clock_ms, true, false, true, false};
                update_cursor(clamp_x(x), clamp_y(y));
                touch_left = true;
                emit_btn_down("left");
                return;
            }
            // A second finger cancels an in-progress left drag and switches to
            // two-finger scroll; a long-press right click is kept until cancel.
            if (!contacts.empty() && !two_finger) {
                if (touch_left) {
                    touch_left = false;
                    emit_btn_up("left");
                }
                two_finger = true;
                for (auto &kv : contacts) kv.second.suppress_up = true;
            }
            contacts[id] = {clamp_x(x), clamp_y(y), clamp_x(x), clamp_y(y), clock_ms, false, false, false,
                            two_finger /*suppress_up*/};
            if (two_finger) recompute_two_finger(false);
            return;
        }
        if (action == "move") {
            if (contacts.count(id) == 0) return;
            Contact &c = contacts[id];
            c.x = clamp_x(x); c.y = clamp_y(y);
            if (!two_finger) {
                if (c.suppress_up) return;
                double dx = c.x - c.sx, dy = c.y - c.sy;
                if (!c.moved && std::sqrt(dx * dx + dy * dy) > SLOP_VP) {
                    c.moved = true;
                    if (!c.longpress) {
                        touch_left = true;
                        emit_btn_down("left");      // drag starts
                    }
                }
                if (c.moved) update_cursor(c.x, c.y);
            } else {
                recompute_two_finger(true);
            }
            return;
        }
        if (action == "up") {
            if (contacts.count(id) == 0) return;
            Contact c = contacts[id];
            contacts.erase(id);
            if (two_finger) {
                if (contacts.empty()) {
                    two_finger = false;
                    scroll_acc_v = 0; scroll_acc_h = 0; pinch_acc = 0;
                }
                return;
            }
            if (c.suppress_up) return;
            if (c.longpress) {
                if (touch_right) {
                    touch_right = false;
                    emit_btn_up("right");
                }
            } else if (c.moved) {
                if (touch_left) {
                    touch_left = false;
                    emit_btn_up("left");
                }
            } else {
                // tap: left click at release point
                update_cursor(c.x, c.y);
                emit_btn_down("left");
                emit_btn_up("left");
            }
            return;
        }
        if (action == "cancel") {
            // Cancel resets ALL held button/modifier state and every contact
            // and accumulator (negative test: cancel-mid-drag).
            if (touch_left) { touch_left = false; emit_btn_up("left"); }
            if (touch_right) { touch_right = false; emit_btn_up("right"); }
            contacts.clear();
            two_finger = false;
            scroll_acc_v = 0; scroll_acc_h = 0; pinch_acc = 0;
            return;
        }
    }

    void recompute_two_finger(bool emit)
    {
        if (contacts.size() < 2) return;
        double cx = 0, cy = 0;
        int n = 0;
        double dist = 0;
        std::vector<std::pair<double, double>> pts;
        for (auto &kv : contacts) {
            pts.emplace_back(kv.second.x, kv.second.y);
            cx += kv.second.x; cy += kv.second.y; n++;
        }
        cx /= n; cy /= n;
        if (pts.size() == 2) {
            double dx = pts[0].first - pts[1].first;
            double dy = pts[0].second - pts[1].second;
            dist = std::sqrt(dx * dx + dy * dy);
        }
        if (emit) {
            double dv = cy - last_centroid_y;
            double dh = cx - last_centroid_x;
            scroll_acc_v += dv;
            scroll_acc_h += dh;
            int ticks_v = 0, ticks_h = 0;
            while (scroll_acc_v >= SCROLL_NOTCH_VP) { scroll_acc_v -= SCROLL_NOTCH_VP; ticks_v++; }
            while (scroll_acc_v <= -SCROLL_NOTCH_VP) { scroll_acc_v += SCROLL_NOTCH_VP; ticks_v--; }
            while (scroll_acc_h >= SCROLL_NOTCH_VP) { scroll_acc_h -= SCROLL_NOTCH_VP; ticks_h++; }
            while (scroll_acc_h <= -SCROLL_NOTCH_VP) { scroll_acc_h += SCROLL_NOTCH_VP; ticks_h--; }
            if (ticks_v != 0 || ticks_h != 0) emit_wheel(ticks_v, ticks_h);
            // pinch: accumulated distance ratio -> zoom wheel ticks
            if (last_dist > 0 && dist > 0) {
                double ratio = dist / last_dist;
                pinch_acc += std::log(ratio);
                int zoom = 0;
                while (pinch_acc >= std::log(PINCH_NOTCH_RATIO)) { pinch_acc -= std::log(PINCH_NOTCH_RATIO); zoom++; }
                while (pinch_acc <= -std::log(PINCH_NOTCH_RATIO)) { pinch_acc += std::log(PINCH_NOTCH_RATIO); zoom--; }
                if (zoom != 0) emit_wheel(-zoom, 0);  // spread = zoom in (wheel up)
            }
        }
        last_centroid_x = cx; last_centroid_y = cy;
        last_dist = dist;
    }

    void tick(long ms)
    {
        clock_ms += ms;
        for (auto &kv : contacts) {
            Contact &c = kv.second;
            if (two_finger || c.pen || c.suppress_up) continue;
            if (c.longpress || c.moved) continue;
            if (clock_ms - c.start_ms >= LONG_PRESS_MS) {
                c.longpress = true;
                update_cursor(c.x, c.y);
                touch_right = true;
                emit_btn_down("right");
                emit_rightclick();
            }
        }
    }

    // Focus loss: release every held button (physical and synthetic) and drop
    // all gesture state, so no button is left down outside the window.
    void focus_lost()
    {
        if (touch_left) { touch_left = false; emit_btn_up("left"); }
        if (touch_right) { touch_right = false; emit_btn_up("right"); }
        if (mouse_left) { mouse_left = false; emit_btn_up("left"); }
        if (mouse_right) { mouse_right = false; emit_btn_up("right"); }
        if (mouse_middle) mouse_middle = false;
        contacts.clear();
        two_finger = false;
        scroll_acc_v = 0; scroll_acc_h = 0; pinch_acc = 0;
        emit_focus(0);
    }

    void resize(int w, int h)
    {
        surface_w = w; surface_h = h;
        // Clamp every active contact and the cursor into the new bounds.
        for (auto &kv : contacts) {
            kv.second.x = clamp_x(kv.second.x);
            kv.second.y = clamp_y(kv.second.y);
        }
        cursor_x = static_cast<int>(clamp_x(cursor_x));
        cursor_y = static_cast<int>(clamp_y(cursor_y));
        emit_mouse(cursor_x, cursor_y);
    }

    void finish()
    {
        if (touch_left || touch_right || mouse_left || mouse_right || mouse_middle) {
            std::printf("LEAK held=%s%s%s%s%s\n",
                        touch_left ? "touchL" : "",
                        touch_right ? "touchR" : "",
                        mouse_left ? "mL" : "",
                        mouse_right ? "mR" : "",
                        mouse_middle ? "mM" : "");
        }
    }
};

double parseDouble(const char *s, double &out)
{
    char *end = nullptr;
    out = std::strtod(s, &end);
    return end != s;
}

} // namespace

int main()
{
    Mapper m;
    std::string line;
    char buf[1024];
    while (std::fgets(buf, sizeof(buf), stdin)) {
        line = buf;
        while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
        if (line.empty() || line[0] == '#') continue;

        std::vector<std::string> t;
        const char *p = line.c_str();
        while (*p) {
            while (*p == ' ' || *p == '\t') p++;
            if (!*p) break;
            const char *s = p;
            while (*p && *p != ' ' && *p != '\t') p++;
            t.emplace_back(s, p);
        }
        if (t.empty()) continue;
        const std::string &op = t[0];

        if (op == "key") {
            m.key_event(std::atoi(t[1].c_str()), t[2] == "down",
                        t.size() > 3 ? std::atoi(t[3].c_str()) : 0);
        } else if (op == "text") {
            m.emit_textinput(t[1], false, -1, -1, -1);
        } else if (op == "ime") {
            const std::string &kind = t[1];
            std::string str = t[2];
            int caret = std::atoi(t[3].c_str());
            int repl = std::atoi(t[4].c_str());
            if (kind == "comp") {
                m.emit_textinput(str, true, caret, caret, repl);
            } else if (kind == "commit") {
                m.emit_textinput(str, false, -1, -1, -1);
            } else if (kind == "cancel") {
                // empty commit clears the marked composition span
                m.emit_textinput("", false, -1, -1, -1);
            } else if (kind == "select") {
                // selection [caret,repl) active: text will replace that span
                m.emit_textinput("", false, caret, caret, repl);
            }
        } else if (op == "mouse") {
            double x, y;
            parseDouble(t[1].c_str(), x); parseDouble(t[2].c_str(), y);
            m.note_physical_mouse();
            m.update_cursor(x, y);
        } else if (op == "enter") {
            m.note_physical_mouse();
            m.emit_focus(1);
        } else if (op == "leave") {
            m.focus_lost();
        } else if (op == "mbtn") {
            m.note_physical_mouse();
            if (t[2] == "down") m.mouse_down(t[1].c_str());
            else m.mouse_up(t[1].c_str());
        } else if (op == "wheel") {
            m.note_physical_mouse();
            m.emit_wheel(std::atoi(t[1].c_str()), t.size() > 2 ? std::atoi(t[2].c_str()) : 0);
        } else if (op == "touch") {
            int id = std::atoi(t[1].c_str());
            bool pen = t[5] == "pen";
            double x, y;
            parseDouble(t[3].c_str(), x); parseDouble(t[4].c_str(), y);
            m.touch_event(id, t[2], x, y, pen);
        } else if (op == "tick") {
            m.tick(std::atol(t[1].c_str()));
        } else if (op == "frame") {
            m.frame_scan(t[1] == "1", t[2] == "1", t[3] == "1", t[4] == "1");
        } else if (op == "axis") {
            int dy = std::atoi(t[1].c_str());
            int dx = std::atoi(t[2].c_str());
            double scale = std::atof(t[3].c_str());
            int zoom = 0;
            if (std::isfinite(scale) && scale > 0.0) {
                if (scale >= PINCH_NOTCH_RATIO) zoom = -1;          // spread = zoom in
                else if (scale <= 1.0 / PINCH_NOTCH_RATIO) zoom = 1; // pinch = zoom out
            }
            if (zoom != 0) m.emit_wheel(zoom, 0);
            else if (dy != 0 || dx != 0) m.emit_wheel(-dy, dx);
        } else if (op == "resize") {
            m.resize(std::atoi(t[1].c_str()), std::atoi(t[2].c_str()));
        } else if (op == "emulate") {
            m.emulate_rclick = t[1] == "on";
        } else if (op == "leakcheck") {
            m.finish();
        } else {
            std::fprintf(stderr, "unknown op: %s\n", op.c_str());
            return 2;
        }
    }
    m.finish();
    return 0;
}
CPPEOF

# ---------------------------------------------------------------------------
# Build the reference mapper
# ---------------------------------------------------------------------------
printf '[test] building reference mapper: %s\n' "${BIN}"
if ! "${CXX}" -std=c++17 -Wall -Wextra -Werror -O2 "${DRIVER}" -o "${BIN}" 2>"${WORKDIR}/build.log"; then
  printf 'FAIL: host build of reference mapper failed\n' >&2
  cat "${WORKDIR}/build.log" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run all fixtures
# ---------------------------------------------------------------------------
rc=0
count=0

for infile in "${FIXTURE_DIR}"/*-in; do
  [ -e "${infile}" ] || continue
  base="${infile%-in}"
  expected="${base}-expected"
  if [ ! -f "${expected}" ]; then
    printf 'FAIL: missing expected file for %s\n' "${infile}" >&2
    rc=1
    continue
  fi
  count=$((count + 1))
  name="$(basename "${base}")"

  printf '\n== fixture: %s ==\n' "${name}"
  if ! "${BIN}" < "${infile}" > "${WORKDIR}/actual.txt" 2>"${WORKDIR}/run.log"; then
    printf 'FAIL: mapper crashed on %s\n' "${name}" >&2
    cat "${WORKDIR}/run.log" >&2
    rc=1
    continue
  fi

  if diff -u "${expected}" "${WORKDIR}/actual.txt" > "${WORKDIR}/diff.txt" 2>&1; then
    printf 'PASS: %s matches expected OpenTTD sequence (%s lines)\n' \
      "${name}" "$(wc -l < "${expected}" | tr -d ' ')"
  else
    printf 'FAIL: %s diverged from expected OpenTTD sequence\n' "${name}" >&2
    cat "${WORKDIR}/diff.txt" >&2
    rc=1
  fi
done

if [ "${count}" -eq 0 ]; then
  fail "no fixtures found in ${FIXTURE_DIR}"
fi

printf '\n[test] input matrix: %s fixtures, %s\n' \
  "${count}" "$([ "$rc" -eq 0 ] && echo ALL PASS || echo FAILED)"
exit "$rc"
