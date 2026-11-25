/**
 * Index.ets — App 入口（左侧会话抽屉 + 右侧对话区）
 * ---------------------------------------------------------------------------
 * 交互对齐 DeepSeek 官方网页版：左边是会话栏，右边是对话。
 * 手机竖屏放不下常驻侧栏，所以改成从左侧滑出的抽屉。
 *
 *   主区    ：只有对话（ChatPage）
 *   抽屉    ：新对话 / 会话列表（SessionDrawer）
 *   模型选择：在对话页底部胶囊上，点开是系统下拉菜单（bindMenu）
 *
 * 与旧版的区别：
 *   ① 原来的「对话 / 模型 / 会话」三个底部 Tab 取消，会话搬进抽屉
 *   ② 模型选择不再单开页面/面板，直接在对话页胶囊上弹系统菜单
 */
import { ChatPage } from './ChatPage';
import { SessionDrawer } from './SessionDrawer';
import { probeCleartext } from '../common/ApiClient';

@Entry
@Component
struct Index {
  /** 当前会话 id（对话页与抽屉共享）。 */
  @State sessionId: string = '';
  /** 当前模型显示名。 */
  @State modelLabel: string = 'DeepSeek-V4.1-Flash';
  /** 明文 HTTP 自检结果，只在为 false 时显示警告条。 */
  @State cleartextOk: boolean = true;
  /** 抽屉是否展开。 */
  @State drawerOpen: boolean = false;

  aboutToAppear(): void {
    this.cleartextOk = probeCleartext();
  }

  /** 系统栏高度（px，由 EntryAbility 写入）。 */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 主区：只有对话
      Column() {
        if (!this.cleartextOk) {
          Row() {
            Text('注意：系统未放行明文 HTTP（cleartext）。请在 module.json5 里挂载 network_config。')
              .fontSize(12).fontColor('#92400E').layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .backgroundColor('#FEF3C7')
        }

        ChatPage({
          sessionId: $sessionId,
          modelLabel: $modelLabel,
          // 原来的「会话」Tab 入口，现在打开左侧抽屉
          onOpenSessionsTab: () => { this.drawerOpen = true; }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      // 抽屉 + 遮罩（带滑入/滑出动画）
      if (this.drawerOpen) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => {
            this.drawerOpen = false;
          })
          .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))

        SessionDrawer({
          sessionId: $sessionId,
          modelLabel: $modelLabel,
          onClose: () => { this.drawerOpen = false; },
          onPicked: () => { this.drawerOpen = false; }
        })
          .width('80%')
          .height('100%')
          .shadow({ radius: 18, color: '#33000000', offsetX: 6, offsetY: 0 })
          .transition(TransitionEffect.translate({ x: -360 })
            .animation({ duration: 260, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    // 不再画到系统栏下面：交给系统留安全区，
    // 否则顶栏图标被状态栏压住、底部输入框被手势条裁掉。
  }
}
