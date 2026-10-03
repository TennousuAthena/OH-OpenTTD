#!/usr/bin/env bash
# test-desktop-input.sh — host-side lock for the HarmonyOS desktop input bridge
# (Todo 14: keyboard/mouse/trackpad).
#
# This compiles the REAL bridge core (src/video/harmonyos_input.cpp) as pure
# C++ on the host (no XComponent/NAPI dependency) and links it against a small
# recording driver that installs a HarmonyOSInputSink printing the canonical
# OpenTTD-call sequence. It then replays the Todo 10 desktop fixtures
# (keyboard-canonical, keyboard-frame-scan, mouse-canonical, touchpad-axis)
# and compares the emitted sequence byte-for-byte against the golden files.
# Desktop-specific goldens retain the current bridge's character mappings and
# positional button events; the historical reference mapper uses its own goldens.
# Batched replay also exercises motion bursts, event barriers, held drags,
# fixed-cursor movement and callback arrivals during a production queue drain.
#
# Because the bridge core is the same translation unit the device build uses,
# a PASS here proves the real device glue produces the exact OpenTTD event
# sequence the input matrix specifies.
#
# Usage: scripts/harmonyos/test-desktop-input.sh
# Exit:  0 = all fixtures pass, 1 = any fixture fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/test-fixtures/input"
BRIDGE_CPP="${REPO_ROOT}/src/video/harmonyos_input.cpp"

CXX="${CXX:-c++}"
WORKDIR="${TMPDIR:-/tmp}/openttd-ohos-desktop-input-test"
BIN="${WORKDIR}/desktop-input"
DRIVER="${WORKDIR}/driver.cpp"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "${BRIDGE_CPP}" ]; then
  fail "bridge source not found: ${BRIDGE_CPP}"
fi
if [ ! -d "${FIXTURE_DIR}" ]; then
  fail "fixture directory not found: ${FIXTURE_DIR}"
fi

mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# Recording driver. Installs a sink that prints the canonical OpenTTD-call
# sequence (same grammar as the Todo 10 reference mapper output), then replays
# the trace line grammar from stdin through the real bridge handlers.
#
# Trace line grammar (input):
#   key <code> <down|up> <repeat>      raw HarmonyOS keycode event
#   mouse <x> <y>                      physical mouse move
#   enter | leave                      physical mouse window enter/leave
#   mbtn <left|right|middle> <down|up> physical mouse button
#   wheel <vy> <vx>                    physical mouse wheel (precise deltas)
#   axis <dy> <dx> <scale>             touchpad axis (scroll deltas + pinch)
#   frame <left> <up> <right> <down>   per-frame InputLoop held-state scan
#   leakcheck                          assert no held button remains
#   # comment
#
# Output line grammar (matches the *-expected golden files):
#   keypress kc=<hex> char=<hex> rep=<n>
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
#include "harmonyos_input.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <initializer_list>
#include <utility>

