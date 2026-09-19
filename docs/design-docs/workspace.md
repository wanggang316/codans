# 设计文档：Workspace

**状态：** 已上线（打开已有 workspace、创建与添加成员、源 Project 标记、成员与整体移除、按成员仓库取 PR 并在根行聚合）
**作者：** Gump（与 Claude）

## 背景与范围

一个任务经常横跨多个仓库（app + api + shared lib）。codans 今天一仓一 Project，用户要为每个仓库开 worktree、开 agent 会话，自己在中间传话。**Workspace** 让一个 agent 在一个终端里跨多仓库工作：一个普通文件夹作为根目录，里面放若干子仓库 checkout，元数据落在 `<root>/.codans/workspace.json`。

建模上，**workspace 是一个 Project**：根目录是它的 main Worktree 行（agent 在这里跑），每个子仓库 checkout 是它下面一个**真正的 Worktree 行**。这样 tab / pane / 通知归属 / agent 状态 / `codans tree` 全部沿用四层层级，不需要平行的「子仓库行」通道。代价是 Worktree 的若干「本仓库 worktree」语义要按 kind 门控——本文逐条列出。

### 共同架构约束（不可违反）

- **`Catalog.currentVersion` 不升版**。新字段 `Project.isWorkspace` / `Worktree.sourceGitRoot` 走 `decodeIfPresent` + 默认值省略 key，旧 catalog 往返字节一致（先例：`archived` / `isPinned` / `remoteHost`）。
- **workspace 根永不被探测 git 根**。`HierarchyClient.reconcile` 在 `discoverGitRoot` 之前按 `project.isWorkspace` 分支到 `reconcileWorkspace`。否则一个恰好位于某仓库内的根目录会被自动升格为该仓库，随后的 stale sweep 会在一个焦点脉冲内把所有子行软归档。
- **成员关系以 manifest 为准，活体事实以 git 为准**。manifest 只说「哪些仓库、什么角色、当初怎么建的」；分支与所属仓库每次 reconcile 从 git 读回（`git symbolic-ref --short HEAD`、`git rev-parse --git-common-dir`），手改或过期的 manifest 只能标错名字，不能让 app 对错误仓库动手。
- **本地限定**。Server（SSH）Project 不能是 workspace，也不能作为成员来源。
- `HierarchyManager` 不 spawn 进程；manifest 读写在 `CodansCore/Workspace/`，git 在 `GitWorktreeCLI` / `GitWorktreeClient`。

## 目标与非目标

### 目标

- 把一个已有 manifest 的文件夹加进侧栏即成为 workspace：根行 + 子行，分支实时刷新，`tree --json` 报 `kind: workspace`。（M1）
- 从侧栏已注册的本地 Project 或任意本地仓库路径创建 workspace，CLI 优先（`codans workspace create/add`），GUI sheet 走同一条编排。（M2）
- 成员可增删；移除 workspace 默认只删条目，显式选择才动磁盘与分支。（M2/M3）
- 子仓库在其源 Project 中仍可见、带「in workspace X」标记，但所有破坏性批量操作绕开它。（M2）
- 子仓库 PR 状态按仓库取数，根行聚合显示。（M3）
- 成员来源补齐：远程 URL（先 clone 到用户选定的本地位置，之后与本地仓库一致）；检出模式补「使用已有远程跟踪分支」（本地同名分支存在时显式选 Keep / Reset，默认 Keep）。（M4）

### 非目标

- symlink「link」模式：`HierarchyManager.canonicalPath` 会把 symlink 子目录解析成源 checkout 的路径，与源 Project 的 main 行落在同一 canonical path，无法成为独立行。用 `existingBranch` 建一个新 worktree 覆盖同一诉求。
- workspace 整体归档（Project 级 archive 尚不存在）。
- 裸仓库作为成员来源：暂不支持，探测到即以 `WorkspaceError.bareRepository` 拒绝（D17），CLI 与 sheet 给出同一原因。

## 设计

### 数据模型

