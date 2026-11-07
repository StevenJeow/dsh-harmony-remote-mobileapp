/**
 * ChatPage.ets — 「对话」页
 * ---------------------------------------------------------------------------
 * · 顶部：当前模型名（点它跳到模型页）、当前会话名（点它跳到会话页）
 * · 中间：消息列表（用户靠右蓝底、助手靠左灰底）+ 顶部「加载更早的消息」
 * · 底部：＋ 上传按钮 + 输入框 + 发送键
 *        发送键在任务运行中会变成红色的「停止」键，点了走 POST /cancel
 *
 * 会话 id 的来源：进页面先用空 sessionId 调 GET /status，
 * 让服务端按它的自动选择规则（显式 > 本部署自己且已 attach > 恰好一个 agent）
 * 挑一个回来，再写进 this.sessionId（@Link，会同步给另外两个 Tab）。
 */
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { MarkdownView } from '../common/MarkdownView';
import {
  ChatMessage, MessagesData, StatusData, SendData, CancelData, Result,
  UploadedFileInfo, UploadedImage, UploadData,
  ConfirmEvent, ConfirmPayload, ConfirmQuestion, ConfirmOption, ConfirmAnswer, QuestionAnswer, EventsData,
  SessionsData, SessionInfo, ModelsData, ModelSelection, SelectModelData,
  fetchStatus, fetchMessages, fetchSessions, fetchModels, selectModel,
  sendPrompt, cancelTurn, uploadFile, modelLabelOf,
  pickSessionId, pickDefaultSession, pollEvents, answerConfirm, asText, sessionLabelOf,
  DEFAULT_SESSION_CWD, DEFAULT_MODEL, DEFAULT_MODEL_PROVIDER, DEFAULT_EFFORT
} from '../common/ApiClient';

/**
 * 每页拉多少条消息。
 *
 * 实测（本机这条 86 轮的长会话）：limit=10 → 约 60ms / 6.8KB；limit=40 → 约 190ms / 22KB；
 * limit=100 → 约 600ms / 60KB。服务端是按会话日志从后往前重建，代价随条数近似线性增长。
 * 所以首屏只拉最新的一页，更早的由用户点「加载更早的消息」按需加载。
 */
const PAGE_SIZE: number = 20;

/** 发出消息后盯运行状态的轮询间隔（毫秒）。 */
const RUN_POLL_MS: number = 1500;

/** 最多盯多久（约 3 分钟）就停，避免任务卡死时无限轮询。 */
/**
 * 运行态轮询上限（次数 × RUN_POLL_MS）。
 *
 * 原来只有 120 次（≈3 分钟），任务一跑久界面就不再更新，看着像卡死 ——
 * 这也是一种"抽风"。现在放到 40 分钟，正常都由 refreshRunState 自己停（任务结束时）。
 */
const MAX_WATCH_TICKS: number = 1600;

/** 单文件上限，与插件端 MAX_UPLOAD_BYTES(32MB) 对齐。 */
const MAX_UPLOAD_CLIENT_BYTES: number = 32 * 1024 * 1024;

/** 按扩展名猜 MIME，上传时告诉服务端用。 */
function guessMime(name: string): string {
  const lower: string = name.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.md')) {
    return 'text/markdown';
  }
  if (lower.endsWith('.json')) {
    return 'application/json';
  }
  if (lower.endsWith('.csv')) {
    return 'text/csv';
  }
  return 'text/plain';
}

/** 从 picker 返回的 URI 里取出文件名。 */
function fileNameOf(uri: string): string {
  const parts: string[] = uri.split('/');
  const last: string = (parts.length > 0) ? parts[parts.length - 1] : 'upload.bin';
  try {
    return decodeURIComponent(last);
  } catch (e) {
    return last;
  }
}

@Component
export struct ChatPage {
  /** 当前会话（与另外两个 Tab 共享）。@Watch 保证别的 Tab 改了它这里会重新拉数据。 */
  @Link @Watch('onSessionChanged') sessionId: string;
  /** 当前模型显示名。 */
  @Link modelLabel: string;

  /** 由父组件注入：切到模型页 / 会话页。 */
  onOpenModelTab: () => void = () => {};
  onOpenSessionsTab: () => void = () => {};
  /** 由父组件注入：回到首次设置页（地址填错了要有地方改）。 */
  onResetConfig: () => void = () => {};

  /**
   * 消息容器：**已加载过的内容全都留在这里，只增不减**。
   *
   * 这是修复「往前翻出来的历史一两秒就没了」的关键。以前 `loadMessages`
   * 是**整个替换**成「最新一页」，而任务运行期间 `refreshRunState` 每
   * 1.5 秒就会调它一次 —— 于是刚加载上来的更早那几页立刻被抹掉。
   * 现在轮询只往这里**合并**，渲染列表从容器算出来。
   */
  @State messages: ChatMessage[] = [];
  /** 容器属于哪个会话；会话一切换就必须清空，否则两个会话的消息会混在一起。 */
  private storeSessionId: string = '';
  /** 是否已经成功往前翻过页。用来判断最新一页的 hasMore 能不能采信。 */
  private olderLoaded: boolean = false;
  /** 实际渲染的消息（已滤掉空文本），只在数据变化时算一次。 */
  @State shown: ChatMessage[] = [];
  /** 前面是否还有更早的消息（决定要不要显示「加载更早」）。 */
  @State hasMore: boolean = false;
  /** 正在加载更早的消息。 */
  @State loadingOlder: boolean = false;
  /** 加载卡在哪个阶段（只用于把转圈的文案变成线索）。 */
  @State loadStage: string = '';
  @State input: string = '';
  /**
   * 初值给 false（而不是 true）：aboutToAppear 在首次 build 之前就会跑，
   * bootstrap 第一行又把 loading 置真，所以不会闪；但万一这个组件实例的
   * aboutToAppear 没跑到（组件被销毁重建之类），页面会显示「还没有消息」
   * 而不是永远转圈 —— 转圈是一个不带任何线索的状态，能不给就不给。
   */
  @State loading: boolean = false;
  @State sending: boolean = false;
  @State running: boolean = false;
  @State errorMsg: string = '';

  /**
   * 当前会话的标题与工作目录 —— 只用于页头显示。
   *
   * 以前页头直接把 sessionId 原样打出来（`session-8c420f9f-cea4-...`），
   * 又长又看不懂，是整页最刺眼的一块。现在改成显示会话标题（跟「会话」页一致），
   * 取不到时退回短 id，绝不把整串 uuid 铺在标题行。
   */
  @State sessionTitle: string = '';
  @State sessionCwd: string = '';

  /** 已上传、等待随下一条消息一起发出的文件（显示成输入框上方的芯片）。 */
  @State pendingFiles: UploadedFileInfo[] = [];
  /** 已上传的图片；原样交给 /send 的 images。 */
  @State pendingImages: UploadedImage[] = [];
  /** 正在上传。 */
  @State uploading: boolean = false;
  /** 「停止」已按下，正在等运行态真正结束。 */
  @State cancelling: boolean = false;

  /** 列表当前是否停在底部。决定新消息到达时要不要自动跟随。 */
  private atBottom: boolean = true;
  private listScroller: Scroller = new Scroller();

  /* ---- confirm-approval：DSH 的「问人」确认 ---- */
  /** 长轮询游标（服务端事件自增号）。 */
  private eventCursor: number = 0;
  /** 长轮询循环是否在跑。 */
  private eventLoopOn: boolean = false;
  /** 已弹过框的确认 id，避免同一请求弹两次。 */
  private shownConfirms: string[] = [];

