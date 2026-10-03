/**
 * Typed native declarations for libentry.so (NAPI module "entry").
 *
 * These MUST match the exports registered in entry/src/main/cpp/napi_init.cpp:
 * drawPattern / changeColor / getLifecycleState. No `any` / `unknown` — every
 * binding is explicitly typed for the ArkTS compiler.
 */

/** Lifecycle state ordinal, mirrors openttd::AppState in lifecycle_bridge.h. */
export enum AppLifecycleState {
  NONE = 0,
  CREATED = 1,
  WINDOW_LOADED = 2,
  FOREGROUND = 3,
  BACKGROUND = 4,
  DESTROYED = 5,
}

/**
 * Draws a placeholder pattern into the native surface.
 * @returns 0 on success (stub; rendering arrives with the game core).
 */
export const drawPattern: () => number;

/**
 * Changes the placeholder surface color (stub).
 * @returns 0 on success.
 */
export const changeColor: () => number;

/**
 * Returns the current lifecycle state of the native bridge.
 * @returns an AppLifecycleState ordinal.
 */
export const getLifecycleState: () => number;

/** Configure the prepared UIAbility sandbox before the surface starts the engine. */
export const configurePaths: (root: string, language?: string) => number;
export const onEngineExit: (callback: (code: number) => void) => void;
export const onOpenUrl: (callback: (url: string) => void) => void;

export interface GameTextInputState {
  session: number;
  sequence: number;
  active: boolean;
  text: string;
  left: number;
  top: number;
  width: number;
  height: number;
  caret: number;
  maxChars: number;
}
export const getTextInputState: () => GameTextInputState;
export const setTextInput: (session: number, sequence: number, text: string,
  selectionStart: number, selectionEnd: number, previewStart: number, previewEnd: number) => void;
export const textInputKey: (session: number, key: number, down: boolean) => void;

export const pause: () => void;
export const resume: () => void;
export const shutdown: () => void;

export const editBoxGainedFocus: () => void;
export const editBoxLostFocus: () => void;
export const getText: () => string;
