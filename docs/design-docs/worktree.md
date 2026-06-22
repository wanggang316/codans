# 设计文档：Worktree

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

> 生命周期 / 侧边栏排序 / 状态栏 / 分支切换器均已上线。唯一例外是 §分支切换器与历史 末尾的 **Diff Viewer History tab**，状态为 `已设计未实现`（代码无 `DiffFeature`，详见该节）。

## 背景与范围

一个 **Worktree** 是某 Project 的一个 `git worktree`——磁盘上一个具体的分支 checkout，自带目录与 Tab/Pane 布局。codans 的核心工作流就是多个 feature 并行、一个 feature 一个 Worktree、各有自己的终端与 agent。能力与验收标准见 [worktree-management 产品规格](../product-specs/worktree-management.md)。

本设计覆盖 Worktree 的四个相邻子系统，它们共享同一套不变量（catalog ↔ on-disk 一致、UUID 标识、带 version 的原子 rename 持久化）：

1. **生命周期**——创建（流式 file-copy）、发现 CLI 创建的 worktree、archive/unarchive 软隐藏、安全/强制删除、prune、删除前终端安全检查。
2. **侧边栏排序**——每个 Project 下 worktree 行的四段排序模型。
3. **状态栏**——titlebar 中段按优先级切换形态的状态槽。
4. **分支切换器与历史**——header 分支区是可点击 popover（应用内 `git switch`）。本子系统还记录 Diff Viewer History tab 的设计意图，但该部分 `已设计未实现`（见对应小节）。

四块在代码里落在不同 feature 目录，但都围绕 `Worktree`/`Project` 模型与 `HierarchyManager`/`HierarchyClient` 这条单一写入面展开，故合并为一份设计。

### 共同架构约束（不可违反）

- **Catalog ↔ on-disk 一致**：`catalog.json` 的每条 Worktree 行必须对应一个真实存在的 git worktree 目录。发现/reconcile 只追加不删；唯一的删除路径是用户主动 Prune / Remove。
- **`HierarchyManager` 是 `@MainActor @Observable` 运行时态**，不持有 TCA / 表现层瞬时状态，也不 spawn 进程；git 工作一律经 `GitWorktreeClient` / `GitService`（nonisolated async），成功后才回到 manager 改 catalog。
- **标识符一律 UUID**；`WorktreeID` 在 `HierarchyManager.createWorktree` 写入 catalog 那一刻才生成（不预分配）。
- **持久化是带 version 的原子 rename JSON**；给 `Worktree` 加字段走 `decodeIfPresent` + 条件编码模式，已有 `archived` / `archivedAt` / `isPinned` 先例，且不升 schema 版本。
- **单窗口语义**：所有 Worktree 操作在单 `WindowGroup` 内，无 `SpaceID` 参数、无跨窗口同步（无 `Space` 容器层；分组语义由 Project 标签承担，见 project-tags 设计）。

## 目标与非目标

### 目标

- 通过 sheet 创建 Worktree：实时分支名校验、base-ref 下拉（默认 Project 默认远程分支）、可选 fetch-origin、可选 copy-ignored / copy-untracked 带流式进度。
- 保持 catalog 与磁盘 worktree 持续 reconcile：CLI 创建的自动出现；外部删除的标记 stale 并提供 prune。
- archive 作为软隐藏（仅元数据）：关闭其 tabs/panes，但不动文件与 git ref；unarchive 就地恢复。
- 安全删除给出可操作错误（点名未提交文件，提供强制升级）；强制删除有独立确认；删除目录前先终止挂着的终端进程。
- 把侧边栏 worktree 排序正式定义为四段，每段在五个维度上行为清晰；引入用户可控的段内拖拽重排（持久化）与 pending 段（让创建流式过程可见、不阻塞）。
- titlebar 中段稳定承载"当前 Worktree 现在怎么样"的单行叙事；五种形态共用一套优先级与切换动画。
- header 分支区成为一等操作入口：可点、可切、有 loading、有上下文（最近提交）；切换后的刷新完全复用 `WorktreeHeadWatcher` 的 HEAD-change 回路，不引入手工 reload 链。

### 非目标

- 应用内 commit / rebase / merge / pull / push / cherry-pick / revert / stash / discard 等写操作 UI（terminal-first）。脏工作区切换失败时原样冒泡 git stderr，不裁剪、不翻译、不自动 stash。
- 无分支的 detached-commit worktree；创建后就地改 worktree 路径；多 worktree 批量操作；跨 Project 移动 worktree。
- 改 `Project.worktreesDirectory` 默认值（由 Project-options 编辑，本设计只消费）。
- service 层"分支能否安全切换"的预检（不复制 git 的自有判断，见 Alternatives）。
- 给 `Worktree` 加 `sortIndex` 字段（段内顺序由 catalog 数组下标承担，见 §侧边栏排序）。
- toast / motivational / pending 的持久化（纯内存，重启丢弃）。
- 命令面板 keybinding 配置系统（快捷键仍硬编码 ⌘P，经共享常量消除漂移）。
- 为非 git 的 Plain Project 适配分支 popover / PR 槽（`Project.supportsWorktrees == (gitRoot != nil)` 单一谓词裁剪所有非 git affordance；affordance 隐藏而非禁用）。

---

## 生命周期

### 概览

核心客户端是 **`GitWorktreeClient`**——一个 `Sendable` 的 async 闭包结构（与 `HierarchyClient` / `GitServiceClient` 同形），包裹打包进 app 的 `git-wt` 脚本及若干互补的 `git` 调用。它是 worktree 操作**唯一**的 git spawn 面；所有 IO 跑在 main actor 之外，调用方 await。

侧边栏新增两个 feature（TCA reducer + sheet）：`CreateWorktreeFeature`（创建表单 + 同步预检）与 `ArchivedWorktreesFeature`（从 Project `⋯` 菜单打开，Project 作用域）。两者都由 `HierarchySidebarFeature` 呈现，使侧边栏保持 sidebar 作用域 sheet 状态的单一所有者。

`HierarchyManager` 是纯状态层，新增 `setWorktreeArchived` / `reconcileDiscoveredWorktrees` / `reorderWorktrees` 等突变；git 工作（shell-out、流式、prune）由 `GitWorktreeClient` 在 feature 的 `Effect` 里完成，**成功后**才回 manager 改 catalog。