namespace {

void emit_keypress(int kc, char32_t ch, int rep)
{
    std::printf("keypress kc=%04x char=%04x rep=%d\n", kc, static_cast<int>(ch), rep);
}
void emit_mouse(int x, int y)        { std::printf("mouse x=%d y=%d\n", x, y); }
void emit_focus(int f)               { std::printf("focus %d\n", f); }
void emit_btn_down(const char *b)    { std::printf("btndown %s\n", b); }
void emit_btn_up(const char *b)      { std::printf("btnup %s\n", b); }
void emit_rightclick()               { std::printf("rightclick\n"); }
void emit_wheel(int v, int h)        { std::printf("wheel v=%d h=%d\n", v, h); }
void emit_ctrl(int c)                { std::printf("ctrl %d\n", c); }
void emit_dirkeys(int m)             { std::printf("dirkeys %d\n", m); }
void emit_exit()                     { std::printf("exit\n"); }

void install_sink()
{
    HarmonyOSInputSink sink;
    sink.keypress     = [](int kc, char32_t ch, int rep) { emit_keypress(kc, ch, rep); };
    sink.mouse_move   = [](int x, int y) { emit_mouse(x, y); };
    sink.mouse_button = [](int button, bool down, bool clicked) {
        const char *name = (button == HARMONYOS_MOUSE_BUTTON_LEFT) ? "left" : "right";
        if (down) {
            emit_btn_down(name);
            if (clicked) emit_rightclick();
        } else {
            emit_btn_up(name);
        }
    };
    sink.wheel        = [](int v, int h) { emit_wheel(v, h); };
    sink.focus        = [](bool in) { emit_focus(in ? 1 : 0); };
    sink.ctrl_changed = [](bool c) { emit_ctrl(c ? 1 : 0); };
    sink.dirkeys      = [](int m) { emit_dirkeys(m); };
    sink.exit_request = []() { emit_exit(); };
    HarmonyOSInputSetSink(sink);
}

std::vector<std::string> burst_events;
bool burst_fixed = false;
bool fix_on_wheel = false;
bool enqueue_during_move = false;

void install_burst_sink()
{
    HarmonyOSInputSink sink;
    sink.mouse_move = [](int x, int y) {
        burst_events.push_back("move " + std::to_string(x) + " " + std::to_string(y));
        if (enqueue_during_move) {
            enqueue_during_move = false;
            HarmonyOSHandleMouseEvent(3, 0, x + 1, y + 1, 0, 0);
        }
    };
    sink.mouse_button = [](int button, bool down, bool) {
        burst_events.push_back(std::string(down ? "down " : "up ") + std::to_string(button));
    };
    sink.keypress = [](int key, char32_t, int) {
        burst_events.push_back("key " + std::to_string(key));
    };
    sink.wheel = [](int v, int h) {
        burst_events.push_back("wheel " + std::to_string(v) + " " + std::to_string(h));
        if (fix_on_wheel) burst_fixed = true;
    };
    sink.focus = [](bool focused) {
        burst_events.push_back(focused ? "focus 1" : "focus 0");
        if (!focused) burst_fixed = false;
    };
    sink.cursor_fixed = [] { return burst_fixed; };
    HarmonyOSInputSetSink(sink);
}

void reset_burst()
{
    enqueue_during_move = false;
    fix_on_wheel = false;
    HarmonyOSInputQueueInstance().Clear();
    HarmonyOSResetInputState();
    HarmonyOSInputDrain();
    burst_fixed = false;
    burst_events.clear();
}

void move(int x, int y) { HarmonyOSHandleMouseEvent(3, 0, x, y, 0, 0); }
void button(int action, int bit, int x, int y) { HarmonyOSHandleMouseEvent(action, bit, x, y, 0, 0); }

bool expect(const char *name, std::initializer_list<const char *> expected)
{
    std::vector<std::string> want(expected.begin(), expected.end());
    if (burst_events == want) {
        std::printf("PASS: %s\n", name);
        return true;
    }
    std::fprintf(stderr, "FAIL: %s\n", name);
    for (const auto &event : burst_events) std::fprintf(stderr, "  actual: %s\n", event.c_str());
    for (const auto &event : want) std::fprintf(stderr, "  expected: %s\n", event.c_str());
    return false;
}

bool run_burst_tests()
{
    install_burst_sink();
    bool ok = true;

    reset_burst();
    for (int i = 0; i < 10000; ++i) move(i, i * 2);
    HarmonyOSInputDrain();
    ok &= expect("free pointer burst reaches newest coordinates", {"move 9999 19998"});

    reset_burst();
    move(1, 1); move(2, 2);
    HarmonyOSHandleKeyEvent(2017, true, 0);
    move(3, 3); move(4, 4);
    HarmonyOSHandleMouseEvent(HARMONYOS_MOUSE_ACTION_WHEEL, 0, 0, 0, 1, -1);
    move(5, 5); move(6, 6);
    HarmonyOSHandleHoverEvent(true, 0, 0);
    move(7, 7); move(8, 8);
    HarmonyOSResetInputState();
    move(9, 9); move(10, 10);
    HarmonyOSInputDrain();
    ok &= expect("keyboard wheel focus and reset preserve motion barriers", {
        "move 2 2", "key 65", "move 4 4", "wheel 1 -1", "move 6 6",
        "focus 1", "move 8 8", "focus 0", "move 10 10"});

    reset_burst();
    move(1, 1); move(2, 2);
    button(1, 1, 3, 3);
    move(4, 4); move(5, 5);
    button(2, 1, 6, 6);
    move(7, 7); move(8, 8);
    HarmonyOSInputDrain();
    ok &= expect("left drag keeps all moves and edge coordinates", {
        "move 3 3", "down 0", "move 4 4", "move 5 5", "move 6 6", "up 0", "move 8 8"});

    reset_burst();
    HarmonyOSHandleKeyEvent(2072, true, 0);
    button(1, 1, 1, 1);
    move(2, 2); move(3, 3);
    HarmonyOSHandleHoverEvent(false, 0, 0);
    move(4, 4); move(5, 5);
    HarmonyOSInputDrain();
    ok &= expect("focus loss releases emulated right drag before coalescing", {
        "move 1 1", "down 1", "move 2 2", "move 3 3", "up 1", "focus 0", "move 5 5"});
    ok &= HarmonyOSInputHeldStateMask() == 0;

    reset_burst();
    button(1, 2, 1, 1);
    move(2, 2); move(3, 3);
    button(2, 2, 4, 4);
    HarmonyOSInputDrain();
    ok &= expect("right drag preserves movement", {
        "move 1 1", "down 1", "move 2 2", "move 3 3", "move 4 4", "up 1"});

    reset_burst();
    button(1, 4, 1, 1);
    move(2, 2); move(3, 3);
    HarmonyOSResetInputState();
    move(4, 4); move(5, 5);
    HarmonyOSInputDrain();
    ok &= expect("middle held moves survive until reset", {
        "move 1 1", "move 2 2", "move 3 3", "focus 0", "move 5 5"});
    ok &= HarmonyOSInputHeldStateMask() == 0;

    reset_burst();
    fix_on_wheel = true;
    HarmonyOSHandleMouseEvent(HARMONYOS_MOUSE_ACTION_WHEEL, 0, 0, 0, 1, 0);
    move(1, 1); move(2, 2);
    HarmonyOSInputDrain();
    ok &= expect("wheel activates fixed cursor before subsequent motion run", {
        "wheel 1 0", "move 1 1", "move 2 2"});

    reset_burst();
    for (auto type : {HarmonyOSInputEventType::Touch, HarmonyOSInputEventType::TextInput,
                     HarmonyOSInputEventType::TextKey, HarmonyOSInputEventType::FrameScan}) {
        move(1, 1); move(2, 2);
        HarmonyOSInputEvent event;
        event.type = type;
        HarmonyOSInputQueueInstance().Push(std::move(event));
    }
    move(3, 3); move(4, 4);
    HarmonyOSInputDrain();
    ok &= expect("touch text and frame events are motion barriers", {
        "move 2 2", "move 2 2", "move 2 2", "move 2 2", "move 4 4"});

    reset_burst();
    enqueue_during_move = true;
    move(10, 10);
    HarmonyOSInputDrain();
    ok &= expect("callback arrival stays out of current finite batch", {"move 10 10"});
    ok &= !HarmonyOSInputQueueInstance().Empty();
    burst_events.clear();
    HarmonyOSInputDrain();
    ok &= expect("callback arrival is processed on the next drain", {"move 11 11"});
    ok &= HarmonyOSInputQueueInstance().Empty();

    HarmonyOSInputQueue queue;
    HarmonyOSInputEvent event;
    event.type = HarmonyOSInputEventType::MouseMove;
    queue.Push(event);
    auto batch = queue.TakeBatch();
    const bool timestamped = batch.size() == 1 && batch.front().enqueue_time_ns != 0 && queue.Empty();
    ok &= timestamped;
    std::printf("%s: queued events carry monotonic timestamps\n", timestamped ? "PASS" : "FAIL");
    reset_burst();
    return ok;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc == 2 && std::strcmp(argv[1], "--burst-tests") == 0) return run_burst_tests() ? 0 : 1;
    install_sink();

