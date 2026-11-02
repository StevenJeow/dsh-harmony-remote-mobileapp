/**
 * ApiClient.ets — 「DSH 遥控器」的网络层
 * ---------------------------------------------------------------------------
 * 只做三件事：
 *   1. 集中存放 baseURL / token（换服务器只改这里）
 *   2. 统一发请求：自动带 X-DSH-Token、统一超时、统一解析 {ok,error} 信封
 *   3. 把每个接口包成一个返回强类型结果的方法，页面只关心业务
 *
 * 后端是 dsh 插件 dsh-harmony-remote，它复用 dsh 网页端同一套后端（ctx.apiProxy）。
 * 成功：{"ok":true,...}  失败：{"ok":false,"error":{"code","message"}} + HTTP 状态码
 *
 * 只用 @kit.NetworkKit 的 http 模块，不用 Web 组件。
 */
import { http, networkSecurity } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

/* ==========================================================================
 * 集中配置区 —— 真正的值放在 LocalConfig.ets（不进版本库）
 *
 * 为什么要拆开：BASE_URL 和 TOKEN 是「这台电脑专属」的东西，尤其是 TOKEN，
 * 拿到它就等于能在这台电脑上执行命令。以前它们硬编码在本文件里，
 * 这个工程一推到 GitHub 就等于把遥控器的钥匙一起推上去了。
 * 现在本文件只做转发，仓库里看到的是 LocalConfig.example.ets 模板。
 * ========================================================================== */

import {
  LOCAL_BASE_URL, LOCAL_TOKEN,
  LOCAL_SESSION_TITLE, LOCAL_SESSION_CWD,
  LOCAL_MODEL_PROVIDER, LOCAL_MODEL, LOCAL_EFFORT
} from './LocalConfig';

/** 电脑的局域网 IP + 插件端口。手机必须和电脑在同一个 Wi-Fi 下。 */
export const BASE_URL: string = LOCAL_BASE_URL;

/** 与插件 cordis.patch.yml 里的 token 必须一致。 */
export const TOKEN: string = LOCAL_TOKEN;

/** http 模块自己的超时（毫秒）。 */
export const TIMEOUT_MS: number = 15000;

/* ==========================================================================
 * 默认会话 / 默认模型 —— 让遥控器「每次连上就是对的」
 *
 * 默认会话的匹配顺序：
 *   ① 标题精确命中 DEFAULT_SESSION_TITLE（最精确，优先）
 *   ② 否则按工作区目录 DEFAULT_SESSION_CWD 命中，多条时取最近更新的
 * 两个都可以留空串；都留空 = 不指定默认会话，走原来的自动推断。
 * ========================================================================== */

/** 默认会话的标题（精确匹配）。 */
export const DEFAULT_SESSION_TITLE: string = LOCAL_SESSION_TITLE;

/**
 * 默认会话的工作区目录（留空 = 不按目录找）。
 * 注意：光靠目录不够精确 —— 可能有多个会话的 cwd 相同，所以标题优先，目录只作兜底。
 */
export const DEFAULT_SESSION_CWD: string = LOCAL_SESSION_CWD;

/**
 * 默认模型：deepseek-flash + high（思考深度）档。
 * DEFAULT_MODEL 留空串表示不改模型（想自己挑模型就把这行清空）。
 */
export const DEFAULT_MODEL_PROVIDER: string = LOCAL_MODEL_PROVIDER;
export const DEFAULT_MODEL: string = LOCAL_MODEL;
export const DEFAULT_EFFORT: string = LOCAL_EFFORT;

/**
 * 硬超时（毫秒）—— 给整个请求套一层 Promise 竞速。
 *
 * 为什么需要它：实测手机连不上电脑时，如果网络层是「静默丢包」（路由器开了 AP 隔离、
 * 或手机不在同一网段），TCP 握手会一直等到系统级超时（几分钟），
 * 而 http 模块的 connectTimeout 在这种场景下不一定被触发 —— 结果就是界面永远转圈。
 * 有了这层硬超时，最多 12 秒必定返回一个明确的错误，而不是无限等待。
 */
export const HARD_TIMEOUT_MS: number = 12000;

/** 记录这次失败是不是被「客户端硬超时」掐断的（区分于真正的网络错误）。 */
interface TimeoutFlag {
  fired: boolean;
}

