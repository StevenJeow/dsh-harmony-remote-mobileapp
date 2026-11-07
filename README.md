<p align="center">
  <img src="docs/icon.png" width="112" alt="DSH 遥控器">
</p>

<h1 align="center">DSH 遥控器（鸿蒙手机端）</h1>

用鸿蒙手机远程操作电脑上的 DSH（DeepSeek Harness）的聊天客户端。纯 ArkTS + ArkUI 原生实现，
不套网页壳。电脑端跑 [`dsh-harmony-remote`](https://github.com/StevenJeow/dsh-harmony-remote)
插件提供 HTTP 接口，手机 App 通过局域网直连。

> **非官方项目。** 本项目由个人开发者（STEVEN JEOW）开发维护，与深度求索（DeepSeek）官方
> 无隶属关系，未获得官方背书、合作或授权。项目名称只使用生态通行的缩写「DSH」，
> 不使用官方商标作为产品名。

- 包名：`hmos.dsh.stevenjeow`（沿用开发版，改成你自己的也可以）
- 兼容版本：HarmonyOS 6.1.1(24)，编译目标 26.0.0
- 设备类型：手机

## 能做什么

- **对话**：看消息流、发指令、任务运行中可以「停止」；历史消息上滑分页加载
- **确认弹窗**：DSH 的审批（要不要执行某个工具）和 `ask_user_question` 都能在手机上答，
  支持单选 / 多选 / 自定义输入
- **上传**：文件与图片，随下一条消息一起发出去
- **模型**：按供应商分组列出可用模型，切换模型和推理档位（如 high / low）
- **会话**：列出所有会话、切换、新建
- **Markdown**：自己写的渲染器，标题 / 粗体 / 行内代码 / 代码块 / 表格 / 列表 / 引用 / 链接，
  代码块与表格支持横向滚动，不会撑破气泡

## 目录结构

```
entry/src/main/ets/
├── common/
│   ├── ApiClient.ets            网络层：接口封装、超时、错误码翻译
│   ├── RuntimeConfig.ets        运行期配置（地址/令牌，存 preferences）
│   ├── LocalConfig.ets          构建期默认值（可选，不进版本库）
│   ├── LocalConfig.example.ets  构建期默认值模板
│   └── MarkdownView.ets         轻量 Markdown 渲染器
└── pages/
    ├── Index.ets                入口，先判配置再决定进主界面还是设置页
    ├── SetupPage.ets            首次进入的连接设置页
    ├── ChatPage.ets             对话页
    ├── ModelPage.ets            模型页
    └── SessionsPage.ets         会话页
```

## 开始之前：电脑端要有插件

手机只是个遥控器，真正的 DSH 在电脑上跑。电脑端需要在 DSH 的插件配置里启用
`dsh-harmony-remote`，并让它监听局域网：

```yaml
- insert:
    - id: harmony-remote
      name: 'dsh-harmony-remote'
      config:
        host: '0.0.0.0'      # 只在本机用可以写 127.0.0.1，但手机就连不上了
        port: 3100
        token: '<自己生成一串足够长的随机串>'
        exposeTool: true
```

`host` 绑到 `0.0.0.0` 时**必须**配 `token`：每个请求都要带 `X-DSH-Token` 头。
这个接口能读所有会话记录、能让 agent 在这台电脑上执行命令，等于一台遥控钥匙，
别用弱口令，也别把令牌提交进任何仓库。

## 第一次启动

装好打开 App，会先出现**连接设置页**，填两项：

| 字段 | 填什么 | 能不能留空 |
|---|---|---|
| 服务地址 | 电脑的局域网地址 + 插件端口，如 `http://192.168.1.9:3100` | 不能 |
| 访问令牌 | 与电脑端 `cordis.patch.yml` 里 `harmony-remote` 的 token 一致 | 电脑端绑 `127.0.0.1` 时可留空 |

填好点「保存并连接」，配置存进本机 preferences，**下次启动直接进主界面**，不用再填。

地址填错连不上时，对话页会显示失败原因，旁边有「改地址」按钮可以回去重填。

> 想发一份「装完就带默认地址」的包（比如给同事），可以额外把
> `entry/src/main/ets/common/LocalConfig.example.ets` 复制成 `LocalConfig.ets`
> 并在里面填 `LOCAL_BASE_URL` / `LOCAL_TOKEN` 作为构建期默认值。
> 那个文件在 `.gitignore` 里，不会被提交。

## 本机构建

1. 直接用 DevEco Studio 自带的 hvigor 与 JDK 构建（下面是 Windows 的例子）：

```powershell
$env:DEVECO_SDK_HOME = '<DevEco Studio 安装目录>\sdk'
$env:JAVA_HOME      = '<DevEco Studio 安装目录>\jbr'
$env:PATH           = "$env:JAVA_HOME\bin;$env:PATH"
& '<DevEco Studio 安装目录>\tools\hvigor\bin\hvigorw.bat' assembleApp --no-daemon
```

产物在 `build/outputs/default/` 下：

- `*-unsigned.app` —— App Pack，装机用这个
- `entry/build/default/outputs/default/*.hap` —— 单模块包

> 不带 `DEVECO_SDK_HOME` 会报 `00303217 Invalid value of 'DEVECO_SDK_HOME'`；
> PATH 里没有 `java` 会报 `00308018 spawn java ENOENT`。
> 也可以直接在 DevEco Studio 里点运行，最省事。

## 装到手机

### 推荐：小白调试助手（图形化，不用记命令）

打好的包想直接装到手机上，**建议用「小白调试助手」这类图形化安装工具**：手机打开无线调试
（或插 USB 打开调试模式）后，在工具里选一下打出来的 `.hap` / `.app`，点安装就行，
比手敲 hdc 命令省事，也不用记设备号。

几点提醒：

- 它本质上是把 `hdc` 命令包了一层界面，**签名要求完全一样** —— 未签名的包照样装不上，
  会报 `9568320 no signature file`。
- 手机和电脑要在同一个局域网（无线调试必须），首次连接时手机上会弹允许调试的确认框。
- 装的是同一个包名（`hmos.dsh.stevenjeow`）时会**覆盖**已装版本，不是共存的第二份。

### 命令行方式

```powershell
# 先确认设备连上了
hdc list targets
# 装包（-r 表示覆盖安装）
hdc install -r <路径>.hap
```

`hdc` 在 `<DevEco Studio 安装目录>\sdk\default\openharmony\toolchains\hdc.exe`，
无线调试用 `hdc tconn <手机IP>:<端口>` 连接，端口在手机的「无线调试」页面里看。

### 最省事的方式

直接在 DevEco Studio 里点运行按钮 —— 它会自动构建、签名、安装、启动一条龙。

## 关于签名

仓库里 `build-profile.json5` 的 `signingConfigs` 是空的，所以命令行构建出来的是**未签名**包，
装不上真机。自己用的时候在 DevEco Studio 里配一个本地调试签名即可（会自动写进
`build-profile.json5`，需要登录华为开发者账号）。证书、Profile、密钥库都不要提交到这个仓库。

## 品牌与图标

- 项目名称只用缩写 **DSH**。按 DSH 官方品牌素材使用规范
  （见 `deepseek-ai/deepseek-harness` 仓库的 `GUIDELINES.md`），完整的「DeepSeek Harness」
  是注册商标，不适合直接用作项目名。
- 应用图标是本项目自绘的几何图形（圆角方块 + 白色 `>` 提示符），**不使用、也不修改**
  DeepSeek 任何官方素材。
- 描述里提到「与 DSH / DeepSeek Harness 兼容」这类事实性说明是允许的，本项目只在这一范围内使用该名称。

## 已知限制

- 只支持明文 HTTP 直连局域网（`network_config.json` 放行了 cleartext），没有做 HTTPS
- 只针对手机竖屏调过；平板和横屏没验证
- 换证书 / 换设备后需要重新签名打包

## 许可

[MIT](LICENSE)
