# Product Spec: Worktree Status Bar

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-24

## Summary

把主窗口 titlebar 中段的"空壳"升级为一条有内容、有状态的 **Worktree Status Bar**：它是一个按优先级切换的多态槽位，平时显示当前时间 + 命令面板快捷键提示（motivational），有活跃 PR 时升级为 PR 状态徽章 + checks 色环 + 简述，长任务进行时被 inProgress 进度条覆盖，成功 / 警告以短暂 toast 呈现。

本 spec 只改 titlebar **中间**的这个新槽位。左侧分支标题、右侧 🔔 / Open-in / Git Viewer / Settings 按钮位置与行为**完全保持现状**，不在本 spec 范围内。

目标：让 titlebar 中段承担"当前这个 Worktree 现在怎么样"的单行叙事 —— 永远有用的环境信息 → 有事情发生时的实时状态 → 成败反馈的瞬态回显。

## Goals

1. Titlebar 中段承载**当前 Worktree 的即时状态**（PR / 长任务 / 反馈 / 环境提示），减少用户在 sidebar、终端、浏览器间反复切换。
2. 多个状态源能以**统一的优先级规则**共用同一个槽位，切换带轻量过渡动画，不闪不跳。
3. 复用已有数据源（`HierarchyManager`、`GitHubFeature.snapshots`、`GitHubSnapshotCache`），不重新实现 PR 取数与持久化。
4. 离线可用：未登录 `gh`、没有网络时，motivational 默认态仍能正常显示，不回退到空白或错误态。

## Non-Goals

- 不改动右侧 🔔 / Open-in / Git Viewer / Settings 的行为与位置。
- 不改动左侧分支 / 文件夹标题的行为与位置。
- 不引入新的 PR 数据源，也不扩大现有 `gh` 调用面。
- 不替换 `WorktreeDetailView` 的 tab bar / split viewport / overlay 布局。
- 不处理 Plain（非 git）Project 的 PR 状态（此类 Project 没有分支，天然无 PR 槽；motivational 仍适用）。
- 不处理多个并发长任务的聚合视图（首版只展示最新一个 inProgress toast；多任务聚合列为 Open Question）。
- 不在 spec 内规定动画/色彩/文案的终极细节（交由 hs-design 与 SwiftUI 实现阶段 PR 中定稿）。

## Stakeholders & Users

- **Primary**：一位开发者同时在多个 Worktree / Project 间切换，日常会在终端里跑 agent / run-script，也在 GitHub 上 review PR。
- **Secondary**：偶尔使用的用户（只开一个 Worktree，没配 `gh`）—— 他们应该看到 motivational 默认态，不被空槽或错误态打扰。
- **受影响系统**：`WorktreeDetailView`（承载 `.toolbar {}`）、`WorktreeHeaderFeature`（已有 header 状态，中心槽的归属候选之一）、`GitHubFeature`（PR snapshots + workflow runs）、`EditorFeature`（Open-in 结果可作为 success toast 来源）、`RunScriptFeature` / 未来 custom-command 执行（inProgress / success / warning 的主要发射器）。

## User Stories

- As a 多 Worktree 用户，I want titlebar 中心能在我切换 Worktree 时立即展示该 Worktree 对应 PR 的 checks 状态，so that 我不用打开 GitHub 就知道 CI 是红是绿。
- As a 跑长任务的用户，I want run-script / 首次 reconcile / gh 首次拉取时 titlebar 显示一行 spinner + 描述，so that 我知道应用在忙什么、不用盯 Console。
- As a 等待反馈的用户，I want 操作成功（如 Open-in editor、Mark PR ready）能在 titlebar 弹出一行绿 ✓ 的 toast 并自动消失，so that 我不必确认弹窗也能知道事情成了。
- As a 踩了非致命错误的用户，I want 警告以橙色 toast 停留直到我看一眼，so that 失败不会悄悄被覆盖。
- As a 空闲时刻的用户，I want 什么也没发生时看到当前时间 + 命令面板快捷键，so that titlebar 不浪费、也提示我主要入口在哪。

## Layout Overview

