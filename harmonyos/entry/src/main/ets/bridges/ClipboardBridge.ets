/**
 * ClipboardBridge — reads the system pasteboard, returning null when the
 * clipboard is unavailable (matching GetClipboardContents in
 * src/textbuf.cpp:29 which returns std::nullopt).
 *
 * Reading is async (pasteboard.getData returns a Promise); no thread blocks.
 */
import { pasteboard } from '@kit.BasicServicesKit';

export class ClipboardReadResult {
  available: boolean;
  value: string;

  constructor(available: boolean, value: string) {
    this.available = available;
    this.value = value;
  }
}

export class ClipboardBridge {
  /**
   * Reads plain text from the system pasteboard.
   * @returns a Promise<ClipboardReadResult> — available=true with the text when
   *          readable, or available=false (null equivalent) when the clipboard
   *          has no text / is unavailable / fails.
   */
  static async read(): Promise<ClipboardReadResult> {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await board.getData();
      if (data.hasType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        const text: string = data.getPrimaryText();
        return new ClipboardReadResult(true, text);
      }
      return new ClipboardReadResult(false, '');
    } catch (e) {
      return new ClipboardReadResult(false, '');
    }
  }
}