**中心 trade-off：新增 `GitWorktreeClient` 而非扩展既有 `GitWorktreeCLI` actor。** 旧 actor 直连 `/usr/bin/git`、同步把整段 stdout 缓冲成 `String`，没有 streaming 原语；而本设计要求 `git-wt`（JSON listing、base-dir 语义、流式 copy）——是不同的可执行文件、不同的 flag 约定。两者混在一个类型里会模糊"用的是哪个工具"的契约，并把 spec-critical 的流式创建路径硬塞进一个不适配的 actor。旧 actor 保留为发现的 fallback（dev build 未 checkout submodule 时；`verify-git-wt.sh` 会在构建期而非运行期暴露这点）。

### 接口契约

`GitWorktreeClient`（闭包而非 protocol——与 app 其余 cross-feature seam 一致；路径参数用 `URL` 强制调用点决定是否 file URL）：

- **listing/discovery**：`lsWorktrees(repoRoot) -> [GitWtEntry]`。
- **分支/ref 查询**：`localBranchNames`、`branchRefs`、`defaultRemoteBranchRef`、`isValidBranchName`。
- **创建（流式）**：`createWorktreeStream(CreateWorktreeSpec) -> AsyncThrowingStream<CreateWorktreeEvent, Error>`。仅创建有值得渲染的进度（copy-ignored 大仓可跑 >30s），其余操作有界且短，用一次性 async throws。
- **删除/prune**：`removeWorktree(repoRoot, path)`、`pruneWorktrees(repoRoot) -> Int`。**注意：删除无 `force` 参数**——安全/强制的区分不是 `git-wt` flag，而由调用层先跑 `changedFiles` 预检、再决定是否走删除（详见下文删除流程）。
- **fetch**：`fetchRemote(repoRoot, remote)`。
- **诊断**：`changedFiles(worktreeRoot) -> [String]`，喂给安全删除的错误展示。

事件 `CreateWorktreeEvent` 区分 `.progressLine(String)`（逐行原样渲染）与 `.finished(worktreePath: URL)`——纯行流会把"进度行"与"最终路径"混为一谈，typed event 让消费者明确知道何时完成、拿到结果路径。

错误 `GitWorktreeError`：UI 可见的用 typed case（`branchExists` / `invalidBranchName` / `refNotFound` / `fetchFailed` / `uncommittedChanges(files:)` / `worktreeLocked`），其余兜底 `commandFailed(command:stderr:)` 原样回传 git 命令 + stderr，使 banner 能呈现真实信息而无须穷举每种失败模式。`executableMissing` 对应 `wt` 未打包。

#### `HierarchyClient` 新增闭包

git 工作不藏在 `HierarchyClient` 背后——后者的契约是"同步、main-actor、catalog 突变、确定性错误类"。features 自己编排：先 async 跑 `GitWorktreeClient` 做 git 活，成功后调 `HierarchyClient` 改 catalog。因此 `createWorktreeWithGit(projectID, name, branch, path)` 只是 catalog-append 那一步（同步，不懂 base-ref/copy-flag）。其余新增：

- `setWorktreeArchived(worktreeID, archived)` / `reconcileDiscoveredWorktrees(projectID)`（背景同步，吞 `GitWorktreeError` + 记日志，绝不崩 app）。
- `removeWorktreeWithGit(worktreeID, projectID)`：跑 git 删除 + catalog 删行（无 `force` 参数）。
- **生命周期感知变体** `setWorktreeArchivedWithLifecycle` / `removeWorktreeWithLifecycle`：在元数据突变前后跑用户配置的生命周期脚本（见 §生命周期脚本）。
- `reorderWorktrees(projectID, segment, from, to)`：段内拖拽（见 §侧边栏排序）。
- `promoteWorktree(projectID, worktreeID, .moveToFrontWithinUnpinned)`：被通知子系统调用的离散提升（见 §侧边栏排序 与 notifications 设计）。
- `runningPanelCount(worktreeID) -> Int`：给删除确认文案（用计数而非布尔，文案才能说"3 running processes"而非含糊的复数）。

### 数据存储

`Worktree` 的存活字段：`archived: Bool`、`archivedAt: Date?`、`isPinned: Bool`。**无 `sortIndex`、无 `createdAt`**（段内顺序完全由 catalog 数组下标承担）。

Codable 模式（与 `isPinned` 同形）：`decodeIfPresent ?? false` 保读兼容；`archived == false` 时省略编码，使未归档 worktree 的 on-disk catalog round-trip 完全不变。**不单设 `archivedWorktrees` 数组**——并行数组会复制整个 `Worktree`、fork 唯一性/选中不变量、多出一处跨集合同步；in-place flag 配合 `project.worktrees.filter { !$0.archived }` 一行解决。不升 schema 版本（`CatalogStore` 的保存管线容忍字段新增）。

### 发现 / reconcile 契约

调度（*何时* reconcile）由 Project 管理侧持有（Project 添加时、窗口聚焦 reconcile 时）；本设计持有被调方 `reconcileDiscoveredWorktrees(projectID)`：

1. 读 Project `gitRoot`，nil 则跳过（非 git Project）。
2. `lsWorktrees(gitRoot)`。
3. 每个磁盘上、catalog 里没有的条目（按 `URL.standardizedFileURL.path` 规范化路径匹配）追加一行新 `Worktree`（`archived = false`，detached HEAD 用目录末段当 name）。
4. catalog 里路径已不在磁盘 **且** 不在 `git worktree list` 输出里的，标记 stale——**stale 是视图层按 live git state 每次渲染派生的计算标志，不是存储字段**。
5. **发现绝不删 catalog 行**；prune（用户发起）是唯一删除路径——守住"绝不静默地让 catalog 与磁盘脱节"。

幂等：重复调用结果相同。与并行 `createWorktreeWithGit` 的竞争由 main actor 串行化（append 与 reconcile 不交错）；规范化路径匹配正确去重刚创建的行。

### 删除流程与终端安全

安全 vs 强制不是 `git-wt` flag，而是调用层的两步：