    std::string line;
    float pointer_x = 0, pointer_y = 0;
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
            HarmonyOSHandleKeyEvent(std::atoi(t[1].c_str()), t[2] == "down",
                                    t.size() > 3 ? std::atoi(t[3].c_str()) : 0);
        } else if (op == "mouse") {
            pointer_x = static_cast<float>(std::atof(t[1].c_str()));
            pointer_y = static_cast<float>(std::atof(t[2].c_str()));
            HarmonyOSHandleMouseEvent(3 /* MOUSE_MOVE */, 0,
                                      pointer_x, pointer_y, 0.0f, 0.0f);
        } else if (op == "enter") {
            HarmonyOSHandleHoverEvent(true, 0.0f, 0.0f);
        } else if (op == "leave") {
            HarmonyOSHandleHoverEvent(false, 0.0f, 0.0f);
        } else if (op == "mbtn") {
            int btn = 0;
            if (t[1] == "left") btn = 0x01;
            else if (t[1] == "right") btn = 0x02;
            else if (t[1] == "middle") btn = 0x04;
            int action = (t[2] == "down") ? 1 /* PRESS */ : 2 /* RELEASE */;
            HarmonyOSHandleMouseEvent(action, btn, pointer_x, pointer_y, 0.0f, 0.0f);
        } else if (op == "wheel") {
            HarmonyOSHandleMouseEvent(HARMONYOS_MOUSE_ACTION_WHEEL, 0, 0.0f, 0.0f,
                                      static_cast<float>(std::atof(t[1].c_str())),
                                      t.size() > 2 ? static_cast<float>(std::atof(t[2].c_str())) : 0.0f);
        } else if (op == "axis") {
            HarmonyOSHandleAxisEvent(static_cast<float>(std::atof(t[1].c_str())),
                                     static_cast<float>(std::atof(t[2].c_str())),
                                     static_cast<float>(std::atof(t[3].c_str())));
        } else if (op == "frame") {
            HarmonyOSInputFrameScan(t[1] == "1", t[2] == "1", t[3] == "1", t[4] == "1");
        } else if (op == "leakcheck") {
            if (HarmonyOSInputHeldStateMask() != 0) {
                std::printf("LEAK held=%d\n", HarmonyOSInputHeldStateMask());
            }
        } else {
            std::fprintf(stderr, "unknown op: %s\n", op.c_str());
            return 2;
        }

        /* Drain the queue after each trace line so the emitted sequence is
         * deterministic and ordered exactly as the raw callbacks produced it. */
        HarmonyOSInputDrain();
    }
    HarmonyOSInputDrain();
    return 0;
}
CPPEOF