| 决策 | 内容 | 理由 |
|---|---|---|
| D1 | `Project.isWorkspace: Bool` 持久化，false 省略 key | kind 必须在 `@MainActor` 同步可知（Settings 子面板、侧栏、reconcile 短路），且不依赖磁盘可达 |
| D2 | `ProjectKind.workspace`；派生优先级 `remoteHost → server; isWorkspace → workspace; gitRoot == nil → dir; else gitRepo` | kind 派生、不进 catalog，raw value 无解码风险；workspace 压过 gitRoot，旧构建误写的 gitRoot 不能改变 kind |
| D3 | `CatalogStore.load()` 经 `WorkspaceMarkerRepair` 修复：本地、未标记、根下存在 manifest → 置标记并清 `gitRoot`，立即 `saveNow` | 防跨构建剥字段（`RemoteHostSidecar` 先例）；manifest 是旧构建碰不到的持久信号 |
| D4 | 标记粘性：manifest 丢失不降级为 `.dir`，`ProjectReconciler` 置 `loadState = .failed(...)` | 降级会重新打开 discoverGitRoot + sweep 通道；`FailedProjectRow` 免费给 Retry / Remove |
| D5 | `Project.workspace: WorkspaceManifest?` transient（同 `loadState`），reconcile 填充，仅供展示 | 首次 reconcile 前为 nil，reducer 逻辑不得依赖 |
| D6 | `Worktree.sourceGitRoot: String?` 持久化，nil 省略；来源是 git 而非 manifest；经 `Project.repoRoot(for:)` 读取 | `blockedBranches` 与 GitHub 取数在启动恢复选择时同步读 catalog，早于任何 reconcile |
| D7 | 子行 = 普通 `Worktree`：`name` = 子目录名（根下唯一），`branch` = 实时分支，`path` = `<root>/<name>` canonical | 无需 Worktree 种类字段；name 不随分支改名 |
| D8 | 根行 = `addProject` 已有的 synthetic 行（`path == rootPath`），沿用 main-checkout 守卫；`HierarchyManager.removeWorktree` 对所有 kind 补上该守卫（IPC 路径此前无保护） | |
| D9 | 子目录消失 → 软归档（沿用 stale sweep 语义），前提是 manifest 可读；manifest entry 保留；manifest 不再点名的行原样保留并记日志 | reconcile 永不删行；keep-row 没有 UI 承载 |
| D10 | 源 Project 中的镜像行保留并打标记，破坏性路径逐处守卫（见 M2） | Gump 的选择：信息不丢 |
| D11 | manifest 在 `<root>/.codans/workspace.json`，常量集中在 `WorkspaceLayout`（复用 `HandoffLayout.stateDirectoryName`）；默认根目录 `~/.codans/workspaces/<slug>` | 与 `~/.codans/repos/<project>` 对称 |
| D12 | 创建校验：根目录不得位于任何 git 仓库内 | 旧构建仍会对 workspace 根跑 `discoverGitRoot`，这是唯一真正的防线；已知限制 |
| D13 | 环境变量 `CODANS_WORKSPACE_ROOT` 只在 workspace Project 的 pane 注入（`CODANS_ROOT_PATH` 已等于根目录） | 显式信号，非 workspace 下不存在（M2） |
| D14 | `WorkspacePlan.Member.source: Source = .local(gitRoot) \| .remote(url, cloneDestination)`；`sourceGitRoot` 是派生属性（远程 = clone 目标） | 远程只是「先 clone」的本地源；成员统一是 linked worktree，`sourceGitRoot` 永不等于成员自身路径，drop / remove / reconcile / PR 取数零特判 |
| D15 | `WorkspaceCheckout.remoteTrackingRef(remoteRef, branch, resetLocal)`：本地无同名分支 → `worktree add --track -b`；有且 `resetLocal == false` → 降级为 `existingBranch`；有且 `resetLocal == true` → 先记 `resetBranch(previousTip)` 再 `--track -B` | `-B` 只在用户显式要求重置时出现；账本能把被重置的分支恢复到原 tip |
| D16 | manifest `checkoutMode` 加 `remoteTrackingRef`（`baseRef` 存远程 ref）；`Entry.remoteURL` 只记 provenance | 最小 schema 变化；老构建重存会剥掉 `remoteURL`，只丢信息不改行为 |
| D17 | 来源探测统一走 `GitWorktreeCLI.inspectRepository(at:)`（`--git-common-dir` + `--is-bare-repository`），替代 `discoverGitRoot`；裸仓库来源以 `bareRepository` 拒绝（远程 clone 目标若是裸仓库也不复用）；根目录的祖先探测同样换用 | 子目录与 linked worktree 能归一到仓库根；裸仓库给出明确原因，而不是笼统的「不是 git 仓库」；根不能建在裸仓库目录内 |
| D18 | 来源为仓库子目录或 linked worktree 时接受并归一到仓库根 | 与 `--repo` 的服务端行为一致，少一个拒绝理由 |
| D19 | 远程 clone 默认目标 `~/.codans/sources/<repoName>`（`WorkspaceLayout.defaultSourcesDirectory` / `uniquePath` / `repositoryName(fromRemoteURL:)`），用户可改；目标已存在且 `remote get-url origin` 与 URL 等价（忽略尾部 `/` 与 `.git`）→ 复用不 clone，否则 `cloneDestinationTaken` | 让用户选择 clone 到哪里；复用避免重复 clone；不覆盖别的仓库 |
| D20 | clone 走 `GitWorktreeClient.cloneStream`（`git clone --progress`，`runStream` 按 `\r` 也切行，进程盒可终止，`GIT_TERMINAL_PROMPT=0`）；账本新步 `clonedRepository`，复用的仓库不记账 | 数分钟的 clone 必须可取消、有进度；回滚不能删用户已有仓库 |
| D21 | 创建前 fetch：checkout 引用的 `<remote>/…` 前缀在仓库里配置了 URL 且 `WorktreeSettings.fetchRemoteOnCreate` 为真 → `git fetch <remote>`；未指定 base 的 `newBranch` 视为引用 `origin`；刚 clone 的源跳过；fetch 失败 = 该成员失败并整体回滚 | 与 worktree 创建一致，远程 ref 不新鲜会静默基于旧 tip |
| D22 | `WorkspaceClient.createStream / addStream(…, token)` 流式发 `WorkspaceCreationEvent`（memberStarted(phase) / progressLine / memberFinished / memberFailed / manifestWritten / registered / rollingBack / rolledBack(failures)）；`cancelCreation(token)` 取消驱动任务，流继续到 `rolledBack` 再以 `WorkspaceError.cancelled` 结束；`create / add` 只是 drain；`preflight(plan)` 把 I/O 检查以收集形式暴露 | GUI 逐行进度与可取消；IPC 不变；表单可实时显示每处问题 |
| D23 | 远程 heads 用 `git ls-remote --symref <url> HEAD refs/heads/*`（30 s 上限），`RemoteHeads.parse` 解析 | 远程成员在 clone 前也能选分支、知道默认分支 |

