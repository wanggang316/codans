# 设计文档：CLI（`codans`）

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

> **命令与接口范围。** 已注册的命令包括：`status` / `launch` / `doctor`、`tree`、`project` / `worktree` / `tab` / `pane` 各群（含各级 `list`）、`pane send` / `broadcast`、`agent` / `handoff` 各群（含 `agent status` / `agent wait`）、`workspace` 各群、顶层 `open`、本地的 `skill` 群与 `help-json`。`help-json` 可调用，但不显示在默认 `--help` 中；`--json` 一律是 `{schemaVersion, data | error}` 信封。**完全未实现**：`skill.*` 与 `hook.*` IPC 命名空间（`CodansIPC/Method.swift` 无相应 case，`MethodRouter` 兜底 `not wired in this build`；`codans skill` 是纯本地文件操作，不经 IPC）；`IPC.Method` 里已声明但 `MethodRouter` 未路由的只剩 `hierarchy.zoomPane` / `unzoomPane`（应用没有 zoomed-pane 渲染，`SplitTree.zoomed` 仅被 `focusPane` 写入）与 `hierarchy.setProjectEditor`（项目编辑器设置使用 `editor.setProjectDefault`）。

## 背景与范围

`codans` CLI 是注入到每个 Pane 的命令行界面，是从任意 shell 内部驱动正在运行的 codans 应用的**可编程用户面**。它存在的理由是：本产品是面向 CLI-agent 重度用户的、终端优先的编排器；每个工作流——开 Pane、发文本、跨 Pane 广播、在外部编辑器中打开 worktree——都必须能从用户已经身处的同一个 shell 触达。一个阅读已发布 Skill 的编码 agent 学到的就是**只通过 `codans` 驱动 codans**；应用 GUI 是补充，不是替代。

已就位的同级组件：

- **CodansCore** — 叶子包，承载全部领域类型（`Project`、`Worktree`、`Tab`、`Pane`、各 ID、`Tag`）。CLI 依赖它做 wire 类型。
- **CodansIPC** — Unix socket 上的 JSON-RPC wire 协议（Release：`/tmp/codans-$UID.sock`；Debug：`/tmp/codans-dev-$UID.sock`）。CLI 是参考客户端，应用是参考服务端。`IPC.Method` 枚举（`apps/mac/CodansIPC/Method.swift`）是两端共同 switch 的唯一方法表。
- **HierarchyManager / CatalogStore** — CLI 触发的每个 mutation 的应用侧写入者。每个子命令锚定到一个 RPC 方法（极少数 `open` 走 `editor.*`）。
- **CodansKit**（`apps/mac/CodansKit/`）— CLI 侧共享库：`RPCClient`、`SocketDiscovery`、`AliasResolver`、`Renderer`、`ExitCode`。`codans-cli` 与其测试共用它。

主要契约：

