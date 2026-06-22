# Design Doc: Main Window

**状态：** 已上线（可见）
**Author:** Gump (with Claude)

## Context and Scope

主窗口是两栏布局：左 **Sidebar**（扁平 Project 树 + 底部 footer），右 **Detail**（终端之上一行 **Header**，其下 **Tab 条** + 分屏 **Pane**）。能力与验收见 [Main-Window UI 产品规格](../product-specs/ui-main-window.md)。

层级为 `Catalog → Project → Worktree → Tab → Pane`（四级）。本文记录三个主窗口子系统——Sidebar、Header、Tab 条——各自的**耐久不变量与边界**，即"为什么这样拆、什么绝不能反过来做"。具体 SwiftUI 布局、像素值、reducer 全量 action 表不在此固化（实现可演进）。

相邻子系统的权威文档：

- 通知 / 未读上卷 / 状态栏铃铛：[notifications.md](notifications.md)。
- Tag 模型 / 单窗口 / Tag 过滤：[project-tags.md](project-tags.md)。
- Git Viewer（在外部 git 客户端打开）：[editor-integration.md](editor-integration.md) 的「Git Viewer」一节。

## Sidebar

`HierarchySidebarView` 渲染当前 Catalog 的**扁平 Project 列表**，每个 Project 是一个 section，其下列出 Worktree；底部钉一条 footer（`TagFilterPopoverFooter`），当前露出排序（reorder）与刷新两个动作。`HierarchySidebarFeature`（`@Reducer`）持有展开集合与瞬态 UI 状态（filter 状态、上下文菜单、确认对话框、stub sheet），并把行点击/变更经 `HierarchyClient` 转发。

### 不变量

- **结构数据直读 `@Environment(HierarchyManager.self)`，不进 TCA state。** `HierarchySidebarView` 从 `@Observable` 的 `HierarchyManager.catalog` 直接读 Project / Worktree 树，而非把它镜像进 reducer state。这是一个刻意的状态归属权衡：结构数据有单一事实来源（catalog），catalog 任意变更都经普通 SwiftUI observation 触发重渲染，reducer 不需要平行的 `.catalogChanged` 派发。reducer 只持有**交互意图**与瞬态 UI 状态。未读点的读取同理——直读 `InboxStore`（`@Observable`），它在每次 inbox 变更时 republish。

- **filter/选择编排必须在 intent 侧，先于 `selectXXX` 调用。** 任何"切换前先记下旧态、切换后再恢复新态"的编排（如 Tag filter 切换、Worktree 选择记忆）都必须坐在 **intent**（reducer 的 tap action）里、在调用 `hierarchyClient.selectXXX` / `setActiveTagFilter` **之前**完成。原因：selection 由 hierarchy client 的 selection **流**驱动，该流在 catalog **已经**变更之后才 yield——在流的 handler 里写"旧选择"为时已晚，旧态已从 snapshot 消失。把编排放在 intent 侧使意图与副作用共址，且 TestStore 可驱动。
  > 历史上这条不变量约束的是 Space-switch 编排（`spaceRowTapped` 写旧 Space 的 `lastActiveWorktreeID` 再 `selectSpace`）。Space 已移除（见 [project-tags.md](project-tags.md)），`lastActiveWorktreeID` 字段亦已删除——不要把它当现状。约束本身（"编排在 intent 侧、先于 select"）对 Tag filter 与 Project/Worktree 选择仍然成立。

- **Worktree 删除走确认对话框。** `removeWorktree` 会连带杀掉该 Worktree 全部 tab 的 pane 及其运行中进程——误点会丢失交互式 agent 会话。上下文菜单的 Remove 项先弹 `.confirmationDialog`，确认后才 `hierarchyClient.removeWorktree(...)`。

- **结构变更经 `HierarchyClient`，AppKit 副作用经各自 client。** reducer 自身不做 AppKit/NSWorkspace 调用：Finder 揭示走一个极小的 `FinderClient`（`NSWorkspace.activateFileViewerSelecting`），编辑器打开**不**由侧栏直接调 `EditorClient`，而是 delegate 上抛给父级 → `EditorFeature.openRequested`（见 Header 一节的"resolveDefault 单一来源"）。这让 reducer 保持纯净、TestStore 可驱动，且 AppKit 不渗入 reducer。

