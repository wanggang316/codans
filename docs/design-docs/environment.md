# 设计文档：环境管理（构建通道、路径、环境变量）

**状态：** 已实现（2026-09-05）
**作者：** Gump（与 Claude）

## 背景与范围

codans 有两种构建同时存在于一台机器上：从 `/Applications` 运行的 Release 包，和从 DerivedData 运行的 Debug 包。两者共用一个 bundle id，却各自拥有一套 catalog、settings、zmx 守护进程和 IPC socket。一旦其中任何一样串了，症状都是静默的：两个 app 对同一个 PTY 各挂一个 attach 客户端，输入在两边来回串；dev pane 里跑的 CLI 被生产 app 应答；handoff 指令让 agent 去找一个不存在的子命令。

这些决定原本散落在四处 `#if DEBUG`、五处 `"CODANS_SOCKET_PATH"` 字面量、两份逐字节相同的 socket 路径字符串和一条「必须保持同步」却无人执行的注释里。本文档记录收敛后的结构：**通道决定一次，变量名拼写一次，pane 环境构建一次**，以及哪些资源刻意不隔离。

范围是 `apps/mac` 下四个 Swift target 之间的环境契约：CodansCore（叶子）、CodansKit（CLI 侧库）、`codans-cli`、app。不涉及 Ghostty 自身的配置解析。

## 目标与非目标

**目标**

- 一个 Debug 包和一个 Release 包能同时运行、互不干扰，且不依赖用户做任何配置。
- 每个跨进程边界的名字（环境变量、socket 路径、目录名、命令名）在代码里只有一个拼写点。
- 从 pane 里启动的 CLI 一定回连到生成它的那个 app。
- 测试与冒烟运行能把整个配置根搬到临时目录。

**非目标**

- 按分支或 worktree 隔离。所有 Debug 构建共用 `codans-dev`；需要时用 `CODANS_CONFIG_DIR` 手动隔离。
- 给两个通道不同的 bundle id。这会拆开通知中心身份、Sparkle 状态和 URL scheme 注册，代价大于收益。
- 子进程环境的白名单卫生（git、gh 的 env 转发）。它有自己的机制（`GitProcessEnv`），列在后续项里。

## 设计

### 总览

三个类型，各负责一件事，都在 `CodansCore/Environment/`，因为它是 kit、cli、app 唯一的公共依赖：

| 类型 | 负责 | 消费者 |
|---|---|---|
| `BuildChannel` | 全仓唯一的 `#if DEBUG`；`slug`（`codans-dev` / `codans`）和 `socketPath(uid:)` | `AppDirectories`、`CLIInvocation`、`SocketDiscovery`、`SocketPaths`、CLI 帮助文本 |
| `CodansEnvironment.Key` | codans 读或写的每一个环境变量名，附写者、读者、生命周期 | 所有读写点；旧的类型化持有者（`BuiltinEnvVar`、`TermProgramEnv`、`CLIBundleLocator.EnvKey`、`HandoffKickoff.requestIDEnvironmentKey`）保留 API、从它取值 |
| `HandoffLayout` | `.codans/handoff/` 的文件与目录名 | `HandoffStore`（URL）、`HandoffKickoff`（给接收方的相对路径字符串） |

app 层再加一个 `PaneEnvironment`（`codans/Runtime/`），把「一个 pane 的 shell 以什么环境启动」收成两个阶段，worktree pane 和 Master Terminal 共用。

### 通道隔离了什么

`BuildChannel.current.slug` 派生出全部四样按通道分开的资源：

```
                     Debug                          Release
config root          ~/.config/codans-dev/          ~/.config/codans/
ZMX_DIR              ~/Library/Caches/codans-dev/   ~/Library/Caches/codans/
IPC socket           /tmp/codans-dev-<uid>.sock     /tmp/codans-<uid>.sock
CLI 安装名           /usr/local/bin/codans-dev      /usr/local/bin/codans
```

用构建类型而不是 bundle 身份做判别是刻意的：`codans` CLI 链接同一个 CodansCore，Debug 构建的 CLI 必须和 Debug 构建的 app 算出同一组路径，编译期常量能保证；读 `Bundle.main` 则会分叉，因为 CLI 的 bundle 是它自己。

### 通道没隔离什么

