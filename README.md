# DSH 鸿蒙遥控器

用鸿蒙手机远程操作电脑上的 DSH（DeepSeek Harness）的聊天客户端。纯 ArkTS + ArkUI 原生实现，
不套网页壳。电脑端跑 `dsh-harmony-remote` 插件提供 HTTP 接口，手机 App 通过局域网直连。

- 包名：`hmos.dsh.stevenjeow`
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
│   ├── ApiClient.ets          网络层：接口封装、超时、错误码翻译
│   ├── LocalConfig.ets        本机私有配置（不进版本库，需自己创建）
│   ├── LocalConfig.example.ets 私有配置模板
│   └── MarkdownView.ets       轻量 Markdown 渲染器
└── pages/
    ├── Index.ets              入口，底部三个 Tab 的容器与共享状态
    ├── ChatPage.ets           对话页
    ├── ModelPage.ets          模型页
    └── SessionsPage.ets       会话页
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
这个接口能读所有会话记录、能让 agent 在这台电脑上执行命令，等于一台遥控钥匙，别用弱口令，
也别把令牌提交进任何仓库。

## 本机构建

1. 把 `entry/src/main/ets/common/LocalConfig.example.ets` 复制成
   `entry/src/main/ets/common/LocalConfig.ets`，填上自己的局域网 IP 和令牌。
   这个文件已经在 `.gitignore` 里，不会被提交。

2. 命令行构建（用 DevEco Studio 自带的 hvigor 与 JDK）：

```powershell
$env:DEVECO_SDK_HOME = 'D:\DevEco Studio\sdk'
$env:JAVA_HOME      = 'D:\DevEco Studio\jbr'
$env:PATH           = "$env:JAVA_HOME\bin;$env:PATH"
& 'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleApp --no-daemon
```

产物在 `build/outputs/default/` 下：

- `dsh-default-unsigned.app` —— App Pack，装机用这个
- `entry/build/default/outputs/default/entry-default-unsigned.hap` —— 单模块包

> 不带 `DEVECO_SDK_HOME` 会报 `00303217 Invalid value of 'DEVECO_SDK_HOME'`；
> PATH 里没有 `java` 会报 `00308018 spawn java ENOENT`。

3. 装机：`hdc install <路径>.hap`，或者直接用 DevEco Studio 运行。

## 关于签名

仓库里 `build-profile.json5` 的 `signingConfigs` 是空的，所以上面构建出来的是**未签名**包，
装不上真机。自己用的时候在 DevEco Studio 里配一个本地调试签名即可（会自动写进
`build-profile.json5`）。证书、Profile、密钥库都不要提交到这个仓库。

## 已知限制

- 只支持明文 HTTP 直连局域网（`network_config.json` 放行了 cleartext），没有做 HTTPS
- 只针对手机竖屏调过；平板和横屏没验证
- 换证书 / 换设备后需要重新签名打包

## 许可

未声明许可证。默认保留所有权利。