# ---------------------------------------------------------------------------
# Build the real bridge core + driver on the host.
# ---------------------------------------------------------------------------
printf '[test] building desktop input bridge: %s\n' "${BIN}"
if ! "${CXX}" -std=c++17 -Wall -Wextra -Werror -O2 \
     -I"${REPO_ROOT}/src/video" \
     "${DRIVER}" "${BRIDGE_CPP}" -o "${BIN}" 2>"${WORKDIR}/build.log"; then
  printf 'FAIL: host build of desktop input bridge failed\n' >&2
  cat "${WORKDIR}/build.log" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run the desktop fixtures.
# ---------------------------------------------------------------------------
rc=0
count=0

for name in keyboard-canonical keyboard-frame-scan mouse-canonical touchpad-axis; do
  infile="${FIXTURE_DIR}/${name}-in"
  expected="${FIXTURE_DIR}/${name}-expected"
  if [ -f "${FIXTURE_DIR}/${name}-desktop-expected" ]; then
    expected="${FIXTURE_DIR}/${name}-desktop-expected"
  fi
  if [ ! -f "${infile}" ] || [ ! -f "${expected}" ]; then
    printf 'FAIL: missing fixture for %s\n' "${name}" >&2
    rc=1
    continue
  fi
  count=$((count + 1))

  printf '\n== fixture: %s ==\n' "${name}"
  if ! "${BIN}" < "${infile}" > "${WORKDIR}/actual.txt" 2>"${WORKDIR}/run.log"; then
    printf 'FAIL: bridge crashed on %s\n' "${name}" >&2
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

printf '\n== production queue burst tests ==\n'
if ! "${BIN}" --burst-tests; then
  rc=1
fi

if [ "${count}" -eq 0 ]; then
  fail "no desktop fixtures found in ${FIXTURE_DIR}"
fi

printf '\n[test] desktop input: %s fixtures, %s\n' \
  "${count}" "$([ "$rc" -eq 0 ] && echo ALL PASS || echo FAILED)"
exit "$rc"
