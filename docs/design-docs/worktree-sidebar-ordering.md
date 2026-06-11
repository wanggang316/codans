# Design Doc: Worktree 侧边栏排序规则

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-26

## Context and Scope

侧边栏中每个 Project 节点下渲染若干 Worktree 行。目前（`apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift:45-51`）的排序实现只有 5 行：

```swift
let visible = project.worktrees.filter { !$0.archived }
let main = visible.filter { $0.path == project.rootPath }
let pinned = visible.filter { $0.isPinned && $0.path != project.rootPath }
let rest = visible.filter { !$0.isPinned && $0.path != project.rootPath }
return main + pinned + rest
```

这条规则没有正式定义文档，也回答不了下面这些问题：

- 一个 worktree 创建中（`wt sw` 流式跑了 30s+）的时候，sidebar 里看到的是什么？目前答案是：什么也看不到，因为 sheet 还没关。
- pinned 段里两条 pinned worktree 的相对顺序是什么决定的？目前是 `project.worktrees` 数组的天然顺序，但用户没有任何方式调整它。
- 用户新建一个 worktree（不主动 pin），它出现在 unpinned 段的哪里？目前是末尾，因为 `HierarchyManager.createWorktree` 走 `worktrees.append`。
- 多个 worktree 的归档 / 取消归档 / pin / unpin 操作，是否会改变它们在 sidebar 中的相对位置？目前是隐式跟随 catalog 数组突变。

这些问题不是单点 bug —— 它们共同指向"侧边栏 worktree 排序"作为一个完整概念缺一份正式定义。本设计补齐定义、拓展为四段、并把每段在五个维度上的行为讲清楚。

相关架构约束（不能违反）：

- **Catalog ↔ on-disk 一致**。`catalog.json` 中的每条 Worktree 行必须对应一个真实存在的 git worktree 目录。
- **`HierarchyManager` 是 `@Observable` 运行时态**，不持有 TCA / 表现层瞬时状态。
- **标识符一律 UUID**，且 `WorktreeID` 在 `HierarchyManager.createWorktree` 写入 catalog 那一刻才生成。
- **持久化是带 version 的原子 rename JSON**。给 `Worktree` 加字段需要走 `decodeIfPresent` + 条件编码模式，已有 `archived` / `isPinned` 两个先例。

## Goals and Non-Goals

### Goals

- 把 sidebar worktree 的排序定义为**四段** —— main / pinned / pending / unpinned —— 每段在五个维度上有清晰约定：
  1. 段语义（哪些 worktree 进这段）
  2. 数据来源（catalog 字段 / sidebar 内存集合）
  3. 段内顺序（怎么决定段内两条 worktree 的相对位置）
  4. 用户操作（pin / unpin / 拖拽 / 取消）
  5. 持久化位置（catalog.json / 内存）
- 给 pinned 和 unpinned 段引入用户可控的段内重排（拖拽），重排状态持久化。
- 引入 pending 段，使 `wt sw` 流式过程在 sidebar 可见、不再阻塞用户。
- 定义新建 worktree 的落位规则（默认进哪段、段内放在哪里）。
- 不引入新的持久化文件，也不引入新的 schema version。

### Non-Goals

- Project 之间的排序（已由 `reorderProjects` 实现，不变）。
- Space 之间的排序（同上，已由 `reorderSpaces` 实现）。
- 归档 worktree 的展示（走 `ArchivedWorktreesSheet`，已在 `worktree-management-design.md` 覆盖）。
- 跨 Project 的 worktree 列表（不存在这种视图）。
- 把"新创建的 worktree 自动滚到视口"这种 reveal 行为；本 doc 只管排序，不管滚动。
- 跨窗口的 sidebar order 同步；多窗口语义按现有 "window ↔ Space 1:1" 倾向，每窗口独立。

## Design

### Overview

排序按**段优先**：先决定一条 worktree 属于哪段，再决定它在段内的位置。四段的固定渲染顺序是：

```
main → pinned → pending → unpinned
```

四段在五个维度上的对照：

