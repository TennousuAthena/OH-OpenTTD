#!/usr/bin/env bash
# test-bridges.sh — host-side verification of the OpenTTD HarmonyOS system
# bridges (Todo 18): text-input/IME, document-picker and clipboard/browser.
#
# The bridge cores under harmonyos/entry/src/main/cpp/bridge_{textinput,picker,
# system}.{h,cpp} are DELIBERATELY PURE C++ with no XComponent / NAPI / OHOS
# SDK dependency (see the DESIGN CONTRACT headers), so the full contract can be
# compiled and exercised on the host (macOS / Linux) with the system C++
# compiler. This mirrors the approach of test-lifecycle-bridge.sh.
#
# The embedded driver validates the bridge state machines (PENDING/CALLING/
# DONE/ABORTED) and the exact buffer-text / result / policy outcomes:
#   a)  IME zh-CN Pinyin composition -> exact committed text "你好"
#   b)  TextInput cancel aborts composition without committing
#   c)  focus switch between edit boxes retains each box's buffer
#   d)  DocumentViewPicker cancel -> CANCELLED (nonfatal), still DONE
#   e)  invalid/expired URI -> INVALID_URI
#   f)  empty pasteboard -> null (clipboardAvailable == false)
#   g)  browser launch: rejects ftp://, accepts https://
#   h)  teardown while a request is pending cancels it (no hang/UAF)
#
# Usage: scripts/harmonyos/test-bridges.sh
# Exit:  0 = all scenarios pass, 1 = any scenario fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CXX="${CXX:-c++}"
WORKDIR="${TMPDIR:-/tmp}/openttd-ohos-bridges-test"
BIN="${WORKDIR}/driver"
DRIVER="${WORKDIR}/driver.cpp"

BRIDGE_DIR="${REPO_ROOT}/harmonyos/entry/src/main/cpp"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# Required bridge sources.
for f in \
  bridge_textinput.h bridge_textinput.cpp \
  bridge_picker.h bridge_picker.cpp \
  bridge_system.h bridge_system.cpp; do
  if [ ! -f "${BRIDGE_DIR}/${f}" ]; then
    fail "required bridge source not found: ${BRIDGE_DIR}/${f}"
  fi
done

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# Embedded C++ test driver.
# ---------------------------------------------------------------------------
cat > "${DRIVER}" <<'EOF'
// Embedded host driver for the OpenTTD HarmonyOS system bridges.
// Exercises the pure-C++ state machines and policy checks; prints PASS/FAIL
// per case and exits nonzero on any failure.

#include "bridge_textinput.h"
#include "bridge_picker.h"
#include "bridge_system.h"

#include <cstdio>
#include <cstring>
#include <deque>
#include <string>

using namespace openttd;

static int g_failures = 0;
static int g_checks = 0;

static void check(bool cond, const char* what)
{
    g_checks++;
    if (cond) {
        std::printf("  PASS: %s\n", what);
    } else {
        std::printf("  FAIL: %s\n", what);
        g_failures++;
    }
}

static void section(const char* name)
{
    std::printf("[case] %s\n", name);
}

