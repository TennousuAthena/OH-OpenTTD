# HarmonyOS → OpenTTD Input & IME Compatibility Matrix

This document is the normative specification for translating raw HarmonyOS
XComponent input events (touch, key, mouse, axis/touchpad, stylus) and IME
composition into the OpenTTD input surface. It is the contract that the native
input bridge (`harmonyos/entry/src/main/cpp/`) must implement, and the base for
the data-driven tests in `scripts/harmonyos/test-input-matrix.sh`.

**Ground truth references (upstream OpenTTD 15.3):**

- `src/video/sdl2_v.cpp:241-354` — SDL key → OpenTTD `WKC_*` + modifier bits + character.
- `src/video/sdl2_v.cpp:406-505` — mouse motion / wheel / button → `_cursor`,
  `_left_button_down`, `_right_button_down`, `HandleMouseEvents()`,
  `HandleTextInput()`.
- `src/video/sdl2_v.cpp:609-631` — per-frame modifier scan → `_ctrl_pressed`,
  `_shift_pressed`, `_dirkeys`, `HandleCtrlChanged()`.
- `src/gfx_func.h:72-77` — `HandleKeypress`, `HandleTextInput`,
  `HandleCtrlChanged`, `HandleMouseEvents` signatures.
- `src/gfx_type.h:29-107` — `WindowKeyCodes` (`WKC_*`) numeric values.
- `src/window.cpp:2653-2760` — key dispatch, `HandleTextInput` (marked string,
  caret, insert/replacement), edit-box insertion.

**HarmonyOS API facts (verified against SDK 6.1.0.105, API 23):**

- Key codes: `@ohos.multimodalInput.keyCode` (enum values below).
- XComponent input: ArkUI `.onTouch`, `.onKeyEvent`, `.onMouse` attributes and
  the native `OH_NativeXComponent` touch/mouse/key/axis callbacks.
- IME: `@ohos.inputMethod` — `insertText`, `deleteForward`/`deleteBackward`,
  `updateCursor`, `editorStateChange` with marked text, `setSelection`.
- Touch: `TouchType.Down|Move|Up|Cancel`, per-finger `id`, `toolType`
  (`Finger|Pen`), `touches[]` coordinates.
- Mouse: action `Press|Release|Move|Wheel|Hover*`, `button`
  (`Left|Right|Middle|...`), modifier state (`altKey`/`ctrlKey`/`shiftKey`/`metaKey`),
  `verticalAxisValue`/`tiltX`/`tiltY` for wheel/2D scroll.
- Touchpad/axis: native axis events convey scroll (delta) and pinch (scale).

---

## 1. Key code → `WKC_*` mapping

Logical key codes come from `@ohos.multimodalInput.keyCode`. The mapper converts
the OS logical key plus the current modifier state into an OpenTTD keycode (a
`WindowKeyCodes` value with `WKC_SHIFT|WKC_CTRL|WKC_ALT|WKC_META` modifier bits
ORed in), exactly as `ConvertSdlKeyIntoMy` does for SDL.

