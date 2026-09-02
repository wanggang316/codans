# 设计文档：CLI（`codans`）

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

> **现状 vs 未接线（读前须知）。** 核心动词集已上线、`codans --help` 可见可调用：`status` / `launch` / `doctor`、`tree`、`project` / `worktree` / `tab` / `pane` 各群、`pane send` / `broadcast`、`agent` / `handoff` 各群。**已定义但未接线**（源码中存在，但未挂进 `CodansCLI.subcommands` 或对应 `*Command.subcommands`，故 `codans <cmd>` 报 unknown subcommand）：各级 `list` 子命令、顶层 `open`、`help-json`。**完全未实现**：`skill.*` 与 `hook.*` 命名空间（`CodansIPC/Method.swift` 无相应 case，`MethodRouter` 兜底 `not wired in this build`）。下文逐处标注，勿把未接线 / 未实现当现状能力。

## 背景与范围

`codans` CLI 是注入到每个 Pane 的命令行界面，是从任意 shell 内部驱动正在运行的 codans 应用的**可编程用户面**。它存在的理由是：本产品是面向 CLI-agent 重度用户的、终端优先的编排器；每个工作流——开 Pane、发文本、跨 Pane 广播、在外部编辑器中打开 worktree——都必须能从用户已经身处的同一个 shell 触达。一个阅读已发布 Skill 的编码 agent 学到的就是**只通过 `codans` 驱动 codans**；应用 GUI 是补充，不是替代。

已就位的同级组件：

- **CodansCore** — 叶子包，承载全部领域类型（`Project`、`Worktree`、`Tab`、`Pane`、各 ID、`Tag`）。CLI 依赖它做 wire 类型。
- **CodansIPC** — Unix socket 上的 JSON-RPC wire 协议（Release：`/tmp/codans-$UID.sock`；Debug：`/tmp/codans-dev-$UID.sock`）。CLI 是参考客户端，应用是参考服务端。`IPC.Method` 枚举（`apps/mac/CodansIPC/Method.swift`）是两端共同 switch 的唯一方法表。
- **HierarchyManager / CatalogStore** — CLI 触发的每个 mutation 的应用侧写入者。每个子命令锚定到一个 RPC 方法（极少数 `open` 走 `editor.*`）。
- **CodansKit**（`apps/mac/CodansKit/`）— CLI 侧共享库：`RPCClient`、`SocketDiscovery`、`AliasResolver`、`Renderer`、`ExitCode`。`codans-cli` 与其测试共用它。

本设计解决的 open question：

