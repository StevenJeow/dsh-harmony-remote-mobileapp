/**
 * SessionDrawer.ets — 左侧会话抽屉（对齐 DeepSeek 官方网页版的左侧栏）
 * ---------------------------------------------------------------------------
 * 官方网页是「左栏会话列表 + 右侧对话」，手机竖屏放不下常驻栏，
 * 所以做成从左侧滑出的抽屉：
 *   顶部   ：新对话 + 关闭
 *   中间   ：会话列表（标题 / 时间 / 运行中 / 当前高亮）
 *   底部   ：当前模型入口（点开模型页）
 *
 * 取代原来的「会话」Tab，交互上跟网页版对齐。
 */
import { promptAction } from '@kit.ArkUI';
import {
  SessionInfo, SessionsData, CreateSessionData, Result,
  fetchSessions, createSession, sessionLabelOf, formatTime, asText
} from '../common/ApiClient';

/** 抽屉里的扁平行：分组标题或会话。 */
interface DrawerRow {
  kind: string;
  title: string;
  seq: string;
}

@Component
export struct SessionDrawer {
  /** 当前会话（与对话页共享）。 */
  @Link sessionId: string;
  /** 当前模型显示名。 */
  @Link modelLabel: string;

  /** 关闭抽屉。 */
  onClose: () => void = () => {};
  /** 选中会话后回调（由父组件决定是否关抽屉）。 */
  onPicked: () => void = () => {};
  /** 打开模型页。 */
  onOpenModel: () => void = () => {};

  @State sessions: SessionInfo[] = [];
  @State loading: boolean = true;
  @State creating: boolean = false;
  @State errorMsg: string = '';
  @State query: string = '';
  /** 状态栏高度（px），由 EntryAbility 写入；抽屉内容要避开它。 */
  @StorageProp('safeTopPx') safeTopPx: number = 0;

  /** 搜索过滤 + 按时间分组后的扁平行（'h' 分组标题 / 's' 会话）。 */
  rows(): DrawerRow[] {
    const q: string = this.query.trim().toLowerCase();
    const out: DrawerRow[] = [];
    let lastGroup: string = '';
    for (let i = 0; i < this.sessions.length; i++) {
      const s: SessionInfo = this.sessions[i];
      const title: string = this.titleOf(s).toLowerCase();
      if (q.length > 0 && title.indexOf(q) < 0) {
        continue;
      }
      const g: string = this.groupOf(s.updatedAt !== undefined ? s.updatedAt : 0);
      if (g !== lastGroup) {
        out.push({ kind: 'h', title: g, seq: '' });
        lastGroup = g;
      }
      out.push({ kind: 's', title: this.titleOf(s), seq: asText(s.sessionId) });
    }
    return out;
  }

  /** 今天 / 昨天 / 近 7 天 / 更早 */
  private groupOf(ts: number): string {
    const now: Date = new Date();
    const today: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const t: number = (typeof ts === 'number' && ts > 0) ? ts : 0;
    if (t >= today) {
      return '今天';
    }
    if (t >= today - 86400000) {
      return '昨天';
    }
    if (t >= today - 6 * 86400000) {
      return '近 7 天';
    }
    return '更早';
  }

  /** 某条会话是否当前选中。 */
  private isCurrent(seq: string): boolean {
    return seq === this.sessionId;
  }

  /** 分组标题行。 */
  @Builder
  groupHeader(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor('#9CA3AF')
      .width('100%')
      .padding({ left: 22, right: 18, top: 14, bottom: 6 })
  }