/** 给一个请求 Promise 套上硬超时。 */
function withHardTimeout(work: Promise<http.HttpResponse>, ms: number,
  flag: TimeoutFlag): Promise<http.HttpResponse> {
  return new Promise<http.HttpResponse>((resolve: (r: http.HttpResponse) => void,
    reject: (e: Error) => void) => {
    const timer: number = setTimeout(() => {
      flag.fired = true;
      reject(new Error('客户端在 ' + String(ms / 1000) + ' 秒内没有收到任何响应'));
    }, ms);
    work.then((r: http.HttpResponse) => {
      clearTimeout(timer);
      resolve(r);
    }).catch((e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/**
 * 鸿蒙 http 错误码 → 具体原因。
 * 码值和英文描述全部取自 SDK 的 @ohos.net.http 文档（35 个官方码），不是凭记忆写的。
 * 只列与「连不上 / 连错」相关的，其余走兜底分支。
 */
function explainHttpCode(code: number): string {
  if (code === 201) {
    return '缺少网络权限：module.json5 的 requestPermissions 里没有 ohos.permission.INTERNET';
  }
  if (code === 401) {
    return '请求参数不合法（客户端有 bug，请把这条发给开发者）';
  }
  if (code === 2300003) {
    return 'URL 格式不对：检查 ApiClient.ets 里的 BASE_URL 是不是合法地址';
  }
  if (code === 2300005) {
    return '代理服务器名称解析失败：检查手机是否配了不可用的代理';
  }
  if (code === 2300006) {
    return '域名解析失败（DNS）：BASE_URL 应该填电脑的局域网 IP，不要填域名';
  }
  if (code === 2300007) {
    return '连不上服务器。最常见的原因按顺序查：① 手机和电脑不在同一个 Wi-Fi；'
      + '② 路由器开了「AP 隔离 / 客户端隔离」，同网段设备也互相看不见；'
      + '③ 电脑防火墙把入站挡了；④ 电脑上的 dsh 没在运行 / 插件没加载';
  }
  if (code === 2300008) {
    return '服务器响应格式不合法：端口通了，但对面可能不是 dsh 插件（比如连到了别的服务）';
  }
  if (code === 2300028) {
    return '操作超时：网络可达但没在超时时间内返回，可能是电脑端太忙或链路很慢';
  }
  if (code === 2300052) {
    return '服务器没有返回任何内容：TCP 连上了但对面没回数据，确认 3100 端口上是 dsh 插件';
  }
  if (code === 2300055 || code === 2300056) {
    return '收发数据中途断开：连接被重置，检查电脑端进程是否还在、Wi-Fi 是否稳定';
  }
  if (code === 2300094) {
    return '认证错误：服务端要求认证，检查 token 配置';
  }
  if (code === 2300997) {
    return '系统拦截了明文 HTTP（cleartext）：需要在 module.json5 里挂载 network_config';
  }
  if (code === 2300998) {
    return '系统不允许访问这个域名：网络安全配置的限制';
  }
  if (code === 2300999) {
    return '网络栈内部错误（2300999）';
  }
  return '';
}

/**
 * 把一次请求失败拼成一段可以直接显示给人看、也能直接拿去定位的诊断文本。
 * 包含：方法 + 完整 URL、错误码、具体原因、原始英文信息。
 */
function diagnose(method: string, url: string, code: number, rawMessage: string,
  hardTimeout: boolean): string {
  const where: string = '[' + method + '] ' + url;

  if (hardTimeout) {
    return '连接超时\n' + where
      + '\n12 秒内没有收到任何响应（TCP 连接没能建立起来，属于被静默丢弃）'
      + '\n常见原因：路由器开了 AP 隔离；手机和电脑不在同一网段；电脑 IP 变了；防火墙静默丢包'
      + '\n原始信息：' + rawMessage;
  }

  const why: string = explainHttpCode(code);
  let out: string = '连接失败\n' + where;
  if (code !== 0) {
    out = out + '\n错误码：' + String(code);
  }
  if (why !== '') {
    out = out + '\n原因：' + why;
  }
  out = out + '\n原始信息：' + rawMessage;
  return out;
}

/**
 * 自检：系统是否允许明文 HTTP（cleartext）。
 * HarmonyOS 对 http:// 默认可能拦截，报错码 2300997。
 * 这里用官方 API 直接问系统，把"猜测"变成"实测"：
 * 返回 false 就说明需要在 module.json5 里挂载 network_config。
 * API 低于 18 或调用失败时返回 true（不误报，不打断用户）。
 */
export function probeCleartext(): boolean {
  try {
    return networkSecurity.isCleartextPermitted();
  } catch (e) {
    return true;
  }
}

/* ==========================================================================
 * 数据结构（与插件实际返回的 JSON 一一对应）
 * ========================================================================== */

/** 服务端错误体。 */
export interface ApiError {
  code?: string;
  message?: string;
}

/** 每个响应的统一信封。 */
export interface RawEnvelope {
  ok?: boolean;
  error?: ApiError;
}

/** 一条对话消息（GET /messages 里的一项）。 */
export interface ChatMessage {
  seq?: number;
  role?: string;
  text?: string;
  turn?: number;
  step?: number;
  interrupted?: boolean;
}

/** 推理档位。 */
export interface ReasoningEffort {
  id?: string;
  name?: string;
}

export interface ModelReasoning {
  efforts?: ReasoningEffort[];
  defaultEffort?: string;
}

/** 一个可选模型。 */
export interface ModelInfo {
  id?: string;
  name?: string;
  reasoning?: ModelReasoning;
}

/** 按供应商分组的模型目录。 */
export interface ModelGroup {
  id?: string;
  name?: string;
  models?: ModelInfo[];
}

/** 当前选中的模型。 */
export interface ModelSelection {
  provider?: string;
  model?: string;
  reasoningEffort?: string;
}

/** GET /status 里的候选会话。 */
export interface LiveAgent {
  sessionId?: string;
  status?: string;
  running?: boolean;
}

/** 会话投影里我们要用的那一小块。 */
export interface SessionProjectionValues {
  title?: string;
}

export interface SessionProjections {
  values?: SessionProjectionValues;
}

/** 一个会话（GET /sessions 里的一项）。 */
export interface SessionInfo {
  sessionId?: string;
  updatedAt?: number;
  running?: boolean;
  blank?: boolean;
  cwd?: string;
  agentPreset?: string;
  projections?: SessionProjections;
}

/** GET /status */
export interface StatusData {
  ok?: boolean;
  sessionId?: string;
  running?: boolean;
  agentStatus?: string;
  /** running 取反的显式字段：true 表示"没有任务在跑"，可以恢复「发送」键。 */
  idle?: boolean;
  /** 队列里是否还有没跑的消息（取消默认 keepInbox，排队内容不会丢）。 */
  hasPending?: boolean;
  /** 排队中的回合数。 */
  queuedTurns?: number;
  model?: ModelSelection;
  liveAgents?: LiveAgent[];
}

/** GET /models */
export interface ModelsData {
  ok?: boolean;
  sessionId?: string;
  current?: ModelSelection;
  routable?: boolean;
  groups?: ModelGroup[];
}

/** GET /messages */
export interface MessagesData {
  ok?: boolean;
  sessionId?: string;
  count?: number;
  hasMore?: boolean;
  messages?: ChatMessage[];
}

/** GET /sessions */
export interface SessionsData {
  ok?: boolean;
  count?: number;
  sessions?: SessionInfo[];
}

/** POST /model */
export interface SelectModelData {
  ok?: boolean;
  selected?: ModelSelection;
}

/** POST /send */
export interface SendData {
  ok?: boolean;
  sessionId?: string;
  mode?: string;
  accepted?: boolean;
  /** 本次随消息一起发出去的附件（工作区相对路径）。 */
  fileRefs?: string[];
  /** 本次随消息一起发出去的图片数量。 */
  imageCount?: number;
}

/** 上传成功后服务端返回的文件信息。 */
export interface UploadedFileInfo {
  /** 原始文件名（已做安全处理）。 */
  name?: string;
  /** 落盘后的文件名（带时间戳前缀，避免重名覆盖）。 */
  storedName?: string;
  bytes?: number;
  /** 绝对路径。 */
  path?: string;
  /** 相对会话工作区的路径 —— /send 的 fileRefs 用这个。 */
  relPath?: string;
  mediaType?: string;
}

/**
 * 图片的 wire 形态，与网页端 `EncodedImageAttachment` 完全一致
 * （见 @deepseek-ai/dsh-attachment 的 types.d.ts）。
 * 把它原样放进 /send 的 images，服务端 durablePromptContent() 会
 * 调 admitEncodedImages() 落成正式附件，模型就能真正「看到」这张图。
 */
export interface UploadedImage {
  mediaType?: string;
  /** 标准 base64（不含 data: 前缀）。 */
  data?: string;
  name?: string;
}

/** POST /upload */
export interface UploadData {
  ok?: boolean;
  sessionId?: string;
  /** 'file' 或 'image'。 */
  kind?: string;
  file?: UploadedFileInfo;
  /** 只有图片才有；文本文件为 null。 */
  image?: UploadedImage | null;
}

/** POST /sessions */
export interface CreateSessionData {
  ok?: boolean;
  sessionId?: string;
  agentPreset?: string;
}

/** POST /cancel */
export interface CancelData {
  ok?: boolean;
  sessionId?: string;
  cancelled?: boolean;
}

/* ==========================================================================
 * 请求体（显式接口，方便 ArkTS 类型检查）
 * ========================================================================== */

interface SendBody {
  text: string;
  mode: string;
  sessionId?: string;
  /** 已上传文件在工作区里的相对路径，agent 会照着读。 */
  fileRefs?: string[];
  /** 图片（把 /upload 返回的 image 字段原样回传）。 */
  images?: UploadedImage[];
}

interface SelectModelBody {
  provider: string;
  model: string;
  reasoningEffort?: string;
  sessionId?: string;
}

interface CreateSessionBody {
  agentPreset?: string;
}

interface SessionOnlyBody {
  sessionId?: string;
}

/* ==========================================================================
 * 统一请求
 * ========================================================================== */

/** 一次请求的结果。 */
export interface CallResult {
  /** HTTP 2xx 且响应体 ok:true。 */
  ok: boolean;
  /** HTTP 状态码；网络层失败为 0。 */
  status: number;
  /** 响应体原文。 */
  text: string;
  /** 可直接展示给用户的失败原因。 */
  error: string;
  /** 服务端 error.code；网络层失败为 'network'。 */
  errorCode: string;
}

/** 每个封装方法的通用返回。 */
export interface Result<T> {
  ok: boolean;
  error: string;
  data?: T;
}

/**
 * JSON 里的 `null` / `undefined` / 空串 一律当「没有值」。
 *
 * 必须这么处理：服务端推不出当前会话时，`/status` 返回的是 **JSON null**
 *（不是空串）。只判 `!== undefined` 会让 null 一路传下去，请求变成
 * `?sessionId=null` —— 服务端查不到这个会话，整页就失败。
 * 这就是「服务端能推断出会话时正常、挂了多个 agent 时就抽风」的根因。
 *
 * （写成 helper 还为了类型安全：直接对 string 类型的值写 `!== null`
 *   会触发 TS2367「类型无重叠」报错。）
 */
export function asText(v: string | undefined | null): string {
  return (v === undefined || v === null) ? '' : String(v);
}

/** 路径归一化：斜杠方向、大小写、末尾斜杠都不敏感（不用正则，ArkTS 更稳）。 */
function normPath(p: string): string {
  let s: string = p.split('\\').join('/');
  while (s.length > 1 && s.charAt(s.length - 1) === '/') {
    s = s.substring(0, s.length - 1);
  }
  return s.toLowerCase();
}

/** 会话标题（投影里的 title），没有则空串。 */
function titleOf(s: SessionInfo): string {
  const p: SessionProjections | undefined = s.projections;
  const v: SessionProjectionValues | undefined = (p !== undefined) ? p.values : undefined;
  return (v !== undefined) ? asText(v.title) : '';
}

/**
 * 从 /sessions 里挑出「默认会话」。
 *
 * ① 标题精确命中 DEFAULT_SESSION_TITLE —— 最精确，优先（同一个工作区下
 *    往往有好几个会话，只按目录认会挑错）。
 * ② 否则按 cwd 命中 DEFAULT_SESSION_CWD，多条时取最近更新的那条。
 * 都没命中返回空串，由调用方继续走原有兜底（服务端推断 / liveAgents）。
 */
export function pickDefaultSession(sessions: SessionInfo[]): string {
  if (sessions.length === 0) {
    return '';
  }
  const wantTitle: string = DEFAULT_SESSION_TITLE.trim().toLowerCase();
  const wantCwd: string = normPath(DEFAULT_SESSION_CWD);

  // ① 标题精确匹配
  if (wantTitle !== '') {
    for (let i = 0; i < sessions.length; i++) {
      const s: SessionInfo = sessions[i];
      const sid: string = asText(s.sessionId);
      if (sid !== '' && titleOf(s).trim().toLowerCase() === wantTitle) {
        return sid;
      }
    }
  }

  // ② 目录匹配，取最近更新的
  if (wantCwd === '') {
    return '';
  }
  let bestId: string = '';
  let bestAt: number = -1;
  for (let i = 0; i < sessions.length; i++) {
    const s: SessionInfo = sessions[i];
    const sid: string = asText(s.sessionId);
    if (sid === '' || normPath(asText(s.cwd)) !== wantCwd) {
      continue;
    }
    const at: number = (s.updatedAt !== undefined) ? s.updatedAt : 0;
    if (at > bestAt) {
      bestAt = at;
      bestId = sid;
    }
  }
  return bestId;
}

/** 拼上 ?sessionId=（没值时不拼）。 */
function withSession(path: string, sessionId: string): string {
  const sid: string = asText(sessionId);
  if (sid === '') {
    return path;
  }
  return path + '?sessionId=' + encodeURIComponent(sid);
}

/** 追加一个查询参数（自动判断用 ? 还是 &）。 */
function withParam(path: string, key: string, value: string): string {
  const sep: string = (path.indexOf('?') >= 0) ? '&' : '?';
  return path + sep + key + '=' + encodeURIComponent(value);
}

/**
 * 发一个请求并解析信封。
 * @param path 以 / 开头的路径，可自带查询串
 * @param method http.RequestMethod.GET / POST
 * @param body POST 的 JSON 体；GET 传 undefined
 */
export async function callApi(path: string, method: http.RequestMethod, body?: object,
  hardTimeoutMs: number = HARD_TIMEOUT_MS): Promise<CallResult> {
  const request = http.createHttp();
  const url: string = BASE_URL + path;
  const methodName: string = (method === http.RequestMethod.POST) ? 'POST' : 'GET';
  // 记录这次是不是被客户端硬超时掐断的，好在 catch 里给出不一样的原因说明
  const timeoutFlag: TimeoutFlag = { fired: false };
  try {
    const options: http.HttpRequestOptions = {
      method: method,
      header: {
        'Content-Type': 'application/json',
        'X-DSH-Token': TOKEN
      },
      connectTimeout: TIMEOUT_MS,
      // 读超时跟着硬超时走：长轮询 /events 需要比普通请求宽得多的窗口
      readTimeout: hardTimeoutMs,
      expectDataType: http.HttpDataType.STRING
    };
    if (body !== undefined) {
      options.extraData = JSON.stringify(body);
    }

    const resp: http.HttpResponse =
      await withHardTimeout(request.request(url, options), hardTimeoutMs, timeoutFlag);
    const status: number = resp.responseCode;
    const raw: string = (typeof resp.result === 'string') ? resp.result : JSON.stringify(resp.result);

    // 401 是最常见的配置错误，单独给一句人话
    if (status === 401) {
      return {
        ok: false, status: status, text: raw, errorCode: 'unauthorized',
        error: '密钥不正确（HTTP 401）\n[' + methodName + '] ' + url
          + '\n原因：ApiClient.ets 顶部的 TOKEN 与电脑端 cordis.patch.yml 里的 token 不一致。'
      };
    }

    if (raw === '' || raw === 'null') {
      const fine: boolean = status >= 200 && status < 300;
      return {
        ok: fine, status: status, text: '',
        errorCode: fine ? '' : 'empty',
        error: fine ? '' : ('服务端返回了空响应（HTTP ' + status + '）')
      };
    }

    let envelope: RawEnvelope;
    try {
      envelope = JSON.parse(raw) as RawEnvelope;
    } catch (parseErr) {
      return {
        ok: false, status: status, text: raw, errorCode: 'bad-json',
        error: '响应不是合法 JSON（HTTP ' + status + '）'
      };
    }

    const httpFine: boolean = status >= 200 && status < 300;
    const bodyFine: boolean = envelope.ok !== true ? false : true;
    if (httpFine && bodyFine) {
      return { ok: true, status: status, text: raw, error: '', errorCode: '' };
    }

    const err: ApiError | undefined = envelope.error;
    const code: string = (err !== undefined && err.code !== undefined) ? err.code : 'error';
    let msg: string = (err !== undefined && err.message !== undefined) ? err.message : '';
    if (msg === '') {
      msg = '请求失败';
    }
    return {
      ok: false, status: status, text: raw, errorCode: code,
      error: '服务端拒绝了这次请求\n[' + methodName + '] ' + url
        + '\nHTTP ' + String(status) + '  错误码：' + code
        + '\n原因：' + msg
    };
  } catch (e) {
    // 鸿蒙的网络异常是 BusinessError（继承 Error，多一个 code 字段）；
    // 普通 Error 没有 code，取不到就按 0 处理，走通用说明。
    const be = e as BusinessError;
    let code: number = 0;
    let rawMsg: string = String(e);
    if (be !== undefined) {
      if (be.code !== undefined) {
        code = be.code;
      }
      if (be.message !== undefined) {
        rawMsg = be.message;
      }
    }
    return {
      ok: false,
      status: 0,
      text: '',
      errorCode: (code === 0) ? 'network' : ('http-' + String(code)),
      error: diagnose(methodName, url, code, rawMsg, timeoutFlag.fired)
    };
  } finally {
    request.destroy();
  }
}

/* ==========================================================================
 * 各接口的强类型封装
 * ========================================================================== */

/** GET /status */
export async function fetchStatus(sessionId: string): Promise<Result<StatusData>> {
  const r: CallResult = await callApi(withSession('/status', sessionId), http.RequestMethod.GET);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as StatusData };
}

/**
 * 定「当前会话」。
 *
 * 服务端能唯一推断时（只有一个 agent 挂着）直接用它的结果；推不出来时
 * （同时挂了多个 agent）就自己从 liveAgents 里挑一个，优先「正在运行」的。
 *
 * 这一步不能省：sessionId 为空时，/models、/messages 这些会话相关接口
 * 会全部返回 409 no-session，模型页和对话页看起来就像坏了。
 * 服务端刻意不替我们猜（怕 /send 悄悄发错会话），所以挑的责任在客户端；
 * 用户随时可以在「会话」页改成别的。
 */
export function pickSessionId(d: StatusData | undefined): string {
  if (d === undefined) {
    return '';
  }
  // 注意用 asText：/status 推不出会话时给的是 JSON null，不是空串
  const sid: string = asText(d.sessionId);
  if (sid !== '') {
    return sid;
  }
  const list: LiveAgent[] = (d.liveAgents !== undefined && d.liveAgents !== null) ? d.liveAgents : [];
  for (let i = 0; i < list.length; i++) {
    const a: LiveAgent = list[i];
    if (a.running === true && asText(a.sessionId) !== '') {
      return asText(a.sessionId);
    }
  }
  for (let i = 0; i < list.length; i++) {
    const a: LiveAgent = list[i];
    if (asText(a.sessionId) !== '') {
      return asText(a.sessionId);
    }
  }
  return '';
}

/** GET /models */
export async function fetchModels(sessionId: string): Promise<Result<ModelsData>> {
  const r: CallResult = await callApi(withSession('/models', sessionId), http.RequestMethod.GET);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as ModelsData };
}

/**
 * GET /messages
 * @param beforeSeq 往前翻页用：只取 seq 小于它的更早消息；传 0 表示取最新一页。
 */
export async function fetchMessages(sessionId: string, limit: number,
  beforeSeq: number): Promise<Result<MessagesData>> {
  let path: string = withParam(withSession('/messages', sessionId), 'limit', String(limit));
  if (beforeSeq > 0) {
    path = withParam(path, 'beforeSeq', String(beforeSeq));
  }
  const r: CallResult = await callApi(path, http.RequestMethod.GET);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as MessagesData };
}

/** GET /sessions */
export async function fetchSessions(): Promise<Result<SessionsData>> {
  const r: CallResult = await callApi('/sessions', http.RequestMethod.GET);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as SessionsData };
}

/**
 * POST /send —— mode 用 'followup'（排队一轮）或 'steer'（插话打断当前步骤）。
 * @param fileRefs 已上传文件的工作区相对路径；agent 会照着读。
 * @param images   /upload 返回的 image 字段，原样回传即可。
 */
export async function sendPrompt(sessionId: string, text: string, mode: string,
  fileRefs: string[], images: UploadedImage[]): Promise<Result<SendData>> {
  const body: SendBody = { text: text, mode: mode };
  if (sessionId !== '') {
    body.sessionId = sessionId;
  }
  if (fileRefs.length > 0) {
    body.fileRefs = fileRefs;
  }
  if (images.length > 0) {
    body.images = images;
  }
  const r: CallResult = await callApi('/send', http.RequestMethod.POST, body);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as SendData };
}