```
┌───────────────── Window Titlebar ────────────────────────────────────────────┐
│ ⎇ branch-name │     <StatusSlot — 多态>     │ 🔔  ⇪  📖  ⚙︎                  │
└──────────────────────────────────────────────────────────────────────────────┘
  (unchanged)      ← 本 spec 唯一的改动点 →      (unchanged)
```

- 左：分支 / 文件夹标题 —— **保持现状**
- 中：**本 spec 新增的 `WorktreeStatusSlot`**，`ToolbarSpacer(.flexible)` 夹在两侧
- 右：🔔 通知、⇪ Open-in split、📖 Git Viewer toggle、⚙︎ Settings —— **保持现状**

中段槽位在同一矩形区域内按优先级渲染五种形态之一，所有切换用 `easeInOut(0.2)` + `.opacity` transition。

## Functional Spec

### 槽位形态与优先级

槽位是一个多态视图，根据当前 `StatusSlotKind` 渲染以下五种形态之一。优先级由高到低：

| 优先级 | 形态 | 视觉 | 触发条件 |
|---|---|---|---|
| P0 | `inProgress(message)` | 小号 spinner + 次级色文本 | 有长任务在运行 |
| P1 | `success(message)` | 绿 ✓ + 次级色文本 | 操作刚成功，处于回显窗口内 |
| P1 | `warning(message)` | 橙 ▲ + 次级色文本 | 非致命错误 / 告警，处于回显窗口内 |
| P2 | `pullRequest(model)` | `#编号` 徽章 + checks 色环 + 简述 | 当前分支映射到活跃 PR，且未被上面任何一项覆盖 |
| P3 | `motivational` | 时段图标（🌅/☀️/🌇/🌙）+ `HH:mm – ⌘P 打开命令面板` | 以上都没有时的默认态 |

"活跃 PR" 定义：`GitHubFeature.State.snapshots[worktreeID]` 存在、`state` 不是 `CLOSED`、`number` 非空。

**P0 与 P1 的并存**：若 inProgress 正在展示时又发出一个 success，success 覆盖 inProgress（inProgress 的结束本身就是 success 的发生）。若 inProgress 正在展示时发出 warning，warning 覆盖 inProgress。

**toast 的自动清除**：
- `success`：进入后 **3 秒**自动回落到下一优先级
- `warning`：进入后 **8 秒**自动回落
- `inProgress`：**不自动清**，由发射方显式发送 `.cleared` / `.success(…)` / `.warning(…)` 结束

### PR 形态交互

- 主体区域是一个按钮，点击弹出**既有 `PullRequestPopover`**（360pt，已实现 header / checks / actions / footer）
- 按住 `⌘` 时，PR 简述文字临时替换为 `Open on GitHub <shortcut>`；`⌘+click` 直接打开 `gh` URL
- `#编号` 徽章颜色由 PR 状态决定（open = 绿，draft = 灰，merged = 紫，可复用 `App/Features/GitHub/Theme/PullRequestStateColors.swift`）
- checks 色环：基于 `statusCheckRollup.checks` 做汇总饼图 —— 绿 = success、红 = failure、黄 = pending、灰 = skipped。`breakdown.total == 0` 时不渲染圆环（纯徽章 + 文本）
- 简述文本优先级：merge-ready 阻塞原因 > checks 汇总 > `(Drafted)` > PR 标题

### Motivational 形态

- 时段图标映射（按本地 hour）：`6..<12` 🌅 orange / `12..<17` ☀️ yellow / `17..<21` 🌇 pink / 其他 🌙 indigo
- 文本：`HH:mm – <command-palette-hint>`，用 `TimelineView(.everyMinute)` 每分钟刷新一次
- `<command-palette-hint>` 由已解析的 keybinding 生成（优先读项目内的 `AppShortcuts` 或等价机制；若命令面板快捷键在首版还未登记，先硬编码文案 "Open Command Palette"，并在 Open Questions 里追踪）

### 通用行为

