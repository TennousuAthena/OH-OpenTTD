/**
 * BrowserBridge — opens a system browser via startAbility, restricted to
 * the http/https URL allowlist.
 *
 * The allowlist check is performed in ArkTS (mirroring the pure-C++ policy in
 * cpp/bridge_system.{h,cpp} and docs/harmonyos/bridges.md) before any
 * startAbility call. A disallowed scheme is REJECTED and never launches.
 *
 * No thread is ever blocked: startAbilityByType is async and the promise is
 * awaited by the caller.
 */
import { common } from '@kit.AbilityKit';

export enum BrowserLaunch {
  ACCEPTED = 0,
  DISALLOWED = 1,
  EMPTY = 2,
}

export class BrowserBridge {
  /**
   * Validates a URL against the http/https allowlist (scheme case-insensitive).
   * @param url the URL to validate.
   * @returns ACCEPTED for http(s), DISALLOWED for any other scheme, EMPTY for
   *          a blank URL.
   */
  static validateUrl(url: string): BrowserLaunch {
    if (url.length === 0) {
      return BrowserLaunch.EMPTY;
    }
    const lower: string = url.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return BrowserLaunch.ACCEPTED;
    }
    return BrowserLaunch.DISALLOWED;
  }

  /**
   * Opens `url` in the system browser if and only if it is http/https.
   * @param context the UIAbility context used to start the browser ability.
   * @param url the URL to open.
   * @returns a Promise<BrowserLaunch> — ACCEPTED (and launched) when http/https,
   *          DISALLOWED/EMPTY when rejected (nothing launched).
   */
  static async open(context: common.UIAbilityContext, url: string): Promise<BrowserLaunch> {
    const verdict: BrowserLaunch = BrowserBridge.validateUrl(url);
    if (verdict !== BrowserLaunch.ACCEPTED) {
      return verdict;
    }
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url,
      });
      return BrowserLaunch.ACCEPTED;
    } catch (e) {
      // Browser unable to start is nonfatal; report DISALLOWED-style failure.
      return BrowserLaunch.DISALLOWED;
    }
  }
}