两个构建的 bundle id 都是 `com.gumpw.codans`，凡按 bundle id 寻址的系统资源都是共享的，使用时要知道：

- `UserDefaults.standard`：`@AppStorage` 的面板状态、Command Palette 最近使用、遥测 install-id、Sparkle 的全部状态。
- 系统通知按 bundle id 归属。`codans://focus` 深链**不是**注册的 URL scheme，它只在通知 payload 里由本进程解析，所以不经 LaunchServices。
- Sparkle 在 Debug 里同样运行、同一个 feed。Sentry 在 Debug 里不启动（`CrashReporting` 提前返回）。

### Socket 解析的两种语义

socket 路径的拼写只有一份，但**解析规则故意有两份**，因为两侧回答的问题不同：

```
CLI（SocketDiscovery.resolve）        app（SocketPaths.resolve）
  --socket 标志                          $CODANS_SOCKET_PATH
  → $CODANS_SOCKET_PATH                  → 若等于「对方通道」的默认值：丢弃，用自己的
  → 本通道默认值                         → 否则采用
                                         → 未设置：本通道默认值
```

app 侧的守卫处理「从 Release 的 pane 里 `make mac-run-app`」：子 app 继承了宿主注入的 `CODANS_SOCKET_PATH`，若照单全收会去绑宿主的 socket，报 `alreadyInUse`，自己的 server 起不来，还把错误的 socket 广告给自己的 pane。CLI 侧**绝不能**有这个守卫：pane 里的 CLI 就该拨宿主导出的那个 socket，宿主是哪个通道都一样。两处各自的注释都替对方说明了理由。

历史上 CLI 侧曾把 `$CODANS_SOCKET_PATH` 的读取写在默认参数里，调用方转发自己的可选标志时显式传入 nil、把默认参数顶掉，环境变量从未被读到——dev pane 里的每条命令都打到了生产 app。教训：**读环境变量不要放在 Swift 默认参数里**。

### Pane 环境的两个阶段

```
processBase(inheriting:overrides:socketPath:marketingVersion:)
  1. 继承进程环境
  2. 剥掉 TERM / TERMCAP / TERMINFO / COLORTERM / TERM_PROGRAM(_VERSION)
     —— 让 libghostty 在 PTY 时写入的值生效；从 make → open 启动的 app
        会带着 TERM=dumb，透传下去会弄坏 starship 一类 TUI
  3. 叠加项目 envVars
  4. 最后写 CODANS_SOCKET_PATH、TERM_PROGRAM、TERM_PROGRAM_VERSION
     —— 写在最后，所以项目自定义的同名变量永远遮不住它们

forSurface(base, paneID:, zmxDirectory:)
  5. ZMX_DIR      钉死到本通道的缓存目录
  6. ZMX_SESSION  清空 —— 从 zmx pane 里启动的 app 会继承父会话名，attach 会当作
                  「切换到那个会话」而失败，表现为 tab 一闪就没
  7. CODANS_PANE_ID  pane 自己的 id
```

worktree pane 在 4 和 5 之间还会由 `HierarchyManager.injectingBuiltins` 写入 `CODANS_WORKTREE_PATH` / `CODANS_ROOT_PATH`。Master Terminal 没有项目，走同样两个阶段、overrides 为空。

只注入 `CODANS_PANE_ID` 而不注入 tab / worktree / project id 是有意的：pane id 终生不变，烘进环境是安全的；其余三个会随 pane 被移动而过期，所以由服务端从进程祖先解析。CLI 的 `AliasResolver` 仍认这五个键，是为了让调用方手动导出时能就地短路，但 app 只写 pane 那一个。

### 覆盖点（隔离缝）

| 变量 | 作用 | 典型用法 |
|---|---|---|
| `CODANS_CONFIG_DIR` | 整体搬走配置根，所有 JSON store 跟着走 | 冒烟 / 集成测试，或给某个 worktree 的 dev 构建单独一套数据 |
| `CODANS_SOCKET_PATH` | 指定 IPC socket | pane 内由 app 注入；手动指定实例 |
| `CODANS_CLI_BINARY` | 安装器指向 `.app` 外新编的 CLI | dev |
| `CODANS_GHOSTTY_RESOURCES` | libghostty 资源树的替代根 | 未打包的 `xcodebuild run` |
| `CODANS_DISABLE_ACTION_ROUTING` / `CODANS_DISABLE_THEME_DEV_FALLBACK` | 诊断与测试开关 | 值为 `"1"` 生效 |

