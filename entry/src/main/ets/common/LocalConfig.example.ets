/**
 * LocalConfig.example.ets — 本机私有配置的模板（**这个文件进版本库**）
 * ---------------------------------------------------------------------------
 * 用法：复制一份改名成 LocalConfig.ets，把下面的值换成你自己的。
 *
 *   entry/src/main/ets/common/LocalConfig.example.ets
 *     -> entry/src/main/ets/common/LocalConfig.ets
 *
 * LocalConfig.ets 已被 .gitignore 排除，不会被提交。
 * 千万别把真实的令牌写回这个模板文件里。
 */

/**
 * 电脑的局域网 IP + 插件端口。
 * 手机和电脑必须在同一个 Wi-Fi 下；用 ipconfig 查电脑的无线网卡地址。
 * 例：http://192.168.1.42:3100
 */
export const LOCAL_BASE_URL: string = 'http://<电脑局域网IP>:3100';

/**
 * 访问令牌，必须与电脑端 DSH 配置里 harmony-remote 插件的 token 一致
 * （D:\dsh-data\profiles\web\cordis.patch.yml 中 harmony-remote 的 token 字段）。
 *
 * 这个令牌等于「在你这台电脑上执行命令」的权限，不要外传、不要提交。
 */
export const LOCAL_TOKEN: string = '<在这里填你的令牌>';

/**
 * 打开 App 时默认停在哪个会话。
 * 先按标题精确匹配，匹配不到再按工作区目录找最近更新的那个。
 * 两个都留空串 = 让服务端按它自己的规则自动挑。
 */
export const LOCAL_SESSION_TITLE: string = '';
export const LOCAL_SESSION_CWD: string = '';

/**
 * 默认模型。LOCAL_MODEL 留空串表示「不改模型，沿用电脑端当前的设置」。
 */
export const LOCAL_MODEL_PROVIDER: string = 'deepseek-official';
export const LOCAL_MODEL: string = '';
export const LOCAL_EFFORT: string = 'high';