  /* ---- 确认面板（审批 / ask_user_question）的状态 ----
   * 不用 promptAction.showDialog：它只能给一排按钮，点哪个等于立刻提交，
   * 既没有多选、也没有「选完再确定」，而且字色由系统按钮的 color 决定
   * （所以之前是蓝的）。这里自绘一个面板。 */
  /** 面板是否展开。 */
  @State confirmOpen: boolean = false;
  /** 当前确认的 id（提交时要用，先存下来再关面板）。 */
  private confirmId: string = '';
  /** 'approval' | 'question'。 */
  @State confirmKind: string = '';
  /** 审批：工具名 / 理由。 */
  @State confirmTool: string = '';
  @State confirmReason: string = '';
  /** 问答：题目列表。 */
  @State confirmQuestions: ConfirmQuestion[] = [];
  /**
   * 已选项的键，形如 `q<题号>o<选项号>`。
   *
   * 必须**整体换一个新数组**：@State 只观测第一层，改写下标或 push 同一个
   * 数组不会触发重绘（勾选状态就会卡住）。另外刻意用扁平字符串而不是
   * `string[][]`，也是同一个原因——二维数组的内层改动同样观测不到。
   */
  @State confirmPicked: string[] = [];
  /**
   * 第 qi 题手输框里的内容。**故意不是 @State**：
   * TextInput 是受控的（text 绑到 freeOf(qi)），打字时组件自己已经显示新值，
   * 不需要、也不该为每个按键触发整块面板重绘；而任何一次因别的原因发生的
   * 重绘，读到的都是这里的最新值，所以输入内容不会被「回退」。
   */
  private confirmFree: string[] = [];
  /** 运行态轮询定时器；-1 表示当前没有挂起的定时器。 */
  private runTimerId: number = -1;
  private watchTicks: number = 0;
  /**
   * 是否正在轮询运行态。
   *
   * 不能靠 runTimerId 判断：一次 tick 跑完到下一次排上之间存在空窗，
   * 那时 runTimerId 是 -1，ensureRunWatch 会误以为没在轮询而再起一条链，
   * 结果两条链并发跑 —— 界面就开始抽。
   */
  private runWatching: boolean = false;
  /** loadMessages 的单飞锁：并发调用会让后到的旧响应覆盖新状态。 */
  private loadingMessages: boolean = false;
  /** 默认模型是否已套用（每个页面实例一次，避免跟手动切换打架）。 */
  private modelDefaultDone: boolean = false;
  /** 单飞期间又有调用进来：记下来，等当前这次跑完再补一次，别把请求丢掉。 */
  private loadPending: boolean = false;

  aboutToAppear(): void {
    this.bootstrap();
    // 同时开一条长轮询，接收 DSH 的审批 / ask_user_question 确认
    this.startEventLoop();
  }

  aboutToDisappear(): void {
    this.stopRunWatch();
    this.eventLoopOn = false;
    // 页面走了就把面板收掉，免得下次回来还挂着一个过期的确认
    this.confirmOpen = false;
    this.confirmPicked = [];
  }

  /** 会话被别的 Tab 换掉时重新加载。 */
  onSessionChanged(): void {
    this.loadAll();
  }

  /**
   * 首次进入：
   * 1) 用当前（可能是空串的）sessionId 调 /status，服务端会按规则自动选会话
   * 2) 把服务端定的会话、运行状态、模型名写进本地状态
   * 3) 拉消息
   */
  async bootstrap(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    // 卡住也不会永远转圈：12 秒硬超时之外再兜一层看门狗，
    // 到点就把「卡在哪一步」写出来。异常同样会被抓成文字。
    this.loadStage = '正在获取状态…';
    const watchdog: number = setTimeout(() => {
      if (this.loading) {
        this.loading = false;
        this.errorMsg = '加载超时：卡在「' + this.loadStage + '」\n'
          + '（把这段发我就能定位是哪一步没返回）';
      }
    }, 20000);
    try {
      const st: Result<StatusData> = await fetchStatus(this.sessionId);
      if (!st.ok) {
        this.errorMsg = st.error;
        return;
      }
      const d: StatusData | undefined = st.data;
      let serverSid: string = '';
      // ① 优先用配置里的「默认会话」（按工作区目录认，见 DEFAULT_SESSION_CWD）。
      //    只在会话还没定下来时生效，所以不会覆盖用户手动挑的会话。
      if (this.sessionId === '') {
        serverSid = await this.findConfiguredSession();
      }
      // ② 没配默认 / 没匹配上，才退回服务端推断与 liveAgents
      if (serverSid === '' && d !== undefined) {
        // pickSessionId：服务端推不出唯一会话（挂了多个 agent）时，从 liveAgents
        // 里挑一个默认，否则本页和模型页的会话接口会全部 409 no-session。
        serverSid = pickSessionId(d);
        this.running = (d.running === true);
        this.modelLabel = modelLabelOf(d.model);
      }
      if (serverSid !== '' && serverSid !== this.sessionId) {
        // 赋值会触发 @Watch -> onSessionChanged -> loadAll()，这里就不要再拉一次
        this.sessionId = serverSid;
        return;
      }
      // 这里不要再调 loadAll()：它会把 /status 再请求一次，而上面刚请求过。
      // 只补一次消息即可，省掉一个来回。
      await this.loadMessages(true);
      this.ensureRunWatch();
      await this.loadSessionMeta();
    } catch (e) {
      // 以前这里没有 catch：异步里抛异常没人接，loading 就永远停在 true，
      // 界面上只剩一个永远转的圈，什么线索都没有。
      this.errorMsg = '加载异常：' + String((e as Error).message);
    } finally {
      clearTimeout(watchdog);
      this.loadStage = '';
      this.loading = false;
    }
  }

  /**
   * 任务在跑就确保轮询已启动。
   *
   * 打开页面 / 切会话 / 手动刷新时，都可能遇到「任务早就在跑」的情况
   * （比如这条任务是从网页端发起的，或者 App 刚被杀掉重开）。
   * 不补这一步的话，界面会显示「运行中」，但轮询根本没开 —— 永远不更新。
   */
  ensureRunWatch(): void {
    if (this.running && !this.runWatching) {
      this.startRunWatch();
    }
  }

  /**
   * 按配置的「默认会话」找工作区匹配的会话（DEFAULT_SESSION_CWD，即那个鸿蒙工程）。
   * 找不到就返回空串，调用方继续走原有兜底。
   */
  async findConfiguredSession(): Promise<string> {
    if (DEFAULT_SESSION_CWD === '') {
      return '';
    }
    const res: Result<SessionsData> = await fetchSessions();
    if (!res.ok || res.data === undefined) {
      return '';
    }
    const list: SessionInfo[] = (res.data.sessions !== undefined) ? res.data.sessions : [];
    const hit: string = pickDefaultSession(list);
    if (hit !== '') {
      console.info('[DSH默认会话] 按工作区 ' + DEFAULT_SESSION_CWD + ' 匹配到 ' + hit);
    }
    return hit;
  }

  /**
   * 拉一次会话列表，只为拿到「当前会话叫什么」。
   *
   * 只在进入页面 / 切会话 / 点刷新时调（都在 loadAll 与 bootstrap 里），
   * 不进轮询链 —— /sessions 实测约 150ms，每 1.5 秒拉一次没有意义。
   * 失败就保持空串，页头会自动退回短 id，不影响任何功能。
   */
  async loadSessionMeta(): Promise<void> {
    if (this.sessionId === '') {
      this.sessionTitle = '';
      this.sessionCwd = '';
      return;
    }
    const res: Result<SessionsData> = await fetchSessions();
    if (!res.ok || res.data === undefined) {
      return;
    }
    const list: SessionInfo[] = (res.data.sessions !== undefined) ? res.data.sessions : [];
    for (let i = 0; i < list.length; i++) {
      if (asText(list[i].sessionId) === this.sessionId) {
        this.sessionTitle = sessionLabelOf(list[i]);
        this.sessionCwd = asText(list[i].cwd);
        return;
      }
    }
  }

  /** 页头主标题：优先会话标题，其次短 id，绝不整串 uuid。 */
  headTitle(): string {
    if (this.sessionTitle !== '') {
      return this.sessionTitle;
    }
    if (this.sessionId === '') {
      return '未选择会话';
    }
    return '会话 ' + this.shortId(this.sessionId);
  }