- **macOS 26+**：中心槽 `ToolbarItem` 与现有 branch label 保持一致，使用 `sharedBackgroundVisibility(.hidden)`，避免被系统渲染为圆角胶囊。
- **动画**：所有槽位内切换统一用 `.animation(.easeInOut(duration: 0.2), value: <kind>)`，避免 spinner ↔ 文本突兀。
- **窄窗口**：`ToolbarItemGroup + ToolbarSpacer(.fixed/.flexible)` 负责保持 "左 / 中 / 右" 的相对顺序；当标题栏过窄导致中段不足以展示时，中段整体隐藏 —— 不塌缩成菜单、不与右侧按钮重叠。隐藏阈值：中段原生内容宽度 + 左右各 12pt 边距 > 可用宽度时隐藏。
- **可访问性**：
  - 槽位每种形态都提供 `accessibilityLabel` + `accessibilityValue`，而非依赖系统从视觉元素推断
  - 切换形态时使用 `accessibilityElement(children: .ignore)` 包一层，避免 VoiceOver 在动画期间朗读中间态
  - 槽位参与 VoiceOver 聚焦，但**不抢 focus**（不应干扰终端输入）

## State Machine

```
         ┌─────────────────────────────────────────────────────┐
         │                                                     │
         ▼                                                     │
   ┌───────────┐  .push(inProgress)       ┌──────────────┐    │
   │ (derived) │ ────────────────────────▶│ inProgress   │    │
   │  P2 / P3  │                          └─────┬────────┘    │
   └─────┬─────┘                                │             │
         │                                      │ .cleared    │
         │                                      │ (emitter)   │
         │                                      ▼             │
         │   .push(success)    ┌──────────────────────┐       │
         ├────────────────────▶│ success (≤3s)        │───────┤
         │                     └──────────────────────┘       │
         │                                                    │
         │   .push(warning)    ┌──────────────────────┐       │
         └────────────────────▶│ warning (≤8s)        │───────┘
                               └──────────────────────┘
```

- `(derived)` 表示无活跃 toast 时，槽位从数据直接推导 P2 / P3：有 PR snapshot 就是 PR 态，否则是 motivational。
- toast 的入口只有 `.push(.inProgress|.success|.warning, message)`；出口是计时器触发的 `.cleared` 或新的 `.push` 覆盖。
- 同时有 `inProgress` 活跃时，另一个 `.push(inProgress)` 到达：替换为新的 message（不排队）。

## Data Sources

| 数据 | 来源（已有） | 用途 |
|---|---|---|
| 当前 Worktree 身份 | `HierarchyManager.catalog` + `HierarchySelection` | 决定从哪个 snapshot 读取 PR |
| PR snapshot | `GitHubFeature.State.snapshots[worktreeID]` + `GitHubSnapshotCache` | PR 徽章、checks、简述 |
| workflow run | `GitHubFeature.State.latestWorkflowRuns[prNumber]` | checks 色环的 pending 细节（可选） |
| keybinding | 项目内快捷键解析（`AppShortcuts` 或等价 API，需确认） | motivational hint |
| 当前时间 | `TimelineView(.everyMinute)` | motivational 时间 |

本 spec 只**新增**以下状态：

- `statusToast: StatusToast?` —— 一个 per-window 的 toast 槽位，承载 inProgress / success / warning
- `StatusToast` 数据模型（`enum { inProgress(String), success(String), warning(String) }`）
- toast 发射入口（action / method），供 `EditorFeature.lastOpenResult`、`GitHubFeature` 操作完成、run-script 起止等外部 feature 向 status bar 写入

**状态归属**在 hs-design 里定（候选：扩展 `WorktreeHeaderFeature`、新开 `StatusBarFeature` 与 Header 平级、或挂到 `RootFeature` 广播）。

## Requirements

### Must Have