  /** 一条会话。 */
  @Builder
  sessionRow(title: string, seq: string, time: number, running: boolean) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontWeight(this.isCurrent(seq) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isCurrent(seq) ? '#4D6BFE' : '#1F2329')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (running) {
        Circle({ width: 5, height: 5 }).fill('#10B981').margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor(this.isCurrent(seq) ? '#EEF2FF' : Color.Transparent)
    .borderRadius(12)
    .margin({ left: 10, right: 10, bottom: 2 })
  }


  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    const res: Result<SessionsData> = await fetchSessions();
    if (!res.ok || res.data === undefined) {
      this.errorMsg = res.error;
      this.loading = false;
      return;
    }
    this.sessions = (res.data.sessions !== undefined && res.data.sessions !== null) ? res.data.sessions : [];
    this.loading = false;
  }

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
    const newId: string = (res.data !== undefined) ? asText(res.data.sessionId) : '';
    if (newId === '') {
      promptAction.showToast({ message: '服务端没有返回新的 sessionId', duration: 3000 });
      return;
    }
    this.sessionId = newId;
    this.onPicked();
  }

  pick(s: SessionInfo): void {
    const id: string = asText(s.sessionId);
    if (id === '') {
      return;
    }
    this.sessionId = id;
    this.onPicked();
  }

  /** 会话标题：没有投影标题时退回短 id，绝不出现空白行。 */
  titleOf(s: SessionInfo): string {
    // 注意：sessionLabelOf 在运行时可能返回 null（旧会话没有标题投影），
    // 直接 .trim() 会抛 "Cannot read property trim of null" 把整个页面崩掉。
    const raw: string | null = sessionLabelOf(s);
    const label: string = (raw !== null && raw !== undefined) ? String(raw).trim() : '';
    if (label !== '' && label !== asText(s.sessionId)) {
      return label;
    }
    const id: string = asText(s.sessionId);
    const body: string = id.indexOf('session-') === 0 ? id.substring(8) : id;
    return '会话 ' + (body.length > 8 ? body.substring(0, 8) : body);
  }

  build() {
    Column() {
      // 顶部：新对话 + 关闭
      Row() {
        Text('新对话')
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#4D6BFE')
          .layoutWeight(1)
          .onClick(() => { this.doCreate(); })
        if (this.creating) {
          LoadingProgress().width(18).height(18).color('#4D6BFE').margin({ right: 8 })
        }
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor(['#9CA3AF'])
          .padding(6)
          .onClick(() => { this.onClose(); })
      }
      .width('100%')
      .padding({
        left: 18, right: 12, bottom: 12,
        top: 16 + (this.safeTopPx > 0 ? px2vp(this.safeTopPx) : 0)
      })

      // 搜索框
      Row() {
        Text('🔍').fontSize(14).fontColor('#9CA3AF')
        TextInput({ text: this.query, placeholder: '搜索会话' })
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .placeholderColor('#9CA3AF')
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6 })
          .onChange((v: string) => { this.query = v; })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
      .backgroundColor('#F4F5F7')
      .borderRadius(20)
      .margin({ left: 14, right: 14, bottom: 6 })

      // 会话列表（按时间分组 + 搜索过滤）
      if (this.loading) {
        Column() {
          LoadingProgress().width(24).height(24).color('#9CA3AF')
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorMsg !== '') {
        Column() {
          Text(this.errorMsg).fontSize(12).fontColor('#DC2626')
            .textAlign(TextAlign.Start)
            .margin({ left: 18, right: 18 })
          Button('重试')
            .fontSize(14).height(32).borderRadius(16)
            .backgroundColor('#F4F5F7').fontColor('#1F2329')
            .padding({ left: 18, right: 18 })
            .margin({ top: 12 })
            .onClick(() => { this.load(); })
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.rows().length === 0) {
        Column() {
          Text(this.query.length > 0 ? '没有匹配的会话' : '还没有会话')
            .fontSize(14).fontColor('#9CA3AF')
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.rows(), (r: DrawerRow) => {
            ListItem() {
              if (r.kind === 'h') {
                this.groupHeader(r.title)
              } else {
                Column() {
                  this.sessionRow(r.title, r.seq, 0, false)
                }
                .width('100%')
                .onClick(() => {
                  this.sessionId = r.seq;
                  this.onPicked();
                })
              }
            }
          }, (r: DrawerRow) => r.kind + '|' + r.seq + '|' + r.title)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      Divider().color('#EFEFEF')

      // 底部：用户行（头像 + 名称 + 模型入口）
      Row() {
        Stack() {
          Circle({ width: 30, height: 30 }).fill('#EEF2FF')
          Text('周').fontSize(14).fontColor('#4D6BFE')
        }
        Column() {
          Text('周总').fontSize(14).fontColor('#1F2329')
          Text(this.modelLabel)
            .fontSize(12).fontColor('#9CA3AF')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor(['#EFEFEF'])
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 18 })
      .onClick(() => { this.onOpenModel(); })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    // 铺满整窗，盖住状态栏和底部手势条区域，避免上下露出两条白边
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
