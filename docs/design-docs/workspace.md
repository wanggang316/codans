# 设计文档：Workspace

**状态：** 工作区组模型已上线：源项目列表与 `default` 组、命名组的创建与删除（删除前逐成员检查风险）、Workspace 移除、catalog v3 → v4 与 manifest v1 → v2 迁移、按成员仓库取 PR 并在组行汇总。持久化结构、迁移、运行时映射与验收记录见 [执行计划](../exec-plans/workspace-groups.md)。
**作者：** Gump（与 Claude）

## 工作区组设计

术语见 [GLOSSARY.md](../../GLOSSARY.md)。

### 层级与终端

- Workspace 是项目集合，下面包含 `default` 与命名工作区组；每组下面再显示成员项目的 checkout。
- Workspace 行右侧提供新建组（`+`）、选项（`⋯`）、展开按钮，悬停时出现；同样的入口也作为行的辅助功能动作（New Group、Add Project、Workspace Settings、Remove Workspace）。展开控制整个组列表；各组独立展开或收起，初始收起，成员行再缩进一级（Workspace 0、组 14、成员 28）。
- `default` 行在名称前显示五角星，命名组显示文件夹图标。`default` 是组名，不是 Git 分支名；成员显示各自真实分支。组行第二行显示成员数、分支汇总（一个分支名或「N branches」）与该组的 PR 汇总。
- 添加 Workspace 时选择各项目的主工作区，不要求选择分支，不切换分支，也不新建 Git worktree。
- `default` 成员引用项目已有主工作区，与源 Project 共享同一个磁盘目录；文件修改在两处可见。引用行带 `↗` 标记。
- Workspace 标题只负责组织与管理，不可选中。选择工作区组打开该组自己的终端（cwd 为组目录），选择成员打开该成员自己的终端（cwd 为成员 checkout）。组行的 header 显示组名与「Group · <Workspace>」，不是分支 popover 入口。
- 每组有实际目录。`default` 在组目录内以符号链接引用源项目主工作区；命名组的目录容纳该组新建的 checkout（`<root>/<group>/<project>`）。
- 选中折叠组内的成员（CLI、恢复选择、通知、新加入的引用行）时先展开该组；折叠含选中成员的组不留残影行。

### 创建与成员状态

- 新建入口用于创建命名工作区组：弹窗提供统一分支名称（留空用组名），覆盖全部成员，不允许逐项目覆盖分支名称。任一项目存在同名分支时，在该项目下提示并阻止创建。
- 每个项目单独配置 Base ref、Fetch、复制 ignored / untracked 文件、启动 Agent；默认值沿用各项目设置。
- 任一成员 checkout 创建失败时，整体回滚本次新建的 checkout 和分支，保留表单供修正重试；清理失败时列出残留目录与原因。
- 全部 checkout 创建成功后才执行各项目的 setup script 和 Agent 启动。脚本失败保留工作区组并报告错误，不承诺回滚脚本副作用。
- 组关联各项目的 worktree，不以当前分支作为成员身份。成员分支发生变化时，刷新成员展示及组的分支汇总，不改变成员归属与行 ID；统一分支名称是创建时的约束。
- Workspace 项目列表的增删立即影响 `default`，并用于后续新建组；已有命名组保留创建时的成员，不随项目列表变化自动增删 checkout。

### 删除

