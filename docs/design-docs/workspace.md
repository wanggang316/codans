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

### 非目标

- remote clone、bare repository 作为成员来源。
- symlink「link」模式：`HierarchyManager.canonicalPath` 会把 symlink 子目录解析成源 checkout 的路径，与源 Project 的 main 行落在同一 canonical path，无法成为独立行。用 `existingBranch` 建一个新 worktree 覆盖同一诉求。
- workspace 整体归档（Project 级 archive 尚不存在）。

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
    }
  ],
  "createdAt": "2026-09-10T00:00:00Z",
  "updatedAt": "2026-09-10T00:00:00Z"
}
```

- camelCase，与 catalog / settings 一致；`AtomicFileStore` 原子写，日期 ISO-8601。
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
| 侧栏 Project 行 | 未设置自定义图标时默认显示 `square.stack.3d.up`（`ProjectIconView.defaultSymbol(for:)`，Settings 侧栏同源）；`+`（Add Worktree）沿用 `supportsWorktrees` 隐藏；`⋯` 菜单隐藏 Prune / Archive-Remove All Merged |
| 子行上下文菜单 | 保留 Pin，隐藏 Archive / Remove；`HierarchySidebarFeature` 的 `worktreeArchiveTapped` / `worktreeRemoveTapped` 以 `isWorkspaceChild` 再守一次（快捷键不能绕过） |
| Header | 根行标题「Workspace」，不是分支 popover 目标 |
| 分支切换器 | `blockedBranches` 按 `repoRoot(for:)` 分组，只统计同仓库的兄弟行 |
| 命令面板 | workspace 隐藏 `worktree.new`（并对 `.dir` 一并隐藏）、`worktree.archive` / `worktree.close` / `worktree.open-project-on-github`、`project.prune-stale` 与 merged 批量 |
| 侧栏根行 / 子行 | 根行标题固定为 "Workspace"，副标题为 `~` 缩写的根路径（header 已经写了文件夹名，再写一次会被读成又一个仓库）；子行无 PR 时用 `shippingbox` 仓库图标而非 git-branch（`WorktreeRowIcon.LeadingGlyph.repository`），有 PR 仍由 PR 状态图标占位；header 信息标签同源 |
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
Runtime/
  HierarchyManager          addProject(isWorkspace:)、reconcileWorkspaceChildren、workspaceMembership、根行守卫
  CatalogStore.load         调用 WorkspaceMarkerRepair
  ProjectReconciler         manifest 健康检查
Git/GitWorktreeCLI          currentBranch、repositoryRoot(forCheckoutAt:)
App/Clients/HierarchyClient reconcileWorkspace、addWorkspaceProject、workspaceMembership
```

依赖方向不变：app → Runtime → CodansCore；`CodansCore` 不 import AppKit，不 spawn 进程。

### 创建与添加成员

```
CreateWorkspaceFeature (sheet)  ─┐
                                 ├─▶ WorkspaceClient.create / add ─▶ git worktree add ×N ─▶ manifest ─▶ catalog ─▶ reconcile
WorkspaceHandlers (workspace.*) ─┘        │ 失败 / 取消
                                          └─▶ WorkspaceMaterializationLedger.rollbackSteps（Task.detached）
```

- `CodansCore/Workspace/WorkspacePlan`：title、rootPath、members[{name, sourceGitRoot, role, checkout: newBranch(branch, baseRef) | existingBranch(branch)}]。`validate()` 只做无 I/O 的结构检查（title / root 非空、成员 ≥ 2、name 是根下单段、name 唯一、来源与分支非空）；`WorkspacePlan.validate(members:)` 供单成员 `add` 复用。
- I/O 前置检查在 `WorkspaceClient`：根未注册、不是文件、未带 manifest、**不在任何 git 仓库内**（对根或其最近存在的祖先跑 `discoverGitRoot`，D12）；每个来源必须是仓库根；目标 `<root>/<name>` 不存在；分支名经 `git check-ref-format`；`newBranch` 未指定 base 时取仓库默认远端分支。
- 落盘顺序：建根目录（仅在不存在时，并记账）→ 逐成员 `GitWorktreeClient.addWorktreeAt`（`git -C <src> worktree add [-b <branch>] <dest> [<base>]`；不能用 `wt sw`，它按分支名命名目录）→ 写 manifest → `addWorkspaceProject` → reconcile workspace（子行从 git 取分支与 sourceGitRoot）→ reconcile 每个来源 Project（镜像行即时出现）。
- `WorkspaceMaterializationLedger` 记录 createdDirectory / createdBranch / addedWorktree，逆序回滚：先 `removeWorktree`（relocate-then-prune）再 `deleteBranchIfExists` 再删目录。回滚在 `Task.detached` 中执行并等待完成——父任务取消不能 SIGTERM 清理用的 git 子进程。
- IPC `workspace.create` / `workspace.add` / `workspace.describe`：`WorkspaceHandlers` 走类型化 `throws` 风格，只做 wire → plan 翻译与错误映射（cli.md D21–D23）。CLI `codans workspace create|add|show`。
- GUI：`CreateWorkspaceFeature` + `CreateWorkspaceSheet`（Add 菜单「New Workspace…」、palette `app.new-workspace`、`CommandID.newWorkspace` 默认无绑定）；Folder 与 Branch 跟随 Title 直到手改；候选成员 = 本地 git Project，另可从磁盘添加仓库。workspace 根行的 `+` = 「Add Repository…」：选目录 → `discoverGitRoot` → 以 workspace 名 slug 为分支 `add`，失败走 `lifecycleErrorToast`。
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

- **子仓库作为元数据行而非 Worktree**（Prowl 的做法）：状态刷新要单开通道、diff / 通知 / agent 状态各需一层抽象、没有 tab 计数。放弃。
- **manifest 为唯一真相、不持久化标记**：kind 在加载时需要 stat，根目录不可达时会读成 `.dir`，目录回来后下一脉冲即触发 discoverGitRoot + sweep。放弃。
- **源 Project 中隐藏镜像行**（在 `reconcileDiscoveredWorktrees` 里按 workspace 根前缀跳过）：一条规则解决所有破坏性路径，但源 Project 看不到该分支已被 checkout。Gump 选择显示并打标记，代价是逐处守卫；本文 M2 列全。
- **symlink link 模式**：见非目标。

## 横切关注点

- **已知限制**：旧构建对 workspace 根仍会跑 `discoverGitRoot`；D12 要求根不在仓库内，D3 修复清掉误写的 gitRoot。
- **日志**：`com.gumpw.codans.hierarchy/reconcile` 记录追加 / 归档 / 「manifest 不再点名的行」/ 「子仓库所属仓库与 manifest 声明不符」。
- **测试**：`WorkspaceManifestTests` / `WorkspaceCatalogTests`（CodansCoreTests，host-free）；`HierarchyManagerWorkspaceTests`、`CatalogStoreWorkspaceRepairTests`、`HierarchyHandlersWorkspaceTests`、`HierarchyClientWorkspaceReconcileTests`（后者用真实 git：嵌套在外层仓库内的根不获得 gitRoot、子行取到分支与源仓库）。