完整清单、写者与读者见 `CodansEnvironment.Key` 的逐条注释；那里是唯一真相来源，本表只列覆盖用途的。

### 组件边界

- `BuildChannel`、`CodansEnvironment`、`HandoffLayout` 只依赖 Foundation，无副作用，可在任何 target 使用。
- `SocketDiscovery`（CodansKit）与 `SocketPaths`（app）是两个门面：拼写委托给 `BuildChannel`，各自只保留本侧的解析语义。
- `PaneEnvironment` 属 `codans/Runtime/`，是 app 内唯一写 pane 环境的地方；`HierarchyManager.resolvedEnv` 是它的 Settings 感知封装。
- 新增按通道区分的东西，应从 `BuildChannel.current` 派生，不再新增 `#if DEBUG`。新增环境变量，先在 `CodansEnvironment.Key` 里登记。

## 备选方案

- **按 configuration 给不同 bundle id。** 隔离最彻底，但通知中心、Sparkle、URL scheme 全部一分为二，Debug 包会失去与真实安装一致的系统行为，测的就不再是要发的东西。否决。
- **把两个 socket resolver 合并成一个。** 会丢掉那条故意的不对称，或者要在一个函数里塞两个开关。保留两个门面、共享拼写，成本更低也更诚实。
- **让 `HandoffKickoff` 直接引用 `HandoffStore` 的 URL 再取相对路径。** 会把 prompt 文本和文件系统绑在一起，而 prompt 只需要名字。独立的纯 `HandoffLayout` 更小。
- **注入全部四个层级 id。** tab / worktree / project id 会随 pane 移动而失效，注入即埋雷。只注入不变的那一个。

## Cross-Cutting

- **测试**：`BuildChannelTests`、`CodansEnvironmentTests`、`HandoffLayoutTests`（CodansCore）；`SocketDiscoveryTests`（CodansKit）；`SocketPathsTests`、`PaneEnvironmentTests`、`HierarchyManagerResolvedEnvTests`（app）。`CodansEnvironmentTests` 把旧的类型化持有者钉在目录上，任何一处拼写漂移都会在这里失败。
- **可观测性**：`codans doctor` 打印它解析到的 socket 与 `socketFromEnvironment`；「命令跑到别的 app」先看这个。
- **迁移**：无磁盘格式变化。pane 新增导出 `CODANS_PANE_ID`，仅对显式读它的调用方可见。

## 风险

- **跨分支共享 `codans-dev`。** 一个分支的 Debug 构建写入新枚举值或新字段，老分支的构建读不出来或剥掉。本设计不解决（非目标）；缓解是 `CODANS_CONFIG_DIR`，以及让 catalog 解码对未知枚举值宽容（另行处理）。
- **`ProcessInfo` 默认参数陷阱再次出现。** 缓解：`CodansEnvironment` 的注释与本文档明确禁止；code review 检查。
- **第三方键的语义漂移。** `ZMX_*`、`GHOSTTY_*` 由外部工具定义；目录里登记的是 codans 对它们的用法，不是它们的规范。

## 后续项

不在本次范围、审计中看到的同类问题：

- `GitWorktreeClient` 与 `LiveGitService` 有三处直接透传 `ProcessInfo` 环境给 git，而同目录的 `GitProcessEnv.build` 正是为此存在。
- `LiveGitHubService` 为 `gh` 维护一份独立的转发白名单（`PATH`、`HOME`、`GH_CONFIG_DIR`、`XDG_CONFIG_HOME`）。
- 工具二进制路径各自拼写：`/usr/bin/git` 四处、`/bin/sh` 三处。
- `settings.json` 的文件名在迁移备份代码里拼了四次。
- `WindowActionRouterFeature` 打开 Ghostty 配置时硬编码 `~/.config/ghostty/config`，未按 `GhosttyConfigFile.resolvedConfigURL()` 尊重 `XDG_CONFIG_HOME`。

## 参考

- `docs/architecture.md` 的 IPC 与 Persistence 小节
- `docs/design-docs/cli.md` 的 socket 解析优先级与 pane 注入变量
- `docs/design-docs/agent-handoff.md`