| 维度 \ 段 | main | pinned | pending | unpinned |
|---|---|---|---|---|
| 段语义 | `path == project.rootPath` 且非 archived | `isPinned == true` 且非 main 且非 archived | sidebar 内存中的"创建中"占位 | 其余非 archived |
| 数据来源 | `Project.worktrees`（catalog） | `Project.worktrees`（catalog） | `HierarchySidebarFeature.State.pendingWorktrees` | `Project.worktrees`（catalog） |
| 段内顺序 | 至多一条，无段内顺序 | catalog 数组顺序 | 内存数组的插入顺序（即 `startedAt` 升序） | catalog 数组顺序 |
| 用户操作 | 不可拖出段；不可 unpin（因为根本没 pin） | Pin/Unpin、拖拽重排 | Cancel、Retry、Discard | Pin → 进 pinned 段、拖拽重排 |
| 持久化 | catalog.json | catalog.json | 不持久化（仅当前 session） | catalog.json |

中心 trade-off：**段内顺序统一靠 `Project.worktrees` 数组下标**，而不是给 `Worktree` 加 `sortIndex` 字段。换言之，sidebar 的"段内位置"和 catalog 数组的"行下标"是同一个值。这样：

- 不用扩 schema，不用引入第二套 sidebar-only ordering 表。
- 拖拽重排 = 改 catalog 数组顺序（跟现有 `reorderProjects` 完全对称）。
- 段内的"自然顺序"和"用户排过的顺序"是同一种东西，没有"sidebar 看到的顺序与 catalog 不一致"的偏差需要补偿。

代价：catalog 数组顺序不再是纯粹的"创建历史"，而带上了"用户排过的顺序"语义。这跟 `reorderProjects` 已经做过的取舍一致；`Project` 数组的下标早已被赋予用户排序语义，再让 `Project.worktrees` 走同一条路不增加新的概念负担。

### 段语义详述

#### main 段

只装一条：`worktree.path == project.rootPath`。这是 git 仓库的根 checkout，同一个 Project 下唯一。

为什么单独成段：根 checkout 是**自然存在**的（add Project 时由 reconcile 写入），不是用户创建的。用户预期它永远在最上面，就像 Finder 的"Macintosh HD"永远在 sidebar 顶端 — 即便它技术上"被 pin"了，也不希望它跟其他 pin 同段堆叠、被 pin 排序操作影响。所以 main 段独立于 pinned 之外，并且 `isPinned` 字段对它**无意义**：UI 不显示 Pin/Unpin 按钮，菜单项裁剪掉。

如果 main worktree 被 archive，则该 Project 在 sidebar 中没有 main 段。这是合法状态（`isWorktreeArchived` 主路径已经处理）。

#### pinned 段

进入条件：`isPinned == true && path != project.rootPath && !archived`。

段内顺序：catalog 数组中这些元素的相对位置。

用户操作：
- **Pin**（在 unpinned 行的右键菜单）：把 worktree 移到 pinned 段**末尾**。理由：用户主动 pin 是表达"我要这个长期可见"，但不是"我要它最上面"；放末尾让现有 pinned 顺序稳定，符合"least surprise"。
- **Unpin**（在 pinned 行的右键菜单）：把 worktree 移到 unpinned 段**顶部**（即 catalog 中 unpinned 段的第一个位置）。理由：unpin 通常意味着"我不再需要它高优先级，但它还在用"，放顶部符合"它仍然新鲜"的预期。
- **拖拽**：`ForEach.onMove` 在 pinned 段内有效；跨段拖拽视为"先调 isPinned，再插入到落点位置"的复合操作（详见 §渲染合并 / 拖拽）。

#### pending 段

进入条件：用户在 Create Worktree sheet 点 Create 之后、`wt sw` 流式完成之前。

数据来源：`HierarchySidebarFeature.State.pendingWorktrees: IdentifiedArrayOf<PendingWorktree>`，按 project 过滤后渲染。结构：

