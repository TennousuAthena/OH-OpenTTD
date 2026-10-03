/**
 * PickerBridge — DocumentViewPicker import/export via a cancellable TSFN-style
 * bridge (see cpp/bridge_picker.{h,cpp} for the pure-C++ lifecycle model).
 *
 * A single DocumentViewPicker is modal, so only one request can be in-flight at
 * a time. Results are typed and NEVER throw; a cancelled picker is NONFATAL
 * (CANCELLED). DocumentViewPicker URIs carry a one-time temp grant and must not
 * be persisted — an expired/invalid URI is reported as INVALID_URI.
 *
 * No native/UI thread is blocked: picker.select/save return promises and are
 * awaited by the caller.
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';

export enum PickerResult {
  OK = 0,
  CANCELLED = 1,
  INVALID_URI = 2,
  LOW_SPACE = 3,
  IO_ERROR = 4,
  PATH_ESCAPE = 5,
}

export class PickerCallback {
  id: number;
  result: PickerResult;
  uri: string;
  error: string;

  constructor(id: number, result: PickerResult, uri: string, error: string) {
    this.id = id;
    this.result = result;
    this.uri = uri;
    this.error = error;
  }
}

export class PickerBridge {
  private static inFlight: boolean = false;

  /**
   * Imports (selects) a document via DocumentViewPicker.
   * @param context UIAbilityContext for the picker constructor.
   * @returns a Promise<PickerCallback> — OK+uri on success, CANCELLED when the
   *          user dismisses the picker (nonfatal), or a typed failure.
   */
  static async import(context: common.UIAbilityContext): Promise<PickerCallback> {
    if (PickerBridge.inFlight) {
      return new PickerCallback(0, PickerResult.CANCELLED, '', 'picker already in flight');
    }
    PickerBridge.inFlight = true;
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await docPicker.select();
      if (uris.length === 0) {
        return new PickerCallback(0, PickerResult.CANCELLED, '', 'no document selected');
      }
      const uri: string = uris[0];
      // One-time temp grant; an invalid URI is nonfatal.
      if (uri.startsWith('file://') || uri.startsWith('datashare://')) {
        return new PickerCallback(0, PickerResult.OK, uri, '');
      }
      return new PickerCallback(0, PickerResult.INVALID_URI, uri, 'unsupported URI scheme');
    } catch (e) {
      return new PickerCallback(0, PickerResult.CANCELLED, '', 'picker cancelled or failed');
    } finally {
      PickerBridge.inFlight = false;
    }
  }

  /**
   * Exports (saves) bytes to a user-chosen document via DocumentViewPicker.
   * @param context UIAbilityContext for the picker constructor.
   * @param fileName suggested file name for the save dialog.
   * @returns a Promise<PickerCallback> — OK+uri on success, CANCELLED on dismiss.
   */
  static async export(context: common.UIAbilityContext, fileName: string): Promise<PickerCallback> {
    if (PickerBridge.inFlight) {
      return new PickerCallback(0, PickerResult.CANCELLED, '', 'picker already in flight');
    }
    PickerBridge.inFlight = true;
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [fileName];
      const uris: Array<string> = await docPicker.save(options);
      if (uris.length === 0) {
        return new PickerCallback(0, PickerResult.CANCELLED, '', 'no destination chosen');
      }
      return new PickerCallback(0, PickerResult.OK, uris[0], '');
    } catch (e) {
      return new PickerCallback(0, PickerResult.CANCELLED, '', 'picker cancelled or failed');
    } finally {
      PickerBridge.inFlight = false;
    }
  }
}
