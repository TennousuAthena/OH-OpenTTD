import { pointer } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Keep OpenTTD's tool cursor, hiding the OS pointer only over the active game surface. */
export class GamePointer {
  private static active: boolean = false;
  private static focused: boolean = false;
  private static ready: boolean = false;
  private static hovered: boolean = false;
  private static hidden: boolean = false;

  static setActive(active: boolean): void {
    GamePointer.active = active;
    GamePointer.update();
  }

  static setFocused(focused: boolean): void {
    GamePointer.focused = focused;
    GamePointer.update();
  }

  static setReady(ready: boolean): void {
    GamePointer.ready = ready;
    if (!ready) {
      GamePointer.hovered = false;
    }
    GamePointer.update();
  }

  static setHovered(hovered: boolean): void {
    GamePointer.hovered = hovered;
    GamePointer.update();
  }

  private static update(): void {
    const hide: boolean = GamePointer.active && GamePointer.focused &&
      GamePointer.ready && GamePointer.hovered;
    try {
      if (hide === GamePointer.hidden && (!hide || !pointer.isPointerVisibleSync())) {
        return;
      }
      // Use the synchronous API so a delayed hide cannot run after focus loss.
      pointer.setPointerVisibleSync(!hide);
      GamePointer.hidden = hide && !pointer.isPointerVisibleSync();
    } catch (error) {
      hilog.warn(0x0F00, 'OpenTTD_GamePointer', 'Unable to change pointer visibility: %{public}s',
        JSON.stringify(error));
    }
  }
}