1. **安全删除**：先 `changedFiles(worktreeRoot)`。非空 → 抛/呈现 `uncommittedChanges(files:)`，渲染"3 files have uncommitted changes in `<path>`: a.swift, b.swift, …"，给主按钮"Force Remove" + 次按钮"Cancel"。
2. **强制删除**：独立确认，显式声明"未提交改动将被丢弃""不可撤销"，然后跳过预检直接删。

**终端安全**：确认意图后，检查 `runningPanelCount(worktreeID)`。> 0 则二次确认"This will terminate N running processes in `<worktree>`"；确认后逐个 `runtime.closeSurface(for:)` 硬杀 ghostty surface，**然后**才删目录。catalog 更新永远是最后一步（与 `closeTab` 的既有拆除顺序一致）。首个 close 抛错则中止删除并 banner。

**main checkout 不可删/不可归档**：视图按 `worktree.path == project.rootPath` 判定（非 gitRoot Project 的唯一 worktree 即 main checkout，同规则），裁掉菜单项；`HierarchyManager` 在 archive/remove 路径再设一道 guard 抛 `invariantViolation`，防 UI 被绕过。

### 分支名净化

`sanitizeBranchName`（纯函数）：`/` → `-`，剥除 macOS 文件系统拒绝的字符（`\0` / `:`）。创建前算出目录名并 `FileManager.fileExists` 测 `<worktreesDirectory>/<sanitized>`；存在则报点名碰撞的清晰错误，**不自动加后缀**（静默 suffixing 令人困惑）。

### 生命周期脚本

Project 设置可配 `createScript` / `archiveScript` / `deleteScript`（`ScriptDefinition?`），由 `*WithLifecycle` 闭包驱动。它们与 `worktree.*` C3 hooks（异步 fire-and-forget）**不同**：生命周期脚本**内联运行**——

- create-script 在新建 tab 内运行并 await 退出；**非零退出阻塞创建**。失败时的顺序：catalog 行先 append（脚本能读到自己的路径）→ 失败 → 经 `removeWorktreeWithGit` 回滚 catalog 行，**但留下磁盘目录**（由 Prune 兜底）。
- archive/delete-script 同样开 tab 运行并 await，再进行元数据突变 / 删除。

绕过生命周期的纯路径（`removeWorktreeWithGit` 直连）跳过这些 hook。

### `git-wt` 打包

`git-wt` 作为 submodule 钉在 `apps/mac/ThirdParty/git-wt/`，`.gitmodules` 在**仓库根**。打包只 `cp` **`wt` 脚本本身**进 `Resources/git-wt/wt`（post-build `embed-git-wt.sh`，`chmod +x`，`inputPaths`/`outputPaths` 让 Xcode 做增量），**不**作为 Tuist `resources:` 条目——那会把整个 submodule（README、tests）拷进 bundle。pre-build `verify-git-wt.sh` 断言脚本存在且可执行，否则用清晰的 `git submodule update --init` 提示 fail 构建。

提交钉到上游 `khoi/git-wt` 的 main（**不是** supacode 的 SHA——其 force-rewritten 历史不可达）；运行期 `Bundle.main.url(forResource:"wt", subdirectory:"git-wt")`，nil 则 `GitWorktreeClient` 抛 `.executableMissing`（CI 永不到这条路径，pre-script 先 fail）。

---

## 侧边栏排序

### 概览

排序按**段优先**：先决定一条 worktree 属于哪段，再决定它在段内的位置。四段固定渲染顺序：

```
main → pinned → pending → unpinned
```

四段在五个维度上的对照：

| 维度 \ 段 | main | pinned | pending | unpinned |
|---|---|---|---|---|
| 段语义 | `path == project.rootPath` 且非 archived | `isPinned` 且非 main 且非 archived | 内存中的"创建中"占位 | 其余非 archived |
| 数据来源 | `Project.worktrees`（catalog） | `Project.worktrees`（catalog） | `HierarchySidebarFeature.State.pendingWorktrees` | `Project.worktrees`（catalog） |
| 段内顺序 | 至多一条，无段内顺序 | catalog 数组顺序 | 插入顺序（即 `startedAt` 升序） | catalog 数组顺序 |
| 用户操作 | 不可拖出段；无 Pin/Unpin（无意义） | Pin/Unpin、拖拽重排 | Cancel / Retry / Discard | Pin → 进 pinned、拖拽重排 |
| 持久化 | catalog.json | catalog.json | 不持久化（仅当前 session） | catalog.json |

**中心 trade-off：段内顺序统一靠 `Project.worktrees` 数组下标，而非给 `Worktree` 加 `sortIndex`。** sidebar 的"段内位置"与 catalog 数组的"行下标"是同一个值。于是：不扩 schema、不引第二套 ordering 表；拖拽重排 = 改 catalog 数组顺序（与 `reorderProjects` 完全对称）；"自然顺序"与"用户排过的顺序"是同一种东西，没有"sidebar 与 catalog 不一致"需要补偿。代价：catalog 数组顺序不再纯是"创建历史"，而带上"用户排序"语义——这与 `reorderProjects` 已做过的取舍一致，不增加新概念负担。

### 各段语义

**main 段**：只装 `worktree.path == project.rootPath` 一条——git 仓库根 checkout，每 Project 唯一。它由 reconcile 在 add Project 时写入（自然存在，非用户创建），用户预期它永远置顶（如 Finder 的"Macintosh HD"）。故独立于 pinned 之外，`isPinned` 对它无意义（UI 裁掉 Pin/Unpin）。main worktree 被 archive 后该 Project 无 main 段，是合法状态。

**pinned 段**：`isPinned && path != rootPath && !archived`，段内取 catalog 数组相对位置。
- **Pin**（unpinned 行右键）→ 移到 pinned 段**末尾**：主动 pin 表达"长期可见"而非"最上面"，放末尾让现有 pinned 顺序稳定（least surprise）。
- **Unpin**（pinned 行右键）→ 移到 unpinned 段**顶部**：unpin 通常意味"不再高优先级但还在用"，放顶部符合"仍新鲜"的预期。
- **拖拽**：`ForEach.onMove` 段内有效。