- `default` 不可单独删除；其中的成员通过侧栏引用行「Remove from Workspace…」或 Workspace 设置的 Projects 一节管理，移除引用不删除源项目目录。
- 命名组整组删除（组行上下文菜单「Delete Group…」），不提供单独删除成员的入口。确认框列出受影响项目，并提供是否删除分支的选项（同名分支只列一次）；执行前逐项目检查未提交修改、未推送提交、运行中的终端与组目录内的其他文件。
- 发现风险时，在弹窗中列出具体风险，要求显式勾选「Discard these changes and stop the terminals」后才能继续。检查失败则阻止删除并提供重试，不把无法检查视为没有风险。IPC 在服务端重新检查，不能绕过确认。
- 整个 Workspace 提供「Remove from Sidebar」与「Delete Workspace Files…」（删除所有命名组、`default` 链接及 Workspace 自身目录，同样先检查风险）；两种操作都不删除源项目主工作区。
- 删除部分失败时，保留失败项，组行显示「Deletion incomplete · N items not removed」与 Retry，失败原因在提示与重试弹窗的「Not Removed Last Time」中列出；重启后只保留 `deletion` 状态，Retry 重新检查。
- 成员移除中途失败时，`git worktree remove --force` 可能已删除该 worktree 的管理目录，留下的文件夹不再是 checkout。Retry 的检查发现源仓库不再列出该路径时，把它报告为「Folder left by an earlier removal」（`residualFolder`），与组目录内的其他文件一样需要显式确认；确认后经 `WorkspaceOwnership` 检查删除该文件夹，并对源仓库执行 `git worktree prune`。
- 「Delete Workspace Files…」还会停止 `default` 组行与引用行的终端，这些运行中的终端同样列入检查并需要确认；源项目本身不被删除。
- 删除确认框中，若组内成员的分支都不是该组创建的（如迁移来的 `existing` 组），说明分支因此保留。

### 已有 Workspace 迁移

- 将旧 Workspace 的 checkout 与终端会话整体归入 `existing` 命名组（组目录即 Workspace 根），补充引用源项目主工作区的 `default` 组。
- 保留原目录、worktree 与 tabs / panes 及其 ID，不移动旧目录、不重建 worktree、不切换分支；会话（zmx）照常重新挂载。
- 旧成员可以处于不同分支，不根据分支推导组名，也不为满足新建组的统一分支规则而改动旧成员。
- catalog v3 迁移前复制到 `backups/`；manifest v2 写入新文件 `.codans/workspace-groups.json`，旧的 `workspace.json` 原样保留。迁移是确定性的，重复执行不产生重复组、不重置会话。

### 技术决策：主工作区引用与磁盘所有权

`default` 的成员关系不代表 Workspace 拥有源项目目录。引用行（`reference`）与新建 checkout（`member`）分开处理：成员归属标记与镜像守卫（`Catalog.workspaceMembership`、`WorkspaceMembershipIndex`）只计 `member`，移除引用只改源列表与链接，从不调用 checkout 删除流程。

`default` 的符号链接用于让组级终端访问多个主工作区。catalog 从不存储经过链接的路径：引用行存源主工作区的 canonical 路径，组行存组目录的 canonical 路径。删除的所有权判断是词法的（`WorkspaceOwnership`）：路径须位于 canonical 根内、是记录的组或成员路径、`lstat` 不是符号链接，且 canonical 形式不在任何源项目内；所有删除路径都经过这一处检查。

### 技术决策：迁移保留路径与会话身份

reconcile 按 canonical path 匹配已有 Worktree 并保留其 ID 与 tabs，迁移沿用这一身份。`existing` 组使用旧 Workspace 根作为会话目录；删除该组只删除其成员 checkout，保留根目录与 `.codans`，不递归删除仍被 Workspace、`default` 或其他组使用的父目录。

## 背景与范围

**Workspace** 把同一任务涉及的多个仓库（如 app、api 和 shared library）组织到同一个 Project：一个普通文件夹作为根目录，元数据落在 `<root>/.codans/workspace-groups.json`。

建模上，**workspace 是一个 Project**，本身没有行（`Project.rowWorktree == nil`）。每个可选中的侧栏行都是一个真正的 `Worktree`，以 `Worktree.workspaceSlot { groupID, role }` 标明角色：组目录行（`groupTerminal`）、`default` 的引用行（`reference`）、命名组的成员 checkout（`member`）。这样 tab / pane / 通知归属 / agent 状态 / `codans tree` 全部沿用四层层级。

### 共同架构约束（不可违反）

