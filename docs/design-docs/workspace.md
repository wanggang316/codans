# 设计文档：Workspace

**状态：** 分阶段上线（M1 已上线：打开已有 workspace；M2 创建 / M3 移除与 GitHub 聚合 `已设计未实现`）
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
| 侧栏 Project 行 | `isWorkspace` 显示 `square.stack.3d.up` 图标；`+`（Add Worktree）沿用 `supportsWorktrees` 隐藏；`⋯` 菜单隐藏 Prune / Archive-Remove All Merged |
| 子行上下文菜单 | 保留 Pin，隐藏 Archive / Remove；`HierarchySidebarFeature` 的 `worktreeArchiveTapped` / `worktreeRemoveTapped` 以 `isWorkspaceChild` 再守一次（快捷键不能绕过） |
| Header | 根行标题「Workspace」，不是分支 popover 目标 |
| 分支切换器 | `blockedBranches` 按 `repoRoot(for:)` 分组，只统计同仓库的兄弟行 |
| 命令面板 | workspace 隐藏 `worktree.new`（并对 `.dir` 一并隐藏）、`worktree.archive` / `worktree.close` / `worktree.open-project-on-github`、`project.prune-stale` 与 merged 批量 |
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

### M2：创建（已设计未实现）

- `CodansCore/Workspace/WorkspacePlan`：title、rootPath、members[{name, sourceGitRoot, checkout: newBranch(branch, baseRef) | existingBranch(branch)}]；纯校验：成员 ≥ 2、name 唯一、分支合法、根未注册且不在仓库内、目标路径不与任何已注册 root / worktree 冲突、来源为本地。
- `WorkspaceMaterializationLedger`：记录创建的目录与 `git worktree remove` 清理命令，失败 / 取消逆序回滚；回滚在 `Task.detached` 中执行（父任务取消不能 SIGTERM 清理用的 git 子进程）。
- `GitWorktreeClient.addWorktreeAt(repoRoot:destination:checkout:)`：`git -C <root> worktree add [-b <branch>] <dest> [<baseRef>]`。不能用 `wt sw`（它按分支名命名目录）。
- `App/Clients/WorkspaceClient`（TCA dependency）：validate → mkdir → 逐成员 materialize → 写 manifest → `addWorkspaceProject` + 每成员 `createWorktree` → 触发 workspace 与各源 Project 的 reconcile。GUI sheet 与 IPC handler 共用。
- IPC `workspace.create` / `workspace.add` / `workspace.describe`，`WorkspaceHandlers` 走类型化 `throws` 风格；CLI `codans workspace create <title> --project a --project b [--repo <path>] [--branch] [--base] [--existing] [--path]`、`codans workspace add`、`codans workspace show`。
- 源 Project 镜像行守卫（D10）：行尾徽标「⧉ in <workspace>」；上下文菜单隐藏 Archive / Remove 且 reducer 再查；`mergedWorktreeIDs`（侧栏与 `RootFeature`）过滤；`sweepExpiredArchivedWorktrees` 与 `hierarchy.removeWorktree` 跳过并返回 `conflict`；HEAD watcher 双挂载接受。
- `CodansEnvironment.Key.workspaceRoot` + `BuiltinEnvVar.workspaceRoot`。

### M3：移除、生命周期、GitHub（已设计未实现）

- 成员移除：`git worktree remove`（复用 relocate-then-prune，`repoRoot = sourceGitRoot`）→ 可选删分支 → manifest 更新 → 删 catalog 行 → 删源 Project 镜像行。
- 整体移除：默认只删条目；显式选择才逐成员 `git worktree remove`（任一失败则不删根目录，避免悬空注册）与删分支。
- `HierarchyClient.removeWorktreeWithGit` / `sweepExpiredArchivedWorktrees` / Prune 改走 `Project.repoRoot(for:)`。
- GitHub：取数分组键 `(ProjectID, gitRoot)`，`snapshots[worktreeID]` 不变；根行聚合「N PRs · M merged」。

## 备选方案

- **子仓库作为元数据行而非 Worktree**（Prowl 的做法）：状态刷新要单开通道、diff / 通知 / agent 状态各需一层抽象、没有 tab 计数。放弃。
- **manifest 为唯一真相、不持久化标记**：kind 在加载时需要 stat，根目录不可达时会读成 `.dir`，目录回来后下一脉冲即触发 discoverGitRoot + sweep。放弃。
- **源 Project 中隐藏镜像行**（在 `reconcileDiscoveredWorktrees` 里按 workspace 根前缀跳过）：一条规则解决所有破坏性路径，但源 Project 看不到该分支已被 checkout。Gump 选择显示并打标记，代价是逐处守卫；本文 M2 列全。
- **symlink link 模式**：见非目标。

## 横切关注点

- **已知限制**：旧构建对 workspace 根仍会跑 `discoverGitRoot`；D12 要求根不在仓库内，D3 修复清掉误写的 gitRoot。
- **日志**：`com.gumpw.codans.hierarchy/reconcile` 记录追加 / 归档 / 「manifest 不再点名的行」/ 「子仓库所属仓库与 manifest 声明不符」。
- **测试**：`WorkspaceManifestTests` / `WorkspaceCatalogTests`（CodansCoreTests，host-free）；`HierarchyManagerWorkspaceTests`、`CatalogStoreWorkspaceRepairTests`、`HierarchyHandlersWorkspaceTests`、`HierarchyClientWorkspaceReconcileTests`（后者用真实 git：嵌套在外层仓库内的根不获得 gitRoot、子行取到分支与源仓库）。