**pending 段**：用户在 Create sheet 点 Create 之后、`wt sw` 流式完成之前的占位。数据来自 `HierarchySidebarFeature.State.pendingWorktrees: IdentifiedArrayOf<PendingWorktree>`，按 project 过滤渲染。`PendingWorktree` 持 `PendingWorktreeID`（独立于 `WorktreeID`，避免命名混淆）、冻结的 `CreateWorktreeSpec`、`status: .running / .failed(GitWorktreeError)`、`startedAt`。段内按插入顺序（`startedAt` 升序），无拖拽（临时占位，重排无意义）。
- **Cancel**（仅 `.running`）：取消流式 effect、给 `wt` 发 SIGTERM、从内存移除。**不**主动 `wt remove --force` 清残留目录，交给 Prune。
- **Retry**（仅 `.failed`）：复用同一 `PendingWorktreeID` 重启 effect（`cancelInFlight: true` 保幂等），状态翻回 `.running`。
- **Discard**（仅 `.failed`）：从内存移除。
- 不可：选中（无 `WorktreeID`/Pane）、⌃⌘N 跳转（hotkey 枚举跳过）、Pin / Reveal / Open-in / Archive / Remove（这些都假设有真实 on-disk 路径与 catalog 行）。

**unpinned 段**：剩下的非 archived 非 main 非 pinned，段内取 catalog 数组相对位置。新建 worktree 默认 `isPinned = false` 落此段，**落 catalog 中 unpinned 段顶部**（`createWorktree` 插在"最后一条 main/pinned 之后"的 boundary，而非无脑 `append`）——刚创建的对象是当下最关心的，放顶部省一次滚动，且不打扰已 pin 的顺序。

### 不变量

- **段内顺序 == `Project.worktrees` 数组中该段元素的相对顺序。** 没有第二事实来源。
- **拖拽重排即改 catalog 数组顺序**，经 `reorderWorktrees(projectID, segment, from, to)`（`segment ∈ {.pinned, .unpinned}`；main 无重排，pending 无 onMove）。manager 把 `IndexSet`+`to` 解析成 `WorktreeID` 列表再写回；**若任一 ID 已不存在则整次重排丢弃、不部分应用**（防拖拽期间 reconcile/外部删除使索引失效）。
- **pending 仅存在于 reducer 内存**，不写 catalog.json、不写 settings.json，不是 catalog 行。
- **行 ID 显式带 case 前缀**（`"wt:<uuid>"` / `"pending:<uuid>"`）——`WorktreeID` 与 `PendingWorktreeID` 都基于 UUID，避免 SwiftUI `ForEach` identity 碰撞。
- **通知驱动的提升**经 `promoteWorktree(.moveToFrontWithinUnpinned)`：某 worktree 未读 `0 → N` 边沿时移到 unpinned 段最前。它是与拖拽 `reorderWorktrees` 不同的离散操作，但写的是同一个 catalog 数组顺序。固定的 worktree 永不被自动提升（pin 是比"收到通知"更强的显式信号）；未读回 0 不自动降回。详见 notifications 设计。
- **崩溃恢复**：pending 不持久化；若崩溃前 `wt sw` 已落盘但 catalog 未写，由 `reconcileDiscoveredWorktrees` 下次发现补登记（与"用户在 app 外 `git worktree add`"完全相同的恢复路径，不引入新状态机）。

### 渲染合并

`orderedSidebarRows(project:pendings:) -> [SidebarRow]` 返回异构行（`enum SidebarRow { case worktree(Worktree); case pending(PendingWorktree) }`），按 `main + pinned + pending + unpinned` 拼接；纯 worktree 视图用 `orderedVisibleWorktrees` 取其 `.worktree` 子集。

### pending 段连带的工程影响

pending 是四段中唯一引入新数据源的段，连带几项改动（为让 pending 存在的副产品）：`CreateWorktreeFeature` 责任收窄为表单 + 同步预检，提交时把 `CreateWorktreeSpec` 包成 `PendingWorktree` 经 `.delegate(.beginCreate(pending))` 上抛、sheet 立即 dismiss；流式 effect 上移到 parent（`HierarchySidebarFeature` 持 cancellable，键 `enum CancelID { case pending(PendingWorktreeID) }`）；**catalog 写入仍在 stream 完成时**（`pendingWorktreeFinished` 那一步同步调 `createWorktreeWithGit` 并同步移除 pending 项，保 catalog ↔ on-disk 一致）；`GitWorktreeError → 人类可读字符串`集中到一处（而非散落在 `CreateWorktreeFeature` 与 `ArchivedWorktreesFeature` 各自的私有实现）；生命周期 setup 脚本调度落在 parent 的 finished 步、而非 sheet。

---

## 状态栏

### 概览

新增独立 TCA feature **`StatusBarFeature`**，作 `RootFeature` 直接子 scope。它只持一个字段 `toast: StatusToast?`（承载 inProgress / success / warning 三种瞬态）。**PR 形态与 motivational 形态是视图层派生**（从 `selection` + `gitHub.snapshots[wt]` + `TimelineView` 直接读），不进 feature state——它们是已有数据的纯函数，进 state 只会多一条必须手动维护同步的冗余轴。

中段 SwiftUI 组件 `StatusBarView` 用优先级选择当前形态：

```
toast != nil                  →  toast 形态 (P0 inProgress / P1 success|warning)
toast == nil && 有活跃 PR     →  PR 形态 (P2)
否则                          →  motivational (P3)
```

**关键 trade-off：只把 toast 做成 reducer-managed state，派生态做成 view-level projection**，换取最小状态面。否则把五种形态全 codegen 进一个大 enum、由 reducer 每次 `gitHub.snapshots` 变动 dispatch action，会让 RootFeature 与 TestStore 爆炸式膨胀。

本设计只动 titlebar **中段**；左侧分支标题、右侧 🔔/⇪/📖/⚙︎ 的代码与行为全不动。

### 不变量与契约