- **CLI 二进制名。** 解决为 `codans`，安装时做碰撞检查；早期"`tcode` 作为后备名"的方案已随 Codans 改名废弃（仅安装单一命令 `codans`）。见 [Decisions](#decisions) §D1。
- **CLI 二进制分发。** 解决为：从 Settings → Developer 面板，经单次 macOS 管理员授权对话框，把 bundle 内嵌的已签名二进制 symlink 进 `/usr/local/bin`。见 [Decisions](#decisions) §D2 与 [CLI 安装](#cli-安装)。
- **IPC 背压。** 解决为：每连接有界在飞队列（64），溢出等待 2s 后服务端返回 `IPCError.overloaded`（CLI 退出码 5）。见 [Decisions](#decisions) §D11。

不在范围（归属别处）：

- **任一 RPC 方法的服务端实现** —— 应用侧 socket 路由是另一回事，本文定义*契约*而非服务端 handler。
- **GUI / 深链等价物** —— `codans://` URL 经由相同的 IPC 方法路由（见 architecture §URL scheme）；URL-scheme 解析器归 deeplink 特性所有，不归 `codans`。

## 目标与非目标

### 目标

- **覆盖产品所承诺的全部动词。** Project、Worktree、Tab、Pane、跨 Pane `pane send`、跨作用域 `broadcast`、外部编辑器 `open`。
- **默认机器友好，TTY 上人类友好。** `--json` 发出与 RPC result schema 1:1 的 JSON，使 agent 永远不必去 scrape 文本。
- **无状态的薄 RPC 客户端。** `codans` 不读、不写、不缓存任何属于它自己的持久文件。
- **In-Pane 人体工学。** 每个命令默认作用于"当前 Pane / Tab / Worktree"，读取应用注入的环境变量；显式标志（`--pane`/`--tab`/`--worktree`/`--project`）覆盖。
- **便利别名在任何 mutation 之前解析为 UUID。** 用户可用 `@label`、`current`、index 寻址；内部代码永远只见到 UUID。解析经 `hierarchy.resolveAlias` 一次只读往返完成。
- **一套 wire 协议，两种传输。** CLI 走 socket 上的 JSON-RPC；深链 URL 在应用侧映射到相同方法。CLI 发起与深链发起的命令在下游不可区分。
- **快速且可读地失败。** socket 缺失 → "codans is not running"。schema 不匹配 → `.versionMismatch` 并附两端版本。退出码稳定且可枚举。

### 非目标

- **不带应用运行时的本地回退或只读模式。** `codans` 是控制器；应用没运行就报错。唯一例外是 `codans launch`（它显式负责把应用拉起）。
- **脚本语言内嵌。** 没有 `codans eval`。脚本化通过 hook handler 进行（见 [lifecycle-hooks](lifecycle-hooks.md)，该面**尚未实现**）。
- **包管理。** `codans` 不安装 codans 本身（Sparkle / DMG 负责）。CLI 执行的唯一"安装"是把自身 symlink 进 `/usr/local/bin`。
- **远程控制。** 无 TCP、无 SSH；socket 是本地的。
- **交互式 UI。** 无 TUI 菜单。缺少必需参数即报错。agent 不交互，人类写脚本。
- **shell 函数 / alias 注入。** `codans` 是真实二进制；v1 不提供 `eval "$(codans init zsh)"` 这类 shell 集成层。

## 设计

### 概览

`codans` 是单个 ArgumentParser 根命令二进制。它解析子命令路径，构造类型化 RPC 请求，打开 Unix socket（或报错），发送 length-prefixed JSON 帧，读取响应，并渲染到 stdout。

**为何是这个形状：**

- **ArgumentParser 是唯一框架。** 子命令组合、补全脚本生成、`--help`、`--version` 全是内建，无自定义 dispatch 循环。`@main struct CodansCLI`（`apps/mac/codans-cli/CodansCLI.swift`）是根，`GlobalOptions` 经 `@OptionGroup` 组合进每个子命令。
- **薄 RPC 客户端，不是 microshell。** 每个子命令把 args → `IPC.Request` → renderer，逻辑刻意放在应用侧：我们绝不想要"两个真相来源"。
- **类型化方法枚举的 JSON-RPC。** `IPC.Method` 是 `CodansIPC` 里的 Swift 枚举，两端共同 switch；调用点不散落 stringly-typed 方法名。
- **别名是便利，UUID 是真相。** `AliasResolver`（`CodansKit/Transport/AliasResolver.swift`）对任何非 UUID 的目标预解析；纯 UUID 走本地快路径无往返。
- **输出是一个 renderer 步骤，而非穿插的 print。** `Renderer.emit` / `Renderer.emitObject` 让文本与 JSON 两种模式走同一个 result 类型，使我们无法意外发布只在一种模式下工作的命令。

### 系统上下文图

```
  ┌──────────────────────┐        ┌──────────────────────────┐
  │ user shell / agent   │        │ Codans app               │
  │  (inside any Pane)   │        │   IPC.SocketServer       │
  │                      │        │   ├── system.*           │
  │  $ codans pane send … │        │   ├── hierarchy.*        │
  │       │              │        │   ├── pane.*             │
  │       ▼              │ socket │   ├── terminal.*         │
  │  codans binary       │──────► │   └── editor.*           │
  │   (ArgumentParser)   │  JSON  │   ────── routes ─────    │
  │   AliasResolver      │        │    HierarchyManager      │
  │   RPCClient          │        │    TerminalEngine        │
  │   Renderer           │        │    EditorService         │
  │       ▼              │        │                          │
  │   stdout (text/JSON) │        │                          │
  │   stderr (errors)    │        └──────────────────────────┘
  └──────────────────────┘

  Socket path resolution (SocketDiscovery.resolve):
    1. --socket flag override
    2. $CODANS_SOCKET_PATH               (set by the app in every Pane's env)
    3. build-channel default             (Debug: /tmp/codans-dev-$UID.sock;
                                          Release: /tmp/codans-$UID.sock)

  Injected env vars inside every Pane:
    CODANS_SOCKET_PATH, CODANS_PROJECT_ID, CODANS_WORKTREE_ID,
    CODANS_TAB_ID, CODANS_PANE_ID
```

> 顶层没有 `space` 命名空间，也没有 `CODANS_SPACE_ID`。最高层级是 Project；早期的 Space 容器已被 per-Project `Tag` 取代（见 [project-tags](project-tags.md)）。

### 命令面（实际 shipped 动词集）

下表是 `codans` 实际编译进的命令树，对照 `apps/mac/codans-cli/` 各 `CommandConfiguration` 与 `apps/mac/CodansIPC/Method.swift` 核实。**Subcommand** 列是用户键入的；**IPC method** 列是分发的 `IPC.Method`。

#### 顶层命令

`CodansCLI.configuration.subcommands` 显式挂载：`status`、`launch`、`doctor`、`tree`、`project`、`worktree`、`tab`、`pane`、`broadcast`、`agent`、`handoff`。

| Subcommand | IPC method | 说明 |
|---|---|---|
| `codans status` | `system.status` | server 标识、uptime、connected-clients 数 |
| `codans launch [--wait N]` | *(本地)* | 若未运行则 `open -g Codans.app` 并最多等 N 秒（默认 10）等 socket 出现；唯一会拉起应用的命令 |
| `codans doctor` | *(本地)* | 检查 socket 路径、可达性、是否来自环境变量、CLI 版本；不做应用往返 |
| `codans tree [--project P]` | `hierarchy.listProjects` | **首选发现命令**：一次打印 Project→Worktree→Tab→Pane 全层级 |
| `codans broadcast` | `terminal.broadcastInput` | 见 [send / broadcast](#codans-pane-send--codans-broadcast) |

> `codans --version` 印 `Codans <version>`（ArgumentParser 内建）。

#### `codans project …`

`ProjectCommand.subcommands`：`add`、`rm`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans project add PATH` | `hierarchy.addProject` | `HierarchyManager.addProject` | `PATH`，`[--name NAME]` |
| `codans project rm ID` | `hierarchy.removeProject` | `HierarchyManager.removeProject` | `ID`（别名/名字/`current`） |

> `ProjectList`（`codans project list`，走 `hierarchy.listProjects`）在源码中存在，但**未挂进** `ProjectCommand.subcommands`，因此当前不可经 `codans project list` 调用——用 `codans tree` 看 Project。其底层 `hierarchy.listProjects` 方法本身已在 `MethodRouter` 接线（`codans tree` 正用它），故未接线的只是 CLI 子命令，非服务端方法。Worktree / Tab / Pane 的 `list` 子命令同理（`hierarchy.listWorktrees` / `listTabs` / `listPanes` 均已路由，仅各 `*Command.subcommands` 未挂；见各节脚注）。

#### `codans worktree …`

`WorktreeCommand.subcommands`：`new`、`switch`、`rm`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans worktree new BRANCH` | `hierarchy.createWorktree` | `HierarchyManager.createWorktree` | `BRANCH`，`[--project P] [--path PATH] [--name NAME] [--reuse-existing]` |
| `codans worktree switch ID` | `hierarchy.activateWorktree` | `HierarchyManager.selectWorktree` | `ID` |
| `codans worktree rm [ID]` | `hierarchy.removeWorktree` | `HierarchyManager.removeWorktree` | `ID`，或 `--by-path PATH [--all]`（按规范化路径删一/多行），`[--project P]` |

`--path` 缺省由服务端解析：展开 project 配置的 worktrees 目录并附加分支名；响应回带解析后的绝对路径。`--reuse-existing`：若同规范化路径的 worktree 已存在，返回其 id 而非以 conflict 失败（名字冲突仍失败）。`WorktreeList`（`codans worktree list`）在源码中存在但未挂载。

#### `codans tab …`

`TabCommand.subcommands`：`new`、`switch`、`close`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans tab new [NAME]` | `hierarchy.createTab` | `HierarchyManager.createTab` | `[NAME]`，`[--project P] [--worktree W]` |
| `codans tab switch ID` | `hierarchy.activateTab` | `HierarchyManager.selectTab` | `ID` |
| `codans tab close ID` | `hierarchy.closeTab` | `HierarchyManager.closeTab` | `ID`，`[--project P] [--worktree W]` |

`TabList`（`codans tab list`）在源码中存在但未挂载。

#### `codans pane …`

`PaneCommand.subcommands`：`new`、`focus`、`close`、`label`、`reset`、`send`、`send-key`、`read`、`info`、`capture`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans pane new [CMD…]` | `hierarchy.openPane` | `HierarchyManager.openPane` | `[CMD…]`（省略则默认登录 shell），`[--project P] [--worktree W] [--tab T] [--cwd PATH] [--label TAG…]` |
| `codans pane focus PANE` | `hierarchy.focusPane` | `HierarchyManager.focusPane` | `PANE`（UUID/`@label`/`current`） |
| `codans pane close PANE` | `pane.close` | zmx 守护 `.kill` + sessions 收割 | `PANE`；杀掉 pane 的 zmx 守护并丢弃持久 session 项。与 UI 的 X 按钮（detach 以便日后 attach 复活）不同 |
| `codans pane label PANE TAG…` | `hierarchy.setPaneLabels` | `HierarchyManager.setPaneLabels` | `PANE`，`TAG…`，`[--replace]` |
| `codans pane reset PANE` | `terminal.resetPane` | libghostty reset 绑定动作 | `PANE`；清 scrollback 并重初始化终端，不打扰子进程 |
| `codans pane send [PANE] TEXT` | `terminal.sendInput` / `terminal.sendRawBytes` | `TerminalEngine.sendInput` | 见下 |
| `codans pane send-key [PANE] KEY` | `terminal.sendKey` | ghostty key event | 命名特殊键：`escape/up/down/left/right/tab/enter/backspace/delete/home/end/pgup/pgdn/f1..f12/ctrl_c/ctrl_d/ctrl_l/ctrl_z` |
| `codans pane read [PANE]` | `pane.read` | zmx 守护 `serializeTerminalState` dump | `[--raw]`（vt 格式，保留 ANSI/cursor/modes/OSC 7）`[--tail N] [--range visible\|scrollback\|all]` |
| `codans pane info [PANE]` | `pane.info` | 探测 zmx 守护 | 回带 shell pid + pwd（cursor/modes 在未来 tag 前为 null）；走守护而非 catalog，故陈旧 catalog 行不会冒充 live 真相 |
| `codans pane capture [PANE]` | `terminal.readText` | libghostty 渲染文本 | 纯文本快照；`[--scope viewport\|screen] [--lines N]`。原始 ANSI 字节流捕获**当前不支持**（libghostty 只暴露解析后文本，非原始 PTY 字节流），是 follow-up |

`PaneList`（`codans pane list`，走 `hierarchy.listPanes`）在源码中存在但未挂进 `PaneCommand.subcommands`。

**`codans pane new`** 默认：`--cwd` 回退 `$PWD`；`CMD` 回退登录 shell；`--label` 用 `--label foo bar` 形式接收多个初始标签。

**`codans pane send`** —— 这是最常用命令：

- 一个位置参数 → 发给当前 pane；两个 → 第一是目标 pane，第二是文本。
- 文本默认以 Enter 提交；`--no-enter` 只键入不回车。（wire 层把 Enter 实现为 CR `\r` 而非 `\n`；`\n` 只换行不执行。）
- `--stdin` 从标准输入读到 EOF。
- `--raw <hex>` 发原始字节（如 CSI 序列）——文本路径会丢弃这些；hex 可含 `0x` 与空白。控制字节（ESC/Tab/BS/CR/LF/Ctrl-A..Z）作为 key event 派发以确保 PTY 真正收到，可打印字节走文本通道。`--raw` 与位置文本 / `--stdin` / `--no-enter` 互斥。
- `--focus` 发送后聚焦目标 pane。

#### `codans pane send` / `codans broadcast`

`broadcast` 是**顶层**命令（不在 `pane` 下），把文本扇出到一个作用域：

| Subcommand | IPC method | Args |
|---|---|---|
| `codans broadcast --tab ID TEXT` | `terminal.broadcastInput` | `--tab ID`，`TEXT`，`[--stdin] [--no-enter]` |
| `codans broadcast --worktree ID TEXT` | `terminal.broadcastInput` | `--worktree ID`，`TEXT`，`[--stdin] [--no-enter]` |
| `codans broadcast --label TAG TEXT` | `terminal.broadcastInput` | `--label TAG`，`TEXT`，`[--stdin] [--no-enter]` |

三个作用域标志互斥（由 `CLIBroadcastScopeSelection` 强制）。`broadcast` 用 `IPC.BroadcastScope`（`CodansIPC` 里的 wire 类型，`case tab/worktree/label`）做服务端扇出，省去客户端枚举目标。响应回带 `delivered`（命中 pane 数）。

#### `codans agent …`

`AgentCommand.subcommands`：`list`、`launch`。profile 是 Settings → Agents 里的启动预设（`Settings.agents.profiles`），与 worktree toolbar 的 Agents 菜单同一份数据；设计见 [agent-handoff.md](agent-handoff.md)。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans agent list` | `agent.listProfiles` | `AgentHandlers.listProfiles` | 无；每行回带 id、名字、agent、enabled、PATH 探测结果（未探测完为 null）、是否支持 prompt、完整启动命令 |
| `codans agent launch [PROFILE]` | `agent.launch` | `HierarchyClient.launchAgent` | `[PROFILE]`（名字或 id）或 `--agent TOKEN`（该 agent 第一个启用的 profile，缺则临时裸预设），`[--project P] [--worktree W] [--prompt TEXT\|-] [--tab \| --split right\|left\|up\|down] [--background]` |

`launch` 走与 toolbar 相同的管线（渲染 profile → 合成 `ScriptDefinition` → 新 tab / 分屏 / 当前 pane），永不复用 run pane。禁用的 profile 以 `conflict` 拒绝；不支持初始 prompt 的 agent 带 `--prompt` 以 `unsupported` 拒绝；重名 profile 以 `conflict` 要求传 id。

#### `codans handoff …`

`HandoffCommand.subcommands`：`to`、`save`。源 pane 默认为**调用方 pane**（`--pane` 覆盖），因此 agent 在自己 pane 里执行即交接自己。工件在 worktree 的 `.codans/handoff/` 下。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans handoff to AGENT` | `handoff.to` | `HandoffHandlers.to` | `AGENT`（raw value / 可执行名 / 显示名），`--brief TEXT\|-` 或 `--no-brief`（二选一，必填），`[--pane PANE] [--profile NAME\|ID] [--note TEXT] [--no-launch]` |
| `codans handoff save` | `handoff.save` | `HandoffHandlers.save` | `--brief TEXT\|-` 或 `--no-brief`，`[--pane PANE] [--note TEXT]` |

- 可启动的接收方是有 `promptStyle` 的 agent（当前 `claude-code` / `codex` / `gemini`）；其它 agent 只能配合 `--no-launch`。
- briefing 缺失 → `invalidParams` 并附可直接粘贴的 heredoc；不合格（缺 `## Objective` / `## Current State` / `## Next Steps`）→ `invalidParams` 且零副作用。
- Server 项目 → `unsupported`（工件目录在远端）。
- 环境变量 `CODANS_HANDOFF_REQUEST_ID`（仅应用内面板注入的请求会设置）随请求上送；已被处理或被面板回退取代的请求以 `conflict` 拒绝。
- 响应回带 `artifactPath`、`outgoingAgent`、`receiver`、`branch`、`changedFileCount`、`archivedPath`、`sessionExcerptPath`、`briefing`（`inline`/`none`）、`hasBriefing`、`launchedPane`。

#### `codans open`

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans open [<path>] [--in EDITOR]` | `editor.open` | `EditorService` | `[<path>]`（默认 `$PWD`，相对路径相对 `$PWD` 解析），`[--in EDITOR]` |

> `OpenCommand` 在源码中存在（`apps/mac/codans-cli/Commands/OpenCommand.swift`），但当前**未挂进** `CodansCLI.subcommands`，故 `codans open` 与 `list` 命令同属"已实现但未接线"状态。服务端 `editor.open` 方法本身已在 `MethodRouter.routeEditor` 接线，未接线的只是 CLI 子命令。其契约仍是耐久的，故在此记录。

`EDITOR` 是编辑器 id（`cursor`/`zed`/`vscode`/`xcode`/`finder`/`ghostty`/…）。`path` 在 C8a Phase 4c 后是单一位置参数（早先的 `<worktree>` / `--path` 二分已合并）。编辑器优先级在服务端 `EditorService` 处理：(1) 显式 `--in`（strict，未安装即报错）→ (2) `Settings.projects[pid].defaultEditor`（路径落在已注册 Project 内时，lenient）→ (3) 全局 `Settings.defaultEditorID`（lenient）→ (4) 内建注册表优先级遍历 → (5) Finder 回退（永远可用）。

> editor 的 IPC 面是 `editor.*`（`editor.describe`/`editor.open`/`editor.setGlobalDefault`/`editor.setProjectDefault`），不是更早设想的 `system.openInEditor` / `hierarchy.setProjectEditor`。C8a Phase 4c 把 `editor.setDefault` 改名为 `editor.setGlobalDefault` 并新增 `editor.setProjectDefault`。

#### `codans help-json`

`HelpJSONCommand`（`apps/mac/codans-cli/HelpJSONCommand.swift`）发出整棵 `codans` 子命令树的 JSON（`{name, abstract, subcommands}`），供外部工具推断 CLI 形状而不必解析 `--help` 文本。它配置为 `shouldDisplay: false`（默认 `--help` 隐藏）。**注意：** 它在源码中存在并能 `walk(CodansCLI.self)`，但**未挂进** `CodansCLI.subcommands`，因此当前不可经 `codans help-json` 调用——其 walk 逻辑可达而命令本身不可达。

### 寻址与别名解析

`PANE` / `TARGET` 参数由 `AliasResolver`（`CodansKit/Transport/AliasResolver.swift`）解析，对每种 kind（`project`/`worktree`/`tab`/`pane`）：

1. **UUID** —— 任何合法 UUID 串假定为规范 ID，本地校验，无往返。
2. **`current`** —— 经对应的 `CODANS_{PROJECT,WORKTREE,TAB,PANE}_ID` 环境变量解析（pane 级命令多从 pane id 反推 project/worktree/tab）。
3. **index** —— 当前父容器内 1-based 位置（CLI 侧 1-based 贴合人类，内部 0-based）。
4. **`@label`** —— 仅 Pane：经 `hierarchy.resolvePaneLabel` 解析；多于一个匹配则报 conflict。
5. **path glob** —— 仅 Worktree：经 `hierarchy.resolveWorktreeGlob`。

所有非 UUID 解析是一次到 `hierarchy.resolveAlias` 的往返，先于真正的方法调用。结果只在单次 `codans` 调用内缓存，绝不跨调用。

### Wire 协议

复用 architecture §IPC 的信封规范。要点：

- **请求帧** 是 `UInt32` big-endian 长度前缀 + 恰好 N 个 UTF-8 JSON 字节（**无尾随换行**），每帧 16 MiB 硬上限（超限 → `IPCError.invalidFrame`，关连接）。
- **方法枚举。** `IPC.Method`（`apps/mac/CodansIPC/Method.swift`）覆盖每个 RPC，raw value 是小写点分串（`hierarchy.createWorktree`、`terminal.sendInput`）。两端 switch 此枚举，绝不 switch raw 串。
- **流终止契约。** server-streaming 方法在请求上设 `stream: true`，服务端发 `{id, stream: true, result: …}` 帧。流在**任一**侧关其写半边时结束：服务端优雅收尾发一个终帧 `{id, stream: false, error?: …}` 再关写半边；客户端读到 EOF 后干净退出。客户端发起收尾则 `shutdown(SHUT_WR)`，服务端 flush 在飞帧后发终帧。任一侧 abrupt 关闭被对端视为隐式 `.internal` 流终止。
- **错误码。** `IPCError` 含 `.unknownMethod` / `.invalidParams` / `.notFound` / `.conflict` / `.unsupported` / `.internal` / `.overloaded` / `.versionMismatch`。
- **兼容性握手。** 握手是专用的首帧 RPC `system.hello`（**非**逐请求 header——逐请求 header 会对每次调用重复编码版本信息，并与"一连接一流"规则冲突）。连接打开 → 客户端发 `system.hello`（带 `clientVersion`/`clientBinary`）→ 服务端回 `serverVersion` / `appBundleVersion` / `protocolMajor` / `protocolMinor` / `deprecatedMethods`。major 偏斜浮现为 `.versionMismatch`；minor 偏斜浮现为每会话一次的 stderr 警告。

  **`codans` 把 `system.hello` 与真实请求作为两个 pipelined 帧一次写出**（每次调用都开新连接），使热 socket 上不增加额外往返。版本偏斜时服务端对 hello 返回 `.versionMismatch` 并丢弃第二帧；响应 ID 按 hello vs real 配对，否则抛 `.misorderedResponse`。

### 错误处理模型

- **退出码** 跨版本稳定（`CodansKit/ExitCode.swift`）：`0` 成功 · `1` 用户错误 · `2` not-found · `3` conflict · `4` unsupported · `5` overloaded · `6` versionMismatch · `10` socket 不可达（应用未运行）· `11` 请求超时 · `12` launch 超时 · `13` socket 权限拒绝 · `14` socket 不可用（路径不是 socket / 过长 / socket(2) 失败）· `20` 内部错误。
- **socket 连接失败分类。** connect(2) 的 errno 在 `CodansKit/Transport/SocketConnectionFailure.swift` 收敛成一组 `SocketFailureKind`：`socket-missing`（ENOENT）· `app-not-running`（ECONNREFUSED，陈旧 socket 文件）· `permission-denied`（EACCES/EPERM）· `not-a-socket`（ENOTSOCK）· `path-too-long` · `server-busy`（EAGAIN，accept backlog 满）· `timed-out` · `connection-lost`（已连接后 EPIPE/ECONNRESET）· `socket-create-failed` · `unknown`。分类按**调用方该怎么办**映射退出码：起应用后重试（10）、原样重试（5 / 11）、需要人介入（13 / 14）。未映射的 errno 保持 `unknown` 而非并入相邻类别——错误的类别比诚实的"未知"对分支脚本更有害。
- **分类的可脚本化出口。** 除退出码外，`codans doctor` 输出 `socketStatus`（上述 raw 值，或 `ok`）与可选 `socketHint`，使脚本无须 grep stderr 即可分支。`codans launch` 对起应用无法修复的类别（权限 / 路径）立即失败，不再空转 `--wait` 秒轮询。
- **stderr 文本模式：** 首行 `error: <message>`，后续 `  hint: <suggestion>`（若适用）；无 backtrace、无 "please file a bug" 样板（贴合 git / Ghostty 风格）。
- **进程级 SIGPIPE 忽略。** `main()` 进程级 `signal(SIGPIPE, SIG_IGN)`，使任何写路径（stdout 被管到 `head`、半关 socket）返回 EPIPE 而非以 exit 141 在错误路径渲染前杀死 CLI。
- **取消。** SIGINT 关 socket 中止在飞请求；部分副作用由应用负责回滚（mutation 在 `HierarchyManager` 层原子）。

### 组件边界

```
apps/mac/codans-cli/                  (the CLI binary)
├── CodansCLI.swift                   ArgumentParser root + GlobalOptions
├── HelpJSONCommand.swift             codans help-json (defined; not yet wired)
└── Commands/
    ├── AppCommands.swift             status / launch / doctor
    ├── TreeCommand.swift             tree (+ HierarchyTree / PanePath helpers)
    ├── ProjectCommands.swift         project add / rm
    ├── WorktreeCommands.swift        worktree new / switch / rm
    ├── TabCommands.swift             tab new / switch / close
    ├── PaneCommands.swift            pane new / focus / close / label / reset / info / read
    ├── TerminalCommands.swift        pane send / send-key / read(capture) ; broadcast
    ├── OpenCommand.swift             open (defined; not yet wired)
    └── CommonCommandSupport.swift    CLISession / CommandRunner / shared input plumbing

apps/mac/CodansKit/                   (CLI-side shared library)
├── Transport/{RPCClient, SocketDiscovery, AliasResolver, UnixSocketTransport, Transport}.swift
├── Render/{Renderer, Mode}.swift
├── ExitCode.swift
└── CLIArgumentHelpers.swift

Dependencies:
  codans-cli → CodansCore, CodansIPC, CodansKit, ArgumentParser, Foundation
  codans-cli ⇍ Runtime, Hooks, Git, App                       (hard rule)
```

- **`codans-cli` 允许 import：** `CodansCore`、`CodansIPC`、`CodansKit`、`ArgumentParser`、`Foundation`。
- **禁止：** `AppKit`、`SwiftUI`、`GhosttyKit`、TCA、`@Observable`，以及应用内任何 `Runtime|Hooks|Git|App` 子模块。架构依赖规则已陈述，由 review 强制。
- **`Render/*` 无副作用。** 纯函数 `(Result, Mode) -> String`。

## CLI 安装

> 取代早先"首次启动安装进 `~/.local/bin` + `codans install-cli` + PATH 提示"的方案。该方案的 PATH 提示在结构上有误导（它读 GUI 进程的 `PATH`，那来自 launchd，永不反映 shell rc），且 `~/.local/bin` 不在 macOS 默认 `PATH` 上。

CLI 二进制已由 `scripts/embed-codans.sh` 内嵌到应用 bundle 的 `Contents/Resources/bin/codans`，release 构建随应用一起签名，故 symlink 目标已是稳定、已签名、已公证的产物。

### 模型

安装器对每次 install / uninstall 发出**一条管理员授权的 shell 命令**，经进程内 `NSAppleScript` 执行，使授权对话框以 codans 应用图标与 bundle 名渲染。

- **安装路径：** Release 构建管理 `/usr/local/bin/codans`；Debug 构建管理 `/usr/local/bin/codans-dev`，以免本地开发夺走生产 `codans`。选 `/usr/local/bin` 正因它在默认 macOS PATH 上、位于 `/usr/bin` 之前（`/etc/paths` 如此排）；而 `/opt/homebrew/bin` 不在非 Homebrew shell 的 PATH 上。一个新用户（含读 Skill 的 agent）经单次对话框 + 一次回车即得到可用 `codans`。
- **symlink 目标：** bundle 内 `Bundle.main.resourceURL/bin/codans`。应用移动与 Sparkle 升级保留该相对路径，故 symlink 无需重指。
- **特权模型：** 特权工作是一次 shell 脚本调用，做 (a) `mkdir -p /usr/local/bin`，(b) 仅对在先前非特权探测中已核实为缺失或我方自有 symlink 的项 `rm -f`，(c) 对缺失项 `ln -s`。探测是非特权的、每次 Settings 卡片出现都跑。
- **PATH 提示：** 移除。`installed && !onPath` 这个状态空间不复存在。

### 碰撞检查

二进制以 `codans` 出货。非特权探测把目标分类为 `absent` / `ourSymlink`（解析到我方 bundle 二进制）/ `foreign`。任何 `foreign` 报告为 `.collision(owner:)`，且**对话框永不弹出**——我们不会为一个明知会拒绝执行的操作请求管理员权限。卡片提示用户自行移除外来工具后重试。

### 特权脚本的耐久约束

- **`NSAppleScript` 不能编译含裸换行的 `do shell script`。** 多行脚本必须在 `\n` 处 split，再用 AppleScript 源里的 `& linefeed &` 重新拼接。
- **TOCTOU 复核。** 特权 symlink 清理必须在 execute 时用 `readlink` 重新核实（非特权探测与特权执行之间存在 TOCTOU 窗口）；两侧都用 `resolvingSymlinksInPath()` 比较（可经受 Gatekeeper app-translocation）。一个被用户替换、指向 `/usr/bin/sudo` 的 `~/.local/bin/codans` 不会被移除。
- **一操作一对话框。** 每次 install / uninstall 是单条 `do shell script`；macOS 不会把同手势里的兄弟授权提示合并，故合成一条命令。
- **`set -e` 保证原子。** 任何 `ln` / `rm` 失败即中止，部分状态不可能存在；成功前缀至多是幂等的 `mkdir -p` 与对我方自有 symlink 的 `rm`。
- **shell 注入卫生。** bundle 二进制 URL 是唯一插值，用单引号 + `'\''` 双写转义；脚本其余是字面路径。
- **遗留清理。** 安装时若 `~/.local/bin/{codans,tcode}` 解析到我方 bundle，同一特权脚本顺带移除；外来文件留置不动。

### 组件边界（安装器）

```
CLIInstallerClient (MainActor)
  • Paths { symlink: /usr/local/bin/codans (Debug: codans-dev),
            legacyLocalBin…, bundledBinary: …/Resources/bin/codans }
  • probe()      → CLIInstallStatus            unprivileged, read-only
  • install()    → Result<…, CLIInstallError>  one auth dialog
  • uninstall()  → Result<…, CLIInstallError>  one auth dialog
        │
        ▼
PrivilegedShell (nonisolated)
  • run(command:prompt:)  via NSAppleScript "do shell script … with administrator privileges"
  • .userCancelled  (NSAppleScript errno -128)  /  .scriptFailed(stderr)
        │
        ▼
CLIFilesystem (probe only; real impl + test fakes)
```

依赖方向 `App → Client → Foundation/AppKit` 不变；`CLIBundleLocator` 原样复用（dev 经 `CODANS_CLI_BINARY` 环境变量覆盖，指向 bundle 外新构建的二进制）。

## 备选方案（Alternatives）

- **A1 — 二进制改名 `touch`/`tch`。** 否决：`touch` 撞 POSIX，`tch` 难记。保 `codans`，碰撞检查处理边角。
- **A2 — 单一 `codans call METHOD [JSON]` 动词。** 否决：无补全、无校验、无可发现性，每个用户都得学 raw 方法名。CLI 只暴露类型化命令。
- **A3 — gRPC / Cap'n Proto 取代 JSON-RPC。** 否决：外部 codegen 工具链、二进制 wire 难调试、丢失 agent 可读的 JSON。边界低带宽，可观测性胜过解析成本。
- **A4 — 让 `codans` 在应用未运行时做部分工作。** 否决：破坏"无状态"不变量，引入两套读路径，冒 last-known vs live 分歧的险。除 `codans launch` 外一律干净报错。
- **A5 — `codans` 上的交互式 TUI。** 否决：对 agent 不友好（读不了 TUI），与 GUI 重复。
- **A6 — 别名解析器只放服务端（客户端发裸串）。** 否决：客户端会丧失对畸形 UUID 快速失败的能力。UUID 快路径在 `codans`，真实解析器在应用。
- **A7 — 每命名空间一个二进制（`codans-pane` 等）。** 否决：违反用户预期，倍增补全脚本，无任何轴上的明确收益。

### CLI 安装备选

- **A-I1 — 经登录 shell 探测真实 shell PATH，保留 `~/.local/bin`。** 否决：修了症状不治病；新机用户仍须改 shell profile，GUI/cron 仍找不到 `codans`。
- **A-I2 — 自动编辑 shell rc 文件加 `~/.local/bin`。** 否决：跨 shell 脆弱，与 mise/asdf/direnv 冲突，且结构上够不到 GUI/cron 环境。
- **A-I3 — 非特权写 `/usr/local/bin`。** 否决：仅在 Homebrew 用户自有目录时成立；把 Homebrew 假设泄漏进一个面向所有 macOS 主机的工具。
- **A-I4 — 打包特权 helper（SMJobBless / SMAppService）。** 否决：对一次性 symlink 操作是过度工程；带来永久的签名/公证/版本协商成本。AppleScript 管理员授权是这一规模一次性特权操作的 macOS 钦定形状。

## Decisions

每个判断附理由。"Supacode-parallel"指与参考项目 supacode/supaterm 同选；"divergent"指不同选及原因。

- **D1 — 主二进制名 `codans`。（解决 binary-name open question。）** ergonomic 收益太大不可让，碰撞检查安装器处理边角。*（2026-06-11 Codans 改名后废弃 `tcode` 后备名——CLI 仅安装单一命令 `codans`；碰撞检查仍对外来 `/usr/local/bin/codans` 中止，但不再提供自动后备名。）*
- **D2 — Release 安装进 `/usr/local/bin/codans`，经单次管理员授权对话框。（解决 binary-distribution open question。）** `/usr/local/bin` 在默认 macOS PATH 上，故 `codans` 在每个 shell / GUI launcher / cron 上下文都可用、无须 rc 编辑。Debug 装 `/usr/local/bin/codans-dev`。特权写是每 install/uninstall 一次进程内 `NSAppleScript` 调用，对话框以应用图标与 bundle 名渲染。symlink 指向 bundle 内 `Contents/Resources/bin/codans`，故应用升级保留安装。完整安装设计见 [CLI 安装](#cli-安装)。*（早先方案为 `~/.local/bin` + PATH 提示，因提示结构性嘈杂、目录不在默认 PATH 上而被取代。）*
- **D3 — `codans` 在应用未运行时报错，唯 `codans launch` 例外。** "`codans` 无状态"是这个 CLI 最有价值的属性；放松它意味着永远两套代码路径。
- **D4 — 便利别名经服务端 `hierarchy.resolveAlias` 解析，不在 CLI 解析。** 保持名字解析为唯一真相来源；客户端只本地校验 UUID 格式。
- **D5 — `pane send` / `broadcast` 在 wire 上分别走 `terminal.sendInput` / `terminal.broadcastInput`，broadcast 用 `scope` 区分服务端扇出。** 减小客户端复杂度，让单个观察者对单播与扇出一视同仁。
- **D6 — `--json` 全局且逐动词，每个 result 类型与 RPC 1:1。** 这是 agent 保持可靠的方式；文本 renderer 是人类便利，非主契约。
- **D7 — 退出码稳定且可枚举。** agent 与 shell 脚本必须能按码分支；预先定一组固定码避免"事事 exit 1"。请求超时（11）与 launch 超时（12）分开，使脚本判 `$? -eq 12` 明确表示"应用没起来"。
- **D19 — socket 连接失败按"补救动作"分类，而非按 errno 逐一暴露。** 单一 "cannot connect" 桶迫使调用方 grep stderr 才能把"应用没起来"（重启即可）与"socket 属于另一个 uid"（需要人）区分开。类别数保持在能改变调用方行为的粒度上：起应用后重试 / 原样重试 / 停下找人。errno 本身只在 message 里作为佐证出现，不进入契约。
- **D8 — 流式 RPC 用 `stream: true` + 双向 EOF 终止，无多路复用。** 一连接一流（在其 `system.hello` 之后）；需要两个流就开两个连接。
- **D9 — 每连接有界在飞队列 64，溢出等 2s 后返回 `IPCError.overloaded`。（解决 backpressure open question。）** 防止陷入循环的 agent 把应用 OOM。
- **D10 — `system.hello` 是专用首帧 RPC，非逐请求 header；与真实请求 pipelined 一次写。** 使"每次调用开新连接"属性干净存活——每个新连接恰付一次 `system.hello` 往返。
- **D11 — CLI 本地做 UUID 快路径，其余都是 mutation 前一次服务端往返。** 用延迟换一致性；本地 socket 往返成本（亚毫秒）可忽略。
- **D14 — `codans open` 用 `EditorService` 的内建注册表 + 用户模板，走 `editor.*` IPC 面。** 服务端 4 级优先级（显式 `--in` → per-Project 覆盖 → 全局默认 → Finder 回退）比 CLI 侧 Launch Services 发现更简单，且把"哪个编辑器"的真相留在应用侧。
- **D20 — `handoff` 的源默认是调用方 pane，且 briefing 必须显式给出或显式放弃。** 让在线 agent 交接自己是主路径（它持有任何 transcript 都无法复原的工作上下文）；`--brief`/`--no-brief` 二选一避免 codans 替第三方调用方发起模型调用。接收方只在 `AgentCatalog` 有已验证 `promptStyle` 时可启动；其它 agent 走 `--no-launch`。见 [agent-handoff.md](agent-handoff.md)。
- **D18 — `broadcast` 在顶层命名空间，而 `send` 在 `codans pane` 下。** `broadcast` 是显式的扇出动作、置于顶层减少键入；`send`/`send-key`/`read`/`capture` 作为 pane 级操作归在 `pane` 子命令树下（与 `codans pane send` 的 discussion 示例一致）。

## Cross-Cutting

### 安全

- **Socket 认证。** Unix socket mode `0600` + 用户 uid；accept 时经 `SO_PEERCRED` / `LOCAL_PEERCRED`（macOS）验证 peer，其他 uid 立即关闭。给出进程级隔离，无须显式 token。
- **`pane send` / `broadcast`** 向 Pane 注入文本（含 Enter）——若目标 pane 跑 shell 即可执行命令。这是*刻意*的（agent 正是这么干），但意味着这些命令绝不可被外来进程触达；同一 socket 认证保护它。
- **`codans open`** 经 `editor.*` 走 `Process` argv 数组；编辑器名在服务端校验，路径绝不过 shell 解释器。

### 版本与兼容

- **应用上的 semver。** major 跳变信号 wire 破坏性变更。`codans` 与其出货的应用绑定，但 `codans --version` / `codans doctor` 同时显示两端版本。
- **滚动兼容窗口。** 一个 major 内 CLI 优雅降级：未知方法返回友好错误；老服务端忽略新可选参数；`system.hello` 的 `deprecatedMethods` 使 CLI 每会话一次警告弃用方法。

### 性能

- **往返预算。** 每个非流式命令应在热应用上 < 50ms p95（`codans` 每次调用开新连接以保持认证模型简单）。socket accept + JSON 解码 + 进程内分发 + JSON 编码 = 低毫秒级。
- **冷启动。** `codans launch` 最多等 10s 等 socket 出现；超时 exit 12。

## Risks

| 风险 | 缓解 |
|---|---|
| `codans` 名字在 Linuxbrew / 重 TCP 配置用户上碰撞 | 安装碰撞检查对外来 `/usr/local/bin/codans` 中止，提示用户清理后重试 |
| 用户 `codans` 与运行中应用版本偏斜 | `system.hello` 报告两端版本，偏斜触发明确 stderr 警告；`codans status` / `codans doctor` 是规范诊断 |
| agent 发 wedge 工作流填满在飞队列 | 每连接 64 深队列 + `IPCError.overloaded`（exit 5） |
| 同用户的恶意/有缺陷本地进程发现 socket 驱动应用 | `SO_PEERCRED` 限同用户；记为已接受威胁模型 |
| path-glob worktree 解析歧义 | list 形动词返回全部匹配；mutation 形动词报 `.conflict` 并印候选，用户用 UUID 重跑 |
| UUID 快路径接受了不匹配任何实体的 UUID | 服务端方法发 `notFound`（exit 2）+ 建议；不做模糊匹配（静默纠正更糟） |
| 两个 `codans` 调用竞争同一 mutation | `HierarchyManager` 在 `@MainActor` 串行化；调用按到达顺序落地 |
| 用户取消授权对话框（安装） | `NSAppleScript` 返回 errno -128 → `.userCancelled`，状态不变，卡片提示重试 |
| 用户安装后移动 .app → bundle 路径变 → symlink 悬空 | 探测经 `inspect()` 的"resolved == bundled"检查发现不匹配，分类为 `foreign` 浮现为 `.collision`，用户点 Retry 重装 |

## 参考

- CLI 源码：`apps/mac/codans-cli/`
- CLI 侧共享库：`apps/mac/CodansKit/`
- wire 协议 / 方法枚举：`apps/mac/CodansIPC/Method.swift`
- 领域类型：`apps/mac/CodansCore/`
- CLI 安装器：`apps/mac/codans/App/Clients/CLIInstallerClient.swift`、`PrivilegedShell`；bundle 定位 `apps/mac/CodansCore/CLI/CLIBundleLocator.swift`
- 嵌入脚本：`apps/mac/scripts/embed-codans.sh`