```swift
struct PendingWorktreeID: Hashable, Sendable { let raw: UUID }   // 与 WorktreeID 不同名

struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let spaceID: SpaceID
  let spec: CreateWorktreeSpec       // 提交时冻结
  let displayName: String            // = spec.branch
  var status: Status
  var lastProgressLine: String?
  var startedAt: Date

  enum Status: Equatable {
    case running
    case failed(GitWorktreeError)
  }
}
```

段内顺序：`IdentifiedArray` 插入顺序，即 `startedAt` 升序。无拖拽 — 这是临时占位，重排没有意义。

用户操作：
- **Cancel**（仅 `.running` 时可用）：取消流式 effect，给 `wt` 发 SIGTERM，从内存集合移除。**不**主动跑 `wt remove --force` 清理可能产生的残留目录；交给 Prune。
- **Retry**（仅 `.failed` 时可用）：复用同一个 `PendingWorktreeID` 重启 effect（`.cancellable(id:cancelInFlight: true)` 保证幂等），状态翻回 `.running`。
- **Discard**（仅 `.failed` 时可用）：从内存集合移除。

不可操作：选中（没有 `WorktreeID` 也没有 Pane，无法激活终端）；⌃⌘N 跳转（按 hotkey 顺序枚举时跳过 pending 行）；Pin / Reveal in Finder / Open in editor / Archive / Remove（这些都假设有真实 on-disk 路径与 catalog 行）。

成功路径：`createWorktreeStream` 抛 `.finished(path)` → reducer 同一步内（a）调 `HierarchyClient.createWorktreeWithGit` 写 catalog（生成真实 `WorktreeID`），（b）从 `pendingWorktrees` 移除该项，（c）`selectWorktree` + `createTab` + `openPane`，（d）派发 setup 生命周期脚本 effect。catalog 写入时机不变 —— 仍在 `wt sw` 完成之后，跟今天一致。

崩溃恢复：pending **不持久化**。app 重启后内存集合为空；如果某个 pending 在崩溃前 `wt sw` 已经在 disk 上落了目录但 catalog 还没写，由现有 `reconcileDiscoveredWorktrees(projectID:, spaceID:)` 在下次 reconcile 时发现并补登记。这是和"用户在 app 外面 `git worktree add`"完全相同的恢复路径，不引入新的 state machine。

#### unpinned 段

进入条件：剩下的非 archived 非 main 非 pinned worktree。

段内顺序：catalog 数组中这些元素的相对位置。

用户操作：
- **Pin**：见 pinned 段描述。
- **拖拽**：`ForEach.onMove` 在 unpinned 段内有效。

新建 worktree 落位：默认 `isPinned = false` → 进 unpinned 段；落 catalog 中 unpinned 段的**顶部**。理由：刚创建的 worktree 是用户当下最关心的对象，放顶部省一次滚动。这等价于 `HierarchyManager.createWorktree` 把新行插在"最后一个 main/pinned 之后、第一个 unpinned 之前"，而不是无脑 `append`。

### 渲染合并

`HierarchySidebarView.orderedVisibleWorktrees(in:)` 函数从今天的"返回 `[Worktree]`"演化为返回异构行：

```swift
enum SidebarRow: Identifiable {
  case worktree(Worktree)
  case pending(PendingWorktree)

  var id: String {
    switch self {
    case .worktree(let w): return "wt:\(w.id.raw)"
    case .pending(let p):  return "pending:\(p.id.raw)"
    }
  }
}

static func orderedSidebarRows(
  project: Project,
  pendings: [PendingWorktree]
) -> [SidebarRow] {
  let visible = project.worktrees.filter { !$0.archived }
  let main = visible.filter { $0.path == project.rootPath }
  let pinned = visible.filter { $0.isPinned && $0.path != project.rootPath }
  let rest = visible.filter { !$0.isPinned && $0.path != project.rootPath }
  let projectPending = pendings.filter { $0.projectID == project.id }
  return main.map(SidebarRow.worktree)
       + pinned.map(SidebarRow.worktree)
       + projectPending.map(SidebarRow.pending)
       + rest.map(SidebarRow.worktree)
}
```

`SidebarRow.id` 显式带 case 前缀，避免 `WorktreeID` 与 `PendingWorktreeID` 在 SwiftUI `ForEach` 里的 UUID 碰撞（两者都基于 UUID）。