/** JSON 上传的请求体。 */
interface UploadJsonBody {
  name: string;
  dataBase64: string;
  mediaType?: string;
  sessionId?: string;
}

/** 上传响应的统一拆包（multipart / json 两条通道共用）。 */
function parseUploadReply(status: number, raw: string, url: string, how: string): Result<UploadData> {
  if (status === 401) {
    return {
      ok: false,
      error: '密钥不正确（HTTP 401）\n[POST] ' + url
        + '\n原因：ApiClient.ets 顶部的 TOKEN 与电脑端 cordis.patch.yml 里的 token 不一致。'
    };
  }
  let envelope: RawEnvelope;
  try {
    envelope = JSON.parse(raw) as RawEnvelope;
  } catch (parseErr) {
    return { ok: false, error: '上传响应不是合法 JSON（HTTP ' + String(status) + '）\n[POST] ' + url };
  }
  if (status >= 200 && status < 300 && envelope.ok === true) {
    return { ok: true, error: '', data: JSON.parse(raw) as UploadData };
  }
  const err: ApiError | undefined = envelope.error;
  const code: string = (err !== undefined && err.code !== undefined) ? err.code : 'error';
  const msg: string = (err !== undefined && err.message !== undefined) ? err.message : '未知原因';
  return {
    ok: false,
    error: '上传被拒绝（' + how + '）\n[POST] ' + url
      + '\nHTTP ' + String(status) + '  错误码：' + code + '\n原因：' + msg
  };
}