- **依赖方向：app → CodansCore，单向。** `FinderClient` 是 app 侧；`CodansCore` 永不 import AppKit。

### Tag filter（已实现，当前隐藏）

侧栏底部 footer 钉在 `.safeAreaInset(edge: .bottom)`。Tag 过滤入口（`TagFilterPopoverFooter` 的过滤按钮 + popover 内的 `TagFilterList`）已实现并保留接线：popover 列每个 `Tag` 一行 + 隐含 `[All]` / `[Untagged]`，点击切换 `Catalog.activeTagFilter`（多选 OR；`[Untagged]` 互斥，仅在存在无标签 Project 时出现）。但该过滤按钮**当前刻意隐藏**（`TagChipFooter.swift:49`）——footer 当前只露排序与刷新，过滤可在不重接调用点的前提下重新挂出。Tag 模型（`Tag` / `TagID` / `TagFilter` / `Project.tagIDs` / `Catalog.tags` / `Catalog.activeTagFilter`）、CRUD、迁移与 CLI 全在 [project-tags.md](project-tags.md)，本文不复述。

## Header

Header 是终端 Tab 条之上的一行，现仅承载两个控件：左侧只读 `⎇ branch` 标签、右侧 "Open in …" split button。它由一个 TCA feature（自 `RootFeature` scope）拥有，挂在 `WorktreeDetailView` 内 Header 原位，不改外层 split-view 结构。

> **Header 刻意收窄。** Header 不含通知铃铛，也不含任何 Git Viewer / Diff 切换按钮。通知未读由状态栏铃铛 popover 承载（[notifications.md](notifications.md)：状态栏铃铛是**唯一** popover 入口）。Git 相关入口不挂 Header：⌘⌥G / 菜单 / 命令面板 "Toggle Git Viewer" 启动用户在 Settings → General → Default Git Viewer 选定的**外部 git 客户端**（解析 `general.defaultGitViewerID`；选 None 或解析不出即 no-op）。应用内不再有内置 Git Viewer / diff 查看器（旧 overlay 已移除）——Git 查看交给外部客户端，机制见 [editor-integration.md](editor-integration.md) 的「Git Viewer」一节。下文只保留仍然成立的不变量。

### 不变量

- **`EditorFeature.resolveDefault` 是默认编辑器解析的单一来源。** 把 "project override → 全局默认 → Finder 兜底" 的解析链收到一个 `EditorFeature` 上的纯静态 helper：

  ```swift
  static func resolveDefault(
    projectOverride: EditorID?,
    globalDefault: EditorID?,
    descriptors: [EditorDescriptor]
  ) -> ResolvedDefault   // .editor(EditorDescriptor) | .finder
  ```

  split button 的标签与主动作派发**都**消费它，使两处永不漂移。**Cascade-on-missing**：若 project override 指向一个不在 `descriptors` 里的 id（如自定义编辑器被删），解析级联到全局默认，仅当 override 与全局都解析不出时才落到 `.finder`——避免在已配全局默认时把用户搁浅在 Finder。

- **Header 拥有自己的 TCA feature；编辑器打开经 delegate 上抛。** Header 不内嵌 `EditorClient`，而是 delegate 上抛 `.openRequested(editorID:…)`（`editorID: nil` = 用解析链）给 `RootFeature`，由后者转发进 `EditorFeature.openRequested`。这把 toast 接线（`EditorFeature.lastOpenResult` → `ContentView` toast）保持在单一站点，避免第二个调用点把该状态割裂。给 Header 独立 feature 而非塞进 `EditorFeature` 或 `RootFeature`，是为了让其 UI 状态（如分支区交互）有 reducer 拥有的单一入口、可独立子测试。