#### 拖拽

每段单独挂 `.onMove`。SwiftUI 的 `ForEach.onMove` 给出段内 `IndexSet` + 段内目标位置；reducer 把它转成"在 catalog 数组里把这一段元素重排成 X"的命令，调用新的 `HierarchyClient.reorderWorktrees(_, segment, from, to)`。`segment` 是 enum `{ .pinned, .unpinned }` —— main 段无重排；pending 段无 onMove。

跨段拖拽（pinned ↔ unpinned）暂不支持：用 Pin / Unpin 菜单项替代。理由：跨段拖拽要同时改 `isPinned` 和数组位置，UX 上还需要决定"放在 pinned 段第三个位置 = 既是 pin、又落在该位置"是否符合用户意图，先用菜单项把意图显式化，等真有人提需求再补。

### 数据存储

#### `Worktree` 模型

**不变**。`isPinned: Bool` + `archived: Bool` 两个字段已经能区分前述所有段；没有 `sortIndex` / `createdAt` 字段，段内顺序完全由 catalog 数组下标承担。

#### `PendingWorktree`

新增结构，仅存在于 `HierarchySidebarFeature.State`，不写 catalog.json，不写 settings.json。生命周期 = sidebar reducer 实例的生命周期。

#### catalog.json

schema **不变**。新增的 `reorderWorktrees` 调用走 `HierarchyManager` 的同一条 `CatalogStore` 写盘路径（atomic-rename JSON），不涉及版本号。

### Component Boundaries

```
CodansCore/
  Worktree.swift                     无变更

codans/Runtime/
  HierarchyManager.swift             新增 reorderWorktrees(_, segment, from, to)
                                     调整 createWorktree 的插入位置（unpinned 顶部）

codans/App/Clients/
  HierarchyClient.swift              新增 reorderWorktrees 闭包

codans/App/Features/HierarchySidebar/
  HierarchySidebarFeature.swift      新增 pendingWorktrees 字段
                                     新增 begin/progress/finished/failed/retry/
                                     discard/cancel actions
                                     新增 reorderWorktrees(segment, from, to)
                                     forwarder
                                     parent 接管 createWorktreeStream effect
  HierarchySidebarView.swift         orderedVisibleWorktrees → orderedSidebarRows
                                     ForEach 异构渲染 SidebarRow
                                     pinned / unpinned 段各挂 .onMove
  PendingWorktree.swift              NEW，含 PendingWorktreeID
  PendingWorktreeRow.swift           NEW
  CreateWorktreeFeature.swift        删去流式 effect、progressLines、
                                     lifecycle-script merge；
                                     delegate 改为 .beginCreate(PendingWorktree)
  CreateWorktreeSheet.swift          删去进度日志区
```

依赖方向不变。新增的跨文件耦合都在 `HierarchySidebar/` 内部。

### Pending 段成立所需的实现影响

pending 段是四段中唯一引入新数据源的段，因此连带几项工程改动；这些改动是"为了让 pending 段能存在"的副产品，列在这里以保持本 doc 的完整性，但不构成本设计的主轴。

1. **CreateWorktreeFeature 责任收窄**。今天 sheet 同时承担表单 + 流式创建；改造后只剩表单 + 同步预检（"目录是否已存在"等）。提交时把验证后的 `CreateWorktreeSpec` 包成 `PendingWorktree` 通过 `.delegate(.beginCreate(pending))` 上抛，sheet 立即 dismiss。
2. **流式 effect 上移到 parent**。`HierarchySidebarFeature` 持有 cancellable effect，键为 `enum CancelID { case pending(PendingWorktreeID) }`。stream 抛事件 → parent 派发 `pendingWorktreeProgress / Finished / Failed`。
3. **catalog 写入仍在 stream 完成时**。reducer 在 `pendingWorktreeFinished` 那一步同步调 `createWorktreeWithGit`，并在同一步从 `pendingWorktrees` 移除该项。这条不变化保证了 catalog ↔ on-disk 一致性不被本设计破坏。
4. **错误文案集中化**。`GitWorktreeError → 人类可读字符串` 抽到新的 `GitWorktreeErrorMessage.swift`；今天 `CreateWorktreeFeature` 和 `ArchivedWorktreesFeature` 各有一份 `humanReadable(_:)` 私有副本，本次顺手合并。
5. **生命周期 setup 脚本调度位置变更**。原本由 sheet 在 `.createSucceeded` 步骤通过 `.merge` 派发；改造后由 parent 在 `pendingWorktreeFinished` 步骤派发。`RootFeature` 接收 `.lifecycleScriptResult` delegate 的路径不变。
6. **`HierarchyManager.createWorktree` 插入位置调整**。从 `worktrees.append` 改为"插入在最后一条 main/pinned 之后"，使新 worktree 落 unpinned 段顶部（见 §unpinned 段 新建落位）。

