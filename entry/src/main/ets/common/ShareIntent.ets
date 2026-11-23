/**
 * ShareIntent.ets — 接住「从别的应用分享过来」的图片
 * ---------------------------------------------------------------------------
 * 链路：
 *   相册选中图片 → 系统分享面板 → 用户点「DSH 遥控器」
 *     → 系统以 ohos.want.action.sendData 拉起本应用
 *     → 用 Share Kit 的 systemShare.getSharedData(want) 解析出分享记录
 *     → 取每条记录的 uri，暂存起来
 *     → ChatPage 取走并上传成待发送的附件
 *
 * 为什么要中间存一下：拉起应用时 UI 可能还没起来（冷启动），
 * 页面起来之前数据没地方放，所以先存在这个单例里。
 *
 * 同时也往 AppStorage 写一个自增计数：
 * 应用已经在后台时（热启动），onNewWant 不会重建页面，
 * 页面靠这个 @StorageProp + @Watch 才能知道「又来了一张图」。
 *
 * 兜底：如果系统不是通过 Share Kit 送的（比如从文件管理器「用其他应用打开」），
 * 数据会落在 want.parameters['ability.params.stream'] 里，那条路也一并支持。
 */
import { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ShareIntent';
/** 非 Share Kit 场景下的文件 uri 数组键。 */
const PARAM_STREAM: string = 'ability.params.stream';
/** 页面用 @StorageProp 监听这个计数。 */
export const SHARE_TICK_KEY: string = 'dshShareTick';

export class ShareIntent {
  private static pending: string[] = [];
  private static tick: number = 0;

  /** EntryAbility 的 onCreate / onNewWant 里调用，把 Want 里的分享数据取出来。 */
  static capture(want: Want): void {
    // Share Kit 的解析是异步的（getSharedData 返回 Promise），不阻塞启动
    ShareIntent.parse(want);
  }

  /** 页面取走待处理的 uri（取完即清空，避免重复上传）。 */
  static take(): string[] {
    if (ShareIntent.pending.length === 0) {
      return [];
    }
    const out: string[] = ShareIntent.pending;
    ShareIntent.pending = [];
    return out;
  }

  /** 当前有没有攒着没处理的。 */
  static hasPending(): boolean {
    return ShareIntent.pending.length > 0;
  }

  private static async parse(want: Want): Promise<void> {
    let list: string[] = [];
    try {
      const data: systemShare.SharedData = await systemShare.getSharedData(want);
      const records: systemShare.SharedRecord[] = data.getRecords();
      for (let i = 0; i < records.length; i++) {
        const rec: systemShare.SharedRecord = records[i];
        if (rec.uri !== undefined && rec.uri !== '') {
          list.push(rec.uri);
        }
      }
      hilog.info(DOMAIN, TAG, 'Share Kit 解析到 %{public}d 条记录', records.length);
    } catch (e) {
      // 不是分享拉起的（比如普通点图标启动），getSharedData 会解析失败，这属于正常情况
      hilog.info(DOMAIN, TAG, '不是分享拉起或解析失败：%{public}s', String((e as Error).message));
    }
    if (list.length === 0) {
      list = ShareIntent.extractStream(want);
    }
    if (list.length === 0) {
      return;
    }
    ShareIntent.pending = ShareIntent.pending.concat(list);
    ShareIntent.tick++;
    AppStorage.setOrCreate<number>(SHARE_TICK_KEY, ShareIntent.tick);
    hilog.info(DOMAIN, TAG, '收到 %{public}d 个分享文件，待处理共 %{public}d 个',
      list.length, ShareIntent.pending.length);
  }

  /** 兜底：从 Want 参数里取文件 uri（非 Share Kit 的分享方式）。 */
  private static extractStream(want: Want): string[] {
    const out: string[] = [];
    try {
      const params: Record<string, Object> | undefined = want.parameters;
      if (params !== undefined && params !== null) {
        const raw: Object | undefined = params[PARAM_STREAM];
        if (raw !== undefined && raw !== null) {
          if (Array.isArray(raw)) {
            const arr: string[] = raw as string[];
            for (let i = 0; i < arr.length; i++) {
              const one: string = arr[i];
              if (typeof one === 'string' && one !== '') {
                out.push(one);
              }
            }
          } else if (typeof raw === 'string') {
            const one: string = raw as string;
            if (one !== '') {
              out.push(one);
            }
          }
        }
      }
      if (out.length === 0 && want.uri !== undefined && want.uri !== '') {
        out.push(want.uri);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '读取 want.parameters 失败: %{public}s', String((e as Error).message));
    }
    return out;
  }
}