- **`Catalog.currentVersion` 为 4**。`Project.workspaceGroups`（组记录：id、name、kind、`isExpanded`、`deletion`）与 `Worktree.workspaceSlot` 走 `decodeIfPresent` + 默认值省略 key。版本号提升让 v3 构建无法读入并剥掉新字段。
- **workspace 根永不被探测 git 根**。`HierarchyClient.reconcile` 在 `discoverGitRoot` 之前按 `project.isWorkspace` 分支到 `reconcileWorkspace`。否则一个恰好位于某仓库内的根目录会被自动升格为该仓库，随后的 stale sweep 会把所有行软归档。
- **成员关系以 manifest 为准，活体事实以 git 为准**。manifest 只说「哪些源项目、哪些组、每组哪些成员、当初怎么建的」；分支与所属仓库每次 reconcile 从 git 读回，手改或过期的 manifest 只能标错名字，不能让 app 对错误仓库动手。
- **本地限定**。Server（SSH）Project 不能是 workspace，也不能作为源项目。
- `HierarchyManager` 不 spawn 进程；manifest、链接、所有权与迁移在 `CodansCore/Workspace/`，git 在 `GitWorktreeCLI` / `GitWorktreeClient`，编排在 `WorkspaceClient`。

## 目标与非目标

### 目标

- 把一个已有 manifest 的文件夹加进侧栏即成为 workspace，`tree --json` 报 `kind: workspace`，行带 `workspaceGroup {id, name, role}`。
- 从侧栏已注册的本地 Project、任意本地仓库路径或远程 URL 创建 workspace，GUI sheet 与 `codans workspace` 走同一条编排（`WorkspaceClient`）。
- 源项目可增删，只影响 `default`；命名组按项目设置一次检出全部项目。
- 删除命名组与 workspace 前逐成员检查风险，确认后才动磁盘；部分失败可重试。
- 子仓库 PR 状态按仓库取数，组行汇总显示。

### 非目标

- 单独删除命名组的某个成员；把已有分支加入命名组。
- workspace 整体归档（Project 级 archive 尚不存在）。
- 裸仓库作为源项目：探测到即以 `WorkspaceError.bareRepository` 拒绝，CLI 与 sheet 给出同一原因。

## 设计

### 数据模型