| Harmony keyCode | value | OpenTTD code | `WKC_*` |
|---|---|---|---|
| `KEYCODE_ESCAPE` | 2070 | 1 | `WKC_ESC` |
| `KEYCODE_DEL` (Backspace) | 2055 | 2 | `WKC_BACKSPACE` |
| `KEYCODE_INSERT` | 2083 | 3 | `WKC_INSERT` |
| `KEYCODE_FORWARD_DEL` | 2071 | 4 | `WKC_DELETE` |
| `KEYCODE_PAGE_UP` | 2068 | 5 | `WKC_PAGEUP` |
| `KEYCODE_PAGE_DOWN` | 2069 | 6 | `WKC_PAGEDOWN` |
| `KEYCODE_MOVE_END` | 2082 | 7 | `WKC_END` |
| `KEYCODE_MOVE_HOME` | 2081 | 8 | `WKC_HOME` |
| `KEYCODE_DPAD_LEFT` | 2014 | 9 | `WKC_LEFT` |
| `KEYCODE_DPAD_UP` | 2012 | 10 | `WKC_UP` |
| `KEYCODE_DPAD_RIGHT` | 2015 | 11 | `WKC_RIGHT` |
| `KEYCODE_DPAD_DOWN` | 2013 | 12 | `WKC_DOWN` |
| `KEYCODE_ENTER` | 2054 | 13 | `WKC_RETURN` |
| `KEYCODE_TAB` | 2049 | 14 | `WKC_TAB` |
| `KEYCODE_SPACE` | 2050 | 32 | `WKC_SPACE` |
| `KEYCODE_F1` … `KEYCODE_F12` | 2090…2101 | 33…44 | `WKC_F1`…`WKC_F12` |
| `KEYCODE_GRAVE` | 2056 | 45 | `WKC_BACKQUOTE` |
| `KEYCODE_0`…`KEYCODE_9` | 2000…2009 | 48…57 | `'0'`…`'9'` |
| `KEYCODE_A`…`KEYCODE_Z` | 2017…2042 | 65…90 | `'A'`…`'Z'` |
| `KEYCODE_NUMPAD_DIVIDE` | 2113 | 138 | `WKC_NUM_DIV` |
| `KEYCODE_NUMPAD_MULTIPLY` | 2114 | 139 | `WKC_NUM_MUL` |
| `KEYCODE_NUMPAD_SUBTRACT` | 2115 | 140 | `WKC_NUM_MINUS` |
| `KEYCODE_NUMPAD_ADD` | 2116 | 141 | `WKC_NUM_PLUS` |
| `KEYCODE_NUMPAD_ENTER` | 2119 | 142 | `WKC_NUM_ENTER` |
| `KEYCODE_NUMPAD_DOT` | 2117 | 143 | `WKC_NUM_DECIMAL` |
| `KEYCODE_SLASH` | 2064 | 144 | `WKC_SLASH` |
| `KEYCODE_SEMICOLON` | 2062 | 145 | `WKC_SEMICOLON` |
| `KEYCODE_EQUALS` | 2058 | 146 | `WKC_EQUALS` |
| `KEYCODE_LEFT_BRACKET` | 2059 | 147 | `WKC_L_BRACKET` |
| `KEYCODE_BACKSLASH` | 2061 | 148 | `WKC_BACKSLASH` |
| `KEYCODE_RIGHT_BRACKET` | 2060 | 149 | `WKC_R_BRACKET` |
| `KEYCODE_APOSTROPHE` | 2063 | 150 | `WKC_SINGLEQUOTE` |
| `KEYCODE_COMMA` | 2043 | 151 | `WKC_COMMA` |
| `KEYCODE_PERIOD` | 2044 | 152 | `WKC_PERIOD` |
| `KEYCODE_MINUS` | 2057 | 153 | `WKC_MINUS` |
| `KEYCODE_NUMPAD_0`…`9` | 2103…2112 | 48…57 | `'0'`…`'9'` |
| `KEYCODE_BACK` | 2 | — | system back → `HandleExitGameRequest`, **not** a keycode |

### Modifier bits

| Harmony key | sets | OpenTTD bit |
|---|---|---|
| `KEYCODE_SHIFT_LEFT`/`SHIFT_RIGHT` (2047/2048) | `WKC_SHIFT` | `0x8000` |
| `KEYCODE_CTRL_LEFT`/`CTRL_RIGHT` (2072/2073) | `WKC_CTRL` | `0x4000` |
| `KEYCODE_ALT_LEFT`/`ALT_RIGHT` (2045/2046) | `WKC_ALT` | `0x2000` |
| `KEYCODE_META_LEFT`/`META_RIGHT` (2076/2077) | `WKC_META` | `0x1000` |

Rules (mirroring `ConvertSdlKeyIntoMy`):

1. Base keycode = mapped table value.
2. OR in every currently-held modifier bit.
3. **Character extraction**: if any of `META|CTRL|ALT` is set, or the key is
   flagged unprintable (navigation/function/special keys), the character passed
   to `HandleKeypress` must be `WKC_NONE` (`0`). Otherwise the character is the
   ASCII code of the key (so typing `'a'` produces `WKC_A | WKC_SHIFT` only when
   Shift is held — see §4 text handling).
4. Repeated key-down events (auto-repeat) are forwarded as-is with
   `repeat > 0`; the game decides whether to act.

### Per-frame held-state scan

Mirror `VideoDriver_SDL_Base::InputLoop` (`sdl2_v.cpp:609-631`): once per frame,
recompute from the current modifier/key state:

- `_ctrl_pressed = (mod & WKC_CTRL) != 0`
- `_shift_pressed = (mod & WKC_SHIFT) != 0`
- `_dirkeys` = bitmask of held direction keys (left=1, up=2, right=4, down=8)
- emit `HandleCtrlChanged()` only when `_ctrl_pressed` toggles.

---

## 2. Mouse mapping

Physical mouse and stylus-as-pointer events map 1:1 (see §6 for gestures and the
suppression rule). Physical mouse presence **disables** all touch-gesture
emulation.

