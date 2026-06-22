# Product Spec: Main-Window UI

**状态：** 已上线（可见）
**Author:** Gump (with Claude)

## Summary

codans 的主窗口是一个两栏布局：左侧 **Sidebar** 列出全部 Project 及其 Worktree，底部钉一条 footer（当前提供排序 / 刷新）；右侧 **Detail** 区在终端之上有一行 **Header**，显示当前分支与一个 "Open in …" split button。终端本体（Tab 条 + 分屏 Pane）在 Header 之下。

本规格描述可观测行为与需求。它定义：侧栏如何呈现 Project / Worktree、底部 footer 提供什么、Header 承载什么、未读状态在 UI 何处出现，以及用户可控的策略。实现选择见 [main-window 设计文档](../design-docs/main-window.md)。

层级为 `Catalog → Project → Worktree → Tab → Pane`（四级，无 Space 容器；Project 通过 `Tag` 标签做横切分类，见 [project-tags.md](../design-docs/project-tags.md)）。

## Layout Overview

```
┌───────────────────────┬──────────────────────────────────────────────────────┐
│                       │ Header                                               │
│ + Add Project    [⋯]  │ ┌─────────────┬──────────────────────┬─────────────┐ │
│                       │ │ ⎇ branch    │                      │ ↗ Open in ▾ │ │
│ ▼ Project A   [+] [⋯] │ └─────────────┴──────────────────────┴─────────────┘ │
│    ● main             │ ┌──────────────────────────────────────────────────┐ │
│    ○ feature/login    │ │ Tab 1   Tab 2   Tab 3   +                        │ │
│    ○ fix/crash        │ ├──────────────────────────────────────────────────┤ │
│                       │ │                                                  │ │
│ ▼ Project B   [+] [⋯] │ │                   Terminal Panes                 │ │
│    ● main             │ │              (split horizontal/vertical)         │ │
│                       │ │                                                  │ │
│ ▶ Project C           │ │                                                  │ │
│                       │ │                                                  │ │
│───────────────────────│ └──────────────────────────────────────────────────┘ │
│              ⇅      ⟳ │                                                      │
└───────────────────────┴──────────────────────────────────────────────────────┘
   Sidebar (leading)                     Detail (trailing)
```

Legend: `●` active Worktree, `○` inactive Worktree, `[+]` hover-only add, `[⋯]` options menu，`⇅` 排序（reorder）、`⟳` 刷新——侧栏底部 footer 当前露出的两个动作。Tag 过滤入口已实现但当前隐藏（见下文）。

注：通知铃铛**不在** Header 上。未读通知通过状态栏铃铛 + popover 呈现（见 [notifications.md](notifications.md)）；Git 相关入口也不挂 Header——⌘⌥G / 命令面板 "Toggle Git Viewer" / 菜单启动用户选定的**外部 git 客户端**（Settings → General → Default Git Viewer），应用内的 **Diff inspector 尚未实现**（前瞻设计见 [diff-inspector.md](../design-docs/diff-inspector.md)）。

## User Stories

- 作为多 Project 开发者，我想在一棵树里看到全部 Project 与 Worktree，从而无需翻菜单就能切 Worktree。
- 作为给 Project 打多重标签的用户（`#client-acme` / `#urgent` / `#archive`），我想要一个 Tag filter，从而把视图收窄到我关心的那一组 Project。（该过滤已实现，但当前从侧栏 footer 隐藏——见下文。）
- 作为驱动多 Worktree 的开发者，我想在 Detail 顶部始终看到当前分支名，从而永远不会忘记终端在哪条分支上。
- 作为在终端与编辑器间来回跳的用户，我想要 Header 上一个一键 "Open in …" 按钮 + 编辑器选择器，从而无需复制路径就能把 Worktree 交给编辑器。
- 作为在别处添加了磁盘上 git 仓库的用户，我想在侧栏有一个内联入口，从而无需离开窗口就能添加 Project 或 Worktree。

## Sidebar in Detail

```
┌──────────────────────────┐
│ + Add Project      [⋯]   │ ← sidebar toolbar
├──────────────────────────┤
│ ▼ Project A   [+] [⋯]    │ ← Project section header（colored dots = tags）
│    ● main           ●    │ ← active Worktree（filled dot）
│    ○ feature/login       │   trailing dot = unread notification
│    ○ fix/crash       ●   │
│                          │
│ ▼ Project B   [+] [⋯]    │
│    ● main                │
│                          │
│ ▶ Project C              │ ← collapsed
│                          │
├──────────────────────────┤
│              ⇅        ⟳  │ ← footer：排序（reorder）+ 刷新
└──────────────────────────┘
```

侧栏 body 是一个**扁平的 Project 列表**（无 Space 分组），每个 Project 是一个可折叠 section，其下列出该 Project 的 Worktree。Project 名后跟彩色圆点——每个分配的 Tag 一个，超过 3 个以 "+N" 收口。

