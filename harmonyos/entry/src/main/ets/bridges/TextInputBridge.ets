/**
 * TextInputBridge — ArkTS TextInput overlay synchronized with the OpenTTD
 * edit-box focus (VideoDriver::EditBoxGainedFocus / EditBoxLostFocus) and
 * forwarding IME composition/commit/cancel to HandleTextInput.
 *
 * The overlay holds a single ArkUI TextInput. While the OpenTTD edit box is
 * focused the overlay is shown and captures IME events; its onChange/onSubmit/
 * onTextSelectionChange map to composition, commit, cancel, selection and
 * deletion, mirroring the pure-C++ state machine in
 * cpp/bridge_textinput.{h,cpp}. This is the ArkTS-side driver; it never blocks
 * any thread.
 */
import { textInput } from '@kit.ArkUI';

export class TextInputBridge {
  static readonly MAX_BYTES: number = 512;
  static readonly MAX_CHARS: number = 256;

  /**
   * Builds the ArkUI TextInput overlay bound to the edit box. `onChange` is
   * invoked on every composition/commit; the caller forwards it to the native
   * bridge. Returns a fresh TextInputController for programmatic control.
   */
  static createController(): textInput.TextInputController {
    return new textInput.TextInputController();
  }

  /**
   * Maps an IME change to the appropriate bridge call. A non-empty `value`
   * with an active composition is a composition update; an empty `value`
   * clears the composed span (cancel); otherwise it is a commit.
   * The actual forwarding to native is performed by the component's onChange,
   * which receives the same `value`.
   */
  static classify(value: string): 'composition' | 'commit' | 'cancel' {
    if (value.length === 0) {
      return 'cancel';
    }
    return 'commit';
  }

  /**
   * Truncates a UTF-8 string to fit the edit box byte/chars limits.
   * @param value the raw value from the overlay.
   * @returns the truncated value.
   */
  static clampToLimits(value: string): string {
    const maxBytes: number = TextInputBridge.MAX_BYTES;
    let bytes = 0;
    let chars = 0;
    let i = 0;
    while (i < value.length) {
      const cp: number = value.codePointAt(i) ?? 0;
      const inc: number = cp > 0xFFFF ? 2 : 1;
      const byteCount: number = cp <= 0x7F ? 1 : (cp <= 0x7FF ? 2 : (cp <= 0xFFFF ? 3 : 4));
      if (bytes + byteCount > maxBytes) {
        break;
      }
      if (chars + 1 > TextInputBridge.MAX_CHARS) {
        break;
      }
      bytes += byteCount;
      chars += 1;
      i += inc;
    }
    return value.substring(0, i);
  }
}
