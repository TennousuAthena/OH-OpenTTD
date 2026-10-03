import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import entry from 'libentry.so';
import { GameAssets } from '../platform/GameAssets';
import { GamePointer } from '../platform/GamePointer';
import { BrowserBridge, BrowserLaunch } from '../bridges/BrowserBridge';

const DOMAIN: number = 0x0F00;
const TAG: string = 'OpenTTD_EntryAbility';

/**
 * EntryAbility — Stage-model host ability for the OpenTTD HarmonyOS port.
 *
 * Renders only a full-window native surface (see pages/XComponentPage.ets);
 * no OpenTTD UI is recreated in ArkUI. Native lifecycle events are forwarded
 * to the lifecycle bridge in libentry.so.
 */
export default class EntryAbility extends UIAbility {
  private windowGeneration: number = 0;
  private mainWindow: window.Window | undefined = undefined;
  private abilityForeground: boolean = false;
  private windowVisible: boolean = true;
  private nativePaused: boolean = false;
  private windowEvent = (event: window.WindowEventType): void => {
    if (event === window.WindowEventType.WINDOW_ACTIVE) {
      GamePointer.setFocused(true);
    } else if (event === window.WindowEventType.WINDOW_INACTIVE ||
      event === window.WindowEventType.WINDOW_HIDDEN ||
      event === window.WindowEventType.WINDOW_DESTROYED) {
      GamePointer.setFocused(false);
    }
  };
  private visibilityChanged = (visible: boolean): void => {
    hilog.info(DOMAIN, TAG, 'window visible: %{public}s', visible.toString());
    this.windowVisible = visible;
    this.updateNativeActivity();
  };

  private updateNativeActivity(): void {
    const paused: boolean = !this.abilityForeground || !this.windowVisible;
    GamePointer.setActive(!paused);
    if (paused === this.nativePaused) {
      return;
    }
    this.nativePaused = paused;
    if (paused) {
      entry.pause();
    } else {
      entry.resume();
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Test-env hook: when the ability stage is launched with
    // abilityStage_test_env=1, skip device-only initialisation that is not
    // available in host unit tests. The real device init is deferred to the
    // native lifecycle bridge.
    const testEnv: string = (want?.parameters?.['abilityStage_test_env'] as string) ?? '0';
    hilog.info(DOMAIN, TAG, 'onCreate testEnv=%{public}s', testEnv);
    AppStorage.setOrCreate('gameAssetsReady', false);
    AppStorage.setOrCreate('gameStartupFailed', false);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const generation: number = ++this.windowGeneration;
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    // A PC window can become invisible while its UIAbility stays foreground.
    this.mainWindow = windowStage.getMainWindowSync();
    this.mainWindow.on('windowVisibilityChange', this.visibilityChanged);
    this.mainWindow.on('windowEvent', this.windowEvent);
    GamePointer.setFocused(this.mainWindow.isFocused());
    this.windowVisible = this.mainWindow.isWindowShowing();
    this.updateNativeActivity();
    windowStage.loadContent('pages/XComponentPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load XComponentPage: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'XComponentPage loaded');
    });
    this.prepareGame(generation);
  }

  private async prepareGame(generation: number): Promise<void> {
    try {
      const root: string = await GameAssets.prepare(this.context);
      if (generation !== this.windowGeneration) {
        return;
      }
      const result: number = entry.configurePaths(root, i18n.System.getSystemLanguage());
      if (result !== 0) {
        throw new Error(`Native engine configuration failed: ${result}`);
      }
      hilog.info(DOMAIN, TAG, 'game data prepared: %{public}s', root);
      entry.onOpenUrl((url: string) => {
        if (generation !== this.windowGeneration) {
          return;
        }
        BrowserBridge.open(this.context, url).then((result: BrowserLaunch) => {
          if (result !== BrowserLaunch.ACCEPTED) {
            hilog.warn(DOMAIN, TAG, 'Unable to open browser');
          }
        });
      });
      entry.onEngineExit((code: number) => {
        if (generation !== this.windowGeneration) {
          return;
        }
        hilog.info(DOMAIN, TAG, 'engine exited: %{public}d', code);
        GamePointer.setReady(false);
        if (code === 0) {
          this.context.terminateSelf().catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'Unable to close game: %{public}s', error.message);
          });
        } else {
          AppStorage.setOrCreate('gameAssetsReady', false);
          AppStorage.setOrCreate('gameStartupFailed', true);
        }
      });
      AppStorage.setOrCreate('gameAssetsReady', true);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Unable to prepare game: %{public}s', JSON.stringify(error));
      if (generation === this.windowGeneration) {
        GamePointer.setReady(false);
        AppStorage.setOrCreate('gameStartupFailed', true);
      }
    }
  }

  onWindowStageDestroy(): void {
    GamePointer.setReady(false);
    GamePointer.setFocused(false);
    ++this.windowGeneration;
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
    if (this.mainWindow !== undefined) {
      try {
        this.mainWindow.off('windowVisibilityChange', this.visibilityChanged);
        this.mainWindow.off('windowEvent', this.windowEvent);
      } catch (error) {
        // The system may have destroyed the window before this callback.
        hilog.debug(DOMAIN, TAG, 'Window listener already released');
      }
      this.mainWindow = undefined;
    }
    entry.shutdown();
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
    this.abilityForeground = true;
    this.updateNativeActivity();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    this.abilityForeground = false;
    this.updateNativeActivity();
  }
}