/**
 * 通道一：multipart/form-data（鸿蒙 http 的 multiFormDataList）。
 *
 * 只放**一个** part（file）。sessionId 走查询串而不是 form 字段 —— 少一个 part
 * 就少一个「空 part 让整个 body 变成空」的隐患。Content-Type 故意不手写，
 * 交给库自己生成带 boundary 的头。
 */
async function uploadViaMultipart(sessionId: string, fileName: string, mimeType: string,
  content: ArrayBuffer): Promise<Result<UploadData>> {
  const request = http.createHttp();
  const path: string = (sessionId === '') ? '/upload' : withParam('/upload', 'sessionId', sessionId);
  const url: string = BASE_URL + path;
  const timeoutFlag: TimeoutFlag = { fired: false };
  try {
    const filePart: http.MultiFormData = {
      name: 'file',
      contentType: mimeType === '' ? 'application/octet-stream' : mimeType,
      remoteFileName: fileName,
      data: content
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: {
        'X-DSH-Token': TOKEN
      },
      multiFormDataList: [filePart],
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    };

    const resp: http.HttpResponse =
      await withHardTimeout(request.request(url, options), HARD_TIMEOUT_MS, timeoutFlag);
    const status: number = resp.responseCode;
    const raw: string = (typeof resp.result === 'string') ? resp.result : JSON.stringify(resp.result);
    return parseUploadReply(status, raw, url, 'multipart');
  } catch (e) {
    const be = e as BusinessError;
    let code: number = 0;
    let rawMsg: string = String(e);
    if (be !== undefined) {
      if (be.code !== undefined) {
        code = be.code;
      }
      if (be.message !== undefined) {
        rawMsg = be.message;
      }
    }
    return { ok: false, error: diagnose('POST', url, code, rawMsg, timeoutFlag.fired) };
  } finally {
    request.destroy();
  }
}