| 决策 | 内容 | 理由 |
|---|---|---|
| D1 | `Project.isWorkspace: Bool` 持久化，false 省略 key | kind 必须在 `@MainActor` 同步可知（Settings、侧栏、reconcile 短路），且不依赖磁盘可达 |
| D2 | `ProjectKind.workspace`；派生优先级 `remoteHost → server; isWorkspace → workspace; gitRoot == nil → dir; else gitRepo` | kind 派生、不进 catalog；workspace 压过 gitRoot |
| D3 | `CatalogStore.load()` 经 `WorkspaceMarkerRepair` 修复：本地、未标记、根下存在 manifest（v1 或 v2）→ 置标记并清 `gitRoot` | 防跨构建剥字段；manifest 是旧构建碰不到的持久信号 |
| D4 | 标记粘性：manifest 丢失、不可读或版本更新 → `ProjectReconciler` 置 `loadState = .failed(...)`，不 reconcile、不写入、不回退到 v1 | 降级会重新打开 discoverGitRoot + sweep 通道；`FailedProjectRow` 提供 Retry / Remove |
| D5 | `Project.workspaceGroups` 是 manifest 的缓存（启动时同步渲染）加 UI 状态（`isExpanded`、`deletion`），reconcile 按组 ID 写入并保留 UI 状态 | 首次 reconcile 前也能画出组；展开与删除状态跨启动保留 |
| D6 | `Worktree.workspaceSlot` 标角色；`Worktree.sourceGitRoot` 持久化，来源是 git，经 `Project.repoRoot(for:)` 读取 | 分支保护与 GitHub 取数在恢复选择时同步读 catalog，早于 reconcile |
| D7 | 行路径：组行 = 组目录，引用行 = 源主工作区，成员行 = `<root>/<group>/<name>`，全为 canonical；同一 workspace 内每行路径唯一 | reconcile 按路径匹配并保留 ID；链接路径不会制造独立行 |
| D8 | reconcile 永不删行：成员目录消失 → 软归档；源目录消失 → 引用行保留并标 unavailable（`Project.unavailableWorkspaceRows`，transient）；manifest 不再点名的行原样保留并记日志 | 源目录不归 Workspace 管，不能归档 |
| D9 | manifest v2 在 `<root>/.codans/workspace-groups.json`（`WorkspaceLayout`）；v1 `workspace.json` 只读不写；默认根目录 `~/.codans/workspaces/<slug>` | v1 写入器会丢弃未知字段，分文件保存避免互相覆盖 |
| D10 | 创建校验：根目录不得位于任何 git 仓库内 | 旧构建仍会对 workspace 根跑 `discoverGitRoot` |
| D11 | 环境变量：workspace 行的 pane 注入 `CODANS_WORKSPACE_ROOT`、`CODANS_WORKSPACE_GROUP`、`CODANS_WORKSPACE_GROUP_DIR`；其他 Project 主动移除 | 组终端与成员终端都能定位组目录 |
| D12 | 源项目探测统一走 `GitWorktreeCLI.inspectRepository(at:)`；子目录与 linked worktree 归一到仓库根；裸仓库拒绝 | 与 `--repo` 一致 |
| D13 | 远程源先 clone 到用户选定目录（默认 `~/.codans/sources/<repoName>`），已是同一远程的 clone 则复用；`git clone --progress` 可取消 | 远程只是「先 clone」的本地源 |
| D14 | `createdBranch` 记录组是否新建了该分支；删除只提供删除这类分支，且排除被其他 worktree 检出的分支与默认分支 | 不删除用户原有分支 |
| D15 | 删除检查（`GroupDeletionCheck`）无副作用：`git status --porcelain=v1 -z --untracked-files=all` 计数；有 upstream 用 `@{upstream}..HEAD`，否则 `HEAD --not --exclude=<branch> --branches --remotes`；忙碌终端（`workspaceGroupBusyPanes`）；组目录内非成员条目；源仓库不再列出的成员文件夹（`residualFolder`） | 风险需显式确认；无法检查即阻止 |

### manifest v2

```json
{
  "schemaVersion": 2,
  "title": "Checkout Flow",
  "projects": [
    { "name": "app", "sourceGitRoot": "/Users/me/dev/app" },
    { "name": "lib", "sourceGitRoot": "/Users/me/.codans/sources/lib", "remoteURL": "git@github.com:org/lib.git" }
  ],
  "groups": [
    { "id": "…", "name": "default", "kind": "default", "path": "default" },
    { "id": "…", "name": "fix-login", "kind": "named", "path": "fix-login", "branch": "fix/login",
      "members": [
        { "id": "…", "name": "app", "path": "fix-login/app", "sourceGitRoot": "/Users/me/dev/app",
          "checkoutMode": "newBranch", "branch": "fix/login", "baseRef": "origin/main", "createdBranch": true }
      ] }
  ]
}
```

- `projects` 定义 `default` 的成员与后续新建组的成员；`default` 没有 `members`。名字 `default` 保留给唯一的默认组。
- `path` 相对根目录、词法规范化、不得越出根目录；`.` 只用于迁移来的 `existing` 组。组与成员路径唯一，成员路径不落在其他组目录内。
- 组的 `branch` 是创建时的记录，不是身份；成员各自读取实时分支。
- 结构解码严格，只对可选字段宽容；`validate()` 以类型化错误拒绝上述规则。完整规则见执行计划「Persisted schema」。

### Reconcile

```
ProjectReconciler.reconcile
  └─ 本地 Project：stat rootPath；isWorkspace → WorkspaceManifestStore.loadOrMigrate（v2 优先，否则由 v1 迁移并写 v2），失败即 .failed
       └─ HierarchyClient.reconcile
            ├─ isRemote    → reconcileRemote
            ├─ isWorkspace → reconcileWorkspace        ← 在 discoverGitRoot 之前
            └─ 其余        → discoverGitRoot / lsWorktrees / reconcileDiscoveredWorktrees
```

