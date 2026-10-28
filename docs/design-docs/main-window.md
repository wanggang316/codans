# Design Doc: Main Window

**状态：** 已上线（可见）
**Author:** Gump (with Claude)

## Context and Scope

主窗口是两栏布局：左 **Sidebar**（扁平 Project 树 + 底部 footer），右 **Detail**（窗口工具栏 **Header**，内容区为 Worktree 的 split 树，叶子是 **Pane**，每个 Pane 自带一条 **Tab 条**）。

层级为 `Catalog → Project → Worktree → Pane → Tab`（四级，Content 是 Tab 的载荷）。本文记录 Sidebar 与 Header 两个主窗口子系统的**耐久不变量与边界**，即"为什么这样拆、什么绝不能反过来做"；Pane 布局与 Tab 条归 [pane-layout.md](pane-layout.md)。具体 SwiftUI 布局、像素值、reducer 全量 action 表不在此固化（实现可演进）。

相邻子系统的权威文档：

- 通知 / 未读上卷 / 状态栏铃铛：[notifications.md](notifications.md)。
- Tag 模型 / 单窗口 / Tag 过滤：[project-tags.md](project-tags.md)。
- 内置只读 Changes / Outgoing：[git-diff-viewer.md](git-diff-viewer.md)。
- Git Viewer（内置或外部客户端）：[editor-integration.md](editor-integration.md) 的「Git Viewer」一节。

## Sidebar

`HierarchySidebarView` 渲染当前 Catalog 的**扁平 Project 列表**，每个 Project 是一个 section，其下列出 Worktree；底部钉一条 footer（`TagFilterPopoverFooter`），当前露出排序（reorder）与刷新两个动作。`HierarchySidebarFeature`（`@Reducer`）持有展开集合与瞬态 UI 状态（filter 状态、上下文菜单、确认对话框、stub sheet），并把行点击/变更经 `HierarchyClient` 转发。

**Project 行。** git Project 的行不可选中：点整行或行右侧悬停出现的 `>` 箭头开合其 Worktree 行，主检出（星标）是第一个子行。没有自己仓库的 Project——普通文件夹、远程文件夹、workspace——的行就是它的根目录（`Project.rowWorktree`：`path == rootPath` 的合成 worktree）：行打上该 worktree 的 tag，与 worktree 行一样可选中、打开终端，并承载它的忙碌转圈、未读铃铛、⌃N 与右键菜单；它下面不再列根目录行，于是文件夹没有子行，workspace 只列检出目录，开合只能用箭头。⌃1…⌃0 与 ⌘⌃↑ / ⌘⌃↓ 共用 `Catalog.sidebarSelectionOrder`：按侧栏的 Tag 过滤与排序，只数屏幕上的可选行（折叠 Project 的子行、加载失败的 Project 不计）；揭示（palette、通知跳转、Agents 面板）选中的若是 Project 行自身，不展开该 Project。

### 不变量

- **结构数据直读 `@Environment(HierarchyManager.self)`，不进 TCA state。** `HierarchySidebarView` 从 `@Observable` 的 `HierarchyManager.catalog` 直接读 Project / Worktree 树，而非把它镜像进 reducer state。这是一个刻意的状态归属权衡：结构数据有单一事实来源（catalog），catalog 任意变更都经普通 SwiftUI observation 触发重渲染，reducer 不需要平行的 `.catalogChanged` 派发。reducer 只持有**交互意图**与瞬态 UI 状态。未读点的读取同理——直读 `InboxStore`（`@Observable`），它在每次 inbox 变更时 republish。

- **filter/选择编排必须在 intent 侧，先于 `selectXXX` 调用。** 任何"切换前先记下旧态、切换后再恢复新态"的编排（如 Tag filter 切换、Worktree 选择记忆）都必须坐在 **intent**（reducer 的 tap action）里、在调用 `hierarchyClient.selectXXX` / `setActiveTagFilter` **之前**完成。原因：selection 由 hierarchy client 的 selection **流**驱动，该流在 catalog **已经**变更之后才 yield——在流的 handler 里写"旧选择"为时已晚，旧态已从 snapshot 消失。把编排放在 intent 侧使意图与副作用共址，且 TestStore 可驱动。

- **Worktree 删除走确认对话框。** `removeWorktree` 会连带杀掉该 Worktree 全部 Pane 上全部 Tab 的会话及其运行中进程——误点会丢失交互式 agent 会话。上下文菜单的 Remove 项先弹 `.confirmationDialog`，确认后才 `hierarchyClient.removeWorktree(...)`。