- **toast 槽是唯一的 reducer 状态**；其生命周期（push / auto-clear / 覆盖）在 reducer，PR/motivational 不走 action。
- **`StatusToast`（`CodansCore/StatusBar/`）= `enum { inProgress(String); success(String); warning(String) }`**，放 core 因 `RootFeature` 与未来 feature（run-script 等）都要构造它。**无 `error` case**：致命错误走 sheet/banner，不占这块槽。
- **auto-clear 窗口**：`success` 3s、`warning` 8s、`inProgress` 不自动清（由发射方显式结束）。
- **sequence 令牌**：`State.sequence: UInt64` 单调递增。push 时 `&+= 1` 并取消在飞定时器；定时器 fire `.cleared(seq)` 时仅当 `seq == state.sequence` 才清。这比 `.cancellable(id:)` 更稳——`Task.sleep` 已 resume 之后 `cancelInFlight` 的竞态窗口仍在，sequence 比对能丢弃陈旧 timer。
- **toast 发射经 RootFeature 路由既有 child action**（`coreReducer` 里 pattern-match `.editor(.openSucceeded/.openFailed)`、`.gitHub(.mergeCompleted/.markReadyCompleted/…Completed)` 等 → `.send(.statusBar(.push(...)))`）。零新协议、TestStore 可完整重放。未来 `RunScriptFeature` 接入只在 RootFeature 加 3 条分支（started→inProgress / completed→success / failed→warning），不改 `StatusBarFeature`。**不**走 `StatusBusClient` 侧信道（出了 reducer 系统、TestStore 看不见、与"delegate up, action down"风格矛盾），也**不**让 child 直发 sibling action。
- **PR 数据与 sidebar 同源**：PR 形态读 `gitHub.snapshots[currentWorktreeID]`，与 sidebar 的 `WorktreeGitHubBadge` 是**同一字段**，保证 titlebar 与 sidebar 永远同步——没有第二条 status-bar 专属 PR 通路。**不**读 `GitHubSnapshotCache` 文件流（缓存只反映上次成功批量 fetch，落后于会话内乐观刷新）。"活跃 PR"= snapshot 存在、`state != CLOSED`、`number` 非空。
- **scope 投影是纯函数** `(RootState) -> StatusBarViewModel`，`StatusBarViewModel` 只含渲染所需小 value type 字段（`toast` / `pr` / `isLoadingPR`），明确 Equatable 所有字段（避免比较过宽导致不刷新），让 view 不 import RootFeature 完整 state 面。

### 形态细节

**toast 形态**：inProgress（spinner）/ success（✓）/ warning（▲）+ 次级色文本。

**PR 形态**：`#编号` 徽章（颜色复用 `PullRequestStateColors`：open 绿/draft 灰/merged 紫）+ checks 色环 + 简述。简述优先级：merge-ready 阻塞原因 > checks 汇总 > `(Drafted)` > PR 标题。点击复用既有 `PullRequestPopover`（不重写）。按住 ⌘ 时简述临时换成 `Open on GitHub ⌘↵`，`⌘+click` 直接开 `gh` URL（构造时断言 `scheme == "https"`，失败降级不响应）。
- **checks 色环** `ChecksRollupRing`（14×14pt 四色环图）：复用既有 `PullRequestBadge.CheckRollup.from(checks:)` 汇总成 `{passing, failing, pending, neutral}`（neutral 吸收 skipped），颜色取自既有 `CheckRollupColor`。`total == 0` 不渲染，merged PR 不渲染。不引入任何新颜色/数据模型；sidebar 日后想换 ring 可直接复用（意外 bonus，非设计目标）。
- **⌘ 监听** `CommandKeyObserver`（`@Observable`，`NSEvent.addLocalMonitorForEvents(.flagsChanged)`）：只监听 local events（本进程 focus 时），无需 Accessibility 权限；`CodansApp` 启动时实例化一次经 `.environment` 注入。

**motivational 形态**：时段图标（按本地 hour：6–12 🌅 / 12–17 ☀️ / 17–21 🌇 / 其他 🌙）+ `HH:mm – Open Command Palette ⌘P`，`TimelineView(.everyMinute)` 每分钟刷新。`⌘P` 文案来自**新增共享常量** `CommandPaletteShortcut`（`CodansCore/Shortcuts/`，含 key/modifiers/displayString），`MainWindowCommands` 的菜单绑定也改读它——保证 hint 永远与菜单一致。这是本设计对既有代码唯一的主动改动（外加 RootFeature 加 scope、WorktreeDetailView 加 ToolbarItem）。**不**新建可配置 keybinding registry（超本设计范围）。

### 优先级状态机

```
                    Reducer-managed (toast 槽)
     toast=nil ──push(inProgress m)──►  .inProgress(m)
         ▲                                 │   ▲ push(inProgress m') 替换
         │       push(success/warning m)   │
         │                                 ▼
         │              .success(m) / .warning(m)
         │   .cleared(seq) after 3s/8s     │
         └─────────────────────────────────┘

                    View-level 派生（无 reducer 状态）
       toast == nil
          ├── snapshots[wt] is .open|.merged（非 closed）──► PR 形态
          └── 否则                                       ──► motivational
```

### 窄窗口与 toolbar 集成

中段用 `ViewThatFits(in: .horizontal)`（Full → Compact → `Color.clear` 退化链），SwiftUI 原生测量、零 GeometryReader 侵入、自带退化——设计阶段不定硬阈值；若实现期发现 toolbar 内测量抽风（个别 macOS 版本已知 bug），回退 GeometryReader + 经验阈值（暂定 520pt）。中段挂 `ToolbarItem(placement: .principal)`，两侧 `ToolbarSpacer(.flexible)` / `.fixed` 保持"左/中/右"相对顺序——即便中段是 `Color.clear`，右侧按钮也不左移。macOS 26+ 用 `sharedBackgroundVisibility(.hidden)`（提取为命名 modifier，复用 branch label 的同款分支）避免被渲染成圆角胶囊。所有形态切换统一 `easeInOut(0.2)` + `.opacity`。

无持久化 → 无迁移；无 feature flag（新增 UI 按钮一向不加 flag，回滚直接 revert 中段 toolbar content）。

---

## 分支切换器与历史

### 概览