int main()
{
    // ------------------------------------------------------------------
    // (a) IME zh-CN Pinyin composition -> exact committed text "你好".
    // ------------------------------------------------------------------
    section("IME zh-CN Pinyin composition commits exact text");
    {
        BridgeTextInput t(512, 256);
        t.editBoxGainedFocus();
        // "ni" -> 你 ; "hao" -> 好 ; committed text is "你好".
        t.imeComposition("n", 1);
        t.imeComposition("ni", 2);
        t.imeCommit("\xe4\xbd\xa0");            // 你
        t.imeComposition("h", 1);
        t.imeComposition("ha", 2);
        t.imeComposition("hao", 3);
        t.imeCommit("\xe5\xa5\xbd");            // 好
        check(t.text() == "\xe4\xbd\xa0\xe5\xa5\xbd",
              "committed text == \"\xe4\xbd\xa0\xe5\xa5\xbd\" (\xe4\xbd\xa0\xe5\xa5\xbd)");
        // Commit clears the marked span; the mark position may remain as an
        // EMPTY span (deleteText keeps marks unless update=true), so the
        // invariant is span length 0, not hasMark()==false.
        check(t.buffer().markPos() == t.buffer().markEnd(),
              "no marked composition span remains after commit");
    }

    // ------------------------------------------------------------------
    // (b) TextInput cancel aborts composition without committing.
    // ------------------------------------------------------------------
    section("TextInput cancel aborts composition without committing");
    {
        BridgeTextInput t(512, 256);
        t.editBoxGainedFocus();
        t.textCommit("base");                   // committed plain text
        t.imeComposition("\xe6\x9c\xba", 3);    // 机 (marked)
        check(t.buffer().hasMark(), "composition is marked in-flight");
        t.imeCancel();                          // discard the marked span
        check(!t.buffer().hasMark(), "mark cleared after cancel");
        check(t.text() == "base",
              "buffer restored to pre-composition text (cancel commits nothing)");
    }

    // ------------------------------------------------------------------
    // (c) Focus switch between edit boxes retains each box's buffer.
    // ------------------------------------------------------------------
    section("focus switch between edit boxes retains each box's buffer");
    {
        BridgeTextInput box1(512, 256);
        BridgeTextInput box2(512, 256);
        box1.editBoxGainedFocus();
        box1.textCommit("alpha");
        box1.editBoxLostFocus();
        box2.editBoxGainedFocus();
        box2.textCommit("beta");
        box2.editBoxLostFocus();
        check(box1.text() == "alpha", "box1 retains its buffer after focus switch");
        check(box2.text() == "beta", "box2 retains its buffer after focus switch");
        check(!box1.isFocused() && !box2.isFocused(),
              "neither box reports focus after both lost focus");
    }

    // ------------------------------------------------------------------
    // (d) DocumentViewPicker cancel -> CANCELLED (nonfatal), still DONE.
    // ------------------------------------------------------------------
    section("DocumentViewPicker cancel returns CANCELLED (nonfatal)");
    {
        BridgePicker p;
        uint64_t id = p.start(true);
        check(id != 0, "import request started (CALLING)");
        check(p.state(id) == PickerState::CALLING, "request in CALLING state");
        p.complete(id, PickerResult::CANCELLED, "");
        std::deque<PickerCallback> out;
        size_t n = p.drainResults(out);
        check(n == 1 && out.size() == 1, "one callback delivered on cancel");
        check(out.front().result == PickerResult::CANCELLED,
              "delivered result is CANCELLED");
        check(p.state(id) == PickerState::DONE, "cancel still transitions to DONE");
        check(p.outstanding() == 0, "no outstanding requests after cancel");
    }

    // ------------------------------------------------------------------
    // (e) invalid / expired URI -> INVALID_URI (nonfatal).
    // ------------------------------------------------------------------
    section("invalid URI returns INVALID_URI");
    {
        BridgePicker p;
        uint64_t id = p.start(false);
        p.complete(id, PickerResult::INVALID_URI, "");
        std::deque<PickerCallback> out;
        p.drainResults(out);
        check(!out.empty() && out.front().result == PickerResult::INVALID_URI,
              "delivered result is INVALID_URI");
        check(p.state(id) == PickerState::DONE, "invalid URI still DONE (nonfatal)");
    }

    // ------------------------------------------------------------------
    // (f) empty pasteboard returns null (unavailable).
    // ------------------------------------------------------------------
    section("empty pasteboard returns null");
    {
        BridgeSystem s;
        s.clipboardResult(false, "");           // platform reported no text
        check(!s.clipboardAvailable(), "clipboard reports unavailable (null)");
        check(s.clipboard().value.empty(), "null clipboard carries no placeholder text");
        s.clipboardResult(true, "content");
        check(s.clipboardAvailable(), "non-empty clipboard reports available");
    }

    // ------------------------------------------------------------------
    // (g) startAbilityByType rejects disallowed scheme, accepts https.
    // ------------------------------------------------------------------
    section("browser launch policy: reject ftp://, accept https://");
    {
        BridgeSystem s;
        check(s.openBrowser("ftp://example.com/file") == BrowserLaunch::DISALLOWED,
              "ftp:// rejected (DISALLOWED)");
        check(s.lastLaunchedUrl().empty(), "rejected scheme records no launch URL");
        check(s.openBrowser("https://www.openttd.org") == BrowserLaunch::ACCEPTED,
              "https:// accepted (ACCEPTED)");
        check(s.lastLaunchedUrl() == "https://www.openttd.org",
              "accepted https URL recorded as launched");
        check(s.browserAcceptedCount() == 1, "one accepted launch counted");
        check(s.browserRejectedCount() == 1, "one rejected launch counted");
    }

    // ------------------------------------------------------------------
    // (h) teardown while a request is pending cancels the request.
    // ------------------------------------------------------------------
    section("teardown with pending request cancels it (no hang/UAF)");
    {
        BridgePicker p;
        uint64_t id = p.start(true);
        check(id != 0 && p.state(id) == PickerState::CALLING,
              "request pending in CALLING before teardown");
        p.teardown();                            // ability onDestroy aborts all
        check(p.state(id) == PickerState::ABORTED, "pending request aborted by teardown");
        check(p.tornDown(), "bridge reports torn down");
        std::deque<PickerCallback> out;
        check(p.drainResults(out) == 0 && out.empty(),
              "no post-teardown callbacks run (no UAF/hang)");
        check(p.start(true) == 0, "start after teardown is a no-op");
        check(p.outstanding() == 0, "no outstanding requests after teardown");
    }

    std::printf("RESULT: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
EOF

# ---------------------------------------------------------------------------
# Build the host driver against the bridge sources.
# ---------------------------------------------------------------------------
note "[test] building host bridge driver: ${BIN}"
if ! "${CXX}" -std=c++17 -Wall -Wextra \
    -I"${BRIDGE_DIR}" \
    "${DRIVER}" \
    "${BRIDGE_DIR}/bridge_textinput.cpp" \
    "${BRIDGE_DIR}/bridge_picker.cpp" \
    "${BRIDGE_DIR}/bridge_system.cpp" \
    -o "${BIN}" 2>"${WORKDIR}/build.log"; then
  fail "host build of bridge tests failed; build log:"
  cat "${WORKDIR}/build.log" >&2
fi

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------
note "[test] running host bridge suite"
"${BIN}"

rm -rf "${WORKDIR}"
note "bridge host suite passed."