- **结构变更经 `HierarchyClient`，AppKit 副作用经各自 client。** reducer 自身不做 AppKit/NSWorkspace 调用：Finder 揭示走一个极小的 `FinderClient`（`NSWorkspace.activateFileViewerSelecting`），编辑器打开**不**由侧栏直接调 `EditorClient`，而是 delegate 上抛给父级 → `EditorFeature.openRequested`（见 Header 一节的"resolveDefault 单一来源"）。这让 reducer 保持纯净、TestStore 可驱动，且 AppKit 不渗入 reducer。

- **依赖方向：app → CodansCore，单向。** `FinderClient` 是 app 侧；`CodansCore` 永不 import AppKit。

### 快速分类过滤

侧栏顶部使用胶囊按钮提供 All、Remote、Workspace、Pin、PR。选中项显示图标和名称，其他项仅显示图标并提供 tooltip。Remote 包含 SSH 项目；Pin 复用 Worktree 的置顶状态，仅显示未归档的置顶行及其父项目；PR 使用当前 GitHub 快照，仅显示已匹配到 PR 的未归档 Worktree 及其父项目。PR 数据刷新时同步更新列表和快捷键导航，筛选期间禁止 Worktree 拖拽排序。分类与 Tag 过滤取交集，导航快捷键使用同一结果。分类保存在 Catalog，旧配置默认 All。项目排序期间展示完整列表并禁用分类切换。

### Tag filter（已实现，当前隐藏）

侧栏底部 footer 钉在 `.safeAreaInset(edge: .bottom)`。Tag 过滤入口（`TagFilterPopoverFooter` 的过滤按钮 + popover 内的 `TagFilterList`）已实现并保留接线：popover 列每个 `Tag` 一行 + 隐含 `[All]` / `[Untagged]`，点击切换 `Catalog.activeTagFilter`（多选 OR；`[Untagged]` 互斥，仅在存在无标签 Project 时出现）。但该过滤按钮**当前刻意隐藏**（`TagChipFooter.swift`）——footer 当前只露排序与刷新，过滤可在不重接调用点的前提下重新挂出。Tag 模型（`Tag` / `TagID` / `TagFilter` / `Project.tagIDs` / `Catalog.tags` / `Catalog.activeTagFilter`）、CRUD、持久化和接口边界 全在 [project-tags.md](project-tags.md)，本文不复述。

## Header

Header 由 `WorktreeDetailView.worktreeToolbarContent` 组装到窗口工具栏：左侧 `WorktreeHeaderInfoLabel` 显示 Worktree 身份、分支与 GitHub 信息；中部依次为 New Agent 按钮、状态、独立通知铃铛；右侧依次为 Run Script、Open。创建 Worktree 时使用相同工具栏槽位显示占位内容，避免控件身份随模式切换而重建；New Agent 按钮与铃铛不依赖 Worktree 数据，两种模式下都保持可用。

Header 不显示前台进程计数与进程列表 popover（已移除）。`HierarchyManager.processEntries(in:)` 等进程追踪仍保留，Tab 悬停卡片用它显示当前运行的进程（[worktree-processes.md](worktree-processes.md)）。

> **入口边界。** 通知铃铛是工具栏中独立于状态组的控件，承载通知 popover（[notifications.md](notifications.md)）。Worktree 右键菜单的 “Show Changes” 打开该 Worktree 的独立只读窗口，不切换主窗口选择；主窗口工具栏不单独放置 Diff 入口。菜单和命令面板也提供 “Show Changes”。⌘G / “Toggle Git Viewer” 解析 `general.defaultGitViewerID`：默认 Built-in 打开内置窗口，选择外部客户端则打开该客户端。缺省、`null` 和未知 ID 回退 Built-in。

### New Agent 对话框

New Agent 按钮（`HeaderNewAgentButton`，`plus.bubble` 加彩色渐变，无下拉）、⌘⇧N（`CommandID.newAgent`，File 菜单 “New Agent…”）和命令面板的 “New Agent…” 都发送 `RootFeature.newAgentRequested`，以 sheet 打开 `NewAgentView`（`NewAgentFeature`，`@Presents` 于 `RootFeature.newAgent`，由独立的 `newAgentReducer` 处理）。布局自上而下：