/**
 * 通道二：JSON + base64。
 * 这是网页端同源的那条路（apiproxy 的 prompt 收的就是 base64 图片），
 * 也完全绕开 multiFormDataList。复用 callApi，所以超时/诊断逻辑一致。
 */
async function uploadViaJson(sessionId: string, fileName: string, mimeType: string,
  content: ArrayBuffer): Promise<Result<UploadData>> {
  const body: UploadJsonBody = {
    name: fileName,
    dataBase64: new util.Base64Helper().encodeToStringSync(new Uint8Array(content))
  };
  if (mimeType !== '') {
    body.mediaType = mimeType;
  }
  if (sessionId !== '') {
    body.sessionId = sessionId;
  }
  const r: CallResult = await callApi('/upload', http.RequestMethod.POST, body);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as UploadData };
}

/**
 * POST /upload —— 把文件上传到会话工作区，让 agent 能读到。
 *
 * 先试 multipart；失败自动退到 base64 JSON。两条通道服务端都支持，
 * 哪条在这台设备上能用就用哪条，并在日志里写明走了哪条。
 *
 * 服务端写到 `<会话工作区>/dsh-uploads/`；图片会额外回传 base64（image 字段），
 * 前端把它交给 sendPrompt 的 images，模型就能真正看到这张图。
 *
 * @param content 文件字节。**调用方必须先真的把文件读成字节**，
 *                鸿蒙 http 不会自动去读 uri 指向的文件 —— 传 uri 字符串只会得到空 body。
 */