header 分支区是可点击入口，分支切换在应用内完成。**分支切换逻辑落在独立的 `BranchSwitcherFeature`，不混入 `WorktreeHeaderFeature`**：后者已持 editor / run-script delegate（多 action + delegate case），再叠加 4–6 个切换 action + popover 生命周期 + 缓存失效 + HEAD-change 联动会突破可读性阈值；独立 feature 的 TestStore 也更清晰。Header feature 仅作为 view 上的兄弟出现在同一 `ToolbarItem`，挂载点把 `StoreOf<BranchSwitcherFeature>` 传给 `WorktreeHeaderInfoLabel`。

> **状态：`已设计未实现`。** 产品规格的"Diff Viewer 右侧拆 Changes/History 双 tab"这半边没有对应代码：没有 `DiffFeature` / `DiffTab` / `DiffHistoryListView` / `historyState`。**当前无任何应用内 diff / 历史查看器**——内置 diff overlay 不存在，`toggleDiffInspector` 命令仅把当前 worktree 路径交给用户配置的外部 git viewer（`general.defaultGitViewerID`；未配置时为 no-op）。Diff 能力止于 service 层（`GitServiceClient.commitDiff` 等）。本节末尾的 §Diff Viewer History tab 记录其设计意图；popover 底部"View all"入口的落点依赖它，故 popover 当前不提供该按钮或将其降级。

### Service 层契约

三个 `GitService` 新操作以与既有方法**完全一致的风格**注入（nonisolated、走 `CommandRunner` + `GitProcessEnv` + 16 MiB / 10s caps、argv 在 `GitCommand`、解析在 `GitOutputParser`）：

- `currentBranch(at:) -> String?`——`git symbolic-ref --short HEAD`；detached HEAD 返回 nil（本地按 exit code 判定，**不**抛），其余失败（not-a-repo / git 缺失 / timeout）抛。
- `listAllBranches(at:) -> BranchInventory`——一次 `git for-each-ref` 覆盖 `refs/heads` + `refs/remotes`，current 经 `%(HEAD)` 服务端解析（调用方无需第二次调用）。
- `switchBranch(to: BranchSwitchTarget, at:)`——local → `git switch <name>`；remote tracking → `git switch --track <origin/x>`。失败（脏树/冲突/歧义）以 `GitError.exec(code, stderr)` 原样保留 stderr，UI 取第一行。

模型（`CodansCore/Git/GitModels.swift`，排序/过滤在 service 层做，每个 caller 拿到稳定 render-ready 结果）：
- **`BranchRef { shortName: String; isRemote: Bool; upstream: String? }`**——字段名是 `shortName`（**不是** `name`；产品规格里写 `name` 是笔误，以此为准）。
- `BranchInventory { current: String?; local: [BranchRef]; remote: [BranchRef] }`——local/remote 各按 `shortName` 升序，current 若在 local 则提到位置 0；`<remote>/HEAD` 符号引用别名过滤掉。
- `BranchSwitchTarget = .local(name:) | .remoteTracking(shortName:)`。

`GitCommand.forEachRefBranches` 用 `--format=%(refname)%09%(refname:short)%09%(upstream:short)%09%(HEAD)`，记录换行分隔、字段 tab 分隔（分支名不含 `\t`/`\n`，解析每行单次 split）。**用 `for-each-ref` 而非 `git branch -a`**：后者输出 locale-dependent、symbolic-ref 的 `->` 脆弱；前者是文档化的编程接口、跨 git 版本稳定（`%(…)` token 自 git 2.0+ 稳定）。**单遍而非两遍**：`%(refname)` 前缀已区分 `refs/heads/*` vs `refs/remotes/*`，单遍少一次进程 spawn 且对并发 `git fetch` 原子。

### 不变量与契约

- **切换后刷新完全靠 `WorktreeHeadWatcher` 既有 HEAD-change 回路**，不引入手工 reload。`switchBranch` 成功 → git 写 `.git/HEAD` → watcher tick → catalog refresh → `Worktree.branch` 更新 → `RootFeature` 派发 `headChangedForCurrentWorktree` → `BranchSwitcherFeature` 清缓存 + `isSwitching = false`，header 自然显示新分支。切换发起即 popover dismiss + spinner 起；watcher 200ms debounce 让 spinner 多停 ~200ms，可接受（更快 reset 需引入并行"我刚切了"提示，双重事实来源不值）。
- **不在 service 层预检脏树**：`git status` 然后 `git switch` 非原子（两调间编辑文件会误报）；git 自身已强制此检查，预检可能与之分歧（ignore 规则不同）；每次切换多一次进程 spawn；git 原生 stderr（"Your local changes … would be overwritten"）比我们能合成的更可操作。Native error capture wins。
- **缓存策略**：`BranchSwitcherFeature` 的 `inventory` + `recentCommits` 在 `worktreeChanged` 或 `headChangedForCurrentWorktree` 时失效，下次 `popoverTapped` 重载。第二次开 popover 即时返回；代价是 fetch-only 的陈旧（用户终端跑 `git fetch` 无 HEAD 变化）——接受"下次开 popover 前数据可能 N 秒陈旧"，不值得为此轮询。
- **fast-path 切换**：点 `origin/x` 时若本地已有 `x`，直接 `git switch x` 而非 `--track` 重建。
- **cancellation**：`BranchSwitcherFeature` 三个 CancelID（`.inventory` / `.commits` / `.switch`），切换取消在飞的 inventory/commits 加载（其数据即将陈旧）；成功的 switch 不取消自己（单次短命调用），仅 `worktreeChanged` 取消并重置状态——inventory 加载的 `[gitService]` capture 锁定 dispatch 时刻的 worktree 路径，而非当前 state（防跨 worktree popover 串味）。
- **错误展示**：`switchBranch` 的 `GitError.exec` 映射成 inline `switchError`（取 stderr 第一行，由 `GitSwitcherFeature` 拥有），可关闭、不阻塞其他操作；完整 stderr 留在日志（Console.app 调试）。`listAllBranches` 失败渲染 popover 内空态 + retry（用户仍能看 Recent Commits）。

### Header 布局