### manifest

```json
{
  "schemaVersion": 1,
  "title": "Checkout Flow",
  "description": "optional",
  "taskLinks": ["https://github.com/org/repo/issues/123"],
  "repositories": [
    {
      "name": "app",
      "role": "macOS app",
      "path": "app",
      "sourceGitRoot": "/Users/me/dev/app",
      "checkoutMode": "newBranch",
      "branch": "feat/checkout-flow",
      "baseRef": "origin/main"
    },
    {
      "name": "lib",
      "path": "lib",
      "sourceGitRoot": "/Users/me/.codans/sources/lib",
      "remoteURL": "git@github.com:org/lib.git",
      "checkoutMode": "remoteTrackingRef",
      "branch": "main",
      "baseRef": "origin/main"
    }
  ],
  "createdAt": "2026-09-10T00:00:00Z",
  "updatedAt": "2026-09-10T00:00:00Z"
}
```

- camelCase，与 catalog / settings 一致；`AtomicFileStore` 原子写，日期 ISO-8601。
- `checkoutMode ∈ {newBranch, existingBranch, remoteTrackingRef}`；`remoteURL` 仅远程来源写入，纯 provenance（D16）。
- 解码宽容：每个字段有默认值，未知 key 忽略，未知 `checkoutMode` 读成「未记录」。`normalized(rootPath:)` 补 title / name / path，`validate()` 只接受根下单段相对路径且 name / path 唯一。
- `WorkspaceManifestStore.hasManifest` 只做一次 `stat`，是 add-project 与 catalog 修复的判定依据。

### Reconcile

```
ProjectReconciler.reconcile
  └─ 本地 Project：stat rootPath；isWorkspace → 再 load manifest，失败即 .failed 并返回
       └─ HierarchyClient.reconcile
            ├─ isRemote   → reconcileRemote
            ├─ isWorkspace → reconcileWorkspace        ← 在 discoverGitRoot 之前
            └─ 其余        → discoverGitRoot / lsWorktrees / reconcileDiscoveredWorktrees
```

`reconcileWorkspace`：读 manifest → 写 transient `Project.workspace` → 每个 entry 解析 `<root>/<path>` 并 canonical 化、stat、`currentBranch`、`repositoryRoot(forCheckoutAt:)` → `HierarchyManager.reconcileWorkspaceChildren(projectID:observations:)`：

