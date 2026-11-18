# Design Doc: Pane Layout

**Availability:** Available (Place, the Place picker). Planned: animated transitions (#547). Arrange, the Layout picker, and Pane numbers are described in [Keyboard Shortcuts](keyboard-shortcuts.md).
**Author:** superada2026
**Implementation:** [`SplitTree.placing`](../../apps/mac/CodansCore/SplitTree.swift), [`PlaceRegion`](../../apps/mac/CodansCore/PlaceRegion.swift), [`HierarchyManager.placePane`](../../apps/mac/codans/Runtime/HierarchyManager.swift), [`PaneActionRouterFeature`](../../apps/mac/codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift), [`PlacePickerFeature`](../../apps/mac/codans/App/Features/PlacePicker/PlacePickerFeature.swift)

## Context and Scope

一个 Tab 的 Pane 排在一棵 split tree 里（`Tab.splitTree`）。此前用户只能一次改一个 split：先 split，再拖分隔条。Pane layout 给出窗口管理器式的操作，术语见 [GLOSSARY — Pane layout](../../GLOSSARY.md#pane-layout)。本文记录已实现的 **Place** 与 **Place picker**（[ADR 0013](../adr/0013-place-opens-a-picker-with-no-region-chords.md)）；过渡动画（[ADR 0011](../adr/0011-layout-transitions-resize-terminals-once.md)）在后续工单补充。

## Goals and Non-Goals

Goals：

- 一条命令把聚焦 Pane 放进当前 Tab 的一个区域：左 / 右 / 上 / 下半，左 / 中 / 右三分之一与上 / 中 / 下三分之一，左 / 右与上 / 下三分之二，共 14 个区域。
- 其他 Pane 在剩余区域里保持相对结构。
- 每个区域是可重绑的命令，出现在 Command Palette、Window ▸ Layout 与 Pane 的 Layout 子菜单。

Non-Goals：四分之一（角落）区域；单独的最大化区域（zoom 就是最大化）；撤销；CLI / IPC 动词；跨 Tab 移动 Pane。

## Design

### Overview

Place 是 `CodansCore` 里的纯 split-tree 变换 `SplitTree.placing(_:in:)`，与 `inserting` / `moving` / `resizing` 并列。它不创建、不关闭 Pane，所以 leaf 集合不变，surface 不重建，终端会话一直存活。

结果是区域方向上的一个根 split：

| 区域位置 | 根 split |
|---|---|
| 前（左 / 上） | `split(dir, span, 聚焦 Pane, rest)` |
| 后（右 / 下） | `split(dir, 1 − span, rest, 聚焦 Pane)` |
| 中（中三分之一） | `split(dir, 1/3, rest.left, split(dir, 1/2, 聚焦 Pane, rest.right))` |

`rest` 是去掉聚焦 Pane 后的旧树（`Node.removing` 会折叠单子 split），其他 Pane 的子树原样保留。`span` 为 1/2、1/3 或 2/3。

- **只改 ratio。** 树已是目标形状时，同一构造给出同一棵树，只有 ratio 变化；Place 两次与一次结果相同。
- **中三分之一。** 需要两侧都有 Pane：`rest` 在其根 split 处一分为二，前一半去前三分之一，后一半去后三分之一。两部分各自的子树不变，只有两部分之间的接缝取区域方向：根 split 与区域方向垂直时，这两部分从叠放变为并排，原根 split 的 ratio 由 1/3 的布局取代——中间区域本身要求两侧各有一部分，无法保留它。`rest` 只有一个 Pane 时无法分成两侧（split tree 没有空白区域），这时形状不变、只结束 zoom；命令仍照常列出，与其他区域一致。
- **Zoom。** Place 先结束 zoom：结果树的 `zoomed` 为 `nil`。
- **单 Pane Tab。** 忽略 Place，不报错，树（含 zoom）不变。

### 路由

```
Place picker（⌘⌥K）────────────→ RootFeature.closePlacePicker → .place(region)
Window ▸ Layout / 用户绑定的和弦 ─→ RootFeature.placeFocusedPaneInCurrentTabRequested(region)
Command Palette ─────────────────→ RootFeature.route(.paneAction(.place(region)))
终端右键 / Header 操作菜单 ──────→ GhosttySurfaceView.onPaneAction(.place(region))
                                      │
                                      ▼
            PaneActionRouterFeature: .place(region)  (Pane < 2 → no-op)
                                      │
Pane 右键菜单 Layout 子菜单 ──→ PaneContextMenuModel.place(in:)  (Pane < 2 → disabled)
                                      │
                  HierarchyClient.placePane → HierarchyManager.placePane
                                      │
                  CatalogStore.scheduleSave  +  focusSurfaceView(同一 Pane)
```

菜单与快捷键按 `lastFocusedPane`（无则第一个 leaf）解析聚焦 Pane，与 Focus Pane Left 等命令相同。Command Palette 只在聚焦精确且 Tab 有两个及以上 Pane 时列出 Place（见 [Command Palette](command-palette.md)）。

### Place picker

`⌘⌥K`（`CommandID.placePane`，Settings → Shortcuts 中为 "Place Pane…"，可改键）在当前 Tab 的 split viewport 上打开 Place picker。它与 Layout picker（`⌘⌥L`）是两个 overlay，共用同一个卡片外壳（`PickerOverlay`、`PickerCell`、`PickerThumbnail`）与方向键网格（`PickerGrid`），外观与按键一致；同一时间只开其中一个，打开一个会关闭另一个。

- **区域与按键。** 每个区域一个缩略图，键固定：`1` 左半、`2` 右半、`3` 上半、`4` 下半、`5` 左三分之二、`6` 右三分之二、`7` 上三分之二、`8` 下三分之二、`9` 左三分之一、`A` 右三分之一、`B` 上三分之一、`C` 下三分之一、`D` 中三分之一（列）、`E` 中三分之一（行）。字母不分大小写。每行四个。
- **中三分之一。** `D` / `E` 需要三个及以上 Pane（中间区域两侧各要有 Pane），两个 Pane 时不显示；其他区域的键不变（`PlacePickerFeature.canFill`）。
- **缩略图。** 画出 Place 之后的 Tab：用 `SplitTree.placing` 作用于打开时的 split tree，聚焦 Pane 的区域着色，各区域标出 Pane 编号。picker 不含布局逻辑。
- **按键。** 卡片只接收已显示区域的键（`State.acceptedKeys`，字母含大小写），其他键不处理。区域键立即放置并关闭；方向键移动选中项（←→ 只在本行、↑↓ 只在本列，不回绕），Return 应用选中项；Esc、点击卡片外或再按一次 `⌘⌥K` 关闭且不改变布局。
- **焦点与 Tab。** 卡片打开时持有键盘焦点，关闭后焦点回到聚焦 Pane 的 surface。picker 绑定打开它的 Tab，规则同 Layout picker：切到其他 Tab 或 Worktree 时关闭且不改变布局。只有一个 Pane 的 Tab 不打开，也不报错。
- **路由。** `RootFeature.placePickerToggle(PaneID?)` 打开 `PlacePickerFeature`，来源为 `nil`（主菜单）时取当前 Tab 的聚焦 Pane；应用时经 `PaneActionRouterFeature` 的 `.place(region)`。入口：Window ▸ Layout 与 Pane 右键菜单（`PaneContextMenu`）Layout 子菜单中 Arrange… 之后的 "Place…"（显示生效和弦，单 Pane Tab 中禁用），终端右键菜单与 Pane Header 操作菜单 Layout 子菜单顶部的 "Place…"（`PaneActionRequest.openPlacePicker`），以及 Command Palette 的 "Place…"（`CommandPaletteItem.Kind.openPlacePicker`，出现条件同 Place 项）。

### 快捷键

每个区域一个 `CommandID`（`CommandID.place(_:)`），Settings → Shortcuts 中标题为 "Place in <区域>"，都没有默认和弦（[ADR 0013](../adr/0013-place-opens-a-picker-with-no-region-chords.md)，取代 ADR 0012）：Place 从 Place picker、Command Palette 与 Layout 菜单打开，用户可为常用区域自行绑定。Select Previous / Next Worktree 保持 `⌃⌘↑` / `⌃⌘↓`。

Layout 子菜单有两处：

- Window ▸ Layout 与 Pane 右键菜单（`PaneContextMenu`）的 Layout 子菜单，依次列出 Arrange…、Place…、全部 Place 区域、Focus Pane 1…9，并显示生效和弦。右键菜单作用于所点的 Pane；单 Pane 的 Tab 中 Place 项禁用。
- 终端 surface 的右键菜单与 Pane 卡片 Header 的操作菜单（`GhosttySurfaceView.addPaneActionItems`）在拆分项后有一个 Layout 子菜单：先是 Place…（`PaneActionRequest.openPlacePicker`，经 router 的 `placePickerRequested` delegate 打开所点 Pane 的 Place picker），再是全部 Place 区域。它由 Runtime 构建，显示的和弦来自 app 注入的 `TerminalEngine.menuKeyEquivalent`（读 `ShortcutsStore.resolved`），Runtime 不直接读快捷键注册表。

### Data Storage

结果是一棵普通 split tree，与其他 split 一样经 `CatalogStore.scheduleSave` 写入 `catalog.json`，重启后保留。无新的持久化状态。

## Cross-Cutting Concerns

- **测试。** `SplitTreePlaceTests`：每个区域 × 三种起始形状 × 每个聚焦 Pane，leaf 集合、相对结构、只改 ratio、清除 zoom、单 Pane 不变。`PaneActionRouterFeatureTests` 覆盖路由与单 Pane 忽略；`HierarchyManagerTests` 覆盖持久化；`ShortcutSchemaAuditTests` 覆盖默认和弦（Place 无默认、无重复、无 `⌃⌥`、Worktree 前后切换仍为 `⌃⌘↑/↓`）；`PlacePickerFeatureTests` 覆盖 Place picker 的按键、隐藏的中三分之一与方向键；`RootFeatureTests` 覆盖打开、应用、取消、焦点归还与两个 picker 互斥；`PaneContextMenuTests` 覆盖右键菜单的 Place 与 Place…；`ShortcutDisplayTests` 覆盖菜单显示的生效和弦；`CommandPaletteItemsTests` 覆盖 Palette 的出现条件。
