/**
 * SessionsPage.ets — 「会话」页
 * ---------------------------------------------------------------------------
 * · GET /sessions 列出所有可见会话（标题、工作目录、更新时间、是否在跑）
 * · 点某一条 -> 写进 @Link sessionId（对话页会自动重新加载这个会话）
 * · 右上角「新建」-> POST /sessions，建好后自动选中它
 *
 * 放置位置：entry/src/main/ets/pages/SessionsPage.ets
 */
import { promptAction } from '@kit.ArkUI';
import {
  SessionInfo, SessionsData, CreateSessionData, Result,
  fetchSessions, createSession, sessionLabelOf, formatTime, asText
} from '../common/ApiClient';

@Component
export struct SessionsPage {
  /** 当前会话（与另外两个 Tab 共享）。 */
  @Link sessionId: string;
  /** 当前激活的 Tab（0 对话 / 1 模型 / 2 会话）。用来做「切到本页才加载」。 */
  @Link @Watch('onTabChanged') activeTab: number;

  /** 由父组件注入：选中会话后跳回对话页。 */
  onPicked: () => void = () => {};

  /** 是否已经加载过，避免来回切 Tab 反复请求。 */
  private loaded: boolean = false;

  @State sessions: SessionInfo[] = [];
  @State loading: boolean = true;
  @State creating: boolean = false;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    // 只有当前激活的 Tab 才发请求。这一页的 /sessions 实测要 150ms 左右
    // （返回带 projections 的完整会话摘要），没切过来就不该花这个时间。
    if (this.activeTab === 2) {
      this.load();
    }
  }

  /** 切到本页时才首次加载。 */
  onTabChanged(): void {
    if (this.activeTab === 2 && !this.loaded) {
      this.load();
    }
  }

  async load(): Promise<void> {
    this.loaded = true;
    this.loading = true;
    this.errorMsg = '';
    const res: Result<SessionsData> = await fetchSessions();
    if (!res.ok) {
      this.errorMsg = res.error;
      this.loading = false;
      return;
    }
    this.sessions = (res.data !== undefined && res.data.sessions !== undefined) ? res.data.sessions : [];
    this.loading = false;
  }

  /** 新建会话并选中它。 */
  async doCreate(): Promise<void> {
    if (this.creating) {
      return;
    }
    this.creating = true;
    const res: Result<CreateSessionData> = await createSession('');
    this.creating = false;
    if (!res.ok) {
      promptAction.showToast({ message: res.error, duration: 3000 });
      return;
    }
    // 用 asText：服务端可能给 JSON null（不是空串），直接判 !== undefined 会漏
    const newId: string = (res.data !== undefined) ? asText(res.data.sessionId) : '';
    if (newId === '') {
      promptAction.showToast({ message: '服务端没有返回新的 sessionId', duration: 3000 });
      return;
    }
    this.sessionId = newId;
    promptAction.showToast({ message: '已新建会话', duration: 1500 });
    await this.load();
    this.onPicked();
  }

  /** 选中一条会话。 */
  pick(s: SessionInfo): void {
    const id: string = asText(s.sessionId);
    if (id === '') {
      return;
    }
    this.sessionId = id;
    this.onPicked();
  }

  build() {
    Column() {
      // 顶部：结构跟对话页、模型页一致（主标题 16 粗 + 副信息 11 号，固定 72 高）
      Row() {
        Column() {
          Text('会话').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
          Text('共 ' + String(this.sessions.length) + ' 个').fontSize(11).fontColor('#94a3b8')
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('刷新')
          .fontSize(12).height(30).borderRadius(15)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#f1f5f9').fontColor('#475569')
          .margin({ right: 8 })
          .onClick(() => { this.load(); })

        Button(this.creating ? '新建中' : '新建')
          .fontSize(12).height(30).borderRadius(15)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#3b82f6').fontColor('#ffffff')
          .enabled(!this.creating)
          .onClick(() => { this.doCreate(); })
      }
      .width('100%')
      .height(72)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#ffffff')
      .border({ width: { bottom: 1 }, color: '#eef2f7' })

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color('#3b82f6')
          Text('加载会话列表…').fontSize(13).fontColor('#94a3b8').margin({ top: 8 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg !== '') {
        Column() {
          Text('加载失败').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
          Text(this.errorMsg).fontSize(12).fontColor('#dc2626')
            .textAlign(TextAlign.Start)
            .copyOption(CopyOptions.LocalDevice)
            .margin({ top: 10, left: 18, right: 18 })
          Button('重试').fontSize(14).height(36).borderRadius(18)
            .backgroundColor('#3b82f6').fontColor('#ffffff')
            .padding({ left: 22, right: 22 })
            .margin({ top: 16 })
            .onClick(() => { this.load(); })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.sessions.length === 0) {
        Column() {
          Text('还没有会话').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
          Text('点右上角「新建」开一个').fontSize(13).fontColor('#94a3b8').margin({ top: 8 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.sessions, (s: SessionInfo, index: number) => {
            ListItem() {
              Row() {
                Column() {
                  Row() {
                    Text(sessionLabelOf(s))
                      .fontSize(15)
                      .fontWeight(s.sessionId === this.sessionId ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(s.sessionId === this.sessionId ? '#3b82f6' : '#1e293b')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)

                    if (s.running === true) {
                      Row() {
                        Circle({ width: 6, height: 6 }).fill('#10b981')
                        Text('运行中').fontSize(10).fontColor('#10b981').margin({ left: 4 })
                      }.margin({ left: 8 })
                    }
                  }
                  .width('100%')

                  Text((s.cwd !== undefined && s.cwd !== '') ? s.cwd : '（无工作目录）')
                    .fontSize(11).fontColor('#94a3b8')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })

                  Row() {
                    Text(formatTime(s.updatedAt)).fontSize(11).fontColor('#94a3b8')
                    if (s.agentPreset !== undefined && s.agentPreset !== '') {
                      Text('· ' + s.agentPreset).fontSize(11).fontColor('#94a3b8').margin({ left: 6 })
                    }
                    if (s.sessionId === this.sessionId) {
                      Text('· 当前').fontSize(11).fontColor('#3b82f6').margin({ left: 6 })
                    }
                  }
                  .width('100%')
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor(s.sessionId === this.sessionId ? '#eff6ff' : '#ffffff')
              .onClick(() => { this.pick(s); })
            }
          }, (s: SessionInfo, index: number) => {
            return String(s.sessionId) + '-' + String(index);
          })
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 1, color: '#f1f5f9' })
        .backgroundColor('#ffffff')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f8fafc')
  }
}