| Harmony action | OpenTTD effect |
|---|---|
| `MouseAction.Move` | `_cursor.UpdateCursorPosition(x, y)`; if accepted and `_cursor.fix_at`, snap/warp back; then `HandleMouseEvents()` |
| `MouseAction.Press` (Left) | `_left_button_down = true`; `HandleMouseEvents()` |
| `MouseAction.Release` (Left) | `_left_button_down = false`; `_left_button_clicked = false`; `HandleMouseEvents()` |
| `MouseAction.Press` (Right) | `_right_button_down = true`; `_right_button_clicked = true`; `HandleMouseEvents()` |
| `MouseAction.Release` (Right) | `_right_button_down = false`; `HandleMouseEvents()` |
| `MouseAction.Hover Move/Enter/Leave` | `_cursor.in_window = true/false`; enter also clears relative-mouse lock |
| `MouseAction.Wheel` | `_cursor.wheel--` on scroll up, `++` on scroll down; `_cursor.v_wheel -= verticalAxisValue * 14 * multiplier`; `_cursor.h_wheel += tiltX * 14 * multiplier`; `_cursor.wheel_moved = true` |

> 2D scroll: horizontal (`tiltX`) and vertical (`tiltY`) wheel deltas feed
> `_cursor.h_wheel` / `_cursor.v_wheel` exactly as the SDL `MOUSEWHEEL` branch.
> `_settings_client.gui.scrollwheel_multiplier` scales both.

---

## 3. `_cursor`, `HandleMouseEvents`

The input bridge never mutates OpenTTD game state directly. It only:
1. Updates `_cursor.pos` / `_cursor.in_window` / `_cursor.wheel` / `_cursor.wheel_moved`;
2. Updates `_left_button_down`, `_right_button_down`, `_right_button_clicked`;
3. Calls `HandleMouseEvents()` after any change to position/buttons.

All game-level behaviour (clicking, drag selection, autoscroll, wheel scroll) is
owned by `HandleMouseEvents()` and the window/viewport code (`window.cpp:2653-2760`).
Raw callbacks never dispatch actions outside the OpenTTD event queue.

---

## 4. Text input & IME

### Plain keyboard text

When an edit box has global focus and a printable key is pressed, OpenTTD routes:
- **Keydown** → `HandleKeypress(keycode, character)` for navigation/editing keys
  (arrows, delete, home, end, ctrl/meta/alt combos, F1–F12) or when the character
  is not alphanumeric.
- **Text/commit** → `HandleTextInput(text)` for printable sequences.

This mirrors the SDL split between `KEYDOWN` and `TEXTINPUT`
(`sdl2_v.cpp:464-505`).

### IME composition (inputMethodEngine)

Preserve the full composition lifecycle. Harmony IME events are mapped to an
OpenTTD-native `HandleTextInput` call:

| IME event | OpenTTD call |
|---|---|
| composition update (Pinyin/radical interim string) | `HandleTextInput(marked, marked=true, caret, insert_location, replacement_end)` |
| composition commit (candidate chosen) | `HandleTextInput(text, marked=false)` (replaces the marked segment) |
| composition cancel / editor cleared | clear the marked region; if empty, no visible change |
| selection change | `updateCursor(cursorInfo)` → propagate caret; `HandleTextInput` with matching caret/insert/replacement offsets |
| `insertText` (IME inserts into editor) | append/apply at cursor with `insert_location`/`replacement_end` |

Key requirements:
- **Composition must not be double-fed**: a composition update goes `/marked=true`,
  a commit goes `/marked=false`; the editor replaces the marked span rather than
  appending a second copy.
- **Cancelling IME** must restore the pre-composition text (OpenTTD's
  `InsertString(..., marked=true)` keeps a backup segment that a later
  `/marked=false` empty commit clears).
- **Selection/caret** must map through `caret`, `insert_location`,
  `replacement_end` so mid-string insert/replace behaves correctly.

---

## 5. Touch gesture → mouse mapping

Touch input has no physical mouse, so the bridge runs a small gesture recognizer.
All synthesized events go through the **same** `_cursor`/`HandleMouseEvents()`
path as real mouse input.

Configuration constants:

| Parameter | Value |
|---|---|
| Long-press delay | `500 ms` |
| Long-press movement slop | `8 vp` |
| Tap slop | `8 vp` |
| Two-finger scroll threshold | `8 vp` accumulated |
| Pinch zoom scale step | wheel tick per ~15% scale change |
| Pointer clamping | pointer coordinates clamp into current surface bounds on `resize` |

### Recognizer state

Per touch-contact (finger) the bridge tracks: start position, start timestamp,
current position, whether pressed, whether the contact has moved beyond slop.

### Rules

| Gesture | Trigger | OpenTTD effect |
|---|---|---|
| **Tap** (one finger down→up, no >8vp move, <500ms) | release within slop/time | left click (`left down`→`left up` at release point) |
| **Drag** (one finger) | cross 8vp slop before release | left button drag: `left down` + continuous `mouse move` + `left up` on release |
| **Long-press → right click** (one finger held) | stay within 8vp slop for 500ms | `right down` + `right click`; releasing = `right up` (select). Movement beyond slop after trigger = right-drag |
| **Two-finger drag / scroll** | two contacts move together | `_cursor.v_wheel` / `h_wheel` accumulated from vertical/horizontal delta; `wheel_moved = true` |
| **Pinch** | two contacts move apart/together | scale ratio → wheel delta for zoom; `_cursor.wheel` adjusts |