- **未读计数与（曾经的 Header）popover 行共用同一个 `PaneID → WorktreeID` 索引。** 凡是把未读按 Worktree 聚合的读取，都必须经同一个 `panelWorktreeIndex()` 派生的 `PaneID → WorktreeID` 索引：徽标计数与逐 Worktree 的行计数因此用同一套 orphan 排除策略——pane 已不在 catalog 的条目对二者都不计——所以徽标永不超过实际渲染的行数。这条不变量现由通知子系统持有：`NotificationInbox.totalUnread(in:)` / `notifications(forWorktree:in:)` 是同源实现（[notifications.md](notifications.md) §上卷/`RollupIndex`）。
  > 该索引最初服务于 Header 上的 bell badge + 分组 popover。bell 已迁到状态栏（[notifications.md](notifications.md)）；"计数与行共用一个索引、orphan 对二者一致排除"的约束随之迁移，但**约束本身未变**——任何重新引入逐 Worktree 未读聚合的表面都必须复用这个单一索引，而非自建第二份。

### Git diff 入口（无应用内查看器）

主窗口侧**不**持有任何 Git-Viewer-toggle 状态，Header 上也无对应按钮。旧的右缘 `GitViewer` overlay 已移除（其 `Worktree.gitViewerVisible` 字段、`HierarchyClient.setWorktreeGitViewerVisible`、`ContentView.resolveGVVisible` 等都已不复存在）。当前唯一的 Git diff 入口是 ⌘⌥G / 菜单 / 命令面板 "Toggle Git Viewer"，它解析 `general.defaultGitViewerID` 并启动一个**外部 git 客户端**（选 None 或解析不出即 no-op；`RootFeature.diffInspectorToggledForCurrentWorktree`）。

应用内不再有内置 diff/历史查看器——`apps/mac/codans/App/Features/Diff/` 不存在，`GitViewer` overlay 已从代码移除。落地的只有 `CommandID.toggleDiffInspector` 这个命令 id（其 JSON raw value 仍钉死为 `toggleGitViewer`，避免孤儿化用户的快捷键覆盖；见 [keyboard-shortcuts.md](keyboard-shortcuts.md)）。Git 查看的完整机制见 [editor-integration.md](editor-integration.md) 的「Git Viewer」一节。

## Tab Bar

终端 Tab 条是 Header 与 Pane 视口之间的一行 per-tab chip。`TabBarView` 渲染 chip（标题 + hover 揭示的关闭按钮 + active 顶部下划线），`TabBarFeature` 把每个 tab 操作（new / close / close-others / close-to-right / close-all / rename / reorder / select-by-index / select-adjacent / split）一行转发经 `HierarchyClient`。视图只经 `@Environment(HierarchyManager.self)` 读 catalog，只经 `store.send(…)` 派发，绝不直接够到 `HierarchyClient`。

### 不变量

- **`Tab` 保持 `Codable` 纯数据，分屏树用 `PaneID` 间接、不嵌 `NSView`。** `Tab`（`apps/mac/CodansCore/Tab.swift`）被逐字持久化进 `catalog.json`；`splitTree` 持有 `PaneID` 而非活的 `PaneView`/`NSView`。把 AppKit/SwiftUI 视图嵌进 `Tab` 会逼出一套独立持久化形态、把核心域模型耦合到 UI 类型，并堵死未来的 headless 用途。ID 间接每次渲染一次字典查找，在现实 tab 数下可忽略。

- **`Tab.icon` / `Tab.isDirty` 已实现，"纯文本"非目标已不成立。** 立项时刻意推迟了 `Tab` 上的 icon 与 dirty 字段（理由是"在 C3 hooks 引入自动写入者之前，没有竞争写入者去翻 isDirty / 锁标题"）。该推迟已被后续工作推翻：`Tab.icon` 与 `Tab.isDirty` 现已落在模型上并参与渲染。设计中任何"tabs remain text-only / no isDirty field"的旧表述均不再是现状。（per-pane 运行态的 runtime-only 表示见下条——那是 `HierarchyManager` 上的非持久 Set，与 `Tab.isDirty` 的持久字段是不同层。）

