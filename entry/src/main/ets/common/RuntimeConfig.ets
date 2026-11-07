/**
 * RuntimeConfig.ets — 运行期配置（用户第一次进入 App 时手填）
 * ---------------------------------------------------------------------------
 * 为什么要有它：
 *   LocalConfig.ets 是「编译期」写死的地址和令牌，换一台电脑就得重新编译。
 *   发布版不能这样 —— 别人拿到装好的包，应该能自己填地址。
 *
 * 现在的取值优先级：
 *   ① 用户在首次启动页填的（存在 preferences 里，重启后还在）
 *   ② 没填过 → 退回 LocalConfig.ets 里的构建期默认值（可以留空串）
 *   ③ 都是空 → Index 页会停在「首次设置」页，不让进主界面
 *
 * 存的东西只有两项：接口地址、访问令牌。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LOCAL_BASE_URL, LOCAL_TOKEN } from './LocalConfig';

/** preferences 里的文件名，改了就相当于清空用户填过的地址。 */
const STORE_NAME: string = 'dsh_runtime_config';
const KEY_URL: string = 'base_url';
const KEY_TOKEN: string = 'token';

export class RuntimeConfig {
  private static store: preferences.Preferences | undefined = undefined;
  private static savedUrl: string = '';
  private static savedToken: string = '';

  /** 读一次已保存的配置。必须在任何请求发出前调用（Index 的 aboutToAppear 里调）。 */
  static async init(context: common.Context): Promise<void> {
    if (RuntimeConfig.store !== undefined) {
      return;
    }
    const opt: preferences.Options = { name: STORE_NAME };
    const st: preferences.Preferences = await preferences.getPreferences(context, opt);
    RuntimeConfig.store = st;
    RuntimeConfig.savedUrl = await st.get(KEY_URL, '') as string;
    RuntimeConfig.savedToken = await st.get(KEY_TOKEN, '') as string;
  }

  /** 当前接口地址；去掉结尾的斜杠，避免拼出 `http://x:3100//status` 这种路径。 */
  static baseUrl(): string {
    if (RuntimeConfig.savedUrl !== '') {
      return RuntimeConfig.trimSlash(RuntimeConfig.savedUrl);
    }
    return RuntimeConfig.trimSlash(LOCAL_BASE_URL);
  }

  /** 当前访问令牌；空串表示不发认证头（电脑端绑 127.0.0.1 时不需要）。 */
  static token(): string {
    if (RuntimeConfig.savedToken !== '') {
      return RuntimeConfig.savedToken;
    }
    return LOCAL_TOKEN;
  }

  /** 有没有可用的地址。false = 还没设过，Index 会显示首次设置页。 */
  static hasUrl(): boolean {
    return RuntimeConfig.baseUrl() !== '';
  }

  /** 保存（首次设置页用）。传进来的地址会顺手去掉首尾空白和结尾斜杠。 */
  static async save(url: string, token: string): Promise<void> {
    RuntimeConfig.savedUrl = RuntimeConfig.trimSlash(url);
    RuntimeConfig.savedToken = token.trim();
    const st: preferences.Preferences | undefined = RuntimeConfig.store;
    if (st !== undefined) {
      await st.put(KEY_URL, RuntimeConfig.savedUrl);
      await st.put(KEY_TOKEN, RuntimeConfig.savedToken);
      await st.flush();
    }
  }

  /** 清空已保存的配置，下次进来重新填。 */
  static async clear(): Promise<void> {
    RuntimeConfig.savedUrl = '';
    RuntimeConfig.savedToken = '';
    const st: preferences.Preferences | undefined = RuntimeConfig.store;
    if (st !== undefined) {
      await st.delete(KEY_URL);
      await st.delete(KEY_TOKEN);
      await st.flush();
    }
  }

  private static trimSlash(v: string): string {
    let s: string = v.trim();
    while (s.length > 0 && s.charAt(s.length - 1) === '/') {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