行 1 = `WorktreeRowIcon` + 分支名（`.headline`）+ 尾随 chevron-down（`isSwitching` 时换 `ProgressView().controlSize(.mini)`）；行 2 = `worktree.name · project.name`（`.caption .secondary`）。`branchTitle`：`worktree.branch == nil` → `"(detached)"`（未来 `Worktree.headSha` 可用后点亮 `"(detached @ <short-sha>)"`）；否则 `worktree.branch ?? worktree.name`（worktree.name fallback 覆盖刚 clone 无 HEAD 的情形）。整行 `.contentShape(.rect)` + hover 高亮，点击 toggle `popoverTapped`，`.popover(arrowEdge: .bottom)` 挂 `BranchSwitcherView`。Project 名沿 `Worktree → Project` 反查，`WorktreeHeaderInfoLabel` 已接收 `project: Project` 直接读 `project.name`。

### Diff Viewer History tab（`已设计未实现`）

> 此小节为设计意图记录；当前无对应代码，且其前置依赖（Diff Viewer 本身）也不存在。

意图是 Diff Viewer 右侧拆 Changes/History segmented control：Changes 呈现未提交改动，History 列当前分支 commit 历史（分页，首页 50、滚动到底加载下页），点 commit 在左侧渲染该 commit 整体 unified diff，左侧标题在 History 模式显示 `<short-sha> · <subject>` 而非文件路径。`commitDiff` 复用既有 `GitServiceClient.commitDiff` + 既有 16 MiB / `maxFileBytes` / `maxFileLines` caps（超限走"too large"占位）。设计倾向把 History 做成 `DiffFeature` 的内嵌 `HistoryState` 而非 child reducer（两 tab 共用同一左侧 drawer，child 会需要 scope plumbing 或父级 active-selection reducer，得不偿失），HEAD 变化或 `worktreeSelected` 时重置 History 状态。popover 的 Recent Commits（≤10 条）与 History 首页（50 条）用**独立缓存**而非同源——sort/limit 形不同，共享会让冷启动时 popover 为更大的那个等待，且 HEAD 变化的失效顺序耦合。

落地前置依赖：`DiffFeature` 本身（当前不存在）。它落地后，本节状态转为已上线，popover 的"View all"入口接通"打开 Diff Viewer → selected tab = History"。

---

## 组件边界

```
CodansCore/
  Worktree.swift                    archived / archivedAt / isPinned；无 sortIndex
  Git/GitModels.swift               BranchRef(shortName) / BranchInventory / BranchSwitchTarget
  StatusBar/StatusToast.swift       inProgress / success / warning
  Shortcuts/CommandPaletteShortcut.swift   ⌘P 共享常量
  Settings/GitProjectSettings.swift create/archive/deleteScript

codans/Git/
  GitWorktreeClient.swift           唯一 git spawn 面（worktree 操作）；nonisolated async
  GitWorktreeCLI.swift              发现的 fallback（非打包构建）
  GitService.swift / LiveGitService.swift / GitCommand.swift / GitOutputParser.swift
                                    currentBranch / listAllBranches / switchBranch + 解析器

codans/Runtime/
  HierarchyManager.swift            纯状态：setWorktreeArchived / reconcileDiscoveredWorktrees /
                                    reorderWorktrees(segment) / promoteWorktree / createWorktree(插 boundary)
                                    WorktreeSegment{.pinned,.unpinned}；无 git IO
  WorktreeHeadWatcher.swift         监听 .git/HEAD → 驱动 catalog 刷新（分支切换与 header 的唯一刷新源）

codans/App/Clients/
  HierarchyClient.swift             append：setWorktreeArchived / reconcile / createWorktreeWithGit /
                                    removeWorktreeWithGit / *WithLifecycle / reorderWorktrees /
                                    promoteWorktree / runningPanelCount
  GitServiceClient.swift            +currentBranch / listAllBranches / switchBranch

codans/App/Features/HierarchySidebar/
  HierarchySidebarFeature / View    orderedSidebarRows；pending 生命周期；段内 .onMove
  SidebarRow.swift / PendingWorktree.swift / CommandKeyObserver.swift
  CreateWorktreeFeature / Sheet     表单 + 同步预检（流式 effect 已上移 parent）
  ArchivedWorktreesFeature / Sheet  Project 作用域归档列表

codans/App/Features/BranchSwitcher/
  BranchSwitcherFeature / View / BranchRowView / RecentCommitRowView

codans/App/Features/WorktreeHeader/
  WorktreeHeaderInfoLabel.swift     2 行布局 + popover host

codans/App/Features/StatusBar/
  StatusBarFeature / StatusBarView
  Views/{StatusToastView, StatusPullRequestView, StatusMotivationalView, ChecksRollupRing}

codans/App/Features/Root/RootFeature.swift   statusBar scope + toast 路由分支；
                                             WorktreeHeadWatcher events → BranchSwitcher
codans/App/Commands/MainWindowCommands.swift 读 CommandPaletteShortcut

apps/mac/ThirdParty/git-wt/         submodule（仓库根 .gitmodules）
apps/mac/scripts/{verify,embed}-git-wt.sh
```

依赖方向：`Views → Feature → Core`；features → clients → managers/shell。`GitWorktreeClient` / `GitService` 纯 nonisolated async，从不碰 `@Observable`。`BranchSwitcherFeature` 只依赖 `GitServiceClient`，打开 Diff Viewer 经 `Action.delegate`（由 `RootFeature` 消费），不 import `DiffFeature`；`StatusBarFeature` 仅依赖 `CodansCore`，View 读 `gitHubStore` 经注入而非 `@Dependency`。

## 备选方案（Alternatives）

