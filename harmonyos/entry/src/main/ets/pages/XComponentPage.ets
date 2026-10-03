import { hilog } from '@kit.PerformanceAnalysisKit';
import { GamePointer } from '../platform/GamePointer';

const DOMAIN: number = 0x0F00;
const TAG: string = 'OpenTTD_XComponentPage';

/**
 * XComponentPage — hosts the full-window native surface for OpenTTD.
 *
 * The XComponent uses the "entry" native library (libentry.so) declared by
 * entry/src/main/cpp/napi_init.cpp. The library registers itself as a NAPI
 * module under the same name, and its XComponent callbacks drive the native
 * lifecycle bridge. No ArkUI game UI is rendered here.
 */
@Entry
@Component
struct XComponentPage {
  private controller: XComponentController = new XComponentController();
  @StorageLink('gameAssetsReady') private assetsReady: boolean = false;
  @StorageLink('gameStartupFailed') private startupFailed: boolean = false;

  aboutToDisappear(): void {
    GamePointer.setReady(false);
  }

  build() {
    Stack() {
      if (this.assetsReady) {
        XComponent({
          id: 'openttd-surface',
          type: XComponentType.SURFACE,
          libraryname: 'entry',
          controller: this.controller,
        })
          .width('100%')
          .height('100%')
          .focusable(true)
          .defaultFocus(true)
          .onLoad(() => {
            GamePointer.setReady(true);
            hilog.info(DOMAIN, TAG, 'surface loaded');
          })
      } else {
        Column({ space: 16 }) {
          if (this.startupFailed) {
            Text('游戏启动失败').fontSize(24).fontColor(Color.White)
            Text('请检查剩余存储空间后重新打开应用。').fontColor(Color.White)
          } else {
            LoadingProgress().width(48).height(48).color(Color.White)
            Text('正在准备游戏资源…').fontColor(Color.White)
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .onHover((hovered: boolean) => {
      GamePointer.setHovered(hovered);
    })
    .onMouse(() => {
      GamePointer.setHovered(true);
    })
  }
}