export async function uploadFile(sessionId: string, fileName: string, mimeType: string,
  content: ArrayBuffer): Promise<Result<UploadData>> {
  const bytes: number = content.byteLength;
  console.info('[DSH上传] 开始: ' + fileName + '  mime=' + mimeType + '  bytes=' + String(bytes));
  if (bytes <= 0) {
    return { ok: false, error: '文件读出来是 0 字节，没有内容可上传（' + fileName + '）' };
  }

  // 先走 base64 JSON：它复用 callApi（与 /send、/model 同一条路，已在真机上验证可用），
  // 不依赖 multiFormDataList，也不依赖库去读文件。multipart 作为备选。
  const first: Result<UploadData> = await uploadViaJson(sessionId, fileName, mimeType, content);
  if (first.ok) {
    console.info('[DSH上传] base64 JSON 成功: ' + fileName);
    return first;
  }
  console.error('[DSH上传] base64 JSON 失败，改试 multipart: ' + first.error);

  const second: Result<UploadData> = await uploadViaMultipart(sessionId, fileName, mimeType, content);
  if (second.ok) {
    console.info('[DSH上传] multipart 成功: ' + fileName);
    return second;
  }
  console.error('[DSH上传] 两条通道都失败: ' + fileName);
  return {
    ok: false,
    error: '上传失败（base64 和 multipart 两种方式都试过了，文件 ' + String(bytes) + ' 字节）\n\n'
      + '① base64 JSON：\n' + first.error + '\n\n'
      + '② multipart：\n' + second.error
  };
}