- 有目录无行 → 追加子行；有行 → 原地刷新 `branch` / `sourceGitRoot`（保留 id、tabs、flags，不改 name）；目录消失且行未归档未 pin → 软归档；根行永不触碰；空观察集不归档。
- 不调用 `sweepExpiredArchivedWorktrees`（它按 `project.gitRoot` 删 worktree，对 workspace 无意义；M3 改走 `repoRoot(for:)`）。

### UI 门控（M1）

| 位置 | 规则 |
|---|---|
| 侧栏 Project 行 | 未设置自定义图标时默认显示 `square.stack.3d.up`（`ProjectIconView.defaultSymbol(for:)`，Settings 侧栏同源）；`+` 对 workspace 是「Add Repository…」（打开 add 模式的 New Workspace sheet），对其余 kind 沿用 `supportsWorktrees`；`⋯` 菜单隐藏 Prune / Archive-Remove All Merged |
| 子行上下文菜单 | 保留 Pin，隐藏 Archive / Remove；`HierarchySidebarFeature` 的 `worktreeArchiveTapped` / `worktreeRemoveTapped` 以 `isWorkspaceChild` 再守一次（快捷键不能绕过） |
| Header | 根行标题「Workspace」，不是分支 popover 目标 |
| 分支切换器 | `blockedBranches` 按 `repoRoot(for:)` 分组，只统计同仓库的兄弟行 |
| 命令面板 | workspace 隐藏 `worktree.new`（并对 `.dir` 一并隐藏）、`worktree.archive` / `worktree.close` / `worktree.open-project-on-github`、`project.prune-stale` 与 merged 批量 |
| 侧栏根行 | 标题固定为 "Root"，副标题为 `~` 缩写的根路径（header 已经写了文件夹名，再写一次会被读成又一个仓库）；图标为 `star.fill`（`WorktreeRowIcon.LeadingGlyph.workspaceRoot`，与默认分支的锚点标记同形）；子行沿用普通 worktree 行的图标；header 信息标签同源 |
| Settings | `visibleSections(.workspace) = [general, editor, environment]`；侧栏图标区分 |
| IPC | `hierarchy.createWorktree` 对 workspace 返回 `invalidParams`；`hierarchy.addProject` 见 manifest 即注册为 workspace；`hierarchy.removeWorktree` 拒绝根行（`conflict`） |
| CLI | `codans tree` 的 Project 行带 `[workspace]`，`--json` 增加 `kind` 与 worktree 的 `sourceGitRoot` |

### 组件边界

```
CodansCore/Workspace/
  WorkspaceLayout           路径常量、默认目录、title → 文件夹名
  WorkspaceManifest         schema、宽容 Codable、normalize / validate
  WorkspaceManifestStore    hasManifest / load / save（AtomicFileStore）
  WorkspaceMembership       Catalog.workspaceMembership(forCanonicalPath:)
  WorkspaceMarkerRepair     catalog 加载修复
  WorkspacePlan             创建意图：Member.Source、WorkspaceCheckout、结构校验
  WorkspaceMaterializationLedger  已落盘步骤与逆序回滚
  WorkspaceCreationEvent    流式创建事件
  WorkspacePreflight        I/O 检查的收集结果
  RemoteHeads               ls-remote --symref 输出解析
Runtime/
  HierarchyManager          addProject(isWorkspace:)、reconcileWorkspaceChildren、workspaceMembership、根行守卫
  CatalogStore.load         调用 WorkspaceMarkerRepair
  ProjectReconciler         manifest 健康检查
Git/GitWorktreeCLI          currentBranch、repositoryRoot(forCheckoutAt:)、inspectRepository(at:)
Git/GitWorktreeClient       addWorktreeAt、cloneStream、lsRemoteHeads、branchTip、forceMoveBranch、remoteURL
App/Clients/HierarchyClient reconcileWorkspace、addWorkspaceProject、workspaceMembership
App/Clients/WorkspaceClient create / add（及 stream 变体）、preflight、drop、remove
App/Features/CreateWorkspace/
  CreateWorkspaceFeature      sheet reducer（create / add 两种模式）
  CreateWorkspaceMemberDraft  MemberDraft、MemberEditor、RefInventory、MemberIssue
  CreateWorkspaceAddEntry     URL 输入的分类（URL / 路径）与远程去重键
  CreateWorkspaceSheet        分组 Form 外壳（工作区一节、添加按钮、项目列表）+ presenter
  WorkspaceMemberRow          列表行：来源图标、名称与来源、检出摘要、问题 / 进度、编辑与删除
  WorkspaceMemberEditorSheet  添加 / 编辑弹窗（已打开项目、文件夹、远程三种来源 + 检出设置）
  WorkspaceRefPicker / WorkspaceCreationBar
```