  /** 把 `session-xxxx…` 缩成 8 位，够区分又不会把标题行撑爆。 */
  shortId(id: string): string {
    const body: string = id.indexOf('session-') === 0 ? id.substring(8) : id;
    return body.length > 8 ? body.substring(0, 8) : body;
  }

  /**
   * 套用默认模型（deepseek-flash + high，见 ApiClient 顶部常量）。
   *
   * 每个页面实例只做一次；当前**已经是**默认就不写，避免无谓请求。
   * 效果就是「每次连上默认是 flash/high」，但你在模型页手动切换后不会被立刻改回去。
   */
  async applyModelDefault(): Promise<void> {
    if (this.modelDefaultDone || this.sessionId === '' || DEFAULT_MODEL === '') {
      return;
    }
    this.modelDefaultDone = true;
    const res: Result<ModelsData> = await fetchModels(this.sessionId);
    if (!res.ok || res.data === undefined) {
      return;
    }
    const cur: ModelSelection | undefined = res.data.current;
    const same: boolean = (cur !== undefined
      && cur.provider === DEFAULT_MODEL_PROVIDER
      && cur.model === DEFAULT_MODEL
      && (DEFAULT_EFFORT === '' || cur.reasoningEffort === DEFAULT_EFFORT));
    if (same) {
      return;
    }
    const out: Result<SelectModelData> = await selectModel(
      this.sessionId, DEFAULT_MODEL_PROVIDER, DEFAULT_MODEL, DEFAULT_EFFORT);
    if (out.ok) {
      this.modelLabel = modelLabelOf({ provider: DEFAULT_MODEL_PROVIDER, model: DEFAULT_MODEL });
      console.info('[DSH默认模型] 已套用 ' + DEFAULT_MODEL + ' / ' + DEFAULT_EFFORT);
    }
  }

  /** 刷新状态 + 消息。 */
  async loadAll(): Promise<void> {
    try {
      const st: Result<StatusData> = await fetchStatus(this.sessionId);
      if (st.ok && st.data !== undefined) {
        this.running = (st.data.running === true);
        this.modelLabel = modelLabelOf(st.data.model);
        // 还没有会话时再补挑一次（例如 App 先起来、agent 之后才挂上）
        if (this.sessionId === '') {
          const sid: string = pickSessionId(st.data);
          if (sid !== '') {
            this.sessionId = sid;   // 触发 @Watch -> onSessionChanged -> loadAll()
            return;
          }
        }
      }
      await this.loadMessages(true);
      await this.applyModelDefault();   // 会话确定后套用默认模型（flash/high）
      await this.loadSessionMeta();     // 页头要显示会话标题
      this.ensureRunWatch();
    } catch (e) {
      // 这个函数是被 @Watch / 定时器调起来的，抛出去没人接，会静默消失
      this.errorMsg = '刷新异常：' + String((e as Error).message);
    }
  }

  /**
   * 拉「最新一页」并重算渲染列表。
   * 首次进入、点刷新、切换会话、发完消息之后都走这里。
   */
  /**
   * 拉「最新一页」并重算渲染列表。
   * @param autoScroll 内容真的变多时是否自动滚到底部。
   *                   轮询时靠它避免把正在翻历史的用户每 1.5 秒拽回底部。
   */
  async loadMessages(autoScroll: boolean = true): Promise<void> {
    // 单飞：轮询、切会话、发送后、刷新都可能同时调它。并发跑的话，
    // 先发的请求后回来就会把已经显示的新消息改回旧状态（界面抽一下）。
    // 但不能直接丢掉这次调用 —— 切会话时若正好撞上轮询在飞，消息就永远不更新了
    // （没任务在跑时没有轮询兜底）。所以记一个 pending，等这次跑完立刻补跑一次。
    if (this.loadingMessages) {
      this.loadPending = true;
      return;
    }
    this.loadingMessages = true;
    try {
      this.loadStage = '正在拉取消息…';
      const res: Result<MessagesData> = await fetchMessages(this.sessionId, PAGE_SIZE, 0);
    if (!res.ok) {
      this.errorMsg = res.error;
      return;
    }
    this.errorMsg = '';
    // 换会话了：容器必须清空。以前靠「整个替换」天然做到，现在改成合并，
    // 不显式清就会把上一个会话的消息留在里面。
    if (this.storeSessionId !== this.sessionId) {
      this.storeSessionId = this.sessionId;
      this.messages = [];
      this.hasMore = false;
      this.olderLoaded = false;
    }
    const seqBefore: number = this.lastSeqOf(this.messages);
    // ★ 合并而不是替换：轮询每 1.5 秒来一次，替换会把用户翻出来的历史抹掉
    this.mergeMessages((res.data !== undefined && res.data.messages !== undefined) ? res.data.messages : []);
    // hasMore 的含义是「比容器里最老的那条还更早的还有吗」。最新一页返回的
    // hasMore 只说明「比这一页更早的还有」—— 容器里已经装了更早的页时不能
    // 采信它，否则每 1.5 秒一次的轮询会把「加载更早」按钮错误地藏掉。
    // 只有 loadOlder 那次请求（窗口正好截止在容器最老一条）才是权威的。
    const pageHasMore: boolean = (res.data !== undefined && res.data.hasMore === true);
    if (!pageHasMore) {
      this.hasMore = false;
    } else if (!this.olderLoaded) {
      this.hasMore = true;
    }
    this.shown = this.filterVisible(this.messages);
    // 注意：不能拿数组长度判断"有没有新内容" —— 容器里还可能有更早的页，
    // 长度变化不代表末尾有新消息。要比最后一条的 seq。
    const seqAfter: number = this.lastSeqOf(this.messages);
    if (autoScroll && seqAfter !== seqBefore && this.atBottom) {
      this.scrollToBottom();
    }
    } finally {
      // 任何分支（含中途 return、抛异常）都要解锁，否则后面永远拉不到消息
      this.loadingMessages = false;
      if (this.loadPending) {
        this.loadPending = false;
        this.loadMessages(autoScroll);   // 补跑一次（此时锁已释放，不会递归下去）
      }
    }
  }

  /** 一条消息的 seq（缺省按 0 处理，方便比较）。 */
  seqOf(m: ChatMessage): number {
    return (m.seq !== undefined) ? m.seq : 0;
  }

  /**
   * 把一批消息并进容器：按 seq 去重、保持升序，同一条以新到的为准
   * （运行中同一个 seq 的正文会被追加更新）。
   *
   * 故意不用 Array.sort：两边本来就是升序，逐个插入 + 查重就够，
   * 数据量是几十到几百条，也不值得为它冒编译风险。
   */
  mergeMessages(incoming: ChatMessage[]): void {
    const out: ChatMessage[] = this.messages.slice();
    for (let i = 0; i < incoming.length; i++) {
      const m: ChatMessage = incoming[i];
      const s: number = this.seqOf(m);
      let settled: boolean = false;
      let insertAt: number = out.length;
      for (let k = 0; k < out.length; k++) {
        const ks: number = this.seqOf(out[k]);
        if (s !== 0 && ks === s) {
          out[k] = m;
          settled = true;
          break;
        }
        if (s !== 0 && ks > s) {
          insertAt = k;
          break;
        }
      }
      if (!settled) {
        out.splice(insertAt, 0, m);
      }
    }
    this.messages = out;
  }

  /** 一批消息里最大的 seq。 */
  lastSeqOf(list: ChatMessage[]): number {
    let max: number = -1;
    for (let i = 0; i < list.length; i++) {
      const s: number | undefined = list[i].seq;
      if (s !== undefined && s > max) {
        max = s;
      }
    }
    return max;
  }