### Multi-touch tracking by finger ID

- Touch contacts are keyed by **finger id** (XComponent TouchObject `id`).
- New finger down with no active drag: if already two fingers, ignore third
  (Scroll/Pinch only use exactly two contacts).
- `TouchType.Cancel` for any active contact MUST reset that contact's held
  state and any synthesized button it was emulating.

### Cancellation safety (critical)

Cancelling a multi-touch **mid-drag** must atomically reset **all** held
button/modifier state: `_left_button_down`, `_right_button_down`,
`_left_button_clicked`, `_right_button_clicked`, active gesture contacts, and
`_cursor.wheel` accumulators if the gesture owned them. No synthetic button is
left down. This is asserted by the negative test fixture `cancel-mid-drag`.

### Focus loss & surface resize

- **Window leave / focus loss** releases every held button (physical and
  synthetic) and clears all gesture contacts, so no button stays down outside
  the window. Asserted by fixture `focus-loss`.
- **Surface resize** clamps the pointer and every active contact into the new
  bounds; subsequent drags continue from the clamped position. Asserted by
  fixture `resize-during-drag`.

---

## 6. Touchpad axis & pinch

Native XComponent axis events carry scroll deltas and pinch scale:

| Axis value | Meaning | OpenTTD effect |
|---|---|---|
| vertical scroll delta (`< 0` = up) | touchpad two-finger swipe up | `_cursor.wheel--` once per accumulated notch; `v_wheel` update |
| horizontal scroll delta | touchpad horizontal swipe | `_cursor.h_wheel +=` |
| pinch scale | touchpad pinch | scale→wheel zoom (same as §5 pinch) |

Touchpad events are treated like physical mouse wheel events: they update
`_cursor.wheel`/`v_wheel`/`h_wheel` and set `wheel_moved`, then
`HandleMouseEvents()` runs. Release of the touchpad does **not** synthesize a
button click.

---

## 7. Stylus as pointer

Pen/tool (`toolType == Pen`) is treated as a **pointer**, not a touch gesture:

- Pen contact = mouse button (pen tip) → `_left_button_down`/`_left_button_clicked` on down, cleared on up.
- Pen move while in contact = left drag; pen hover = mouse hover (updates `_cursor.pos`, `_cursor.in_window`).
- Pen side/barrel button (if reported) → `_right_button_down`/`_right_button_clicked`.
- **Gesture emulation is disabled for pen contacts**: a pen is a pointer, so
  long-press / tap emulation never applies (avoids double-activation).

---

## 8. Physical mouse suppresses gesture emulation

If any physical mouse (or a connected touchpad used as a mouse) is present and
producing mouse events, the bridge disables touch-gesture emulation. Rationale:
a trackpad mouse attached to a device with a touchscreen must not produce
phantom right-clicks from long-presses. Real mouse buttons take precedence; the
touch recognizer is bypassed while `physical_mouse_active` is set.

---

## 9. Event-queue discipline (no direct actions)

**Invariant**: no raw callback may call an OpenTTD action
(`HandleKeypress`, `HandleTextInput`, `HandleMouseEvents`) directly from the
HarmonyOS dispatch thread. All input is pushed into an **input event queue**
that the OpenTTD main loop drains (`PollEvent`-equivalent). This guarantees a
single-threaded, ordered event sequence and lets the data-driven tests replay
canonical traces and compare byte-for-byte the emitted OpenTTD-call sequence.

---

## 10. Test coverage (see `scripts/harmonyos/test-input-matrix.sh`)

| Fixture | Covers |
|---|---|
| `keyboard-canonical` | full key table + modifiers + repeat + direction scan |
| `mouse-canonical` | move/press/release/wheel/hover, `_cursor` state |
| `touch-tap-drag-longpress` | one-finger tap=left, drag=left-drag, long-press=right |
| `touch-scroll-pinch` | two-finger scroll→wheel, pinch→zoom |
| `touchpad-axis` | axis scroll + pinch → wheel |
| `stylus-pointer` | pen as pointer, no gesture emulation |
| `ime-composition` | composition/commit/cancel/selection → `HandleTextInput(marked)` |
| `mouse-suppresses-gestures` | physical mouse present → no emulated gestures |
| `focus-loss` | window leave mid-drag → all held buttons released |
| `resize-during-drag` | surface resize mid-drag → pointer clamped into new bounds |
| `cancel-mid-drag` (negative) | cancel multi-touch mid-drag → all held state resets |

Each fixture is `*-in` (raw HarmonyOS events) + `*-expected` (exact OpenTTD-call
sequence). The reference mapper replays `*-in` and its output must equal
`*-expected` line-for-line.