- [ ] 中心槽在 titlebar 渲染，位置由 `.toolbar {}` 的 `ToolbarSpacer(.flexible)` 负责居中
- [ ] 五种形态均可实现并按上述优先级切换
- [ ] `success` 3 秒后自动消失，`warning` 8 秒后自动消失，`inProgress` 仅由发射方结束
- [ ] PR 态点击复用既有 `PullRequestPopover`，`⌘+click` 在浏览器打开 PR
- [ ] motivational 态按本地 hour 切换四种时段图标，每分钟刷新时间
- [ ] 所有切换使用 `easeInOut(0.2)` + `.opacity` 过渡
- [ ] 左侧分支标题、右侧 🔔 / Open-in / Git Viewer / Settings 位置与行为均不变
- [ ] macOS 26+ 中心槽 toolbar item 不出现多余背景胶囊
- [ ] 所有形态具备语义化的 `accessibilityLabel` / `accessibilityValue`
- [ ] 未登录 `gh` / 无 PR 数据时，槽位稳定回退到 motivational 态，不闪错误

### Should Have

- [ ] 窄窗口阈值下中心槽整体隐藏，而非塌缩成溢出菜单
- [ ] toast 支持 `VoiceOver` 在切换时朗读一次当前状态（不重复朗读）
- [ ] 暗色模式下所有颜色（绿/橙/indigo/pink）满足 AA 对比度

### Could Have

- [ ] inProgress 多任务并发时，标题栏显示 `N tasks running` 聚合态，点击弹出列表
- [ ] success toast 支持 undo action（例如 Open-in editor 之后 2 秒内可撤销）
- [ ] motivational 态支持用户自定义右半句（例如显示最近 commit 的相对时间）
- [ ] PR 态在 checks 全部通过时，圆环做一次极短的"完成"脉冲动画

### Won't Have (This Spec)

- 右侧 🔔 通知按钮的任何改动（分组、计数、popover 内容均保持现状）
- 左侧分支标题的任何改动（rename popover、hover 交互等均保持现状）
- 菜单栏图标、Dock 徽章、macOS 通知中心推送
- 非 git Project 的 PR 状态（不存在 PR）
- 打开 PR 之外的 `gh` 操作快捷入口（保留在既有 `PullRequestPopover`）

## Acceptance Criteria

GWT 格式，每条对应一个可测行为。

### Motivational

- **AC-MV-1** Given 一个新建的空 Project（无 PR 数据）, when 我选中其中一个 Worktree, then titlebar 中心在 300ms 内渲染 motivational 形态，文本形如 `14:02 – Open Command Palette ⌘P`。
- **AC-MV-2** Given motivational 正在展示, when 本地 hour 从 11 跨越到 12, then 图标由 🌅 变为 ☀️（依赖 `TimelineView` 分钟刷新即可，不要求秒级）。

### inProgress / toast

- **AC-IP-1** Given 我点击 `Open in Xcode`, when `EditorFeature` 返回 success, then 中心槽在 200ms 内显示绿 ✓ + `Opened in Xcode`，3 秒后自动回落到 motivational / PR 态。
- **AC-IP-2** Given run-script 正在运行, when 它仍在运行, then 中心槽持续显示 `⟳ Running <script>` 且不被 motivational 替换。
- **AC-IP-3** Given inProgress `Running tests` 正在展示, when 发射方发出 success `Tests passed`, then 中心槽切换为 success 形态，且 inProgress spinner 消失。
- **AC-IP-4** Given warning `Push rejected` 正在展示, when 用户不操作, then 8 秒后自动回落。

### PR 态

- **AC-PR-1** Given 当前 Worktree 的分支有活跃 PR（open 状态、checks 全绿）, when 无 toast 占用, then 中心槽显示 `#123` 绿徽章 + 绿 ring + `4/4 checks`。
- **AC-PR-2** Given PR 态正在展示, when 我按住 `⌘`, then 简述文本在 100ms 内切换为 `Open on GitHub <shortcut>`；松开后切回。
- **AC-PR-3** Given PR 态正在展示, when 我点击徽章区域, then 弹出既有 `PullRequestPopover`，内容与 sidebar 同源。
- **AC-PR-4** Given 当前 Worktree 的分支 PR 被 merged, when 数据刷新到达, then 中心槽 0.2s 内过渡为紫色 `#123` 徽章且不再显示 checks ring。
- **AC-PR-5** Given 当前 Worktree 的分支 PR 已 closed, when 数据刷新到达, then 中心槽回落到 motivational 态（closed PR 不占槽）。