  /** 已加载消息里最小的 seq（往前翻页的游标）。 */
  oldestSeq(): number {
    let min: number = 0;
    for (let i = 0; i < this.messages.length; i++) {
      const s: number | undefined = this.messages[i].seq;
      if (s !== undefined && (min === 0 || s < min)) {
        min = s;
      }
    }
    return min;
  }

  /** 往前加载更早的一页，拼到列表前面。 */
  async loadOlder(): Promise<void> {
    if (this.loadingOlder || !this.hasMore) {
      return;
    }
    const oldest: number = this.oldestSeq();
    if (oldest <= 0) {
      this.hasMore = false;
      return;
    }
    this.loadingOlder = true;
    try {
      const res: Result<MessagesData> = await fetchMessages(this.sessionId, PAGE_SIZE, oldest);
      if (!res.ok) {
        promptAction.showToast({ message: res.error, duration: 3000 });
        return;
      }
      const older: ChatMessage[] = (res.data !== undefined && res.data.messages !== undefined)
        ? res.data.messages : [];

      // 合并进容器（内部按 seq 去重）。去重这点很重要：后端还没支持 beforeSeq 时
      // （插件改了 lib/index.js 但 dsh 没重启，ESM 缓存会继续跑旧代码）返回的会是
      // 同一页，靠去重就能识别出来，不会无限重复插入。
      const beforeLen: number = this.messages.length;
      this.mergeMessages(older);
      if (this.messages.length === beforeLen) {
        this.hasMore = false;
        promptAction.showToast({
          message: '没有更早的消息了（若后端未支持分页，需要完整重启 dsh 才生效）',
          duration: 3500
        });
        return;
      }
      this.hasMore = (res.data !== undefined && res.data.hasMore === true);
      this.olderLoaded = true;
      this.shown = this.filterVisible(this.messages);
    } catch (e) {
      promptAction.showToast({ message: '加载更早失败：' + String((e as Error).message), duration: 3000 });
    } finally {
      // 放 finally 里：中途抛异常时这个圈也必须停
      this.loadingOlder = false;
    }
  }