- **扩展 `GitWorktreeCLI` 而非新增 `GitWorktreeClient`。** 否决：旧 actor 同步缓冲 stdout、无 streaming，且直连 `/usr/bin/git` 而非 spec 要求的 `git-wt`；混在一个类型里模糊"用哪个工具"。详见 §生命周期 概览。
- **archive 作为 Project 上独立 `[Worktree]` 数组。** 否决：fork 唯一性/选中不变量、多一处跨集合同步；in-place `archived: Bool` 配合现有 filter 一行解决。
- **创建/发现直接放 `HierarchyManager`。** 否决：manager 是 `@MainActor @Observable`，spawn 进程 + 消费 `AsyncStream` 会阻塞 UI 或逼每个 callsite 学 async；且其内存 `CatalogStore` 单测会被 `Process` 依赖打破。
- **流式创建用 `AsyncSequence<String>`（仅行）。** 否决：会把"进度行"与"最终路径"混为一谈；typed `CreateWorktreeEvent` 显式区分。
- **全局跨 Project 归档 sheet（如 supacode）。** 否决：codans 侧边栏 Project 作用域、`⋯` 菜单在 Project 级；跨 Project 归档面无明显落点。每 Project sheet 保持导航本地。
- **段内顺序载体：`sortIndex` 字段 / settings.json sidebar-order 表。** 均否决：`sortIndex` 要 schema 变更且 pin/unpin 跨段时需重算；独立 order 表产生第二事实来源、需要 catalog↔order 偏差补偿函数（正是 Context 想消除的复杂度）。catalog 数组下标承担，与 `reorderProjects` 对称。
- **pending 态归属：catalog ghost row / `HierarchyManager` `@Observable` 字段。** 均否决：ghost row 破坏 catalog↔disk 不变量、逼每个 catalog 消费方学会跳过 pending 行、并要求 `WorktreeID` 提前分配；`HierarchyManager` 字段违反"manager 是 TCA-free Runtime"且 pending 由 action 驱动（Retry/Discard/Cancel）。sidebar reducer 内存最简。
- **跨段拖拽即触发 isPinned 变更。** 否决：意图歧义（拖到 pinned 第三位是想 pin 后落第三、还是测试落点？）+ `onMove` 跨段计算复杂度跳升。先用 Pin/Unpin 菜单项把意图显式化。
- **状态栏挂 `WorktreeHeaderFeature` / `RootFeature` 顶层。** 均否决：Header mixing toast 让两件事 action enum 混杂、bell 测试被迫断言无 toast；RootFeature 顶层加字段使 toast 的 timer effect 更难测、牵动大量类型推断。独立 `StatusBarFeature` 迁移点单一。
- **PR 数据读 `GitHubSnapshotCache` 文件流。** 否决：缓存只反映上次成功批量 fetch，落后于会话内乐观刷新，会让 titlebar 滞后于 sidebar。直接读 feature state 同源。
- **分支 popover 状态塞 `WorktreeHeaderFeature`；`git branch -a`；两遍 `for-each-ref`。** 均否决，见 §分支切换器 各节。
- **History 做成 child `DiffHistoryFeature`。** 否决（属 `已设计未实现` 部分）：两 tab 共用左侧 drawer，child 需 scope plumbing 或父级 active-selection reducer，内嵌 `HistoryState` 更省。

## 风险

| 风险 | 缓解 |
|---|---|
| `wt` 脚本未打包 → 运行期错误。 | pre-build `verify-git-wt.sh` 用清晰 submodule 提示 fail 构建；`GitWorktreeClient` 仍防御性抛 `.executableMissing`。 |
| `wt ls --json` 输出格式漂移。 | submodule 钉 commit SHA，谨慎 bump；`GitWtEntry` 解码容忍多余 key 但缺必需 key 时大声 fail（正确信号）。 |
| 流式创建挂起（巨型 `node_modules`）。 | sheet/pending 行全程可 Cancel；取消经 `AsyncThrowingStream.onTermination` 在取消消费 Task **之前** terminate 子进程（否则 resumption 孤儿化、子进程泄漏）。写测试：长任务中途取消断言 `wt` 已退出。 |
| 强制删除硬杀终端丢未保存工作。 | 确认对话框点名进程数 + 未提交改动单独警告；终端内容本就瞬态（不跨 session 持久化 scrollback）。 |
| reconcile 与 create 竞争。 | 两路 catalog 写经 main actor 串行；规范化路径匹配去重刚创建行。 |
| 拖拽期间 catalog 突变使 `IndexSet→ID` 失效。 | `reorderWorktrees` 转 `WorktreeID` 列表后 manager 自检：任一 ID 不存在则整次丢弃、不部分应用。 |
| `pendingFinished` 与 `pendingCancel` 竞争。 | 两者串行抵达 reducer；finished 步顶端 guard `pendingWorktrees[id] != nil`，cancel 先到则 finished 成 no-op。 |
| pending 行堆叠失控。 | 每 project 软上限 8 条；第 9 次提交 sheet banner 拒绝。 |
| `for-each-ref` 格式漂移 / `--track` 歧义。 | 钉文档化 `%(…)` token；caller 传全限定 `origin/x`，UI 永不传歧义输入。 |
| `WorktreeHeadWatcher` 200ms debounce 让 spinner 多停 ~200ms。 | 可接受；更快 reset 需双重事实来源。 |
| 大 merge commit diff 撞 16 MiB cap（History，`已设计未实现`）。 | 复用既有 working-tree diff 的"too large"占位，UX 一致。 |
| `ViewThatFits` 在 toolbar 内测量失真。 | 回退 GeometryReader + 520pt 阈值。 |
| `EditorFeature.openFailed(reason:)` 未脱敏可能带路径。 | toast 路由的 `shortMessage` 只取第一行 + 截断 80 字符。 |
| `CommandKeyObserver` 未停止泄漏 monitor。 | `start()`/`stop()` 绑 `CodansApp` onAppear/onDisappear，weak-self capture。 |

## 参考

- 产品规格：[worktree-management.md](../product-specs/worktree-management.md)
- 模型：`apps/mac/CodansCore/{Worktree,Project}.swift`、`CodansCore/Git/GitModels.swift`、`CodansCore/StatusBar/StatusToast.swift`、`CodansCore/Shortcuts/CommandPaletteShortcut.swift`
- git 面：`apps/mac/codans/Git/{GitWorktreeClient,GitService,GitCommand,GitOutputParser}.swift`
- 运行时：`apps/mac/codans/Runtime/{HierarchyManager,WorktreeHeadWatcher}.swift`
- 写入面：`apps/mac/codans/App/Clients/{HierarchyClient,GitServiceClient}.swift`
- features：`apps/mac/codans/App/Features/{HierarchySidebar,BranchSwitcher,WorktreeHeader,StatusBar}/`
- 通知驱动的提升：[notifications.md](notifications.md)
- 打包：`apps/mac/ThirdParty/git-wt/`、`apps/mac/scripts/{verify,embed}-git-wt.sh`