底部的 **footer** 钉在侧栏底部（`.safeAreaInset`），当前露出两个动作：排序（进入 / 退出内联重排会话）与刷新（手动重跑 project 协调器以拾取 out-of-band 变更）。它匹配 macOS 侧栏惯例（System Settings、Mail），让顶边保持干净。

**Tag filter 当前隐藏。** 一个按 Tag 收窄 Project 列表的过滤器已实现并保留接线（`TagFilterPopoverFooter` 的过滤按钮 + popover 内的 `TagFilterList`），但其触发按钮当前从 footer **刻意隐藏**（`TagChipFooter.swift:49`）。重新挂出后的行为：

```
┌──────────────────────────────────────────────┐
│ [All] [● client-acme] [● urgent] [Untagged]  │
└──────────────────────────────────────────────┘
```

- 每个 Tag 一行，外加隐含的 `[All]` 与 `[Untagged]`。点击切换它在 `Catalog.activeTagFilter` 中的成员资格（多选 OR）。
- `[All]` 清除 filter；`[Untagged]` 互斥（选它会取消所有 Tag），且仅当至少一个 Project 无标签时才出现。

## Header in Detail

```
┌─────────────────────────────────────────────────────────────────┐
│  ⎇  feature/login                              ↗ Open in ▾       │
└─────────────────────────────────────────────────────────────────┘
   └── read-only branch label                    └─ split button + picker caret
```

Header 只承载两样：左侧只读分支标签，右侧 "Open in …" split button。它**不**承载通知铃铛，也**不**承载任何 Git Viewer / Diff 切换按钮——这两类能力都不在 Header 上：

- **通知**：状态栏铃铛是唯一的 inbox popover 入口；未读以按层级上卷的徽标呈现（见下文 Display 与 [notifications.md](notifications.md)）。
- **Git diff**：⌘⌥G、命令面板 "Toggle Git Viewer"、或菜单启动用户在 Settings → General → Default Git Viewer 选定的**外部 git 客户端**（选 None 或解析不出即 no-op）。应用内的 **Diff inspector**（右缘改动文件列表 + 全区 diff drawer）**尚未实现**——为前瞻设计，见 [diff-inspector.md](../design-docs/diff-inspector.md)。

"Open in …" picker（split button 的 caret）：

```
                                 ┌─────────────────────┐
                                 │ VS Code       ⌘E    │
                                 │ Cursor    (not found)│ ← disabled
                                 │ Zed                 │
                                 │ Xcode               │
                                 │ Sublime             │
                                 │─────────────────────│
                                 │ Reveal in Finder    │
                                 │─────────────────────│
                                 │ + Custom editors…   │
                                 └─────────────────────┘
                                            ▲
                                       ↗ Open in ▾
```

## Requirements

### Must Have

- [x] 两栏布局：Sidebar 在左，Detail 在右。无常驻第三列。
- [x] Sidebar body 把 Project 渲染为一棵扁平的可折叠 section 列表（无 Space 分组）；每个 section 在其下列出该 Project 的 Worktree。
- [x] Empty 状态显示占位信息 + "Add Project" 动作。
- [x] Sidebar 底部钉一条 footer，露出排序（reorder）与刷新两个动作。
- [~] Tag filter（每个 Tag 一行 + 隐含 `[All]` / `[Untagged]`，点击切换 `Catalog.activeTagFilter` 成员，多选 OR；`[All]` 清 filter；`[Untagged]` 互斥且仅在存在无标签 Project 时出现）——**已实现但当前从 footer 隐藏**（`TagChipFooter.swift:49`），接线保留可随时重新挂出。
- [x] 每个 Project section header 在 hover 时显示一个 `+`（"在此 Project 下添加 Worktree" 流程）与一个 `⋯` options 菜单（rename / remove …）。
- [x] 每个 Worktree 行有右键上下文菜单，至少含：Remove Worktree、Reveal in Finder、Open in（默认编辑器）。
- [x] Sidebar toolbar 顶部有 "Add Project" 按钮（与 empty 状态同一入口）。
- [x] 无 sidebar 模式切换（Hierarchy ↔ Inbox）。通知只从状态栏铃铛触达，不在侧栏、不在 Header。
- [x] Detail 区在终端 Tab 条之上渲染一行 Header。
- [x] Header 左侧显示活跃 Worktree 的只读分支标签（git-branch icon + 分支名）。
- [x] Header 右侧显示一个 "Open in …" split button。
- [x] "Open in …" 主动作在默认编辑器打开当前 Worktree（无默认则 Finder）。caret 打开 picker。
- [x] picker 列出六个内建编辑器（VS Code、Cursor、Zed、Xcode、Sublime、Finder）外加任何用户自定义编辑器。未安装者禁用并附解释 tooltip；Finder 始终可用。
- [x] Header 之下的终端 Tab 条与分屏 Pane 行为照旧；无回归。
- [x] 选中一个无活跃 Tab 的 Worktree 时显示 empty 占位 + "New Tab" 按钮。

### Should Have