- **Project › Worktree** 选择器与右侧的 Worktree Options 开关（`switch.2`）。Project 默认为当前选中项目；没有项目时换成与侧栏 `+` 相同的 Add Project 菜单。文件夹和 workspace 项目只有一个工作位置，不显示 Worktree 选择器。Git 项目的 Worktree 选择器默认 “New Worktree”，也可选本地或远程分支。
- **Branch name** 与 **Worktree Options**（Base ref、Fetch origin、Copy ignored / untracked），只在 “New Worktree” 时出现，Options 默认收起。这部分就是内嵌的 `CreateWorktreeFeature`，默认值（`CreateWorktreeFeature.State.seeded`）、校验和分支冲突提示与 Create Worktree sheet 共用一份实现。
- **Prompt** 输入框，底部为 Agent 菜单（默认第一个可用 profile，过滤规则同 `AgentInstallationStore.offeredProfiles`）和发送按钮（Return / ⌘↩）。

发送的结果由 `RootFeature` 执行：

| 目标 | 结果 |
|---|---|
| New Worktree | 走侧栏 pending 创建流程；`PendingWorktree.launchAgentProfileID` / `launchAgentPrompt` 在 Worktree 落地（setup 脚本跑完）后经 `worktreeMaterialized` 启动 agent |
| 已被某个可见 Worktree 检出的分支（本地或对应的远程分支） | 选中该 Worktree，直接以 prompt 启动 agent |
| 没有 Worktree 的本地分支 | 以 `pathOverride` 检出到新 Worktree 后启动 agent；SSH 项目不提供 |
| 本地不存在的远程分支（`origin/x`） | 从该远程分支新建本地分支 `x` 的 Worktree 后启动 agent |
| 文件夹 / workspace 项目 | 在其唯一 Worktree 中启动 agent |

prompt 经 profile 的 `promptStyle` 拼进启动命令；空 prompt 只启动 agent。

未发送就关闭时，`RootFeature.newAgentDraft` 保留对话框的选择（项目、目标、分支名、选项、agent、prompt），下次打开时恢复；发送后清空。草稿只在内存中，App 重启即丢弃。依赖已加载分支信息的部分（base ref、分支名校验、已选分支）在选项加载完成后恢复，已不存在的 base ref 或分支回落到默认值。

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

- **未读计数与通知 popover 行共用同一个 `ContentID → WorktreeID` 索引。** 凡是把未读按 Worktree 聚合的读取，都必须经同一个 `panelWorktreeIndex()` 派生的 `ContentID → WorktreeID` 索引：徽标计数与逐 Worktree 的行计数因此用同一套 orphan 排除策略——Content 已不在 catalog 的条目对二者都不计——所以徽标永不超过实际渲染的行数。这条不变量现由通知子系统持有：`NotificationInbox.totalUnread(in:)` / `notifications(forWorktree:in:)` 是同源实现（[notifications.md](notifications.md) §上卷/`RollupIndex`）。

### Git diff 入口与状态

`RootFeature` 将打开请求交给 `DiffWindowManager`，每个 Worktree 复用一个独立的普通 `NSWindow` 和 `DiffFeature` store。主窗口切换 Worktree 不改变已打开的 Diff 窗口。开关 Diff 不改变终端布局；关闭窗口停止刷新并释放 WebView，重开恢复比较范围、文件选择和窗口位置。

“Show Changes” 是菜单、命令面板及 Worktree 右键菜单中的内置窗口入口。Changes 默认展示全部当前变更（含未跟踪文件）；Outgoing 比较目标分支与 HEAD 的共同祖先到 HEAD 的已提交改动。比较范围、基准和文件选择按 Worktree 在当前应用会话中保留；可见期间每两秒刷新本地 Git 状态，不自动 fetch。

代码通过独立的 `DiffViewKit`（WKWebView + Web Diff 组件）渲染。该组件只收发文档和事件；Git 查询、路径校验和编辑器打开由 Codans 拥有。面板只读，不提供暂存、丢弃、提交或编辑操作。接口和边界见 [git-diff-viewer.md](git-diff-viewer.md)。

外部入口 “Toggle Git Viewer” 保留 `CommandID.toggleDiffInspector` 及 JSON raw value `toggleGitViewer`，继续调用 `RootFeature.diffInspectorToggledForCurrentWorktree`，按设置打开 Built-in 独立窗口或外部客户端。见 [editor-integration.md](editor-integration.md) 和 [keyboard-shortcuts.md](keyboard-shortcuts.md)。