`reconcileWorkspace`：读 manifest → `WorkspaceDefaultLinks.sync`（只建、改、删符号链接，从不碰非链接条目）→ 每个组目录、引用与成员解析 canonical 路径、stat、`currentBranch`、`repositoryRoot(forCheckoutAt:)` → `HierarchyManager.reconcileWorkspaceGroups`：写 `workspaceGroups`（按组 ID 保留 `isExpanded` 与 `deletion`）；按 canonical 路径匹配行，设置 `workspaceSlot`，原地刷新 `branch` / `sourceGitRoot`，不改名；为已存在的目录追加缺失行；按 D8 处理消失的目录。

### UI 门控

| 位置 | 规则 |
|---|---|
| 侧栏 Workspace 行 | 不可选中，点击开合；图标默认 `square.stack.3d.up`；`+` = New Group…；`⋯` = Workspace Settings… / Add Project… / Remove Workspace…；这些入口也是行的辅助功能动作 |
| 组行 | 选中即选中组目录行；悬停 chevron 开合（辅助功能动作 Expand / Collapse Group）；上下文菜单：命名组 Delete Group…（有 `deletion` 时为 Retry Deletion…），`default` 没有删除入口 |
| 引用行 / 成员行 | 分支在上、文件夹名在下；没有 Archive / Remove / Delete；引用行有 Remove from Workspace…。`HierarchySidebarFeature` 的 `worktreeArchiveTapped` / `worktreeRemoveTapped` 拒绝所有 workspace 行 |
| 源 Project 镜像行 | 命名组的成员在源 Project 中显示为镜像行并带「in workspace X」标记，上下文菜单隐藏 Archive / Remove；引用行与源主工作区同路径，不加标记 |
| Header | 组行：组名 + 「Group · <Workspace>」，不打开分支 popover；成员行与普通 worktree 相同 |
| 分支切换器 | `blockedBranches` 按 `repoRoot(for:)` 分组，只统计同仓库的兄弟行 |
| 侧栏筛选 | 分类与 PR 筛选作用于成员行；有匹配成员的组行保持可见，并在筛选视图中展开 |
| Settings | Workspace 的 Projects 一节列出源项目（名称、实时分支、路径），Add Project 菜单、Add Folder…、每行 Remove…（确认框附在表单上，列出该引用行的运行中终端） |
| IPC / CLI | `hierarchy.createWorktree` / `removeWorktree` 对 workspace 行返回 `invalidParams` / `conflict`；`codans tree` 按组嵌套，`--json` 带 `kind` 与 `workspaceGroup` |

### 组件边界

```
CodansCore/
  Persistence/CatalogMigrationV3ToV4   纯函数：旧 workspace 行 → existing 组 + default 组记录
  Workspace/
    WorkspaceLayout              路径常量、默认目录、title → 文件夹名
    WorkspaceManifest            v1 schema（只读，迁移输入）
    WorkspaceGroupsManifest      v2 schema、validate
    WorkspaceManifestMigration   v1 → v2（确定性 ID）
    WorkspaceManifestStore       hasManifest / loadOrMigrate / save（AtomicFileStore）
    WorkspaceGroup               组记录、WorkspaceSlot、侧栏投影所需类型
    WorkspaceDefaultLinks        default 目录的符号链接同步
    WorkspaceOwnership           删除前的词法所有权检查
    WorkspaceMembership          member 角色的归属索引
    WorkspaceGroupPlan / WorkspacePreflight / WorkspaceCreationEvent / WorkspaceMaterializationLedger
    GroupDeletion / WorkspaceRemoval   删除检查、请求与结果
    WorkspaceMarkerRepair        catalog 加载修复
  Catalog+Sidebar                workspaceSidebarRows、workspaceGroupMembers / Summary、workspaceGroup(standingFor:)
Runtime/
  CatalogStore.load              v3 迁移（备份副本、立即写 v4）、更新版本只读
  HierarchyManager               reconcileWorkspaceGroups、组展开 / 删除状态、removeWorkspaceRows
  ProjectReconciler              manifest 健康检查
App/Clients/
  HierarchyClient                reconcileWorkspace、addWorkspaceProject、workspaceGroupBusyPanes
  WorkspaceClient(+Sources / +Groups / +Deletion)   创建、源增删、建组、删除检查、删组、移除 Workspace
App/Features/
  CreateWorkspace/               addWorkspace / addSource / newGroup 三种模式的 sheet
  HierarchySidebar/              组行、WorkspaceGroupDeletionFeature / Dialog、WorkspaceRemovalDialogs
  Settings/                      Workspace 的 Projects 一节
```