- **CLI 二进制名。** Release 为 `codans`，Debug 为 `codans-dev`；安装时做碰撞检查，不提供自动后备名。见 [Decisions](#decisions) §D1。
- **CLI 二进制分发。** 从 Settings → Developer 面板，经单次 macOS 管理员授权对话框，把 bundle 内嵌的已签名二进制 symlink 进 `/usr/local/bin`。见 [Decisions](#decisions) §D2 与 [CLI 安装](#cli-安装)。
- **IPC 请求调度。** 每连接串行处理请求。`inflightLimit` 默认为 64，但当前串行循环的在飞计数最多为 1；保留的溢出分支立即返回 `IPCError.overloaded`（CLI 退出码 5），没有 2 s 等待。见 [Decisions](#decisions) §D9。

不在范围（归属别处）：

- **任一 RPC 方法的服务端实现** —— 应用侧 socket 路由是另一回事，本文定义*契约*而非服务端 handler。
- **GUI / 深链等价物** —— `codans://` URL 经由相同的 IPC 方法路由（见 architecture §URL scheme）；URL-scheme 解析器归 deeplink 特性所有，不归 `codans`。

## 目标与非目标

### 目标

- **覆盖产品所承诺的全部动词。** Project、Worktree、Tab、Pane、跨 Pane `pane send`、跨作用域 `broadcast`、外部编辑器 `open`。
- **默认机器友好，TTY 上人类友好。** `--json` 发出与 RPC result schema 1:1 的 JSON，使 agent 永远不必去 scrape 文本。
- **应用控制命令使用薄 RPC 客户端。** 层级、终端与 agent 状态由应用管理；`skill` 命令直接读取 bundle 并管理本地 Skill 链接。
- **In-Pane 人体工学。** 每个命令默认作用于"当前 Pane / Tab / Worktree"，读取应用注入的环境变量；显式标志（`--pane`/`--tab`/`--worktree`/`--project`）覆盖。
- **便利别名在任何 mutation 之前解析为 UUID。** 用户可用 `@label`、`current`、index 寻址；内部代码永远只见到 UUID。解析经 `hierarchy.resolveAlias` 一次只读往返完成。
- **一套 wire 协议，两种传输。** CLI 走 socket 上的 JSON-RPC；深链 URL 在应用侧映射到相同方法。CLI 发起与深链发起的命令在下游不可区分。
- **快速且可读地失败。** socket 缺失 → "codans is not running"。schema 不匹配 → `.versionMismatch` 并附两端版本。退出码稳定且可枚举。

### 非目标

- **RPC 命令不提供离线回退。** 应用未运行时，依赖 socket 的命令报错；`launch` 负责启动应用，`skill`、帮助与版本输出不需要应用运行。
- **脚本语言内嵌。** 没有 `codans eval`。脚本化通过 hook handler 进行（见 [lifecycle-hooks](lifecycle-hooks.md)，该面**尚未实现**）。
- **包管理。** `codans` 不安装 codans 本身（Sparkle / DMG 负责）。`skill install` 只管理 bundle 内 Skill 的本地链接；CLI 自身的安装由应用设置面板管理。
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
       equal to the *other* channel's default → the wrong CLI for this
       pane: release `codans` refuses (exit 15, wrong-channel) and names
       `codans-dev`; development `codans-dev` ignores it and dials its own
    3. build-channel default             (Debug: /tmp/codans-dev-$UID.sock;
                                          Release: /tmp/codans-$UID.sock)

  Injected env vars inside every Pane (built by PaneEnvironment):
    CODANS_SOCKET_PATH, CODANS_CLI, CODANS_PANE_ID, CODANS_WORKTREE_PATH,
    CODANS_ROOT_PATH, ZMX_DIR, ZMX_SESSION (cleared), TERM_PROGRAM,
    TERM_PROGRAM_VERSION; PATH gains the spawning app's bundled bin/, whose
    CLI is named for its channel (`codans-dev` in Debug), so that name
    reaches this app however the shell reorders PATH
  Read by `current` if a caller exports them by hand (never injected):
    CODANS_PROJECT_ID, CODANS_WORKTREE_ID, CODANS_TAB_ID, CODANS_TAG_ID
```

> 最高层级是 Project，`Tag` 提供跨 Project 分类（见 [project-tags](project-tags.md)）。

### 命令面（实际 shipped 动词集）

下表是 `codans` 实际编译进的命令树，对照 `apps/mac/codans-cli/` 各 `CommandConfiguration` 与 `apps/mac/CodansIPC/Method.swift` 核实。**Subcommand** 列是用户键入的；**IPC method** 列是分发的 `IPC.Method`。

#### 顶层命令

`CodansCLI.configuration.subcommands` 显式挂载：`status`、`launch`、`doctor`、`tree`、`project`、`worktree`、`tab`、`pane`、`broadcast`、`agent`、`handoff`、`workspace`、`open`、`skill`、`help-json`（隐藏）。

| Subcommand | IPC method | 说明 |
|---|---|---|
| `codans status` | `system.status` | server 标识、uptime、connected-clients 数 |
| `codans launch [--wait N]` | *(本地)* | 若未运行则 `open -g Codans.app` 并最多等 N 秒（默认 10）等 socket 出现；唯一会拉起应用的命令。CLI 自己环境里的 `CODANS_SOCKET_PATH` / `CODANS_CONFIG_DIR` 经 `open --env` 转交给应用，等待的 socket 与应用绑定的是同一个 |
| `codans doctor` | *(本地)* | 检查 socket 路径、可达性、是否来自环境变量、CLI 版本；不做应用往返 |
| `codans tree [--project P]` | `hierarchy.listProjects` | **首选发现命令**：一次打印 Project→Worktree→Tab→Pane 全层级。Project 行对非 git 仓库带 `[dir]` / `[server]` / `[workspace]`；`--json` 的 project 带 `kind`（`ProjectKind` raw value），worktree 带 `sourceGitRoot`（workspace 子仓库的所属仓库，其余为 null），tab / pane 带 `handle`（`t<n>` / `p<n>`） |
| `codans broadcast` | `terminal.broadcastInput` | 见 [send / broadcast](#codans-pane-send--codans-broadcast) |

> `codans --version` 印 `Codans <version>`（ArgumentParser 内建）。

#### `codans project …`

`ProjectCommand.subcommands`：`list`、`add`、`show`、`rename`、`rm`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans project list` | `hierarchy.listProjects` | `HierarchyHandlers.listProjects` | 无 |
| `codans project add PATH` | `hierarchy.addProject` | `HierarchyHandlers.addProject` → `HierarchyManager.addProject` | `PATH`，`[--name NAME]`。`PATH` 下存在 `.codans/workspace.json` 时注册为 workspace（见 [Workspace](workspace.md)） |
| `codans project show [ID]` | `hierarchy.describeProject` | `HierarchyHandlers.describeProject` | `[ID]`；回带 `{id, name, canonicalName, rootPath, gitRoot, remoteHost, isSelected, selectedWorktreeID, worktreeCount, archivedWorktreeCount, tagIDs}` |
| `codans project rename ID NAME` | `hierarchy.renameProject` | `HierarchyManager.renameProject` | `ID`，`NAME`（空串或等于文件夹名 → 清除覆盖） |
| `codans project rm ID` | `hierarchy.removeProject` | `HierarchyManager.removeProject` | `ID`（id/名字/`current`） |

`add` 在边界校验：目录必须存在（否则 `invalidParams`，exit 1）、规范化路径未注册（否则 `conflict` 并回带已有 id）；未传 `gitRoot` 时服务端用 `git rev-parse --show-toplevel` 探测（带 `.codans/workspace.json` 的目录注册为 workspace，不探测、忽略传入的 `gitRoot`），落库后触发与侧栏 Add Project 相同的 reconcile，使仓库项目立刻列出真实 worktree 而非一行无分支的合成 worktree。响应 `{id, rootPath, gitRoot}`。

#### `codans worktree …`

`WorktreeCommand.subcommands`：`list`、`new`、`show`、`switch`、`rename`、`prune`、`rm`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans worktree list` | `hierarchy.listWorktrees` | `HierarchyHandlers.listWorktrees` | `[--project P]` |
| `codans worktree show [ID]` | `hierarchy.describeWorktree` | `HierarchyHandlers.describeWorktree` | `[ID]`；回带 `{id, projectID, projectName, name, path, branch, isArchived, isPinned, isSelected, selectedTabID, tabCount}` |
| `codans worktree rename ID NAME` | `hierarchy.renameWorktree` | `HierarchyManager.renameWorktree` | `ID`，`NAME`（仅侧栏标签，路径/分支不变；空白拒绝），`[--project P]` |
| `codans worktree prune` | `hierarchy.pruneWorktrees` | `GitWorktreeClient.pruneWorktrees` → `HierarchyClient.reconcileDiscoveredWorktrees` | `[--project P]`；回带 `{projectID, pruned}`。文件夹项目 → `invalidParams`，远端项目 → `unsupported` |
| `codans worktree new BRANCH` | `hierarchy.createWorktree` | `HierarchyHandlers.createWorktree` → `GitWorktreeClient.createWorktreeStream` + `HierarchyManager.createWorktree` | `BRANCH`，`[--project P] [--path PATH] [--name NAME] [--base REF] [--reuse-existing] [--profile NAME\|ID] [--agent TOKEN]` |
| `codans worktree switch ID` | `hierarchy.activateWorktree` | `HierarchyManager.selectWorktree` | `ID` |
| `codans worktree rm [ID]` | `hierarchy.removeWorktree` | `HierarchyManager.removeWorktree`；`--delete` → `HierarchyClient.removeWorktreeWithGit` | `ID`，或 `--by-path PATH [--all]`（按规范化路径删一/多行），`[--project P] [--delete]`。不带 `--delete` 只删 catalog 行（真实 git worktree 会被下一次 reconcile 收回）；`--delete` 走侧栏 Remove Worktree 同一条路径（拆 surface → relocate-then-prune → 按 Settings 删分支），响应 `{id, deleted, warning?}` |

`--path` 缺省由服务端解析：展开 project 配置的 worktrees 目录并附加分支名；响应回带解析后的绝对路径。目标路径**不存在**且项目是本地 git 项目时，服务端先经 New Worktree sheet 同一条 `wt sw` 流水线把 worktree 造出来（分支不存在则从 `--base` / 项目 pinned base ref / 默认远程分支 / `HEAD` 新建，存在则直接 checkout；项目的 copy / fetch / setup 设置生效；`wt sw --path` 让分支名与目录名解耦），再入 catalog；路径已存在则原样登记（收编外部创建的 worktree）；远端项目与无 git root 的文件夹项目保持只写 catalog。响应回带 `created`。`--reuse-existing`：若同规范化路径的 worktree 已存在，返回其 id 而非以 conflict 失败（名字冲突仍失败）。git 失败按"调用方该怎么办"映射：非法分支名 / 未知 ref → `invalidParams`，分支已存在 / 未提交改动 / 锁 → `conflict`，其它 → `internal` 附 stderr。

#### `codans workspace …`

`WorkspaceCommand.subcommands`：`create`、`add`、`drop`、`remove`、`show`。成员检出、manifest 写入与删除由服务端 `WorkspaceClient` 编排（见 D21）。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans workspace create TITLE` | `workspace.create` | `WorkspaceHandlers.create` → `WorkspaceClient.create` | `TITLE`，`--project P` / `--repo PATH`（非裸仓库）/ `--remote URL`（各可重复），合计 ≥ 2；`[--branch B] [--base REF] [--existing \| --track] [--reset-local] [--clone-into DIR] [--path ROOT] [--description D]` |
| `codans workspace add WS` | `workspace.add` | `WorkspaceHandlers.add` → `WorkspaceClient.add` | `WS`（别名/名字/`current`），`--project P` / `--repo PATH` / `--remote URL` 三选一；`[--name N] [--branch B] [--base REF] [--existing \| --track \| --ref REMOTE/BRANCH] [--reset-local] [--clone-into DIR] [--role R]` |
| `codans workspace drop WS MEMBER` | `workspace.drop` | `WorkspaceHandlers.drop` → `WorkspaceClient.drop` | `MEMBER` 为成员目录名；`[--keep-branch]`。移走 checkout（relocate-then-prune）、删分支（git 拒绝时回带 note）、改 manifest、删本行与源 Project 的镜像行 |
| `codans workspace remove WS` | `workspace.remove` | `WorkspaceHandlers.remove` → `WorkspaceClient.remove` | 缺省只删条目；`--delete-files` 逐成员注销并删根目录（任一失败则根目录保留并回带 `failures`）；`--delete-branches` 需配合 `--delete-files` |
| `codans workspace show [WS]` | `workspace.describe` | `WorkspaceHandlers.describe` | `WS` 缺省 `current` |

成员来源：`--project` 先经 `hierarchy.resolveAlias` 解析为 id，服务端读其 `gitRoot`；`--repo` 发绝对路径，服务端 `git rev-parse --git-common-dir` + `--is-bare-repository` 求仓库根（仓库子目录、linked worktree 归一到根；裸仓库以 `invalidParams` 拒绝）；`--remote` 发 URL，服务端定 clone 目标（`--clone-into`，缺省 `~/.codans/sources/<repoName>`；该处已是同一远程的 clone 则复用，否则取空闲的 `-N` 兄弟），clone 后与本地来源一致。检出模式：缺省新建分支；`--existing` 用已有本地分支；`--track` 用远程跟踪分支 `origin/<branch>`（`add` 上可用 `--ref <remote>/<branch>` 指定任意远程 ref，分支名缺省取 ref 的分支部分）；`--reset-local` 只与 `--track` / `--ref` 搭配，把已存在的同名本地分支重置到远程 tip，缺省保留本地分支原样。缺省值：成员目录名 = 仓库目录名，分支 = 标题 slug（`add` 用 workspace 名 slug），base = 仓库默认远端分支，根目录 = `~/.codans/workspaces/<slug>`（被占用则 `-2`、`-3`）。`--json` 输出经 `WorkspaceSummaryRenderable`，nil 字段编码为 `null`；成员带 `sourceKind`（`local` / `remote`）与 `remoteURL`。见 [Workspace](workspace.md)。

#### `codans tab …`

`TabCommand.subcommands`：`list`、`new`、`show`、`switch`、`rename`、`close`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans tab list` | `hierarchy.listTabs` | `HierarchyHandlers.listTabs` | `[--project P] [--worktree W]` |
| `codans tab new [NAME]` | `hierarchy.createTab` | `HierarchyManager.createTab` | `[NAME]`，`[--project P] [--worktree W]` |
| `codans tab show [ID]` | `hierarchy.describeTab` | `HierarchyHandlers.describeTab` | `[ID]`；回带 `{id, handle, projectID, worktreeID, title, name, icon, isSelected, focusedPaneID, paneIDs}`（`title` = 用户名或最近的 live 标题） |
| `codans tab switch ID` | `hierarchy.activateTab` | `HierarchyManager.selectTab` | `ID` |
| `codans tab rename ID [NAME]` | `hierarchy.renameTab` | `HierarchyManager.renameTab` | `ID`，`[NAME]`（缺省或空串 → 清除用户标题，回到 shell 的 live 标题），`[--project P] [--worktree W]` |
| `codans tab close ID` | `hierarchy.closeTab` | `HierarchyManager.closeTab` | `ID`，`[--project P] [--worktree W]` |

容器推断（`ScopeResolver`，`CommonCommandSupport.swift`）：显式给出 tab（或 worktree）而 `--project` / `--worktree` 留在 `current` 时，容器从 `codans tree` 一次往返里定位，不依赖调用方所在 pane——`codans tab close t3` 在任何 shell 都可用。

#### `codans pane …`

`PaneCommand.subcommands`：`list`、`new`、`split`、`show`、`focus`、`resize`、`close`、`label`、`reset`、`send`、`send-key`、`read`、`info`、`capture`。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans pane list` | `hierarchy.listPanes` | `HierarchyHandlers.listPanes` | `[--project P] [--worktree W] [--tab T]` |
| `codans pane new [CMD…]` | `hierarchy.openPane` | `HierarchyManager.openPane` | `[CMD…]`（省略则默认登录 shell），`[--project P] [--worktree W] [--tab T] [--cwd PATH] [--label TAG…]` |
| `codans pane split [PANE]` | `hierarchy.splitPane` | `HierarchyManager.splitPane` | `[PANE]`（锚点，唯一的位置参数，默认 `current`），`[--direction right\|left\|up\|down]`（默认 right），`[--cwd PATH]`（默认锚点 pane 的 live 目录，不是 `$PWD`），`[--label TAG…]`，`[--command CMD]`。与键盘分屏同一条路径，新 pane 带项目环境；回带 `{id, anchor, direction}` |
| `codans pane show [PANE]` | `hierarchy.describePane` | `HierarchyHandlers.describePane` | `[PANE]`；回带 `{id, handle, projectID, worktreeID, tabID, workingDirectory（live 优先）, initialCommand, labels, agent, agentSessionID, isLive, isFocused}`。读 catalog；`pane info` 才是问守护 |
| `codans pane focus PANE` | `hierarchy.focusPane` | `HierarchyManager.focusPane` | `PANE`（UUID/`@label`/`current`） |
| `codans pane resize PANE DIR` | `hierarchy.resizePane` | `HierarchyManager.resizePane` | `PANE`，`DIR`（`left`/`right` 动最近的竖分隔线，`up`/`down` 动横的），`[--amount PX]`（像素，默认 40，manager 按 400px/ratio 换算）。该方向没有分隔线则无操作 |
| `codans pane close PANE` | `pane.close` | zmx 守护 `.kill` + sessions 收割 | `PANE`；杀掉 pane 的 zmx 守护并丢弃持久 session 项。与 UI 的 X 按钮（detach 以便日后 attach 复活）不同 |
| `codans pane label PANE TAG…` | `hierarchy.setPaneLabels` | `HierarchyManager.setPaneLabels` | `PANE`，`TAG…`，`[--replace]` |
| `codans pane reset PANE` | `terminal.resetPane` | libghostty reset 绑定动作 | `PANE`；清 scrollback 并重初始化终端，不打扰子进程 |
| `codans pane send [PANE] TEXT` | `terminal.sendInput` / `terminal.sendRawBytes` | `TerminalEngine.sendInput` | 见下 |
| `codans pane send-key [PANE] KEY` | `terminal.sendKey` | ghostty key event | 命名特殊键：`escape/up/down/left/right/tab/enter/backspace/delete/home/end/pgup/pgdn/f1..f12/ctrl_c/ctrl_d/ctrl_l/ctrl_z` |
| `codans pane read [PANE]` | `pane.read` | zmx 守护 `serializeTerminalState` dump | `[--raw]`（vt 格式，保留 ANSI/cursor/modes/OSC 7）`[--tail N] [--range visible\|scrollback\|all]` |
| `codans pane info [PANE]` | `pane.info` | 探测 zmx 守护 | 回带 shell pid + pwd（cursor/modes 当前为 null）；走守护而非 catalog，故陈旧 catalog 行不会冒充 live 真相 |
| `codans pane capture [PANE]` | `terminal.readText` | libghostty 渲染文本 | 纯文本快照；`[--scope viewport\|screen] [--lines N]`。原始 ANSI 字节流捕获**当前不支持**（libghostty 只暴露解析后文本，非原始 PTY 字节流） |

**`codans pane new`** 默认：`--cwd` 回退 `$PWD`；`CMD` 回退登录 shell；`--label` 用 `--label foo bar` 形式接收多个初始标签。

**`codans pane send`** —— 这是最常用命令：

- 一个位置参数 → 发给当前 pane；两个 → 第一是目标 pane，第二是文本。
- 文本默认以 Enter 提交；`--no-enter` 只键入不回车。（wire 层把 Enter 实现为 CR `\r` 而非 `\n`；`\n` 只换行不执行。）
- `--stdin` 从标准输入读到 EOF。
- `--raw <hex>` 发原始字节（如 CSI 序列）——文本路径会丢弃这些；hex 以空白分词，每个词可各自带 `0x`（`"0x15 0x0d"` 与 `"150d"` 等价，`TerminalHandlers.decodeHex`）。控制字节（ESC/Tab/BS/CR/LF/Ctrl-A..Z）作为 key event 派发以确保 PTY 真正收到，可打印字节走文本通道。`--raw` 与位置文本 / `--stdin` / `--no-enter` 互斥。
- `--focus` 发送后聚焦目标 pane。
- `--wait`：发送后在服务端轮询，直到 pane 的前台任务结束（`HierarchyManager.paneIsBusy`，即前台进程组轮询器的 busy 位）且屏幕在 `--stable-ms`（默认 500）内无变化；轮询器最快 500 ms 才看得到 busy，所以短命令在 1.5 s 的 grace 静默后也算完成。`--capture` 蕴含 `--wait`，并回带命令新增的屏幕行（`TerminalHandlers.capturedOutput`：去掉发送前后屏幕的公共前缀、回显的命令行、重绘的提示行；终端只暴露渲染文本而非命令边界，故为 best effort）。超过 `--wait-timeout`（默认 30 s，上限 600）→ exit 11 / `WAIT_TIMEOUT`。响应多出 `completed`、`waitedMs`、`busyObserved`、`output`。

#### `codans pane send` / `codans broadcast`

`broadcast` 是**顶层**命令（不在 `pane` 下），把文本扇出到一个作用域：

| Subcommand | IPC method | Args |
|---|---|---|
| `codans broadcast --tab ID TEXT` | `terminal.broadcastInput` | `--tab ID`，`TEXT`，`[--stdin] [--no-enter]` |
| `codans broadcast --worktree ID TEXT` | `terminal.broadcastInput` | `--worktree ID`，`TEXT`，`[--stdin] [--no-enter]` |
| `codans broadcast --label TAG TEXT` | `terminal.broadcastInput` | `--label TAG`，`TEXT`，`[--stdin] [--no-enter]` |

三个作用域标志互斥（由 `CLIBroadcastScopeSelection` 强制）。`broadcast` 用 `IPC.BroadcastScope`（`CodansIPC` 里的 wire 类型，`case tab/worktree/label`）做服务端扇出，省去客户端枚举目标。响应回带 `delivered`（命中 pane 数）。

#### `codans agent …`

`AgentCommand.subcommands`：`list`、`status`、`wait`、`launch`。profile 是 Settings → Agents 里的启动预设（`Settings.agents.profiles`），与 worktree toolbar 的 Agents 菜单同一份数据；设计见 [agent-handoff.md](agent-handoff.md)。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans agent list` | `agent.listProfiles` | `AgentHandlers.listProfiles` | 无；每行回带 id、名字、agent、enabled、PATH 探测结果（未探测完为 null）、是否支持 prompt、完整启动命令 |
| `codans agent status` | `agent.listStates` | `AgentHandlers.listStates` ← `AgentStateStore.entries` | 无；Agents View 的每一行：`paneID`、`handle`、`agent`、`state`（idle/working/blocked/finished）、`since`、`sessionID`、`title`、所在 project / worktree / tab、`isFocused`。实时状态来自 `AgentStateStore`；退出快照与重启恢复规则见 [Active Agents](active-agents-view.md) |
| `codans agent wait PANE --until COND` | `agent.wait` | `AgentHandlers.wait`（服务端每 200 ms 轮询 store） | `PANE`，`--until idle\|working\|blocked\|finished\|changed\|exit`，`[--wait-timeout 1..600]`（默认 60；全局 `--timeout` 是 RPC 客户端上限，会被抬高以覆盖它）。`changed` = 相对 arm 时的状态有任何变化；`exit` = pane 上不再绑定 agent。服务端在 deadline 返回 `satisfied=false`，CLI 转成 exit 11 / `WAIT_TIMEOUT` 并在 `details` 里带最后状态 |
| `codans agent launch [PROFILE]` | `agent.launch` | `HierarchyClient.launchAgent` | `[PROFILE]`（名字或 id）或 `--agent TOKEN`（该 agent 第一个启用的 profile，缺则临时裸预设），`[--project P] [--worktree W] [--prompt TEXT\|-] [--tab \| --split right\|left\|up\|down] [--background]` |

`launch` 走与 toolbar 相同的管线（渲染 profile → 合成 `ScriptDefinition` → 新 tab / 分屏 / 当前 pane），永不复用 run pane。禁用的 profile 以 `conflict` 拒绝；不支持初始 prompt 的 agent 带 `--prompt` 以 `unsupported` 拒绝；重名 profile 以 `conflict` 要求传 id。

#### `codans handoff …`

`HandoffCommand.subcommands`：`to`、`save`。源 pane 默认为**调用方 pane**（`--pane` 覆盖），因此 agent 在自己 pane 里执行即交接自己。工件在 worktree 的 `.codans/handoff/` 下。

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans handoff to AGENT` | `handoff.to` | `HandoffHandlers.to` | `AGENT`（raw value / 可执行名 / 显示名），`--brief TEXT\|-` 或 `--no-brief`（二选一，必填），`[--pane PANE] [--profile NAME\|ID] [--note TEXT] [--no-launch] [--tab \| --split right\|left\|up\|down]` |
| `codans handoff save` | `handoff.save` | `HandoffHandlers.save` | `--brief TEXT\|-` 或 `--no-brief`，`[--pane PANE] [--note TEXT]` |

- 接收方按 `AgentCatalog` 的 `promptStyle` 决定 kickoff 方式：有则作为命令行参数，无则由 app 在 agent 出现后注入。注入路径使用画面稳定与文本回显启发式，并在匹配后自动发送 Enter；不能据此确认焦点一定处于输入框。具体等待时限与失败行为见 [Agent Profiles 与 Handoff](agent-handoff.md#agent-profile-数据模型)。`--no-launch` 只保存工件，不启动接收方。
- 放置：默认在同一 worktree 的后台新 tab；`--split <方向>` 以**源 pane** 为锚分屏（不是当前聚焦的 pane），`--tab` 显式选新 tab。`.focused` 不可用——交接绝不覆盖源 agent 的 pane。
- briefing 缺失 → `invalidParams` 并附可直接粘贴的 heredoc；不合格（缺 `## Objective` / `## Current State` / `## Next Steps`）→ `invalidParams` 且零副作用。
- Server 项目 → `unsupported`（工件目录在远端）。
- 环境变量 `CODANS_HANDOFF_REQUEST_ID`（仅应用内面板注入的请求会设置）随请求上送；已被处理或被面板回退取代的请求以 `conflict` 拒绝。
- 响应回带 `artifactPath`、`outgoingAgent`、`receiver`、`branch`、`changedFileCount`、`archivedPath`、`sessionExcerptPath`、`briefing`（`inline`/`none`）、`hasBriefing`、`launchedPane`。`archivedPath` / `sessionExcerptPath` 相对 worktree 根（形如 `.codans/handoff/archive/…`），与 kickoff 提示词、`context.md` 同一基准；`artifactPath` 是绝对路径。

#### `codans open`

| Subcommand | IPC method | Anchors to | Args |
|---|---|---|---|
| `codans open [<path>] [--in EDITOR]` | `editor.open` | `EditorService` | `[<path>]`（默认 `$PWD`，相对路径相对 `$PWD` 解析），`[--in EDITOR]` |

`EDITOR` 是编辑器 id（`cursor`/`zed`/`vscode`/`xcode`/`finder`/`ghostty`/…）。`path` 是单一位置参数，必须指向本地现有目录。服务端按以下顺序选择编辑器：显式 `--in`（strict，未安装即报错）→ `Settings.projects[pid].defaultEditor`（路径位于已注册 Project 内且编辑器已安装时）→ `Settings.general.defaultEditorID`（lenient）→ 内建注册表优先级 → Finder。项目覆盖由 `EditorHandlers` 解析，其余选择与启动由 `EditorService` 完成。

> editor 的 IPC 面是 `editor.*`：`editor.describe` / `editor.open` / `editor.setGlobalDefault` / `editor.setProjectDefault`。

#### `codans skill …`

`SkillCommand.subcommands`：`list`、`install`、`uninstall`、`path`。纯本地文件操作，不走 socket，app 不必运行。

| Subcommand | Anchors to | Args |
|---|---|---|
| `codans skill list` | `SkillInstaller.report` | `[--target claude\|codex\|agents…] [--scope user\|project] [--project-root DIR]`；每个 bundled skill × target 的状态：`installed` / `missing` / `other-version`（指向别的 bundle 的链接）/ `conflict` |
| `codans skill install [ID…]` | `SkillInstaller.install` | 同上 + `[--force]`；把 `Contents/Resources/skills/<id>` 软链到 `~/.claude/skills`、`~/.codex/skills`、`~/.agents/skills`（`--scope project` 则是 `<git root>/.claude/skills` 等）。`other-version` 直接替换，`conflict` 需 `--force` |
| `codans skill uninstall [ID…]` | `SkillInstaller.uninstall` | 只移除指向某个 bundle 的链接，其它占位一律不动 |
| `codans skill path [ID]` | `SkillLocator` | 打印 bundled 目录 |

bundled 目录由 `scripts/embed-skills.sh` 在构建时从仓库根 `skills/` 拷入 `Resources/skills`；CLI 通过自身二进制位置（`Resources/bin/<cli>` 上溯两级）或 `CODANS_SKILLS_DIR` 找到它。默认 target 为"已检测到"的 agent（其 `~/.claude` 等目录存在）。Settings ▸ Developer ▸ Agent skills 是同一 `SkillInstaller` 的 GUI 入口（每个 target 一行 Install / Remove，见 [settings.md](settings.md#developer-pane)）；安装与否始终是用户的选择，app 不会自动链接。

#### `codans help-json`

`HelpJSONCommand`（`apps/mac/codans-cli/HelpJSONCommand.swift`）发出整棵 `codans` 子命令树的 JSON（`{name, abstract, subcommands}`），供外部工具推断 CLI 形状而不必解析 `--help` 文本。它配置为 `shouldDisplay: false`（默认 `--help` 隐藏），已挂进 `CodansCLI.subcommands`。

### 寻址与别名解析

`PANE` / `TARGET` 参数由 `AliasResolver`（`CodansKit/Transport/AliasResolver.swift`）与服务端 `HierarchyHandlers.resolveAlias` 共同解析，对每种 kind（`project`/`worktree`/`tab`/`pane`）依次尝试：

1. **UUID** —— 任何合法 UUID 串假定为规范 ID，本地校验，无往返。
2. **`current` / `.`** —— 若对应的 `CODANS_{PROJECT,WORKTREE,TAB,PANE}_ID` 环境变量存在则本地解析；否则交给服务端：先把调用方归属到 pane（连接的内核 peer PID 沿祖先链匹配 live pane 的 shell PID，退而取请求里的 `contextPaneID`），pane 级直接返回，project / worktree / tab 级从 catalog 中持有该 pane 的行读出。pane 只导出自己的 id，所以 `--project current` 等全靠这一步；不在 pane 里 → `notFound(kind, "current")`，CLI 渲染为"no current <kind>: this shell is not inside a Codans pane"（exit 2）。
3. **`@label`** —— 仅 Pane：匹配 `Pane.labels`；多于一个匹配则报 conflict。
4. **`t<n>` / `p<n>`** —— `TargetHandleRegistry` 的稳定短句柄。
5. **名字** —— project 按 name / canonicalName；worktree 按 name 或 branch，调用方在 pane 里时限定在该 pane 的 project 内；tab 按 title，限定在该 pane 的 worktree 内；均不区分大小写。唯一命中即返回，多个命中 → `conflict`（请传 id），零命中 → `notFound`。pane 没有名字：裸词按 `invalidParams` 拒绝并提示引号（常见于未加引号的 `pane send echo hi`）。
6. **路径**（仅 worktree）—— `/abs`、`~/x`、`./x`、`../x`、`..` 视为路径（分支名也含 `/`，故只认这些前缀）：CLI 先相对 `$PWD` 变成绝对路径（`AliasResolver.absolutePathIfPathShaped`），服务端按规范化路径匹配"等于 worktree 根或位于其下"的 worktree，跨 project；嵌套时取最深的一个。

**位置参数只承载目标**：每个动词最多一个位置目标，容器用 `--project/--worktree/--tab`；文本、命令、新对象的名字不与目标争位（`pane send` 的一参/二参形式是唯一例外，`pane split` 的命令走 `--command`）。早先设想的 index 与 path glob 形式未实现。所有非 UUID 解析是一次到 `hierarchy.resolveAlias` 的往返，先于真正的方法调用。结果只在单次 `codans` 调用内缓存，绝不跨调用。

### 输出契约（`--json`）

每条命令的 `--json` 在 stdout 打印**一个**对象（`Renderer` 统一包装，`CodansKit/Render/Envelope.swift`）：

```json
{ "schemaVersion": "codans.cli.pane.send.v1", "data": { … } }
{ "schemaVersion": "codans.cli.pane.focus.v1",
  "error": { "code": "NOT_FOUND", "message": "pane not found: p9", "hint": "…", "details": { "kind": "pane", "id": "p9" } } }
```

- `schemaVersion` = `codans.cli.<命令路径>.v1`，命令路径由 `CommandPaths` 从根 `CommandConfiguration` 树推出（不含可执行名，`codans` / `codans-dev` 相同），经 task-local `Renderer.context` 传给每次渲染；`CommandRunner.run(self, globals:)` 负责设置它并把失败也渲染成信封（JSON 模式下错误走 stdout，文本模式仍是 stderr 的 `error:` / `hint:` 行）。
- `error.code` 是 `CLIErrorCode` 的稳定字符串：每个退出码有默认码（`CLIErrorCode.default(for:)`），另有 `NO_CURRENT_CONTEXT`、`EMPTY_INPUT`、`WAIT_TIMEOUT`、`CAPTURE_UNSUPPORTED` 这类退出码分不清的情形；`details` 带结构化上下文（`kind`/`id`、`waitedMs`…）。
- 形状由 `apps/mac/codans-cli/Resources/schema/cli-output.schema.json`（JSON Schema 2020-12）描述：信封 + `error` 严格，`data` 按 `schemaVersion` 绑定到各命令的定义；回归 harness 末尾用 `docs/user-tests/cli-regression/validate-json.py`（无依赖的子集校验器）校验命令的 JSON 输出。单测 `RendererEnvelopeTests` 钉住信封与退出码 → 错误码表。
- 例外：`codans help-json` 裸打印命令树；ArgumentParser 拒绝的命令行（exit 64）打印解析器自己的文本。

### Wire 协议

复用 architecture §IPC 的信封规范。要点：

- **请求帧** 是 `UInt32` big-endian 长度前缀 + 恰好 N 个 UTF-8 JSON 字节（**无尾随换行**），每帧 16 MiB 硬上限（超限 → `IPCError.invalidFrame`，关连接）。
- **方法枚举。** `IPC.Method`（`apps/mac/CodansIPC/Method.swift`）覆盖每个 RPC，raw value 是小写点分串（`hierarchy.createWorktree`、`terminal.sendInput`）。两端 switch 此枚举，绝不 switch raw 串。
- **流终止契约。** 请求设 `stream: true`；数据帧为 `{id, stream: true, result: …}`。服务端订阅结束时发送 `{id, stream: false}`；`RPCClient` 收到终帧立即结束流，不等待 EOF；响应携带 `error` 时抛出该 IPC 错误。没有终帧的 EOF 在当前客户端中映射为 `RPCError.timeout`，与帧间等待超时相同。`UnixSocketTransport.close()` 使用 `SHUT_RDWR` 并关闭 fd；没有 `SHUT_WR` 半关闭握手或收到客户端半关闭后 flush 并回终帧的契约。
- **错误码。** `IPCError` 含 `.unknownMethod` / `.invalidParams` / `.notFound` / `.conflict` / `.unsupported` / `.internal` / `.overloaded` / `.versionMismatch`。
- **兼容性握手。** 握手是专用的首帧 RPC `system.hello`（**非**逐请求 header——逐请求 header 会对每次调用重复编码版本信息，并与"一连接一流"规则冲突）。连接打开 → 客户端发 `system.hello`（带 `clientVersion`/`clientBinary`）→ 服务端回 `serverVersion` / `appBundleVersion` / `protocolMajor` / `protocolMinor` / `deprecatedMethods`。服务端按客户端与服务端版本的 major 检查兼容性，不兼容时返回 `.versionMismatch`。客户端检查握手错误，不读取成功响应中的 minor 或 `deprecatedMethods` 来生成警告。

  **`codans` 把 `system.hello` 与真实请求作为两个 pipelined 帧一次写出**（每次调用都开新连接），使热 socket 上不增加额外往返。版本偏斜时服务端对 hello 返回 `.versionMismatch` 并丢弃第二帧；响应 ID 按 hello vs real 配对，否则抛 `.misorderedResponse`。

### 错误处理模型

- **退出码** 跨版本稳定（`CodansKit/ExitCode.swift`）：`0` 成功 · `1` 用户错误 · `2` not-found · `3` conflict · `4` unsupported · `5` overloaded · `6` versionMismatch · `10` socket 不可达（应用未运行）· `11` 请求超时 · `12` launch 超时 · `13` socket 权限拒绝 · `14` socket 不可用（路径不是 socket / 过长 / socket(2) 失败）· `15` wrong-channel（pane 属于另一构建通道，CLI 拒绝跨越）· `20` 内部错误。ArgumentParser 自己拒绝的命令行（未知子命令 / 选项、缺参数、枚举值非法）按其惯例退出 `64`（`EX_USAGE`）。
- **`--timeout`** 在 `CLISession.connect` 设为 `RPCClient` 的默认期限，命令内每次调用（含别名解析）都受它约束，不需要各调用点逐一透传。
- **socket 连接失败分类。** connect(2) 的 errno 在 `CodansKit/Transport/SocketConnectionFailure.swift` 收敛成一组 `SocketFailureKind`：`socket-missing`（ENOENT）· `app-not-running`（ECONNREFUSED，陈旧 socket 文件）· `permission-denied`（EACCES/EPERM）· `not-a-socket`（ENOTSOCK）· `path-too-long` · `server-busy`（EAGAIN，accept backlog 满）· `timed-out` · `connection-lost`（已连接后 EPIPE/ECONNRESET）· `socket-create-failed` · `unknown`。分类按**调用方该怎么办**映射退出码：起应用后重试（10）、原样重试（5 / 11）、需要人介入（13 / 14）。未映射的 errno 保持 `unknown` 而非并入相邻类别——错误的类别比诚实的"未知"对分支脚本更有害。
- **分类的可脚本化出口。** 除退出码外，`codans doctor` 输出 `socketStatus`（上述 raw 值、`wrong-channel`，或 `ok`）与可选 `socketHint`，使脚本无须 grep stderr 即可分支。`codans launch` 对起应用无法修复的类别（权限 / 路径）立即失败，不再空转 `--wait` 秒轮询。
- **stderr 文本模式：** 首行 `error: <message>`，后续 `  hint: <suggestion>`（若适用）；无 backtrace、无 "please file a bug" 样板（贴合 git / Ghostty 风格）。
- **进程级 SIGPIPE 忽略。** `main()` 进程级 `signal(SIGPIPE, SIG_IGN)`，使任何写路径（stdout 被管到 `head`、半关 socket）返回 EPIPE 而非以 exit 141 在错误路径渲染前杀死 CLI。
- **取消。** SIGINT 关 socket 中止在飞请求；部分副作用由应用负责回滚（mutation 在 `HierarchyManager` 层原子）。

### 组件边界

```
apps/mac/codans-cli/                  (the CLI binary)
├── CodansCLI.swift                   ArgumentParser root + GlobalOptions
├── HelpJSONCommand.swift             codans help-json (hidden)
└── Commands/
    ├── AppCommands.swift             status / launch / doctor
    ├── TreeCommand.swift             tree (+ HierarchyTree / PanePath helpers)
    ├── ProjectCommands.swift         project list / add / rm / commands …
    ├── WorktreeCommands.swift        worktree list / new / switch / rm
    ├── TabCommands.swift             tab list / new / switch / close
    ├── PaneCommands.swift            pane list / new / focus / close / label / reset / info / read
    ├── TerminalCommands.swift        pane send / send-key / capture ; broadcast
    ├── OpenCommand.swift             open
    └── CommonCommandSupport.swift    CLISession / CommandRunner / ScopeResolver / shared input plumbing

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

> CLI 安装由 Settings → Developer 管理。GUI 进程的 `PATH` 不能代表调用方 shell 的配置，因此安装器不据此判断 CLI 是否可从每个 shell 访问。

CLI 二进制已由 `scripts/embed-codans.sh` 内嵌到应用 bundle 的 `Contents/Resources/bin/<名字>`——Debug 为 `codans-dev`，Release 为 `codans`，名字来自 `Project.swift` 的 `CODANS_CLI_NAME` 构建设置并与 `BuildChannel.slug` 一致——release 构建随应用一起签名，故 symlink 目标已是稳定、已签名、已公证的产物。

### 模型

安装器对每次 install / uninstall 发出**一条管理员授权的 shell 命令**，经进程内 `NSAppleScript` 执行，使授权对话框以 codans 应用图标与 bundle 名渲染。

- **安装路径：** Release 构建管理 `/usr/local/bin/codans`；Debug 构建管理 `/usr/local/bin/codans-dev`，以免本地开发夺走生产 `codans`。选 `/usr/local/bin` 正因它在默认 macOS PATH 上、位于 `/usr/bin` 之前（`/etc/paths` 如此排）；而 `/opt/homebrew/bin` 不在非 Homebrew shell 的 PATH 上。调用方使用自己的 `PATH` 解析命令，或直接使用安装路径。
- **symlink 目标：** bundle 内 `Bundle.main.resourceURL/bin/<名字>`。应用移动与 Sparkle 升级保留该相对路径，故 symlink 无需重指。指向别的构建、或指向已不存在的内置二进制的软链判为 stale：卡片显示 Stale / Reinstall，Install 在同一次特权调用里替换，不当作外来文件。
- **特权模型：** 特权工作是一次 shell 脚本调用，做 (a) `mkdir -p /usr/local/bin`，(b) 仅对在先前非特权探测中已核实为缺失或我方自有 symlink 的项 `rm -f`，(c) 对缺失项 `ln -s`。探测是非特权的、每次 Settings 卡片出现都跑。
- **PATH 提示：** 安装器不展示基于 GUI 进程 `PATH` 的可用性判断。

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

- **D1 — Release 二进制名 `codans`，Debug 为 `codans-dev`。** 安装器对目标路径做碰撞检查，遇到外来文件中止，不提供自动后备名。
- **D2 — Release 安装进 `/usr/local/bin/codans`，Debug 安装进 `/usr/local/bin/codans-dev`。** 每次 install/uninstall 经一次进程内 `NSAppleScript` 管理员授权调用，对话框使用应用图标与 bundle 名。软链指向 bundle 内的 CLI；调用方需将安装目录加入 `PATH`，或使用绝对路径。完整安装设计见 [CLI 安装](#cli-安装)。
- **D3 — 应用状态只通过 RPC 访问。** RPC 命令不维护离线副本；`launch`、本地 `skill` 命令与帮助输出有各自独立的执行路径。
- **D4 — 便利别名经服务端 `hierarchy.resolveAlias` 解析，不在 CLI 解析。** 保持名字解析为唯一真相来源；客户端只本地校验 UUID 格式。
- **D5 — `pane send` / `broadcast` 在 wire 上分别走 `terminal.sendInput` / `terminal.broadcastInput`，broadcast 用 `scope` 区分服务端扇出。** 减小客户端复杂度，让单个观察者对单播与扇出一视同仁。
- **D6 — `--json` 全局且逐动词，每个 result 类型与 RPC 1:1。** 这是 agent 保持可靠的方式；文本 renderer 是人类便利，非主契约。
- **D7 — 退出码稳定且可枚举。** agent 与 shell 脚本必须能按码分支；预先定一组固定码避免"事事 exit 1"。请求超时（11）与 launch 超时（12）分开，使脚本判 `$? -eq 12` 明确表示"应用没起来"。
- **D19 — socket 连接失败按"补救动作"分类，而非按 errno 逐一暴露。** 单一 "cannot connect" 桶迫使调用方 grep stderr 才能把"应用没起来"（重启即可）与"socket 属于另一个 uid"（需要人）区分开。类别数保持在能改变调用方行为的粒度上：起应用后重试 / 原样重试 / 停下找人。errno 本身只在 message 里作为佐证出现，不进入契约。
- **D8 — 流式 RPC 用 `stream: true` 数据帧和 `stream: false` 终帧，无多路复用。** 一连接一流（在其 `system.hello` 之后）；需要两个流就开两个连接。终帧、EOF 与错误行为见 §Wire 协议。
- **D9 — 每连接串行处理。** `SocketConnection.serve()` 等待当前请求完成后才处理下一帧。`inflightLimit = 64` 是保留的计数阈值，不是已实现的 64 深请求队列，也不提供缓冲内存上限；溢出分支直接返回 `IPCError.overloaded`。并行调度和有界入站缓冲尚未实现。
- **D10 — `system.hello` 是专用首帧 RPC，非逐请求 header；与真实请求 pipelined 一次写。** 每个新连接执行一次握手，两个请求帧合并写出以减少等待。
- **D11 — CLI 本地做 UUID 快路径，其余都是 mutation 前一次服务端往返。** 用延迟换一致性；本地 socket 往返成本（亚毫秒）可忽略。
- **D14 — `codans open` 走 `editor.*` IPC。** 项目覆盖由 `EditorHandlers` 按目录归属解析，`EditorService` 负责已安装编辑器的选择与本地 Launch Services 启动；CLI 不复制注册表和优先级规则。
- **D20 — `handoff` 的源默认是调用方 pane，且 briefing 必须显式给出或显式放弃。** 让在线 agent 交接自己是主路径（它持有任何 transcript 都无法复原的工作上下文）；`--brief`/`--no-brief` 二选一避免 codans 替第三方调用方发起模型调用。接收方任何 agent 均可启动：有已验证 `promptStyle` 的走命令行参数，其余在 agent 出现后由 app 键入 kickoff；`--no-launch` 仍可只归档不启动。见 [agent-handoff.md](agent-handoff.md)。
- **D21 — workspace 磁盘操作由 app 层 `WorkspaceClient` 编排。** GUI 与 IPC 共用成员检出、manifest 写入及失败清理路径，handler 只负责 wire 转换与错误映射。`worktree new` / `rm --delete` 和 handoff 也有磁盘副作用，命令组不能作为只读边界。见 [workspace.md](workspace.md)。
- **D22 — 成员来源在客户端区分「已注册 Project」「本地路径」与「远程 URL」，仓库根一律由服务端求。** `--project` 走 D4 的别名解析拿到 id；`--repo` 发绝对路径，`--remote` 发仓库 URL。这样 CLI 不需要本地 git，也不会把 CLI 机器上的路径解析结果与 app 的 catalog 对不上。
- **D23 — workspace 成员数量校验放 `CodansKit`（`CLIWorkspaceMemberSource.resolve`），在拨号前抛 `userError`。** 与 `CLIBroadcastScopeSelection` 同型：纯参数逻辑放 kit 才能被 `CodansKitTests` 覆盖，且区分于服务端的 `notFound` / `conflict`。
- **D24 — 检出模式三选一（`--existing` / `--track` / `--ref`）与 `--reset-local` 的搭配约束同样放 kit（`CLIWorkspaceCheckoutFlags.resolve`），服务端 `WorkspaceHandlers.checkout` 再守一次。** wire 上 `useExistingBranch` / `remoteRef` / `trackRemote` 是三个独立字段而非一个枚举：第三方客户端漏传其一时缺省仍是「新建分支」，永不落到会改写本地分支的 `-B` 路径；`resetLocalBranch` 缺省 nil，只有显式 `true` 才生效。
- **D18 — `broadcast` 在顶层命名空间，而 `send` 在 `codans pane` 下。** `broadcast` 是显式的扇出动作、置于顶层减少键入；`send`/`send-key`/`read`/`capture` 作为 pane 级操作归在 `pane` 子命令树下（与 `codans pane send` 的 discussion 示例一致）。

## Cross-Cutting

### 安全

- **Socket 认证。** Unix socket mode `0600` + 用户 uid；accept 时经 `SO_PEERCRED` / `LOCAL_PEERCRED`（macOS）验证 peer，其他 uid 立即关闭。给出进程级隔离，无须显式 token。
- **`pane send` / `broadcast`** 向 Pane 注入文本（含 Enter）——若目标 pane 跑 shell 即可执行命令。这是*刻意*的（agent 正是这么干），但意味着这些命令绝不可被外来进程触达；同一 socket 认证保护它。
- **`codans open`** 经 `editor.*` 校验本地目录与编辑器，再通过 Launch Services 打开；不把目录路径交给 shell 解释器。

### 版本与兼容

- **版本来源。** `codans --version` 与 `codans doctor` 显示 CLI 构建版本；服务端版本由 `system.hello` 返回。应用与 bundle 内 CLI 共同分发。
- **握手兼容边界。** 服务端拒绝 major 不兼容的客户端；成功握手不保证每个方法都可用，调用方仍需处理未知方法、参数错误和响应解码失败。`deprecatedMethods` 是握手字段，CLI 没有弃用警告逻辑。

### 性能

- **往返预算。** 每个非流式命令应在热应用上 < 50ms p95（`codans` 每次调用开新连接以保持认证模型简单）。socket accept + JSON 解码 + 进程内分发 + JSON 编码 = 低毫秒级。
- **冷启动。** `codans launch` 最多等 10s 等 socket 出现；超时 exit 12。

## Risks

| 风险 | 缓解 |
|---|---|
| `codans` 名字在 Linuxbrew / 重 TCP 配置用户上碰撞 | 安装碰撞检查对外来 `/usr/local/bin/codans` 中止，提示用户清理后重试 |
| 用户 `codans` 与运行中应用版本偏斜 | `system.hello` 拒绝 major 不兼容；`codans doctor` 检查本地 CLI 与 socket 可达性，不查询服务端版本 |
| 客户端持续发送而请求处理较慢 | 当前逐帧串行处理；64 在飞阈值不限制 reader / 解码缓冲积压，不能作为内存保护保证 |
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