### 用户可见行为变更总结

| 操作 | 今天 | 本设计后 |
|---|---|---|
| 点 Create 后的 sheet | 保持打开直到 `wt sw` 完成 | 立即关闭，sidebar 出现 pending 行 |
| 创建中能不能切 project / 切 worktree | 不能（modal） | 能 |
| 创建失败的恢复入口 | sheet 内的 banner + Create 按钮 | sidebar pending 行的 Retry / Discard |
| 新建 worktree 出现在 unpinned 段 | 末尾 | 顶部 |
| 拖拽重排 worktree | 不支持 | pinned 段、unpinned 段段内可拖 |
| Pin 一个 worktree 后它的位置 | catalog 中保留原位置（视觉跳到 pinned 段尾） | 显式落 pinned 段尾（与今天等价，但语义明确） |
| Unpin 一个 worktree 后它的位置 | 留在 catalog 原位置（视觉落 unpinned 段中某处） | 显式落 unpinned 段顶 |

## Alternatives Considered

设计中有四处需要选择，每处单列，给出推荐的反方案及拒绝理由。

### 段内顺序载体：catalog 数组下标 vs `Worktree.sortIndex` 字段 vs settings.json sidebar-order 表

- **A1（已选）catalog 数组下标承担段内顺序**。trade-off：catalog 数组顺序兼具"创建历史"与"用户排序"两层语义。优点：不动 schema，不引入第二套 ordering 表，跟 `reorderProjects` 对称。
- **A2 给 `Worktree` 加 `sortIndex: Int`**。优点：段内顺序与 catalog 数组下标解耦，"自然顺序"与"用户排过的顺序"语义分离。缺点：引入字段意味着 schema 变更（虽然走 `decodeIfPresent` 不破老存档），并且 `sortIndex` 在 pin/unpin 跨段时需要重算，比直接挪数组下标繁琐。**拒绝**。
- **A3 在 settings.json 加 per-project `sidebarWorktreeOrder: [WorktreeID]` 表**。优点：catalog 完全保持"创建历史"纯净。缺点：产生第二套 ordering 表，需要写"如果某 worktree 在 catalog 但不在 sidebar order 表中，怎么补位"的合并函数（即 catalog ↔ sidebar order 的偏差补偿）。这是 doc 顶部 Context 想消除的复杂度本身。**拒绝**。

### Pending 状态归属：sidebar reducer in-memory vs catalog ghost row vs HierarchyManager `@Observable`