依赖方向：app → Runtime → CodansCore；`CodansCore` 不 import AppKit，不 spawn 进程。

### 创建与源项目

```
CreateWorkspaceFeature (sheet)  ─┐
                                 ├─▶ WorkspaceClient ─▶ manifest v2 ─▶ links ─▶ catalog ─▶ reconcile
WorkspaceHandlers (workspace.*) ─┘
```

- `createWorkspace`：校验根目录（D10/D12），把源解析为主工作区（已注册 Project、本地路径、远程 clone），写只有 `default` 的 manifest，同步链接，注册并 reconcile。不建分支、不切分支；回滚只删本次创建的根目录与 clone。
- `addSource` / `removeSource`：只改 `projects`、同步链接、增删引用行；命名组不变，源目录不动。
- GUI：Add 菜单「New Workspace…」打开 `CreateWorkspaceFeature`（`.addWorkspace`）：Title、Location、Projects（Add Project 菜单 / Add Folder… / Add Remote…）。Workspace 行的 Add Project… 打开 `.addSource`。样式与 Settings 一致：`Form` + `.formStyle(.grouped)`，按钮栏在表单下方。新加入的引用行被选中并展开 `default`。

### 新建组

- `createGroupStream(plan, token)`：先再跑一次 preflight，任一阻塞问题在 I/O 前失败；逐项目可选 fetch，再以 `createWorktreeStream(pathOverride: <root>/<group>/<name>)` 检出，记账（`createdDirectory`、仅在分支原本不存在时记 `createdBranch`、`addedWorktree`）。
- 任一检出失败或取消：在 `Task.detached` 中逆序回滚，`rolledBack(failures)` 报告残留路径与原因，manifest 与 catalog 不写入。worktree 移除失败时保留包含它的组目录，并报告该目录与原因。preflight 要求计划包含当前所有源项目（`missingSource`）。
- 全部检出完成：写 manifest、reconcile、发出 `registered`；然后逐成员跑 setup script（失败记为 `setupFailed`，组保留）；流以 `GroupCreationResult` 结束，`RootFeature` 随后为每个成员启动所选 Agent 并选中、展开该组。
- GUI：Workspace 行 `+` 打开 `.newGroup` sheet：Name、Branch（留空用组名），每个项目一节（Based on、Fetch、Copy ignored、Copy untracked、Launch agent），默认值来自 `groupCreationDefaults`。

### 删除与移除