依赖方向不变：app → Runtime → CodansCore；`CodansCore` 不 import AppKit，不 spawn 进程。

### 创建与添加成员

```
CreateWorkspaceFeature (sheet)  ─┐
                                 ├─▶ WorkspaceClient.create / add ─▶ git worktree add ×N ─▶ manifest ─▶ catalog ─▶ reconcile
WorkspaceHandlers (workspace.*) ─┘        │ 失败 / 取消
                                          └─▶ WorkspaceMaterializationLedger.rollbackSteps（Task.detached）
```

- `CodansCore/Workspace/WorkspacePlan`：title、rootPath、members[{name, source: local(gitRoot) | remote(url, cloneDestination), role, checkout: newBranch(branch, baseRef) | existingBranch(branch) | remoteTrackingRef(remoteRef, branch, resetLocal)}]。`validate()` 只做无 I/O 的结构检查（title / root 非空、成员 ≥ 2、name 是根下单段、name 唯一、来源 / URL / clone 目标与分支非空、远程 ref 形如 `<remote>/<branch>`）；`WorkspacePlan.validate(members:)` 供单成员 `add` 复用。

成员来源与检出模式：

| 来源 | 落盘 | `sourceGitRoot` |
|---|---|---|
| 已注册本地 Project | `worktree add` | Project 的 `gitRoot` |
| 本地仓库路径（子目录、linked worktree 归一到仓库根；裸仓库拒绝，D17/D18） | `worktree add` | 仓库根 |
| 远程 URL | `git clone --progress` 到 clone 目标（默认 `~/.codans/sources/<name>`，已是同一远程的 clone 则复用，D19/D20）→ `worktree add` | clone 目标 |

| 模式 | 命令 | 账本 |
|---|---|---|
| `newBranch(branch, base?)` | `worktree add -b <branch> <dest> [<base>]`（base 缺省 = 默认远端分支，且必须是仓库已有的 ref） | `createdBranch` |
| `existingBranch(branch)` | `worktree add <dest> <branch>` | — |
| `remoteTrackingRef`，本地无同名分支 | `worktree add --track -b <branch> <dest> <remote>/<branch>` | `createdBranch` |
| `remoteTrackingRef`，本地有同名分支，Keep | 降级为 `existingBranch(branch)` | — |
| `remoteTrackingRef`，本地有同名分支，Reset | `worktree add --track -B <branch> <dest> <remote>/<branch>` | 先记 `resetBranch(previousTip)` |