- **B1（已选）sidebar reducer in-memory**。trade-off：sidebar 多一个集合需要渲染。优点：catalog ↔ disk 一致性不动；pending 行不会被 GitClient / EditorService / 生命周期脚本误读为真实 worktree。
- **B2 catalog 里加一行带 `pending: Bool` 的 ghost worktree**。优点：渲染路径统一，`orderedVisibleWorktrees` 几乎不用改；现有 pin / unpin / 选中机器复用。缺点：（a）破坏 catalog ↔ disk 不变量；（b）每个 catalog 消费方（GitClient、EditorService、`runWorktreeLifecycleScript`、`openPane`、`selectWorktree`、GitHub PR 订阅、`reconcileDiscoveredWorktrees` 的路径规范化匹配）都要学会跳过 pending 行；（c）`WorktreeID` 必须在提交时就分配，要么之后被替换（让一切引用失效），要么 `HierarchyManager.createWorktree` 接受外部分配的 ID（今天它不接受）。**拒绝**：把瞬时态污染到稳定的、广泛被消费的持久模型上，代价远高于多一个本地集合。
- **B3 `HierarchyManager` 上加 pending `@Observable` 字段**。优点：跨 sidebar 实例存活、跨窗口共享。缺点：违反"`HierarchyManager` 是 TCA-free Runtime"的不变量；pending 生命周期由 action 驱动（Retry / Discard / Cancel），动这部分需要把数据外移再用 AsyncStream 桥回 TCA。多窗口共享在"window ↔ Space 1:1"倾向下也不是清晰收益。**拒绝**。

### 新建 worktree 的 catalog 落位：append vs prepend-into-unpinned vs after-pinned

- **C1（已选）插在最后一条 main/pinned 之后、第一条 unpinned 之前**（= unpinned 段顶）。trade-off：刚创建的对象在视觉上最显眼，符合用户当下意图；同时不改变 main / pinned 段的相对顺序，已 pin 的偏好不被打扰。
- **C2 直接 `worktrees.append`（catalog 末尾，= unpinned 段尾）**。这是今天的行为。缺点：在已有 5+ 个 worktree 的 Project 上，刚创建的 worktree 直接被推到屏幕外，需要滚动。**拒绝**：与 pending 段（pending 出现在 pinned 之后）形成"创建中显眼、创建完反而消失到底部"的反差，UX 不连贯。
- **C3 用户在 Create sheet 上提供"Pin once created"checkbox**。优点：用户显式表达落位意图。缺点：增加一个低使用率的开关；用户不勾选时仍要回答 C1/C2 的问题。**拒绝**：先用 C1 默认行为，等真的有"创建即 pin"诉求再加。

### 跨段拖拽：菜单项 only vs 拖拽即触发 isPinned 变更

- **D1（已选）跨段拖拽不支持，只走 Pin / Unpin 菜单项**。trade-off：操作多一个菜单层级，但意图显式。
- **D2 拖拽即触发 isPinned 变更 + 段内位置变更**。优点：操作一气呵成。缺点：意图歧义（用户拖到 pinned 第三个位置，是想 pin 后落第三、还是想测试落点？），需要 hover 高亮 + 拖动确认动画来消歧；且实现要拆 `onMove` 的 `IndexSet→target` 为跨段计算，复杂度跳升。**拒绝**：等 D1 落地后看是否有用户反馈再补。

## Cross-Cutting Concerns

### 测试

- `HierarchySidebarFeatureTests` 已用 `TestStore`；新增覆盖：
  - `orderedSidebarRows` 在 1 main + 2 pinned + 1 pending + 3 unpinned 时返回 7 行且顺序正确。
  - 新建 worktree 出现在 unpinned 段顶部（验证 `HierarchyManager.createWorktree` 的插入位置变更）。
  - Pin → 落 pinned 段尾；Unpin → 落 unpinned 段顶（验证 `HierarchyClient` 提供的位置变更，而不是隐式跟随 catalog）。
  - 段内拖拽（`reorderWorktrees(.pinned, from:, to:)`）改变 catalog 数组顺序。
- pending 生命周期通过 `gitWorktreeClient` 的 `createWorktreeStream` 测试值（可控的 `AsyncThrowingStream`）驱动：
  - begin → progress → finished → catalog 出现新行 + pending 移除。
  - begin → throw → pending 进 `.failed`。
  - failed → retry → success（同一 ID 跑两次）。
  - running → cancel → pending 移除 + effect 取消。
- Sheet 测试改为验证新 delegate 形状 `.beginCreate(spec)`；progress 区移除后保留对表单校验、目录预检的覆盖。

### 持久化

无 schema 变更。`reorderWorktrees` 落 `CatalogStore` 的同一条原子 rename 写盘路径。`pendingWorktrees` 不写盘。

### 多窗口