### 视觉 / 系统

- **AC-VS-1** Given macOS 26+, when 中心槽处于任意形态, then 没有额外的 toolbar 背景胶囊（与现有 branch label 一致）。
- **AC-VS-2** Given 窗口宽度低于阈值, when titlebar 被收窄, then 中心槽整体不渲染，左右两侧按钮位置保持稳定，不溢出菜单。
- **AC-VS-3** Given VoiceOver 打开, when 中心槽从 PR 态切换到 inProgress, then VoiceOver 朗读当前态一次，不重复朗读过渡态。
- **AC-VS-4** Given 任何形态切换, when 切换完成, then 左右两侧的 ⎇ 分支标题 / 🔔 / ⇪ / 📖 / ⚙︎ 位置与大小无可感知变化。

## Design Considerations (for hs-design)

以下决策**不在本 spec 内定案**，仅列出待分析项，供下一阶段设计文档展开：

1. **状态归属**：`statusToast` 挂在 `WorktreeHeaderFeature` 上，还是新开 `StatusBarFeature` 与 Header 平级？影响 toast 发射方的 action 路径与 TestStore 组织。
2. **toast 发射协议**：统一为一个 `StatusBusClient`（向 status bar push 事件）还是各 feature 直接向目标 reducer dispatch？
3. **PR 数据的读取路径**：中心槽是订阅 `GitHubFeature.State.snapshots[worktreeID]`（TCA scope），还是读 `GitHubSnapshotCache` 的 snapshot stream？
4. **checks 色环组件**：新建独立可复用组件（可能被 sidebar 复用），还是只在 toolbar 内内联实现？
5. **motivational 快捷键来源**：优先读项目内已有的 keybinding 解析 API；若命令面板尚未登记快捷键，是硬编码文案、还是这一版暂时不显示 hint？
6. **toast 节流**：同一 message 的重复 `.push` 是否合并；`inProgress → success → inProgress` 的极短序列是否应抖动合并。
7. **窄窗口阈值具体值**：需要在设计阶段用 Figma / 真机测出 minimum readable width。

## Open Questions

- [ ] **OQ-1**：命令面板在 codans 里是否已有 `AppShortcuts` 等价机制？若无，motivational hint 的快捷键部分是 (a) 硬编码文案 (b) 隐藏 hint 只显示时间 (c) 推迟到命令面板落地后再开 motivational 态？
- [ ] **OQ-2**：PR checks rollup 在 `GitHubFeature` 当前数据结构里是否已包含 `skipped` / `neutral` 状态？圆环配色需要据此确认。
- [ ] **OQ-3**：`EditorFeature.lastOpenResult` 现在如何驱动 UI？本 spec 假设它能被 status bar 订阅产生 success/warning toast —— 如果它目前只用一次性 sheet，需要一个 Observable 通道。
- [ ] **OQ-4**：run-script / custom-command 的执行状态目前是否暴露为可订阅的 flow？若尚未，本 spec 的 inProgress 态需要它先具备生命周期事件。
- [ ] **OQ-5**：Plain（非 git）Project 的 Worktree 在 titlebar 左侧显示文件夹图标（已支持）。中心槽 PR 态自动跳过即可，但 **motivational 是否也要为 Plain Project 定制一个替代提示**（例如 `Folder · ⌘P to Command Palette`）？
- [ ] **OQ-6**：多个活跃 toast 是否需要队列？首版选择"后到覆盖先到"，是否需要改为"inProgress 可叠加、success/warning 排队"？

## Glossary

- **StatusSlot / Status Bar**：titlebar 中段的多态槽位（本 spec 唯一讨论对象）
- **Toast**：一次性、限时显示的 inProgress / success / warning 消息
- **Motivational**：无事件时的默认态（时间 + 图标 + hint）
- **PR snapshot**：`GitHubFeature` 为每个 Worktree 缓存的 PR 概要（title / state / checks / reviews 等）
- **Checks ring**：汇总 PR statusCheckRollup 的紧凑饼图/环图