/** POST /model */
export async function selectModel(sessionId: string, provider: string, model: string,
  reasoningEffort: string): Promise<Result<SelectModelData>> {
  const body: SelectModelBody = { provider: provider, model: model };
  if (sessionId !== '') {
    body.sessionId = sessionId;
  }
  if (reasoningEffort !== '') {
    body.reasoningEffort = reasoningEffort;
  }
  const r: CallResult = await callApi('/model', http.RequestMethod.POST, body);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as SelectModelData };
}

/** POST /sessions */
export async function createSession(agentPreset: string): Promise<Result<CreateSessionData>> {
  const body: CreateSessionBody = {};
  if (agentPreset !== '') {
    body.agentPreset = agentPreset;
  }
  const r: CallResult = await callApi('/sessions', http.RequestMethod.POST, body);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as CreateSessionData };
}

/** POST /cancel */
export async function cancelTurn(sessionId: string): Promise<Result<CancelData>> {
  const body: SessionOnlyBody = {};
  if (sessionId !== '') {
    body.sessionId = sessionId;
  }
  const r: CallResult = await callApi('/cancel', http.RequestMethod.POST, body);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as CancelData };
}

/* ==========================================================================
 * 纯工具函数（不碰网络）
 * ========================================================================== */

/** (provider, model) 拼成一行显示文本。 */
export function modelLabelOf(sel: ModelSelection | undefined): string {
  if (sel === undefined || sel.model === undefined || sel.model === '') {
    return '未选择模型';
  }
  if (sel.provider !== undefined && sel.provider !== '') {
    return sel.model + ' · ' + sel.provider;
  }
  return sel.model;
}