- **per-pane running/dirty 是 `HierarchyManager` 上的 runtime-only `Set<PaneID>`，永不持久化，各 teardown 路径清它。** chip 的"忙"指示源于该 wall-clock-live 的运行态集合；持久化它会泄漏陈旧的 spinner（重启后仍转）。每条拆除路径——`closePane` / `closeTab` / `tearDownWorktreeSurfaces`——都必须清理对应条目。同类的 `lastFocusedPaneByTab: [TabID: PaneID]`（`selectTab` 时据此恢复焦点，落到 split 树最左叶兜底）也是 runtime-only。

- **SwiftUI `@Observable` 不穿透 TCA client 闭包 → chip dirty 须经 `@Environment` 直读 `HierarchyManager`；休眠读用安全默认。** `@Observable` 的追踪不会穿过一个 TCA client 闭包，因此 chip 的 dirty 态必须直接经 `@Environment(HierarchyManager.self)` 读，而非经 client 返回值。配套地，`HierarchyClient.liveValue` 对休眠态的 `tabIsDirty` / `lastFocusedPane` 读取返回**安全默认 false/nil**（而非 `fatalError`），使关停期间渲染的 chip 保持惰性、不崩。

- **快捷键命名空间分层：⌘1–9 / ⌃⌘1–9 / ⌥⌘1–9。** tab 的 select-by-index 落在 **⌥⌘1–⌥⌘9**——因为 ⌘1–⌘9 与 ⌃⌘1–⌃⌘9 已分别占用（见下方漂移说明），且 ⌥⌘N 命名空间符合"层级越深、修饰键越深"的既有模式。⌘T new / ⌘W close / ⌘⇧[ / ⌘⇧] prev-next 经主菜单声明，使其在菜单栏可见、且在响应链上优先于 Ghostty 内部绑定（菜单绑定优先，是预期非 bug）。`selectAdjacentTab` 必须经 `selectTab` 路由（直接写 `selectedTabID` 会绕过焦点恢复，键盘切 tab 会丢掉记住的 pane）。
  > 漂移说明：tab-bar 旧文称 "⌘1–⌘9 已绑 Space 切换、⌃⌘1–⌃⌘9 绑 Worktree 跳转"。Space 已移除，⌘1–⌘9 现**刻意留空**未重新绑定（[project-tags.md](project-tags.md) §3.9），为将来"切到第 N 个 project"留位。⌃⌘1–⌃⌘9 的 Worktree 跳转保留。tab index 留在 ⌥⌘1–⌥⌘9 的结论不受影响（该命名空间仍空闲）。

- **重排用 snapshot-on-drop，不逐 tick 调 `moveTab`。** 拖拽重排在**落下**时一次性提交绝对顺序 `reorderTabs(orderedIDs:)`，而非每个指针 tick 调 `moveTab(offset:)`。后者每次触发一次持久化保存，且两个连续 tick 跨过同一中点时引入重排闪烁。snapshot-on-drop 更省、更易单测、且贴合 catalog 真正想要的变更形态。

- **active 用顶部下划线，不用填充背景。** active tab 用 2pt 顶部下划线指示，而非填充背景。填充背景会与 per-chip hover 态竞争（hover 任意 chip 都近似"选中"），削弱选中信号；细色下划线让 hover 词汇保持干净、在密集 tab 条中一眼可辨。

- **不建并行 `TabBarState`。** tab 是 hierarchy-scoped（每 Worktree）。另起一个 `@Observable TabBarState` 容器意味着同一数据两个事实来源，并在 create/close/select 周围引入同步危险。既有模式（视图读 `HierarchyManager`、reducer 经 `HierarchyClient` 转发）已可扩展；在 `HierarchyClient` 上多挂几个闭包的边际成本，低于长期协调两个 store 的成本。

- **`selectedTabID` 始终有效。** `closeOtherTabs` / `closeTabsToRight` / `closeAllTabs` 等批量关闭必须保证幸存 tab 的 `selectedTabID` 仍指向一个存在的 tab。这是 `HierarchyManagerTests` 的核心不变量。

### 错误策略

