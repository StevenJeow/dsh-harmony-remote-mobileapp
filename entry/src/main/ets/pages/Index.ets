/**
 * Index.ets — App 入口页（底部三个 Tab 的容器）
 * ---------------------------------------------------------------------------
 * 取代原来的 ArkWeb 版首页（用 Web 组件套网页那条路已废弃）。
 * 现在完全是原生 ArkTS + ArkUI 实现，通过网络层直连电脑上的 dsh-harmony-remote 插件。
 *
 * 本文件只做两件事：
 *   1. 用 Tabs + TabContent 承载「对话 / 模型 / 会话」三个页面
 *   2. 持有三个页面共享的状态：
 *        sessionId  —— 当前会话（三个页面都要用；初值由服务端自动选择规则确定）
 *        modelLabel —— 当前模型名（对话页顶部显示，模型页切换后回写）
 *
 * 用 @State + @Link 做跨 Tab 同步：子页面改 sessionId，其他页面立刻跟着变。
 */
import { ChatPage } from './ChatPage';
import { ModelPage } from './ModelPage';
import { SessionsPage } from './SessionsPage';
import { SetupPage } from './SetupPage';
import { common } from '@kit.AbilityKit';
// 用一次网络自检，把「明文 HTTP 是否被系统放行」这个事实显示出来
import { probeCleartext } from '../common/ApiClient';
import { RuntimeConfig } from '../common/RuntimeConfig';

@Entry
@Component
struct Index {
  /**
   * 当前选中的 Tab：0 对话 / 1 模型 / 2 会话。
   * 注意：不能叫 tabIndex —— 那是 ArkUI CustomComponent 基类上的内置方法
   * （CommonMethod.tabIndex(index): CommonAttribute，用于焦点顺序），
   * 同名会报 "Property 'tabIndex' ... is not assignable to the same property in base type"。
   */
  @State activeTab: number = 0;
  /** 当前会话 id。空串表示"还没确定"，服务端会按自动选择规则帮我们挑一个。 */
  @State sessionId: string = '';
  /** 当前模型显示名（对话页顶部、模型页回显都用它） */
  @State modelLabel: string = '未选择模型';
  /** 明文 HTTP 自检结果，只在为 false 时显示警告条 */
  @State cleartextOk: boolean = true;

  /**
   * 配置是否读完（preferences 是异步的，读完之前不能决定显示哪个界面，
   * 否则会先闪一下「首次设置」页再跳到主界面）。
   */
  @State booted: boolean = false;
  /** 有没有可用的服务地址。false = 显示首次设置页。 */
  @State configured: boolean = false;

  private tabsController: TabsController = new TabsController();

  aboutToAppear(): void {
    this.cleartextOk = probeCleartext();
    this.boot();
  }

  /** 先读一次运行期配置，再决定进主界面还是进设置页。 */
  async boot(): Promise<void> {
    try {
      await RuntimeConfig.init(getContext(this) as common.Context);
      this.configured = RuntimeConfig.hasUrl();
    } catch (e) {
      // 读不出来就当没配过，让用户重新填，别把 App 卡在转圈上
      this.configured = false;
    }
    this.booted = true;
  }

  /**
   * 三个 Tab 的底栏。
   * 故意写成「零参数 @Builder + 直接读 this.activeTab」：
   * 带参数的 @Builder 在 ArkUI V1 里按值捕获，状态变了不会重绘，高亮会卡住；
   * 零参数版本能正常跟着 this.activeTab 刷新。
   */
  @Builder
  tabBarChat() {
    Column() {
      // 「对话」Tab 用本项目自己的图标（media/icon.png：蓝底 + 白色 ">" 提示符）。
      // 不用 deepseek 官方鲸鱼标 —— 见 README「品牌与图标」一节。
      // PNG 不能用 fillColor 染色，所以选中/未选中用不透明度区分；
      // 0.32 是为了让未选中的图标跟另外两个符号（#94a3b8）看着差不多重。
      Image($r('app.media.icon'))
        .width(22)
        .height(22)
        .objectFit(ImageFit.Contain)
        .opacity(this.activeTab === 0 ? 1 : 0.32)
      Text('对话').fontSize(11).margin({ top: 2 })
        .fontColor(this.activeTab === 0 ? '#3b82f6' : '#94a3b8')
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  tabBarModel() {
    Column() {
      if (this.activeTab === 1) {
        SymbolGlyph($r('sys.symbol.wand_and_stars_fill')).fontSize(22).fontColor(['#3b82f6'])
      } else {
        SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(22).fontColor(['#94a3b8'])
      }
      Text('模型').fontSize(11).margin({ top: 2 })
        .fontColor(this.activeTab === 1 ? '#3b82f6' : '#94a3b8')
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  tabBarSessions() {
    Column() {
      if (this.activeTab === 2) {
        SymbolGlyph($r('sys.symbol.clock_fill')).fontSize(22).fontColor(['#3b82f6'])
      } else {
        SymbolGlyph($r('sys.symbol.clock')).fontSize(22).fontColor(['#94a3b8'])
      }
      Text('会话').fontSize(11).margin({ top: 2 })
        .fontColor(this.activeTab === 2 ? '#3b82f6' : '#94a3b8')
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (!this.booted) {
        // 读配置的那几毫秒：给个转圈，别让用户看见半截界面
        Column() {
          LoadingProgress().width(32).height(32).color('#3b82f6')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (!this.configured) {
        // 首次进入（或配置被清空）：先填服务地址和令牌
        SetupPage({
          onDone: () => {
            this.configured = true;
            // 配置刚变，三个 Tab 页的数据都要按新地址重拉一遍
            this.sessionId = '';
          }
        })
      } else {
        // 只有系统真的拦明文 HTTP 时才出现，平时不占地方
        if (!this.cleartextOk) {
          Row() {
            Text('注意：系统未放行明文 HTTP（cleartext）。请在 module.json5 里挂载 network_config。')
              .fontSize(12)
              .fontColor('#92400e')
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .backgroundColor('#fef3c7')
        }

      // 这一层刻意不放全局品牌栏：三个 Tab 页各自已有页头，
      // 再叠一层等于连着两层标题栏，顶部被吃掉 46px，
      // 而且三个页面页头高度不一样时，切 Tab 正文会上下跳。
      // 品牌感由对话页页头左侧的小图标承担（见 ChatPage.header）。

      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        TabContent() {
          ChatPage({
            sessionId: $sessionId,
            modelLabel: $modelLabel,
            onOpenModelTab: () => { this.tabsController.changeIndex(1); },
            onOpenSessionsTab: () => { this.tabsController.changeIndex(2); },
            // 连不上时提供「改地址」的出口，回首次设置页
            onResetConfig: () => { this.configured = false; }
          })
        }
        .tabBar(this.tabBarChat())

        TabContent() {
          ModelPage({
            sessionId: $sessionId,
            modelLabel: $modelLabel,
            activeTab: $activeTab,
            onPicked: () => { this.tabsController.changeIndex(0); }
          })
        }
        .tabBar(this.tabBarModel())

        TabContent() {
          SessionsPage({
            sessionId: $sessionId,
            activeTab: $activeTab,
            onPicked: () => { this.tabsController.changeIndex(0); }
          })
        }
        .tabBar(this.tabBarSessions())
        }
        .barMode(BarMode.Fixed)
        .barHeight(56)
        .layoutWeight(1)
        .onChange((index: number) => {
          this.activeTab = index;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }
}