/** 会话显示名：优先投影里的 title，其次截断的 sessionId。 */
export function sessionLabelOf(s: SessionInfo): string {
  const title: string | undefined = s.projections?.values?.title;
  if (title !== undefined && title !== '') {
    return title;
  }
  const id: string = (s.sessionId !== undefined) ? s.sessionId : '';
  if (id.length > 22) {
    return id.substring(0, 22) + '…';
  }
  return (id === '') ? '（未知会话）' : id;
}

/** 两位补零（写成独立函数而不是局部箭头，规避 ArkTS 对函数表达式的限制）。 */
function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

/** 毫秒时间戳 -> MM-DD HH:mm */
export function formatTime(ms: number | undefined): string {
  if (ms === undefined || ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' '
    + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/* ==========================================================================
 * confirm-approval：DSH 的「问人」确认（审批 / ask_user_question）
 * --------------------------------------------------------------------------
 * 服务端（dsh-harmony-remote 插件）把 DSH 的审批框和提问**旁路一份**推过来，
 * 电脑端原生框仍然照常弹出；哪一端先作答就哪一端生效，另一端会收到「已被处理」。
 * ========================================================================== */

/**
 * /events 是长轮询：服务端没有事件时会把请求挂最多 25 秒。
 * 必须给它比普通请求宽得多的硬超时，否则本地 12 秒就把自己掐断了。
 */
export const EVENT_TIMEOUT_MS: number = 30000;

/** 一个可选项（ask_user_question）。 */
export interface ConfirmOption {
  label?: string;
  description?: string;
}

/** 一个问题（ask_user_question）。 */
export interface ConfirmQuestion {
  id?: string;
  header?: string;
  question?: string;
  options?: ConfirmOption[];
  /** 允许多选；缺省是单选。多选时选项打勾、可以反悔，点「确定」才提交。 */
  multiSelect?: boolean;
  /** 附在题目下方、不进选项标签的补充材料（plan-review 时是整份计划原文）。 */
  detail?: string;
}

/** confirm_request 的业务负载。 */
export interface ConfirmPayload {
  /** 审批场景：要执行哪个工具。 */
  toolName?: string;
  /** 审批场景：为什么需要审批。 */
  reason?: string;
  sessionId?: string;
  /** 问答场景：要问的问题列表。 */
  questions?: ConfirmQuestion[];
}

/** 服务端推来的一条事件。 */
export interface ConfirmEvent {
  cursor?: number;
  /** 'confirm_request'（新确认）| 'confirm_resolved'（已被处理）。 */
  type?: string;
  id?: string;
  /** 'approval' | 'question'。 */
  kind?: string;
  payload?: ConfirmPayload;
}

export interface EventsData {
  ok?: boolean;
  cursor?: number;
  events?: ConfirmEvent[];
}

/**
 * ask_user_question 的单题作答。
 *
 * 字段名只能是 `id`：DSH 那边叫 `AskUserQuestionAnswerItem { id, selected, custom? }`，
 * 而且 `id` 是 dsh-tool-ask-user 的 output schema 里 required 的 string。
 * 之前这里写的是 `questionId`，于是 DSH 收到的每道题 id 都是 undefined ——
 * 服务端现在会替旧版 App 改名兜底，但新版本一律走 `id`。
 */
export interface QuestionAnswer {
  id?: string;
  selected?: string[];
  custom?: string;
}

/** 回填的答案：审批用 outcome，问答用 answers。 */
export interface ConfirmAnswer {
  /** 'allowed-once' | 'rejected' | 'cancelled'。 */
  outcome?: string;
  answers?: QuestionAnswer[];
}

interface ConfirmBody {
  id: string;
  answer: ConfirmAnswer;
}

/**
 * GET /events —— 长轮询拉确认请求。
 * @param since 上次拿到的游标；首次传 0。
 */
export async function pollEvents(since: number): Promise<Result<EventsData>> {
  const path: string = withParam('/events', 'since', String(since));
  const r: CallResult = await callApi(path, http.RequestMethod.GET, undefined, EVENT_TIMEOUT_MS);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '', data: JSON.parse(r.text) as EventsData };
}

/**
 * POST /confirm —— 回填答案。
 * 返回 409（already-resolved）表示另一端已经先作答了，这不是错误。
 */
export async function answerConfirm(id: string, answer: ConfirmAnswer): Promise<Result<EventsData>> {
  const body: ConfirmBody = { id: id, answer: answer };
  const r: CallResult = await callApi('/confirm', http.RequestMethod.POST, body);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, error: '' };
}