- I/O 前置检查在 `WorkspaceClient.resolve` / `preflightRoot`（`preflight(plan)` 以收集形式复用同一套）：根未注册、不是文件、未带 manifest、**不在任何 git 仓库内**（对根或其最近存在的祖先跑 `inspectRepository`，D12/D17）；本地来源必须是仓库（归一到根）；远程 clone 目标不存在或已是同一远程的 clone；目标 `<root>/<name>` 不存在；分支名经 `git check-ref-format --branch`（无仓库也能问，远程来源在 clone 前就校验）。
- 落盘顺序：建根目录（仅在不存在时，并记账）→ 逐成员 [clone（记 `clonedRepository`）→ fetch（D21）→ 定稿 checkout（默认 base、Keep / Reset 判定）→ `GitWorktreeClient.addWorktreeAt`（不能用 `wt sw`，它按分支名命名目录）] → 写 manifest → `addWorkspaceProject` → reconcile workspace（子行从 git 取分支与 sourceGitRoot）→ reconcile 每个来源 Project（镜像行即时出现）。每步经 `WorkspaceCreationEvent` 上报（D22）。
- `WorkspaceMaterializationLedger` 记录 createdDirectory / clonedRepository / createdBranch / resetBranch / addedWorktree，逆序回滚：先 `removeWorktree`（relocate-then-prune），再 `branch -f <branch> <previousTip>` 或 `deleteBranchIfExists`，再删 clone 目录与根目录。回滚在 `Task.detached` 中执行并等待完成——父任务取消不能 SIGTERM 清理用的 git 子进程；无法撤销的项经 `rolledBack(failures:)` 报给调用方。
- IPC `workspace.create` / `workspace.add` / `workspace.describe`：`WorkspaceHandlers` 走类型化 `throws` 风格，只做 wire → plan 翻译与错误映射（cli.md D21–D23）。CLI `codans workspace create|add|show`。
- GUI（`App/Features/CreateWorkspace/`）：`CreateWorkspaceFeature` + `CreateWorkspaceSheet`（Add 菜单「New Workspace…」、palette `app.new-workspace`、`CommandID.newWorkspace` 默认无绑定；workspace 根行的 `+`「Add Repository…」打开同一 sheet 的 add 模式：Workspace / Location 只读、恰好一个成员、提交走 `addStream`）。样式与 Settings 面板一致：`Form` + `.formStyle(.grouped)`，行用 `TextField` / `LabeledContent` / `Picker`（原生弹出菜单），不自绘控件；Cancel / Create 放在表单下方的按钮栏（不叠在表单上，避免行滚到按钮后面）；宽 560，高度随内容，最高 760 后滚动。
  - 第一节「New Workspace」：Title；Location（父目录 + 文件夹按钮，显示 `<location>/<slug>`，文件夹名始终跟随标题）。没有统一的分支设置：New branch 留空的分支名取标题 slug（`State.defaultBranch`），填了就用自己的。打开时列表为空，不预置侧栏选中的 Project：每个项目都由用户自己添加（预置行若在 `onAppear` 里追加，会在 sheet 弹出动画中途撑高表单，底部按钮随之跳动）。
  - 三个添加按钮放在卡片外（节脚，Settings 在列表下放「Add…」按钮的位置）：列表为空时在第一节下方，有项目后在列表下方。**Add Project** 是下拉按钮，列出尚未加入的已注册 Project（`availableCandidates`，菜单只画 SF Symbol，自定义图片回退为文件夹），选中即打开该项目的弹窗；**Add Folder…** 先弹文件夹选择器，选定后打开弹窗并探测该目录；**Add Remote…** 打开 URL 弹窗。add 模式列表已有一个项目后按钮消失。
  - 第二节「Projects」：列表为空时整节不显示。每个项目一行——来源图标（已注册 Project 用它自己的 `ProjectIconView`，磁盘上的文件夹 `folder`，远程 `globe`）、文件夹名 + 来源路径或 URL（中间截断，悬停看全文与 clone 目标）、一行检出摘要（`checkoutSummary`：New branch X from Y / Branch X / Branch X, tracking origin/X …）、红 / 橙问题行；右侧铅笔（编辑）与垃圾桶（删除）。创建中右侧换成进度圈 / 勾，摘要下显示阶段与最后一行进度、失败原因或 Rolled back。空列表显示一行说明。
  - 弹窗（`WorkspaceMemberEditorSheet`，`State.editor: MemberEditor`，同为分组 Form，宽 500，底部 Cancel / Add 或 Save）：第一节是来源，每种弹窗只有一种设定方式——已打开项目（`Kind.project`，标题「Add <name>」）与编辑（`Kind.edit`）只读显示 Repository（名称 + 路径或 URL）；文件夹（`Kind.folder`）为 Folder 行（路径 + Choose… 重新选择；`inspectRepository` 后命中已注册 Project 记为 Project 并在副标题注明，裸仓库与非仓库在节脚给出原因，按 canonical 根去重）；远程（`Kind.remote`）为 URL 输入（停顿 600 ms 或 ⏎ 后生效；`AddEntryClassifier` 识别，路径与无法识别的文字只在 ⏎ 时报错；按 host/path 去重）+ Clone to（默认 `~/.codans/sources/<name>`，选过的父目录在换 URL 后保留）；编辑远程项目时仍可改 Clone to。选定来源后出现第二节：Checkout（New branch / Existing branch 两种）、该模式的分支行、Folder name（默认仓库名，与列表或 add 模式已有名字冲突时加 `-2`；手改后换来源不再改名）。New branch 的 Branch 占位符显示标题 slug，Based on 首项为「Default (origin/main)」；Existing branch 只有一个 Branch 下拉，Local 与 Remote 分组同列（两类分支本就由 `branchRefs` 一次取回），选本地即直接检出（菜单不标注占用状态；选中已被其他 worktree 检出的分支时，节脚说明占用位置并建议改用 New branch），选远程则建同名本地分支跟踪它（副标题说明；本地已有同名分支时改为 Local branch 选择：Keep local branch 默认 / Reset to <ref>）。选中的是哪一类由仓库自己的分支列表判定（`MemberDraft.existingRefIsRemote`），列表未加载时该成员被 incomplete / blocking 挡住，不会按名字形状猜。节脚显示分支加载状态与 Retry 和问题。
  - 弹窗的草稿与列表分离：Add / Save 才写回列表，Cancel 丢弃（新草稿的 refs 加载一并取消）。字段编辑 `member(id, …)` 发给 id 相同的弹窗草稿，否则发给行；refs 结果两处都写。preflight 检查「列表 + 弹窗草稿」（`checkedPlan`），被编辑的行保留旧结果、由草稿接收新结果。弹窗打开或创建进行中，行的编辑与删除不生效。弹窗对未填完的项同样只禁用 Add 并在底部提示，唯一例外是跟随标题的空分支（标题可能还没填，主表单会提示）。
  - refs 加载：本地源四并发（`branchRefs` / `localBranchNames` / `lsWorktrees` / `defaultRemoteBranchRef`）；远程源 `lsRemoteHeads` 与 20 s 竞速。
  - 校验分三级（`MemberIssue.Severity`）：`incomplete`（没填完：标题、成员数、分支、未选分支、分支加载中）只禁用 Create，不标红，按钮栏左侧提示第一项；`blocking`（名字非法或重复、分支语法 `BranchNameSyntax.quickCheck`、新分支已存在、已有分支不存在、分支被其他 worktree 检出——Keep 与 Reset 都查、远程分支不存在、add 模式名字冲突，以及 300 ms debounce 后 `WorkspaceClient.preflight` 回填的 I/O 结果）红字列在所在行下与弹窗节脚；`warning` / `info` 不阻塞。preflight 文案面向表单（路径用 `~`，空分支不报），名字已有问题时不再重复「目录已存在」。
  - 创建：`createStream(plan, token)` 事件驱动各行状态（Cloning… / Fetching… / Checking out… + 进度行 / Checked out / 失败原因 / Rolled back），按钮栏左侧显示当前阶段；运行中 Cancel 调 `cancelCreation(token)`，流继续到 `rolledBack(failures)`；结束后按钮栏显示结果（已取消、需手工清理的项、失败原因），Create 可直接重试，任何编辑清除结果。`registered` → `delegate(.created)` / `.added(projectID, worktreeID)`，侧栏选中新建的 workspace 或新行。