每个窗口的 `HierarchySidebarFeature` 独立实例，独立 `pendingWorktrees`。两窗口同时跑同一个 project 的 create，由 `wt sw` 自身的"目标目录已存在"检查兜底（赢家创建成功，输家在 stream 中收到 `branchExists` 或 `commandFailed`）。这是不引入跨窗口同步的取舍代价，与现有 sidebar selection 的"每窗口独立"完全对称。

### 可观测性

`os.Logger` 子系统 `com.gumpw.codans.app`，category `worktree-sidebar-order`：
- `info`：`reorderWorktrees(segment, from, to)`、`pin/unpin` 的位置变更、`pendingBegin / Finished`。
- `error`：`pendingFailed`，附 `GitWorktreeError` variant。

### 迁移

无。本设计对老用户的可见变更：
- 老 catalog.json 装出来后，第一次拖拽 / pin / unpin 才会改变数组顺序。
- 老安装 + 新版本启动时，无 pending 数据要恢复。

## Risks

| Risk | Mitigation |
|---|---|
| **段内顺序与 catalog 数组下标耦合"过死"。** 未来若要做"按 PR 状态排序"等隐式排序，与"用户拖拽过的顺序"会冲突。 | 隐式排序应作为渲染层的二次排序，**不**回写 catalog 数组。本设计只承诺"`Project.worktrees` 数组顺序 = pinned/unpinned 段内顺序"；任何其他派生顺序（PR 状态、最近活动）应在 `orderedSidebarRows` 之后再做一次 stable sort，且默认关闭。 |
| **拖拽期间 catalog 突变（reconcile 写入新 worktree、外部 `wt remove` 触发删除）会让 `IndexSet`-to-WorktreeID 解析失效。** | `reorderWorktrees` 闭包接受 `from: IndexSet, to: Int` 转成 `WorktreeID` 列表后再写回 `HierarchyManager`，由 manager 自检：若任一 ID 不再存在则丢弃整次重排，不部分应用。 |
| **新建 worktree 落 unpinned 段顶 vs 用户期望"末尾"** 的偏好分歧。 | 默认行为有 doc 记录；如果有真实用户反馈再加 settings 开关。先不加 — over-engineered defaults 是更大的成本。 |
| **Stream 取消未真正杀掉 `wt` 进程。** 若 `GitWorktreeClient.createWorktreeStream` 的 Process 不响应取消，cancel 会孤儿化子进程。 | 写测试：跑长任务（copy-ignored 大仓库），中途取消，断言 `wt` 进程已退出。`GitWorktreeClient.swift:343` 的注释声明支持外部取消，验证后才能依赖；若不支持则在 stream 的 `onTermination` 里显式 `Process.terminate()`。 |
| **`pendingFinished` 与 `pendingCancel` 的竞争**：用户在 `.finished` 即将派发的瞬间点 Cancel。 | catalog-append 走 sync MainActor reducer 步；cancel 与 finished 串行抵达 reducer。在 finished 步顶端加 guard `state.pendingWorktrees[id: id] != nil else { return .none }`，cancel 先到则 finished 成 no-op。 |
| **行 ID 碰撞**：`WorktreeID` 与 `PendingWorktreeID` 都基于 UUID，SwiftUI `ForEach` 行 identity 可能撞。 | `SidebarRow.id` 显式带 case 前缀（`"wt:<uuid>"` / `"pending:<uuid>"`），doc 中明确。 |
| **pending 行堆叠失控**：用户连续点 8 次 Create。 | 每个 project 软上限 8 条 pending；第 9 次提交时 sheet 里 banner 拒绝："等待已有创建任务完成。" |

## Open Items

- pending 行的失败原因是否在 tooltip / inspector 里完整显示原始 `GitWorktreeError`？目前设计只显示一行截断文案。倾向：实现时加 hover tooltip 展示完整 stderr。
- pinned 段是否暴露"按字母 / 按 PR / 按最近活动"的二次排序入口？倾向：不在 v1，留到有用户提需求。
- 是否在 sidebar 工具栏暴露"全部展开 / 全部收起 pending"开关？倾向：pending 是临时态，不开。