## Tab Bar

Tab 条不是 Worktree 级的一行，而是**每个 Pane 自带一条**：Worktree 的内容区是一棵 split 树，叶子是 Pane，每个 Pane 在自己的内容区顶部渲染一条胶囊 tab 条，列出它持有的 Tab 并显示选中的那一个。焦点 Pane 的条用活动样式，其余 Pane 的条用非活动窗口样式；⌘T / ⌘W / ⌘1…⌘0 / ⌘⇧[ / ⌘⇧] 作用于焦点 Pane 的条，分屏命令新建 Pane。`TabBarView` 仍是胶囊 tab 条的实现（视觉对齐 AppKit 的 macOS 26 window-tabbing 条、溢出堆叠、新建 / 关闭动画、snapshot-on-drop 重排），`TabBarFeature` 把条上的每个操作一行转发经 `HierarchyClient`；chip 的忙碌、进度、徽标与实时标题来自该 Tab 的 `TabChrome`，不在 `HierarchyManager` 上。

模型、不变量（Pane 永不为空、`selectedTabID` 始终有效、`focusedPaneID` 一致）、焦点与选中、条尾控件与窄 Pane 的折叠规则、关闭确认、拖拽分期，以及 catalog v5 的 Tab 条目形状，统一见 [pane-layout.md](pane-layout.md)；键盘绑定见 [keyboard-shortcuts.md](keyboard-shortcuts.md)。

## Component Boundaries

| 组件 | 拥有 | 不拥有 |
|---|---|---|
| `HierarchySidebarFeature` | 展开集合、filter/popover/sheet 瞬态状态、上下文菜单派发、选择/filter 编排、delegate 上抛 | 编辑器打开副作用（delegate 给 EditorFeature）、Finder 揭示（经 FinderClient）、catalog 变更（经 HierarchyClient） |
| `HierarchySidebarView` | 视觉树、hover chrome、行点、底部 footer（排序/刷新；Tag 过滤已实现但当前隐藏） | 选择逻辑、catalog 状态（直读 `hierarchyManager.catalog`）、inbox 状态（直读 `inboxStore`） |
| `WorktreeDetailView` / Header feature | 工具栏布局、Worktree 身份、New Agent 入口、状态与进程入口、Run / Open 操作及 delegate | 默认编辑器解析（`EditorFeature.resolveDefault`）、通知数据（InboxStore）、Git diff 状态（DiffFeature） |
| `DiffFeature` / `DiffPanelView` | 只读比较范围、文件选择、请求生命周期、可见期刷新及独立窗口 | Git 命令执行（GitServiceClient）、编辑器启动（DiffEditorClient）、终端会话所有权 |
| `TabBarFeature` | 把各 Pane 条上的每个 Tab 操作一行转发经 client；无状态 reducer | catalog 状态、内容活体状态（在 `ContentRuntime` / `TabChrome` 上） |
| `HierarchyManager` | catalog 变更、结构性运行态（焦点 Pane、选中 Tab）、Tag CRUD | 各 feature 的 UI 状态、内容活体状态与 surface（归 `Runtime/Content/`） |
| `FinderClient` | `reveal(path:)` 经 NSWorkspace | 编辑器打开（不同 client） |

依赖方向：app → CodansCore，单向。`FinderClient` 与各 feature 在 app 侧；`CodansCore` 永不 import AppKit。

## References

- Tag / 单窗口：[project-tags.md](project-tags.md)
- 通知 / 上卷 / 状态栏铃铛：[notifications.md](notifications.md)
- 内置 Changes / Outgoing：[git-diff-viewer.md](git-diff-viewer.md)
- Git Viewer（外部 git 客户端）：[editor-integration.md](editor-integration.md)
- 键盘快捷键统管：[keyboard-shortcuts.md](keyboard-shortcuts.md)
- Pane 布局 / Tab 条 / 内容运行时：[pane-layout.md](pane-layout.md)
- 层级 / catalog：`apps/mac/CodansCore/`（Catalog、Project、Worktree、Pane、Tab、ContentSnapshot、SplitTree）
- 层级变更面：`apps/mac/codans/App/Clients/HierarchyClient.swift`
- 主窗口 feature：`apps/mac/codans/App/Features/{HierarchySidebar,WorktreeHeader,TabBar}/`