tab-bar 的副作用是同步 `try?` 调进 `HierarchyClient`：`.notFound(...)` 对未知 ID，未变更状态静默 no-op（不排保存）。错误经 `Logger("com.gumpw.codans.tab-bar")` 记录后吞掉——tab-bar 失败罕见且 dead-end。两个 runtime map（`paneRunning` / `lastFocusedPaneByTab`）按设计非持久，其余每个变更经共享的去抖 `CatalogStore.scheduleSave(catalog)` 落盘。

## Component Boundaries

| 组件 | 拥有 | 不拥有 |
|---|---|---|
| `HierarchySidebarFeature` | 展开集合、filter/popover/sheet 瞬态状态、上下文菜单派发、选择/filter 编排、delegate 上抛 | 编辑器打开副作用（delegate 给 EditorFeature）、Finder 揭示（经 FinderClient）、catalog 变更（经 HierarchyClient） |
| `HierarchySidebarView` | 视觉树、hover chrome、行点、底部 footer（排序/刷新；Tag 过滤已实现但当前隐藏） | 选择逻辑、catalog 状态（直读 `hierarchyManager.catalog`）、inbox 状态（直读 `inboxStore`） |
| Header feature | 分支标签 + Open-in split button 的 UI 状态、editor-open delegate 上抛 | 默认编辑器解析（`EditorFeature.resolveDefault` 单一来源）、通知（状态栏）、Git diff（⌘⌥G 走外部客户端；应用内 Diff inspector 待实现） |
| `TabBarFeature` | 把每个 tab 操作一行转发经 client；无状态 reducer | catalog 状态、运行态/焦点 map（在 HierarchyManager 上） |
| `HierarchyManager` | catalog 变更、`paneRunning` / `lastFocusedPaneByTab` runtime-only map、Tag CRUD | 各 feature 的 UI 状态 |
| `FinderClient` | `reveal(path:)` 经 NSWorkspace | 编辑器打开（不同 client） |

依赖方向：app → CodansCore，单向。`FinderClient` 与各 feature 在 app 侧；`CodansCore` 永不 import AppKit。

## 设计沿革（History）

本节仅记录改变了当前形态的承重转变，正文已按现状陈述、不再复述被取代或删除的中间态：

- **Space → Tag / 单窗口**（[project-tags.md](project-tags.md)，Approved）：`Space` / `SpaceID` / `CatalogWindow` 从域模型整体移除，层级 5→4 级。**已删除字段**：`Space.lastActiveWorktreeID`、`Space.selectedProjectID`、`CatalogWindow.selectedSpaceID`——切勿当现状。横切分类改由 `Tag` 承载；侧栏底部不再有 Space switcher（Tag 过滤已实现但当前隐藏，见上文 §Tag filter）；⌘1–⌘9 / ⌘K 解绑。
- **Git Viewer overlay 移除**：旧的右缘 `GitViewer` overlay 连同 Header 上的切换按钮一并移除；应用内不再有内置 diff 查看器，落地的只有 `CommandID.toggleDiffInspector` 命令 id。当前 ⌘⌥G / 命令面板 / 菜单的 "Toggle Git Viewer" 启动外部 git 客户端（机制见 [editor-integration.md](editor-integration.md)）。
- **通知铃铛不在 Header**（[notifications.md](notifications.md)）：未读以按层级上卷的徽标呈现，唯一 popover 入口是状态栏铃铛。

## References

- 产品规格：[ui-main-window.md](../product-specs/ui-main-window.md)
- Tag / 单窗口：[project-tags.md](project-tags.md)
- 通知 / 上卷 / 状态栏铃铛：[notifications.md](notifications.md)
- Git Viewer（外部 git 客户端）：[editor-integration.md](editor-integration.md)
- 键盘快捷键统管：[keyboard-shortcuts.md](keyboard-shortcuts.md)
- 层级 / catalog：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane,SplitTree}.swift`
- 层级变更面：`apps/mac/codans/App/Clients/HierarchyClient.swift`
- 主窗口 feature：`apps/mac/codans/App/Features/{HierarchySidebar,WorktreeHeader,TabBar}/`