- **删除命名组**（组行「Delete Group…」/ `codans workspace group delete`）：`checkGroupDeletion` 给出风险（D15）；`deleteGroup` 重新检查，`checkFailed` 或未确认的风险直接抛出。执行：在 catalog 与 manifest 记下 `deletion`，拆除组内所有行的 surface，逐成员 `removeWorktree(repoRoot: sourceGitRoot, path)`（relocate-then-prune；`residualFolder` 成员经 `WorkspaceOwnership` 删除文件夹后 `git worktree prune`）、按选项删分支、从 manifest 删成员、删行与镜像行；单个成员失败则保留它与原因并继续。全部成员移除后，组目录经 `WorkspaceOwnership` 允许且不是 `.` 时删除，再删组记录与组行；否则组保留 `deletion` 状态。
- **移除 Workspace**（Workspace 行「Remove Workspace…」/ `codans workspace remove`）：`sidebarOnly` 只删 catalog 条目；`deleteOwnedFiles` 用 `checkWorkspaceDeletion` 对所有命名组与 `default` 组行、引用行的运行中终端做一次合并检查（同样需要确认），逐组删除，删除 `default` 链接与目录，全部成功且所有权允许时再删根目录并删 catalog 条目；部分失败保留 Workspace 与失败组的 `deletion` 状态。两者都不删除源主工作区。
- 引用的移除见「创建与源项目」，从不删除磁盘内容。

### GitHub：按成员仓库取数

`GitHubFeature` 的状态以 `ProjectID` 为键。`RootFeature.gitHubFetchUnits(in:)` 把 workspace 按 `Project.repoRoot(for:)` 拆成取数单元，每个成员仓库一个，键为 `workspaceFetchGroupID(workspace:gitRoot:)`（对 `"<workspaceID>|<canonical gitRoot>"` 取 SHA-256 前 16 字节做成 `ProjectID`，跨启动稳定）；组目录行没有仓库，不参与取数。

- 激活 Project 时对每个单元各发一次 `projectActivated`；`pruneToCatalog` 与 `seedFromCache` 按同一组键处理。
- 心跳 poll 只有一个槽位：workspace 里跟随选中行所属仓库，其余仓库靠激活 / 焦点 / pane 内 git 命令后的刷新。
- PR 汇总在组行：只统计该组的引用或成员行，显示「N PRs · M merged」。

## 备选方案

- **子仓库作为元数据行而非 Worktree**：状态刷新要单开通道、diff / 通知 / agent 状态各需一层抽象。放弃。
- **manifest 为唯一真相、不持久化组记录**：首次 reconcile 前无法画出组，根目录不可达时会丢失展开与删除状态。放弃。
- **在 v1 manifest 里追加组字段**：v1 写入器会丢弃未知字段，旧构建一次保存就会抹掉组。改用独立的 v2 文件。
- **命名组成员复用已有分支或已有 worktree**：与「一组一个分支、组拥有其 checkout」冲突，删除时无法判断归属。放弃。

## 横切关注点

- **已知限制**：旧构建对 workspace 根仍会跑 `discoverGitRoot`，D10 要求根不在仓库内。v3 构建会把 v4 catalog 移到 `backups/` 并以空 catalog 启动；迁移时的 v3 备份可用于降级。远程源的 clone 只在创建回滚时删除。
- **日志**：`com.gumpw.codans.hierarchy/reconcile` 记录追加 / 归档 / 「manifest 不再点名的行」/ 默认链接目录中的非链接条目。
- **测试**：CodansCoreTests（`CatalogMigrationV3ToV4Tests`、manifest v2 编解码与 v1 → v2 迁移、`WorkspaceOwnership`、`WorkspaceDefaultLinks`、`CatalogSidebarTests`）；`PersistenceVersioningTests`、`CatalogStoreWorkspaceRepairTests`；`HierarchyManagerWorkspaceTests`、`HierarchyClientWorkspaceReconcileTests`（真实 git：迁移后身份、分支切换、源缺失）；`WorkspaceClientTests`、`WorkspaceSourcesTests`、`WorkspaceGroupCreationTests`、`WorkspaceGroupDeletionTests`（真实 git + 真实 `CatalogStore` + `FakeHierarchyRuntime`）；TestStore：`CreateWorkspaceFeatureTests`、`HierarchySidebarFeatureTests`、`WorkspaceGroupDeletionFeatureTests`、`ProjectSettingsWorkspaceSourcesTests`；`WorkspaceHandlersTests`、`HierarchyHandlersWorkspaceTests`、`WorkspaceCommandsTests`。原生验收记录见执行计划「Status」。