- 源 Project 镜像行守卫（D10）：行尾徽标「⧉ <workspace>」点击跳到 workspace 子行；上下文菜单隐藏 Archive / Remove 且 `HierarchySidebarFeature.isWorkspaceMember` 在 reducer 再守一次；`mergedWorktreeIDs`（侧栏 header 与 `RootFeature`）过滤；`sweepExpiredArchivedWorktrees` 跳过；`hierarchy.removeWorktree` 对子行与镜像行都返回 `conflict`；HEAD watcher 双挂载接受。
- `CodansEnvironment.Key.workspaceRoot` / `BuiltinEnvVar.workspaceRoot`：`injectingBuiltins(workspaceRoot:)` 只在 workspace Project 的 pane 写入，非 workspace 主动移除同名 key。

### 移除

- **成员移除**（子行「Remove from Workspace…」/ `codans workspace drop`）：`WorkspaceClient.drop` 先 `tearDownWorktreeSurfaces`，再 `GitWorktreeClient.removeWorktree(repoRoot: sourceGitRoot, path)`（relocate-then-prune），默认删分支（git 拒绝时把原因作为 note 回带，与 Delete Worktree 一致），从 manifest 删 entry，删本行，再删源 Project 里指向同一目录的镜像行。根行不是成员，`cannotDropRoot`。
- **整体移除**（⋯ 菜单「Remove Workspace…」/ `codans workspace remove`）：`WorkspaceCleanup.entryOnly` 只 `removeProject`，磁盘不动；`deleteFiles` 逐成员注销（失败记入 `failures`，继续处理其余成员），条目一律删除，**根目录只在全部注销成功时删除**——否则源仓库会留下指向已删目录的 worktree 注册。GUI 对话框给「Remove from Sidebar」与「Remove and Delete Checkouts」（分支保留）；`--delete-branches` 仅 CLI 提供。
- 子行的 Archive 仍不开放（归档一个别的仓库的 checkout 没有意义）；`sweepExpiredArchivedWorktrees` 与 Prune 对 workspace 不运行。

### GitHub：按成员仓库取数

`GitHubFeature` 的所有按 Project 键控的状态（`snapshotsByProject`、in-flight / queued 集合、`projectGitRoots`、`projectWorktreePairs`、cancel id、磁盘缓存）**原封不动**。变化只在 `RootFeature` 的派发侧：