  /** 跳过空文本的消息（纯工具调用的步骤没有可读正文）。 */
  filterVisible(list: ChatMessage[]): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (let i = 0; i < list.length; i++) {
      const m: ChatMessage = list[i];
      const t: string = (m.text !== undefined) ? m.text : '';
      if (t.trim() !== '') {
        out.push(m);
      }
    }
    return out;
  }

  /** 列表滚到底部（等一帧，让新消息先完成布局）。 */
  scrollToBottom(): void {
    setTimeout(() => {
      try {
        this.listScroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 列表还没渲染完就滚会抛错，忽略即可
      }
    }, 120);
  }

  /**
   * 长轮询循环：接收 DSH 的确认请求（审批框 / ask_user_question）。
   *
   * 服务端会把请求挂住最多 25 秒，事件一到立刻返回，所以延迟接近实时。
   * 出错就歇 3 秒重试 —— 断线时既不会卡死界面，也不会疯狂重连。
   */
  async startEventLoop(): Promise<void> {
    if (this.eventLoopOn) {
      return;
    }
    this.eventLoopOn = true;
    while (this.eventLoopOn) {
      const res: Result<EventsData> = await pollEvents(this.eventCursor);
      if (!this.eventLoopOn) {
        break;
      }
      if (!res.ok || res.data === undefined) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => { resolve(); }, 3000);
        });
        continue;
      }
      const cursor: number | undefined = res.data.cursor;
      if (cursor !== undefined) {
        this.eventCursor = cursor;
      }
      const events: ConfirmEvent[] = (res.data.events !== undefined) ? res.data.events : [];
      for (let i = 0; i < events.length; i++) {
        const ev: ConfirmEvent = events[i];
        // 只处理新确认；confirm_resolved 等未知类型直接忽略（兼容旧端）
        if (ev.type === 'confirm_request') {
          this.openConfirm(ev);
        }
      }
    }
  }

  /** 收到一条确认请求 -> 展开自绘面板。 */
  openConfirm(ev: ConfirmEvent): void {
    const id: string = (ev.id !== undefined) ? ev.id : '';
    if (id === '' || this.shownConfirms.indexOf(id) >= 0) {
      return;
    }
    // 上一个确认还占着面板时不来抢：抢掉会把用户已经勾好的选择冲掉。
    // 这条照旧留在服务端 pending、电脑端的框也还在，不影响任何一端。
    if (this.confirmOpen) {
      return;
    }
    this.shownConfirms.push(id);

    const p: ConfirmPayload | undefined = ev.payload;
    this.confirmId = id;
    this.confirmPicked = [];
    this.confirmFree = [];
    this.confirmKind = (ev.kind === 'approval') ? 'approval' : 'question';
    if (ev.kind === 'approval') {
      this.confirmTool = (p !== undefined && p.toolName !== undefined && p.toolName !== '') ? p.toolName : '未知';
      this.confirmReason = (p !== undefined && p.reason !== undefined) ? p.reason : '';
      this.confirmQuestions = [];
    } else {
      this.confirmTool = '';
      this.confirmReason = '';
      this.confirmQuestions = (p !== undefined && p.questions !== undefined) ? p.questions : [];
    }
    this.confirmOpen = true;
  }

  /**
   * 收起面板并且**什么都不回填**。
   *
   * 这是刻意的：审批那侧回 'cancelled' 等于真的把审批取消掉（不是「先放着」），
   * 保持沉默才能让电脑端的原生框继续接管。
   */
  dismissConfirm(): void {
    this.confirmOpen = false;
    this.confirmPicked = [];
    this.confirmFree = [];
    promptAction.showToast({ message: '已关闭，可在电脑端继续作答', duration: 2500 });
  }

  /* ---- 面板渲染要用的小取数函数 ----
   * build/@Builder 体里不声明局部变量（ArkTS 的 UI 描述里那样不安全），
   * 所以一律走这类小方法。另外 ArkTS 的类型收窄对「下标访问」不生效，
   * undefined 全部在这里挡掉。 */

  panelTitle(): string {
    return (this.confirmKind === 'approval') ? 'DSH 需要你的确认' : 'DSH 想问你';
  }

  optsOf(q: ConfirmQuestion): ConfirmOption[] {
    return (q.options !== undefined) ? q.options : [];
  }

  labelOf(opt: ConfirmOption): string {
    return (opt.label !== undefined) ? opt.label : '?';
  }

  descOf(opt: ConfirmOption): string {
    return (opt.description !== undefined) ? opt.description : '';
  }

  questionOf(q: ConfirmQuestion): string {
    return (q.question !== undefined) ? q.question : '';
  }

  headerOf(q: ConfirmQuestion): string {
    return (q.header !== undefined) ? q.header : '';
  }

  isMulti(q: ConfirmQuestion): boolean {
    return q.multiSelect === true;
  }

  hasDetail(q: ConfirmQuestion): boolean {
    return q.detail !== undefined && q.detail !== '';
  }

  detailOf(q: ConfirmQuestion): string {
    return (q.detail !== undefined) ? q.detail : '';
  }

  /** 题目没有选项时给一个手输框（DSH 的 custom 字段就是给这种自由回答用的）。 */
  needsFreeText(q: ConfirmQuestion): boolean {
    return this.optsOf(q).length === 0;
  }

  /** 自定义回答那一行的小标题。 */
  customLabel(q: ConfirmQuestion): string {
    return this.needsFreeText(q) ? '回答' : '其他（也可以自己写）';
  }

  /** 自定义回答输入框的占位提示。 */
  customHint(q: ConfirmQuestion): string {
    if (this.needsFreeText(q)) {
      return '直接输入回答…';
    }
    return this.isMulti(q) ? '不在上面选项里？可以补在这里' : '选上面，或者直接写在这里';
  }

  /* ---- 勾选 ---- */

  /** 选项键：`q<题号>o<选项号>`。 */
  pickKey(qi: number, oi: number): string {
    return 'q' + String(qi) + 'o' + String(oi);
  }

  isPicked(qi: number, oi: number): boolean {
    return this.confirmPicked.indexOf(this.pickKey(qi, oi)) >= 0;
  }

  /**
   * 点一个选项。
   * 多选：切换（可以反悔、可以取消）。
   * 单选：同一题里替换掉原来那个；再点一次则是取消 —— 不会「点了就提交、选错没法改」。
   */
  togglePick(qi: number, oi: number, multi: boolean): void {
    const key: string = this.pickKey(qi, oi);
    const wasPicked: boolean = this.confirmPicked.indexOf(key) >= 0;
    const sameQuestion: string = 'q' + String(qi) + 'o';
    const next: string[] = [];
    for (let i = 0; i < this.confirmPicked.length; i++) {
      const k: string = this.confirmPicked[i];
      if (k === key) {
        continue;
      }
      if (!multi && k.indexOf(sameQuestion) === 0) {
        continue;
      }
      next.push(k);
    }
    if (!wasPicked) {
      next.push(key);
    }
    // 必须整体换一个新数组：@State 只观测第一层，改下标 / push 不会触发重绘，
    // 勾选状态就会卡住不动。
    this.confirmPicked = next;
    // 单选：刚勾上一个选项，就把这一题的自定义回答清掉（两者互斥）。
    // 多选时允许「勾几项 + 再补一句」，所以不清。
    if (!multi && !wasPicked) {
      this.setFree(qi, '');
    }
  }

  /** 第 qi 题手输框里的内容。 */
  freeOf(qi: number): string {
    return (this.confirmFree[qi] !== undefined) ? this.confirmFree[qi] : '';
  }

  setFree(qi: number, value: string): void {
    if (qi < 0 || qi >= this.confirmQuestions.length) {
      return;
    }
    const next: string[] = [];
    for (let i = 0; i < this.confirmQuestions.length; i++) {
      next.push(this.freeOf(i));
    }
    next[qi] = value;
    this.confirmFree = next;
    // 单选题的 custom 与 selected 是互斥的（DSH 的 matchesQuestions 就是这么
    // 校验的）：一打字就把这一题的勾选清掉。界面上勾也真的会消失，
    // 用户看得见这个联动，不会以为两个都生效了。
    if (!this.isMulti(this.confirmQuestions[qi]) && value.trim() !== '') {
      const kept: string[] = [];
      const sameQuestion: string = 'q' + String(qi) + 'o';
      for (let i = 0; i < this.confirmPicked.length; i++) {
        const k: string = this.confirmPicked[i];
        if (k.indexOf(sameQuestion) !== 0) {
          kept.push(k);
        }
      }
      this.confirmPicked = kept;
    }
  }

  /* ---- 提交 ---- */

  /** 审批：直接给结局（二选一，不需要「先选再确定」）。 */
  async answerApproval(outcome: string): Promise<void> {
    const id: string = this.confirmId;
    this.confirmOpen = false;
    await this.reportConfirm(id, { outcome: outcome });
  }

  /** 问答：把勾选收成 answers 再提交。 */
  async submitConfirm(): Promise<void> {
    const id: string = this.confirmId;
    const answers: QuestionAnswer[] = [];
    for (let qi = 0; qi < this.confirmQuestions.length; qi++) {
      const q: ConfirmQuestion = this.confirmQuestions[qi];
      const qid: string = (q.id !== undefined) ? q.id : '';
      if (qid === '') {
        continue;
      }
      const opts: ConfirmOption[] = this.optsOf(q);
      const picked: string[] = [];
      for (let oi = 0; oi < opts.length; oi++) {
        if (this.isPicked(qi, oi)) {
          const opt: ConfirmOption = opts[oi];
          if (opt.label !== undefined) {
            picked.push(opt.label);
          }
        }
      }
      const free: string = this.freeOf(qi).trim();
      // 单选题的 custom 与 selected 是互斥的（DSH 的 matchesQuestions 就是这么
      // 校验的）：万一两个都非空，以手输内容为准。多选时两者可以并存 ——
      // 勾几项 + 再补一句说明是合法答案。
      const selected: string[] = (!this.isMulti(q) && free !== '') ? [] : picked;
      if (selected.length === 0 && free === '') {
        continue;
      }
      // 字段名必须是 `id`（DSH 的 AskUserQuestionAnswerItem 就叫 id，
      // 且是 dsh-tool-ask-user output schema 里的 required string）。
      const item: QuestionAnswer = { id: qid, selected: selected };
      if (free !== '') {
        item.custom = free;
      }
      answers.push(item);
    }

    if (answers.length === 0) {
      promptAction.showToast({ message: '还没选，先勾一个再点「确定」', duration: 2000 });
      return;
    }
    this.confirmOpen = false;
    this.confirmPicked = [];
    this.confirmFree = [];
    await this.reportConfirm(id, { answers: answers });
  }

  /** 回填答案并汇报结果。 */
  async reportConfirm(id: string, answer: ConfirmAnswer): Promise<void> {
    const out: Result<EventsData> = await answerConfirm(id, answer);
    if (!out.ok) {
      // 409「已被处理」不是错误：另一端（电脑端原生框）先答了
      const already: boolean = out.error.indexOf('已被处理') >= 0 || out.error.indexOf('already-resolved') >= 0;
      promptAction.showToast({
        message: already ? '这条确认已被处理（另一端先答了）' : ('回填失败：' + out.error),
        duration: 3000
      });
    }
  }

  /** 发送一条指令（可携带已上传的附件与图片）。 */
  async doSend(): Promise<void> {
    const text: string = this.input.trim();
    const refs: string[] = [];
    for (let i = 0; i < this.pendingFiles.length; i++) {
      const rel: string | undefined = this.pendingFiles[i].relPath;
      if (rel !== undefined && rel !== '') {
        refs.push(rel);
      }
    }
    if (text === '' && refs.length === 0 && this.pendingImages.length === 0) {
      return;
    }
    if (this.sending) {
      return;
    }
    this.sending = true;
    const res: Result<SendData> = await sendPrompt(this.sessionId, text, 'followup', refs, this.pendingImages);
    this.sending = false;
    if (!res.ok) {
      promptAction.showToast({ message: res.error, duration: 3000 });
      return;
    }
    // 发出去的附件清空；输入框也清空
    this.input = '';
    this.pendingFiles = [];
    this.pendingImages = [];
    // 立刻刷一次能看到自己刚发的那条
    await this.loadMessages();
    // 开始盯运行态：running=true 就把发送键切成「停止」
    this.startRunWatch();
  }

  /** 点击「停止」：请求取消当前回合，然后等运行态真正结束。 */
  async doCancel(): Promise<void> {
    if (this.cancelling) {
      return;
    }
    this.cancelling = true;
    const res: Result<CancelData> = await cancelTurn(this.sessionId);
    if (!res.ok) {
      this.cancelling = false;
      promptAction.showToast({ message: res.error, duration: 3000 });
      return;
    }
    promptAction.showToast({ message: '已请求停止', duration: 1500 });
    // 立刻问一次服务端：idle 了就马上恢复「发送」键，否则继续轮询等它收尾
    const st: Result<StatusData> = await fetchStatus(this.sessionId);
    if (st.ok && st.data !== undefined && st.data.running !== true) {
      this.running = false;
      this.cancelling = false;
      await this.loadMessages();
      return;
    }
    this.startRunWatch();
  }

  /**
   * 开始轮询运行态（发送之后 / 停止之后都用它）。
   *
   * 用「一次跑完再排下一次」的自调度，**不用 setInterval**：
   * refreshRunState 里有 await，请求一慢 setInterval 就会让多次轮询叠在一起并发跑，
   * 响应乱序回来时界面会先显示新消息再被旧响应改回去 —— 看起来就是"抽风"。
   */
  startRunWatch(): void {
    if (this.runWatching) {
      return;
    }
    this.runWatching = true;
    this.watchTicks = 0;
    // 不等第一个 tick，先问一次
    this.runPoll();
  }

  /** 跑一次轮询，完了再排下一次（绝不并发）。 */
  private runPoll(): void {
    this.refreshRunState().then(() => {
      if (!this.runWatching) {
        return;
      }
      this.watchTicks = this.watchTicks + 1;
      if (this.watchTicks > MAX_WATCH_TICKS) {
        // 兜底：任务跑得极久时不再无限轮询（正常情况下 refreshRunState 会先停）
        this.cancelling = false;
        this.stopRunWatch();
        return;
      }
      this.runTimerId = setTimeout(() => {
        this.runTimerId = -1;
        this.runPoll();
      }, RUN_POLL_MS);
    });
  }

  stopRunWatch(): void {
    this.runWatching = false;
    if (this.runTimerId !== -1) {
      clearTimeout(this.runTimerId);
      this.runTimerId = -1;
    }
  }

  /**
   * 查一次运行态。
   *
   * 两个关键行为：
   *   ① 运行期间**也要拉消息**。dsh 的回复是按 step 追加 assistant/message 事件的，
   *      如果只在结束时拉一次，长任务跑几十秒期间界面会完全静止 —— 看起来像卡死。
   *   ② running 由 true 变 false 的那一刻再补拉一次（拿到最终回复），然后停止轮询。
   */
  async refreshRunState(): Promise<void> {
    const st: Result<StatusData> = await fetchStatus(this.sessionId);
    if (!st.ok || st.data === undefined) {
      return;
    }
    if (st.data.model !== undefined) {
      this.modelLabel = modelLabelOf(st.data.model);
    }
    const nowRunning: boolean = (st.data.running === true);
    const justFinished: boolean = this.running && !nowRunning;
    this.running = nowRunning;

    // ★ 运行中持续刷新 + 结束那一刻补刷
    if (nowRunning || justFinished) {
      await this.loadMessages(true);
    }

    if (!nowRunning) {
      this.cancelling = false;
      this.stopRunWatch();
    }
  }

  /** 「＋」：选文件 -> 读字节 -> 上传到会话工作区。 */
  async pickAndUpload(): Promise<void> {
    if (this.uploading) {
      return;
    }
    let uris: string[] = [];
    try {
      const abilityCtx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(abilityCtx);
      uris = await documentPicker.select();
    } catch (e) {
      // 用户在系统选择器里点了取消 —— 这不是错误，安静返回
      return;
    }
    if (uris === undefined || uris.length === 0) {
      return;
    }
    this.uploading = true;
    for (let i = 0; i < uris.length; i++) {
      await this.uploadOne(uris[i]);
    }
    this.uploading = false;
  }

  /**
   * 读一个 picker URI 的字节并上传。
   *
   * 关键：鸿蒙 http **不会**自己去读 uri 指向的文件 —— 只把 uri 字符串递给它，
   * 请求体就是空的（后端就会报 empty-body）。所以必须在这里真的把内容读成字节，
   * 而且每一步都校验：读不到就明确报错，绝不把空 body 发出去。
   */
  async uploadOne(uri: string): Promise<void> {
    let file: fileIo.File | null = null;
    try {
      const name: string = fileNameOf(uri);
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);

      // 1) 取文件大小：先按 fd 取（标准做法）；某些 provider 取不到时退回按 uri 取
      let size: number = -1;
      try {
        size = fileIo.statSync(file.fd).size;
      } catch (statErr) {
        size = -1;
      }
      if (size <= 0) {
        try {
          const byUri: number = fileIo.statSync(uri).size;
          console.info('[DSH上传] statSync(fd)=' + String(size) + '，改 statSync(uri)=' + String(byUri));
          size = byUri;
        } catch (statErr2) {
          console.error('[DSH上传] 两种 statSync 都失败: ' + uri);
        }
      }
      console.info('[DSH上传] ' + name + ' 声明大小=' + String(size) + ' B');
      if (size <= 0) {
        promptAction.showToast({
          message: '读不到文件大小（可能是云文件或没有读取权限）：' + name,
          duration: 4000
        });
        return;
      }
      if (size > MAX_UPLOAD_CLIENT_BYTES) {
        promptAction.showToast({ message: '文件超过 32MB，暂不支持：' + name, duration: 3000 });
        return;
      }

      // 2) 真的把内容读进内存
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      console.info('[DSH上传] 实际读到 ' + String(read) + ' / ' + String(size) + ' B');
      if (read <= 0) {
        promptAction.showToast({ message: '文件内容读到 0 字节，无法上传：' + name, duration: 4000 });
        return;
      }
      // readSync 可能少读，按实际长度截断，避免尾部留下未初始化的字节
      const content: ArrayBuffer = (read === size) ? buffer : buffer.slice(0, read);

      const res: Result<UploadData> = await uploadFile(this.sessionId, name, guessMime(name), content);
      if (!res.ok) {
        promptAction.showToast({ message: res.error, duration: 4000 });
        return;
      }
      const data: UploadData | undefined = res.data;
      if (data === undefined || data.file === undefined) {
        promptAction.showToast({ message: '上传成功但服务端没返回文件信息', duration: 3000 });
        return;
      }
      this.pendingFiles = this.pendingFiles.concat([data.file]);
      if (data.kind === 'image' && data.image !== undefined && data.image !== null) {
        this.pendingImages = this.pendingImages.concat([data.image]);
      }
      const kindLabel: string = (data.kind === 'image') ? '图片' : '文件';
      promptAction.showToast({
        message: kindLabel + '已上传：' + (data.file.name !== undefined ? data.file.name : name),
        duration: 2000
      });
    } catch (e) {
      const err = e as Error;
      const msg: string = (err !== undefined && err.message !== undefined) ? err.message : String(e);
      promptAction.showToast({ message: '读取文件失败：' + msg, duration: 3500 });
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          // 关不上也不影响主流程
        }
      }
    }
  }

  /** 移除一个待发送附件（图片列表按名字同步移除）。 */
  removePending(index: number): void {
    if (index < 0 || index >= this.pendingFiles.length) {
      return;
    }
    const target: UploadedFileInfo = this.pendingFiles[index];
    const nextFiles: UploadedFileInfo[] = [];
    for (let i = 0; i < this.pendingFiles.length; i++) {
      if (i !== index) {
        nextFiles.push(this.pendingFiles[i]);
      }
    }
    const nextImages: UploadedImage[] = [];
    for (let i = 0; i < this.pendingImages.length; i++) {
      const img: UploadedImage = this.pendingImages[i];
      if (!(img.name !== undefined && img.name === target.name)) {
        nextImages.push(img);
      }
    }
    this.pendingFiles = nextFiles;
    this.pendingImages = nextImages;
  }

  /**
   * 页头。
   *
   * 排版原则（三个页面统一，见 ModelPage / SessionsPage 的页头）：
   *   第一行 主标题 —— 对话页是「这是哪个会话」，会话页是「会话」，模型页是「模型」
   *   第二行 副信息 —— 11 号灰字，对话页放当前模型（可点进模型页）
   * 固定高 72：切 Tab 时内容区的起点不会上下跳，这一点以前是乱的
   * （品牌栏 46 + 对话页 60 / 模型页 60+档位栏 / 会话页 60，三页各不相同）。
   */
  @Builder
  header() {
    Column() {
      // 第一行：会话标题（点击 -> 会话页）
      Row() {
        Row() {
          Image($r('app.media.icon'))
            .width(18)
            .height(18)
            .objectFit(ImageFit.Contain)
          Text(this.headTitle())
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 8 })
          // 「可以去下一层」的提示：以前整块可点但没有任何暗示
          Text('›').fontSize(17).fontColor('#cbd5e1').margin({ left: 4 })
        }
        .layoutWeight(1)
        .onClick(() => { this.onOpenSessionsTab(); })

        if (this.running) {
          Row() {
            Circle({ width: 6, height: 6 }).fill('#10b981')
            Text('运行中').fontSize(11).fontColor('#10b981').margin({ left: 4 })
          }.margin({ right: 8 })
        }

        // 「停止」在底部发送键上（任务运行中发送键会变成停止键），这里只留刷新
        Button('刷新')
          .fontSize(12)
          .height(30)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#f1f5f9')
          .fontColor('#475569')
          .borderRadius(15)
          .onClick(() => {
            this.loadAll();
          })
      }
      .width('100%')

      // 第二行：当前模型（点击 -> 模型页）+ 右侧弱化的工作目录
      Row() {
        Text('模型 · ' + this.modelLabel)
          .fontSize(11).fontColor('#3b82f6')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('›').fontSize(11).fontColor('#93c5fd').margin({ left: 2 })
        Text(this.sessionCwd !== '' ? this.sessionCwd : '')
          .fontSize(11).fontColor('#cbd5e1')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).textAlign(TextAlign.End)
          .margin({ left: 10 })
      }
      .width('100%')
      .margin({ top: 6, left: 26 })
      .onClick(() => { this.onOpenModelTab(); })
    }
    .width('100%')
    .height(72)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16 })
    .backgroundColor('#ffffff')
    .border({ width: { bottom: 1 }, color: '#eef2f7' })
  }

  /** 底部输入区。 */
  /** 有没有可发送的内容（文字或附件）。 */
  canSend(): boolean {
    return this.input.trim() !== '' || this.pendingFiles.length > 0 || this.pendingImages.length > 0;
  }

  @Builder
  inputBar() {
    Column() {
      // 已上传、等待随下一条消息一起发出的附件
      if (this.pendingFiles.length > 0) {
        List({ space: 8 }) {
          ForEach(this.pendingFiles, (item: UploadedFileInfo, index: number) => {
            ListItem() {
              Row() {
                Text(item.name !== undefined ? item.name : '文件')
                  .fontSize(11)
                  .fontColor('#475569')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 140 })
                  .margin({ left: 4 })
                Text('✕')
                  .fontSize(12)
                  .fontColor('#94a3b8')
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.removePending(index);
                  })
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor('#eef2f7')
              .borderRadius(14)
            }
          }, (item: UploadedFileInfo, index: number) => {
            return String(item.relPath) + '-' + String(index);
          })
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(36)
        .padding({ left: 16, right: 16 })
        .margin({ top: 8 })
      }

      Row() {
        // 「＋」上传按钮：选文件 -> 传到会话工作区
        Button(this.uploading ? '···' : '+')
          .fontSize(this.uploading ? 12 : 20)
          .height(40)
          .width(40)
          .padding(0)
          .borderRadius(20)
          .backgroundColor('#f1f5f9')
          .fontColor('#475569')
          .enabled(!this.uploading)
          .onClick(() => {
            this.pickAndUpload();
          })

        TextInput({ text: this.input, placeholder: '发一条指令…' })
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .backgroundColor('#f1f5f9')
          .borderRadius(20)
          .padding({ left: 16, right: 16 })
          .margin({ left: 8 })
          .onChange((value: string) => {
            this.input = value;
          })
          .onSubmit((enterKey: EnterKeyType) => {
            this.doSend();
          })

        // 任务运行中 —— 发送键变成红色的「停止」键
        if (this.running) {
          Button(this.cancelling ? '停止中' : '停止')
            .fontSize(15)
            .height(40)
            .padding({ left: 18, right: 18 })
            .margin({ left: 8 })
            .borderRadius(20)
            .backgroundColor(this.cancelling ? '#fca5a5' : '#dc2626')
            .fontColor('#ffffff')
            .enabled(!this.cancelling)
            .onClick(() => {
              this.doCancel();
            })
        } else {
          Button(this.sending ? '发送中' : '发送')
            .fontSize(15)
            .height(40)
            .padding({ left: 18, right: 18 })
            .margin({ left: 8 })
            .borderRadius(20)
            .backgroundColor(this.canSend() && !this.sending ? '#3b82f6' : '#cbd5e1')
            .enabled(this.canSend() && !this.sending)
            .onClick(() => {
              this.doSend();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 10 })
    }
    .width('100%')
    .backgroundColor('#ffffff')
    .border({ width: { top: 1 }, color: '#eef2f7' })
  }

  /* ================= 确认面板（自绘，黑白配色） =================
   * 刻意写成「零参数 @Builder + 直接读 this.xxx」：ArkUI V1 里带参数的
   * @Builder 是**按值捕获**的，状态变了不会重绘（Index.ets 里已踩过这个坑），
   * 勾选状态就会卡死。同理，这里也不声明局部变量，一切都走小方法。
   *
   * 配色只取黑/白/灰，跟 DSH 自己的主题一致 —— 不再有蓝字。
   */
  @Builder
  confirmPanel() {
    Column() {
      Column() {
        Text(this.panelTitle())
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111111')
          .width('100%')

        if (this.confirmKind === 'approval') {
          Text('工具：' + this.confirmTool)
            .fontSize(13).fontColor('#6b7280').width('100%').margin({ top: 8 })
          if (this.confirmReason !== '') {
            Text(this.confirmReason)
              .fontSize(13).fontColor('#374151').width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
              .margin({ top: 6 })
          }
        } else {
          Scroll() {
            Column() {
              ForEach(this.confirmQuestions, (q: ConfirmQuestion, qi: number) => {
                Column() {
                  if (this.headerOf(q) !== '') {
                    Text(this.headerOf(q))
                      .fontSize(11).fontColor('#9ca3af').width('100%').margin({ top: 10 })
                  }
                  Text(this.questionOf(q))
                    .fontSize(15).fontColor('#111111').width('100%')
                    .wordBreak(WordBreak.BREAK_WORD)
                    .margin({ top: 4 })

                  // plan-review 之类会把整份正文放在 detail 里 —— 不看正文就点
                  // 「批准」是不负责任的，所以直接用现成的 Markdown 渲染器展示。
                  if (this.hasDetail(q)) {
                    Column() {
                      MarkdownView({ text: this.detailOf(q), isUser: false })
                    }
                    .width('100%')
                    .padding(10)
                    .margin({ top: 8 })
                    .backgroundColor('#f7f7f8')
                    .borderRadius(8)
                  }

                  if (this.isMulti(q)) {
                    Text('可多选 · 选完点「确定」')
                      .fontSize(11).fontColor('#9ca3af').width('100%').margin({ top: 6 })
                  }

                  // 选项：勾选态整体反色（黑底白字 + 白色勾选框），
                  // 单选画圆、多选画圆角方框，形状本身就提示能不能多选。
                  ForEach(this.optsOf(q), (opt: ConfirmOption, oi: number) => {
                    Row() {
                      Row() {
                        Text(this.isPicked(qi, oi) ? '✓' : '')
                          .fontSize(12).fontColor('#111111')
                      }
                      .width(18).height(18)
                      .justifyContent(FlexAlign.Center)
                      .backgroundColor('#ffffff')
                      .borderRadius(this.isMulti(q) ? 4 : 9)
                      .border({ width: 1.5, color: this.isPicked(qi, oi) ? '#ffffff' : '#c7c7c7' })

                      Column() {
                        Text(this.labelOf(opt))
                          .fontSize(14)
                          .fontColor(this.isPicked(qi, oi) ? '#ffffff' : '#111111')
                          .width('100%')
                          .wordBreak(WordBreak.BREAK_WORD)
                        if (this.descOf(opt) !== '') {
                          Text(this.descOf(opt))
                            .fontSize(11)
                            .fontColor(this.isPicked(qi, oi) ? '#d4d4d4' : '#9ca3af')
                            .width('100%')
                            .wordBreak(WordBreak.BREAK_WORD)
                            .margin({ top: 2 })
                        }
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      .margin({ left: 9 })
                    }
                    .width('100%')
                    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
                    .backgroundColor(this.isPicked(qi, oi) ? '#111111' : '#ffffff')
                    .border({ width: 1, color: this.isPicked(qi, oi) ? '#111111' : '#d1d5db' })
                    .borderRadius(10)
                    .margin({ top: 8 })
                    .onClick(() => {
                      this.togglePick(qi, oi, this.isMulti(q));
                    })
                  }, (opt: ConfirmOption, oi: number) => String(qi) + '-' + String(oi))

                  // 自定义回答：DSH 允许答案**不在选项里**（custom 字段），
                  // 所以这个输入框始终提供，不是只有「没有选项」的题目才有。
                  // 单选时 custom 与 selected 互斥，一打字会自动清掉勾选；
                  // 多选时两者可以并存（勾几项 + 再补一句说明）。
                  Text(this.customLabel(q))
                    .fontSize(11).fontColor('#9ca3af').width('100%').margin({ top: 12 })
                  TextInput({ text: this.freeOf(qi), placeholder: this.customHint(q) })
                    .width('100%').height(42).fontSize(14)
                    .backgroundColor('#f1f5f9').borderRadius(10)
                    .padding({ left: 12, right: 12 })
                    .margin({ top: 4 })
                    .onChange((value: string) => {
                      this.setFree(qi, value);
                    })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }, (q: ConfirmQuestion, qi: number) => String(qi))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .constraintSize({ maxHeight: 400 })
          .margin({ top: 12 })
        }

        Row() {
          if (this.confirmKind === 'approval') {
            // 审批是二选一的动作，直接给结局，不必再点一次「确定」
            Button('拒绝')
              .layoutWeight(1).height(44).fontSize(15).borderRadius(10)
              .backgroundColor('#ffffff').fontColor('#111111')
              .border({ width: 1, color: '#111111' })
              .onClick(() => { this.answerApproval('rejected'); })
            Button('允许一次')
              .layoutWeight(1).height(44).fontSize(15).borderRadius(10)
              .backgroundColor('#111111').fontColor('#ffffff')
              .margin({ left: 10 })
              .onClick(() => { this.answerApproval('allowed-once'); })
          } else {
            Button('取消')
              .layoutWeight(1).height(44).fontSize(15).borderRadius(10)
              .backgroundColor('#ffffff').fontColor('#111111')
              .border({ width: 1, color: '#111111' })
              .onClick(() => { this.dismissConfirm(); })
            Button('确定')
              .layoutWeight(1).height(44).fontSize(15).borderRadius(10)
              .backgroundColor('#111111').fontColor('#ffffff')
              .margin({ left: 10 })
              .onClick(() => { this.submitConfirm(); })
          }
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('86%')
      .constraintSize({ maxHeight: '80%' })
      .padding(16)
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .border({ width: 1, color: '#e5e7eb' })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(10)
    .backgroundColor('#73000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 吃掉点击，别让手势穿透到下面的聊天页。点空白处什么都不做 ——
    // 要放弃作答请按「取消」，免得一个误触把已经勾好的选择弄丢。
    .onClick(() => {
      // 故意留空
    })
  }

  build() {
    Column() {
      this.header()

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color('#3b82f6')
          // 把「卡在哪一步」显示出来：转圈不再是不带线索的黑盒
          Text(this.loadStage !== '' ? this.loadStage : '加载中…')
            .fontSize(13).fontColor('#94a3b8').margin({ top: 8 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg !== '') {
        Column() {
          Text('连接不上')
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
          // 失败原因包含完整 URL、错误码和具体解释；长按可复制，方便直接发出来定位
          Text(this.errorMsg)
            .fontSize(12).fontColor('#dc2626')
            .textAlign(TextAlign.Start)
            .copyOption(CopyOptions.LocalDevice)
            .margin({ top: 12, left: 18, right: 18 })
          Text('（长按上面这段可以复制）').fontSize(10).fontColor('#94a3b8').margin({ top: 6 })
          Row() {
            Button('重试')
              .fontSize(14).height(36).borderRadius(18)
              .backgroundColor('#3b82f6').fontColor('#ffffff')
              .padding({ left: 22, right: 22 })
              .onClick(() => { this.bootstrap(); })
            // 地址或令牌填错时，这里是唯一的出路：回设置页重填
            Button('改地址')
              .fontSize(14).height(36).borderRadius(18)
              .backgroundColor('#f1f5f9').fontColor('#475569')
              .padding({ left: 22, right: 22 })
              .margin({ left: 10 })
              .onClick(() => { this.onResetConfig(); })
          }
          .margin({ top: 16 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.shown.length === 0) {
        Column() {
          // 用品牌标识代替 emoji：三个页面原本一个 🐾 一个 🗂️ 一个 😕，
          // 各自风格还不一样，是「看着不统一」的主要来源之一。
          Image($r('app.media.icon'))
            .width(56).height(56).objectFit(ImageFit.Contain).opacity(0.18)
          Text('还没有消息，在下面发一条试试').fontSize(13).fontColor('#94a3b8').margin({ top: 12 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12, scroller: this.listScroller }) {
          // 列表最上面：还有更早的消息时给一个入口
          if (this.hasMore) {
            ListItem() {
              Row() {
                if (this.loadingOlder) {
                  LoadingProgress().width(16).height(16).color('#94a3b8')
                  Text('加载更早的消息…').fontSize(12).fontColor('#94a3b8').margin({ left: 6 })
                } else {
                  Text('↑ 加载更早的消息').fontSize(12).fontColor('#3b82f6')
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 10, bottom: 10 })
              .onClick(() => { this.loadOlder(); })
            }
          }

          ForEach(this.shown, (item: ChatMessage, index: number) => {
            ListItem() {
              // 左右定位用 Row + justifyContent（比 Column + alignItems 更可预测）。
              // clip(true) 是安全网：万一某个块（长代码行 / 多列表格）算出来比约束还宽，
              // 也只会在气泡内部被裁掉，不会把整个 List 的内容撑宽 ——
              // 列表一旦被撑宽，所有气泡都会跟着横向偏移错位。
              Row() {
                Column() {
                  // 气泡样式留在这一层，里面交给 Markdown 渲染：
                  // 标题 / 粗体 / 行内代码 / 代码块 / 表格 / 列表 / 引用 / 链接 都能正常显示，
                  // 代码块和表格内部是横向可滚的，不会撑破气泡。
                  MarkdownView({
                    text: (item.text !== undefined) ? item.text : '',
                    isUser: item.role === 'user'
                  })
                }
                .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                // 助手气泡给白底 + 极细描边，页底用浅灰：比原来「浅灰气泡压浅灰底」
                // 更有层次，长回答也不会糊成一片。
                .backgroundColor(item.role === 'user' ? '#3b82f6' : '#ffffff')
                .border({
                  width: item.role === 'user' ? 0 : 1,
                  color: '#eef2f7'
                })
                .borderRadius(16)
                .constraintSize({ maxWidth: '84%' })
                .clip(true)

                if (item.role === 'assistant' && item.interrupted === true) {
                  Text('（被打断）').fontSize(10).fontColor('#f59e0b').margin({ left: 6, bottom: 2 })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Bottom)
              .justifyContent(item.role === 'user' ? FlexAlign.End : FlexAlign.Start)
            }
          }, (item: ChatMessage, index: number) => {
            return String(item.seq !== undefined ? item.seq : index) + '-' + String(index);
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor('#f7f8fa')
        // 记住用户是不是停在底部：只有停在底部时才自动跟随新消息，
        // 否则轮询会每隔 1.5 秒把正在往上翻历史的用户拽回来。
        .onScrollIndex((firstIndex: number, lastIndex: number) => {
          this.atBottom = (lastIndex >= this.shown.length - 1);
        })
      }

      this.inputBar()

      // 确认面板：绝对定位铺满整屏，盖在页面上（zIndex 保证在最上层）。
      // 之所以不把整个页面再包一层 Stack —— position + zIndex 一样是覆盖层，
      // 却不用把上面上百行整体重新缩进。
      if (this.confirmOpen) {
        this.confirmPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }
}