- [x] 未读通知点沿树上卷：有未读的 Worktree 行显示尾部点；其父 Project section header 把这些点聚合为单个指示。
- [~] 一个键盘快捷键聚焦 Tag filter（⌘F），输入即就地过滤、Esc 清回 `.all`——接线保留，但随 Tag filter 入口当前隐藏而无可聚焦目标。
- [x] 一个键盘快捷键触发 "Open in 默认编辑器" 主动作。

### Could Have

- [ ] Project section 内 Worktree 的拖拽重排。
- [ ] Header 中段一个状态 toast 槽（PR checks / CI status）。已由 Worktree status bar 在 titlebar 中段实现，见 [worktree-management.md](worktree-management.md)。
- [~] 对大列表的过滤——以 Tag filter 形式实现（按 Tag 收窄，而非自由文本搜索框）；已实现但当前隐藏（见上）。

### Won't Have

- 从 Header 编辑分支（rename / checkout / switch）。分支标签只读。（分支切换器是独立能力，见 [worktree-management.md](worktree-management.md)。）
- 常驻第三列的 inspector。Diff inspector（落地后）以右缘 + drawer 呈现，不是常驻列。
- "Add Project" / "Add Worktree" 背后的完整 sheet/flow——入口在 UI 中可见，sheet 本体超出本规格范围。
- 主窗口 chrome 上的 gear / settings 按钮。Settings 经既有路径（⌘,）触达。
- 任何应用内分支列表或 checkout picker。
- 通知铃铛 / Git Viewer 切换按钮挂在 Header 上——通知改由状态栏 popover 承载，Git 入口改由 ⌘⌥G / 命令面板触发（启动外部 git 客户端）。

## Acceptance Criteria

- （Tag filter 当前隐藏，以下两条描述其重新挂出后应满足的契约。）给定活跃 Tag filter 为 `.all`，当用户点击某个 Tag，则侧栏只显示带该 Tag 的 Project；再点 `[All]` 恢复全部。
- 给定多个 Project 有不同 Tag，当用户选中两个 Tag，则侧栏显示带其中任一 Tag 的 Project（OR 语义）。
- 给定活跃 Catalog 至少有一个 Project，当 Sidebar 渲染，则每个 Project 作为一个 section header 出现，其 Worktree 作为子行列在其下，名后跟彩色 Tag 点（capped 3 + "+N"）。
- 给定用户 hover 某 Project section header，当 hover 持续，则 header 右侧出现 `+` 按钮并保持到指针离开。
- 给定用户右键某 Worktree 行，当上下文菜单出现，则至少含：Remove Worktree、Reveal in Finder、Open in（默认编辑器）。
- 给定选中一个 Worktree，当 Detail 区渲染，则 Header 行可见，显示 git-branch icon + 当前分支名（只读标签）。
- 给定用户装了 VS Code 但没装 Cursor，当打开 "Open in …" picker，则 VS Code 可用、Cursor 禁用并附解释 tooltip；Finder 始终可用，点击后在活跃 Worktree 路径打开 Finder。
- 给定有未读通知，当某 Worktree 持有未读，则其侧栏行显示尾部未读点，父 Project section 聚合为单个点；铃铛与 inbox 在状态栏而非 Header。
- 给定已在 Settings → General → Default Git Viewer 选定一个已安装的外部 git 客户端，当用户按 ⌘⌥G（或命令面板 "Toggle Git Viewer"），则在当前 Worktree 路径启动该客户端；选 None 或解析不出时为 no-op。（应用内 Diff inspector 尚未实现——其右缘 inspector + drawer 与 per-Worktree 持久化 `Worktree.diffInspectorVisible` 见 [diff-inspector.md](../design-docs/diff-inspector.md)。）

## 设计沿革（History）

本节仅记录改变了当前形态的承重转变，正文已按现状陈述：

- **Space → Tag**（[project-tags.md](../design-docs/project-tags.md)）：层级为 4 级（无 Space 容器）；横切分类改由 `Tag` 承载；侧栏底部不再有 Space switcher；⌘1–⌘9 / ⌘K 的 Space 跳转解绑；per-Space "上次活跃 Worktree" 记忆移除（per-Project `selectedWorktreeID` 已覆盖）。
- **Git Viewer overlay 移除**（[diff-inspector.md](../design-docs/diff-inspector.md)）：旧的右缘 `GitViewer` overlay 与 Header 上的切换按钮一并移除。应用内的 Diff inspector（右缘 inspector + drawer）仍是**前瞻设计、尚未实现**；当前 ⌘⌥G / 命令面板 / 菜单启动外部 git 客户端。设计落地后会引入 `Worktree.diffInspectorVisible`（由 `gitViewerVisible` 重命名而来）。
- **通知铃铛不在 Header**（[notifications.md](notifications.md)）：未读以按层级上卷的徽标呈现，唯一 popover 入口是状态栏铃铛。

## References

- 设计：[main-window.md](../design-docs/main-window.md)
- Tag / 单窗口：[project-tags.md](../design-docs/project-tags.md)
- 通知：[notifications.md](notifications.md)
- Diff inspector（已设计未实现）：[diff-inspector.md](../design-docs/diff-inspector.md)
- 层级模型：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane}.swift`