- `RootFeature.gitHubFetchUnits(in:)` 把一个 Project 拆成若干「取数单元」`(projectID, gitRoot, pairs)`：git Project 一个单元、键为自身 id；workspace 按 `Project.repoRoot(for:)` 分组，每个成员仓库一个单元，键为 `workspaceFetchGroupID(workspace:gitRoot:)`——对 `"<workspaceID>|<canonical gitRoot>"` 取 SHA-256 前 16 字节做成 `ProjectID`，跨启动稳定，磁盘缓存能按同一键回填。
- 激活 Project 时对每个单元各发一次 `projectActivated`；`pruneToCatalog` 的存活集合 = 全部 Project id ∪ 全部单元 id；`seedFromCache` 同样按单元回填。
- 心跳 poll 只有一个槽位：workspace 里跟随**选中成员**所属仓库（`gitHubFetchUnit(in:worktreeID:fallback:)`），其余仓库靠激活 / 焦点 / pane 内 git 命令后的刷新。
- pane 内 `git` / `gh` 命令结束后的刷新只打该 pane 所在行的单元；「Open Project on GitHub」在 workspace 里打开选中成员的仓库。
- 根行聚合徽标：`ProjectHeaderRow.workspacePullRequestSummary` 汇总子行 `snapshots[worktreeID]`，显示「N PRs · M merged」。

取舍：把 `GitHubFeature` 改为复合键会同时改动 reducer、动作签名、磁盘缓存形状与约 160 处测试引用；派生 id 让 reducer 与其测试零改动，代价是 Settings → GitHub 的 per-Project 错误横幅对 workspace 显示的是单元 id 而非名字（当前无消费者读该字段）。

## 备选方案

- **子仓库作为元数据行而非 Worktree**：状态刷新要单开通道、diff / 通知 / agent 状态各需一层抽象、没有 tab 计数。放弃。
- **manifest 为唯一真相、不持久化标记**：kind 在加载时需要 stat，根目录不可达时会读成 `.dir`，目录回来后下一脉冲即触发 discoverGitRoot + sweep。放弃。
- **源 Project 中隐藏镜像行**（在 `reconcileDiscoveredWorktrees` 里按 workspace 根前缀跳过）：一条规则解决所有破坏性路径，但源 Project 看不到该分支已被 checkout。Gump 选择显示并打标记，代价是逐处守卫；本文 M2 列全。
- **symlink link 模式**：见非目标。

## 横切关注点

- **已知限制**：旧构建对 workspace 根仍会跑 `discoverGitRoot`；D12 要求根不在仓库内，D3 修复清掉误写的 gitRoot。老构建重存 manifest 会剥掉 `remoteURL`（D16）。裸仓库既不能作为成员来源，其目录内也不能建 workspace 根（D17）。远程来源的 clone 只在回滚时删除；drop / remove 成员不删 clone，它是普通本地仓库。
- **日志**：`com.gumpw.codans.hierarchy/reconcile` 记录追加 / 归档 / 「manifest 不再点名的行」/ 「子仓库所属仓库与 manifest 声明不符」。
- **测试**：`WorkspaceManifestTests` / `WorkspaceCatalogTests`（CodansCoreTests，host-free）；`HierarchyManagerWorkspaceTests`、`CatalogStoreWorkspaceRepairTests`、`HierarchyHandlersWorkspaceTests`、`HierarchyClientWorkspaceReconcileTests`（后者用真实 git：嵌套在外层仓库内的根不获得 gitRoot、子行取到分支与源仓库）；`WorkspacePlanTests` / `RemoteHeadsTests`（来源、检出、账本、ls-remote 解析）；`WorkspaceClientTests`（真实 git：远程 clone 与复用、裸源被拒、preflight 文案与空分支、remoteTrackingRef 三种情形、回滚恢复被重置分支、fetch 失败、clone 中取消）；`CreateWorkspaceFeatureTests`（TestStore：预选成员、标题派生目录与未命名的新分支、Add Project 菜单打开弹窗、文件夹弹窗随选择器打开 / 拒绝原因 / 重新选择、远程弹窗的 URL 停顿生效 / 去重 / clone 父目录保留、编辑只在 Save 生效、弹窗允许跟随标题的空分支、ls-remote 超时、未填完与问题的分级、两种检出模式的校验（含同一列表里本地 / 远程两条路径）、行摘要、debounce preflight 覆盖弹窗草稿、创建事件流、失败后重试与编辑清除、取消回滚与运行中锁定、add 模式、URL 分类）；`CatalogResolutionTests`（显示中的选中 Project 回退）；`BranchNameSyntaxTests`。
