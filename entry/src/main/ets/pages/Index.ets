/**
 * Index.ets — App 入口（左侧会话抽屉 + 右侧对话区）
 * ---------------------------------------------------------------------------
 * 交互对齐 DeepSeek 官方网页版：左边是会话栏，右边是对话。
 * 手机竖屏放不下常驻侧栏，所以改成从左侧滑出的抽屉：
 *
 *   主区    ：只有对话（ChatPage）
 *   抽屉    ：新对话 / 会话列表 / 模型入口（SessionDrawer）
 *   模型页  ：从抽屉底部进入，全屏覆盖，选完自动关
 *
 * 与旧版的区别：原来的「对话 / 模型 / 会话」三个底部 Tab 取消了 ——
 * 会话列表搬进抽屉，模型入口也搬进抽屉底部，跟网页版一致。
 */
import { ChatPage } from './ChatPage';
import { ModelPage } from './ModelPage';
import { SessionDrawer } from './SessionDrawer';
import { probeCleartext } from '../common/ApiClient';

@Entry
@Component
struct Index {
  /** 当前会话 id（对话页与抽屉共享）。 */
  @State sessionId: string = '';
  /** 当前模型显示名。 */
  @State modelLabel: string = '未选择模型';
  /** 明文 HTTP 自检结果，只在为 false 时显示警告条。 */
  @State cleartextOk: boolean = true;
  /** 抽屉是否展开。 */
  @State drawerOpen: boolean = false;
  /** 模型页是否全屏覆盖。 */
  @State showModel: boolean = false;
  /**
   * 模型页用一个固定的「当前页」值触发加载。
   * ModelPage 里 @Watch 的是 activeTab，等于 1 时才拉模型目录。
   */
  @State activeTab: number = 1;

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
          onOpenModelTab: () => { this.showModel = true; },
          // 原来的「会话」Tab 入口，现在打开左侧抽屉
          onOpenSessionsTab: () => { this.drawerOpen = true; }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      // 抽屉 + 遮罩
      if (this.drawerOpen) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => {
            this.drawerOpen = false;
          })

        SessionDrawer({
          sessionId: $sessionId,
          modelLabel: $modelLabel,
          onClose: () => { this.drawerOpen = false; },
          onPicked: () => { this.drawerOpen = false; },
          onOpenModel: () => {
            this.drawerOpen = false;
            this.showModel = true;
          }
        })
          .width('80%')
          .height('100%')
          .shadow({ radius: 18, color: '#33000000', offsetX: 6, offsetY: 0 })
      }

      // 模型页全屏覆盖
      if (this.showModel) {
        ModelPage({
          sessionId: $sessionId,
          modelLabel: $modelLabel,
          activeTab: $activeTab,
          onSelected: (provider: string, model: string) => {
            this.modelLabel = model;
          },
          onPicked: () => { this.showModel = false; }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    // 不再画到系统栏下面：交给系统留安全区，
    // 否则顶栏图标被状态栏压住、底部输入框被手势条裁掉。
  }
}
