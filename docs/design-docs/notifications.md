# 设计文档：Notifications

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

通知子系统的职责，是在某个 Pane 需要用户时——编码 agent 卡在等待输入、或长任务结束——把用户的注意力拉回到**那个确切的 Pane**，且只拉回那一个。

层级为 `Catalog → Project → Worktree → Tab → Pane`；一个 Pane 是一个 Ghostty surface，多个 Pane 通过 `SplitTree<PaneID>` 在一个 Tab 内分屏排布。

## 目标与非目标

**目标**

- 把运行时已经发出的结构化事件（OSC 9 桌面通知、终端 bell、OSC 133 命令结束、子进程退出、idle、crash）翻译成通知——**无需** stdout 扫描器。
- 用既有的 `AtomicFileStore` 把 inbox 持久化跨重启。
- 把未读状态呈现为按层级上卷的徽标（只在最深的隐藏祖先处显示），外加一个状态栏铃铛 + popover inbox。
- 让每条发出的通知都经过**唯一的策略闸（policy chokepoint）**，在任何副作用之前尊重用户设置与 macOS 授权。
- 仅当来源 Pane 不是用户当前焦点时，才投递 macOS 横幅。

**非目标**

- 无 stdout 正则扫描（见 Alternatives A1）。既不发 OSC 9、也不响铃、也不发 OSC 133 的工具会静默地不被覆盖——这是被记录的限制，而非要去打补丁的缺陷。
- 无基于 hook 的检测（c3-hooks）。预留为未来的增量来源。
- 无用户可编辑的检测规则 / 模板 DSL / 严重级别 / snooze / 应用内 toast 浮层 / 逐事件音效选择。
- 无 inbox 的 CLI 访问。模型放在 `CodansCore`，以便日后暴露成本很小，但 `codans` 当前不查询它。

## 设计总览

驱动一切的核心洞察，分两半：

1. **运行时已经暴露了我们需要的结构化事件**——因此检测只是事件流下游的一个小*翻译器*，而非新的检测引擎。
2. **检测与策略必须分离。** 把「把事件翻译成候选」和「决定要不要呈现它」混在一起，正是当初设置一加入、检测器就长成一坨内联 `if` 的根源。于是拆成：
   - `DetectionTranslator`——**纯函数**；`(event, context) → Step`。它以输入的形式生长旋钮，绝不以状态的形式。
   - `NotificationDetector`——编排：catalog 遍历、muted 标签丢弃、`hasProducedOutput`、击键上下文；产出一个 `Candidate`。
   - `NotificationCoordinator`——**策略闸**：读取实时设置 + 授权状态，向各副作用 sink 派发。所有 gate 只在这里。

```
                                    ┌──────────────────────────┐
                                    │ SettingsStore (v3)       │
                                    │ .notifications: 7 fields │
                                    └─────────┬────────────────┘
                                              │ NotificationSettingsReader
                                              ▼
   ┌──────────────┐  TerminalEvent   ┌────────────────────────┐
   │ TerminalEng. │─────────────────▶│ NotificationDetector   │
   └──────────────┘                  │  • catalog walk        │
   ┌──────────────┐  key input       │  • muted-label drop    │
   │ GhosttyView  │─────────────────▶│  • DetectionTranslator │
   └──────────────┘                  └────────┬───────────────┘
                                              │ Candidate (or drop)
                                              ▼
                       ┌──────────────────────────────────────┐
                       │  NotificationCoordinator (chokepoint) │
                       │  • read settings + authStatus         │
                       │  • dispatch sinks  • unreadByWorktree  │
                       └──┬─────────┬─────────┬─────────┬──────┘
                          ▼         ▼         ▼         ▼
                    ┌────────┐ ┌────────┐ ┌──────┐ ┌──────────────────┐
                    │ Store  │ │OSNotif.│ │ Dock │ │HierarchyClient   │
                    │.append │ │.post(  │ │Badger│ │.reorderWorktrees │
                    │        │ │playSnd)│ │      │ │                  │
                    └────────┘ └────────┘ └──────┘ └──────────────────┘
```

外部触点：`UNUserNotificationCenter`、`NSApp.dockTile`、`AtomicFileStore`。唯一的非 `TerminalEvent` 输入是击键旁路（`PaneKeyboardActivityTracker`）。

## 技术决策

**为何不用 FSM tracker / 用户可编辑的规则 DSL / stdout 扫描器。** 检测刻意建为运行时事件流下游的一个纯翻译器，而非独立的检测引擎。理由：

- **运行时已经暴露了所需的结构化事件**（OSC 9、bell、OSC 133、子进程退出、idle、crash），因此再叠一台带 per-Pane FSM、用户可编辑规则 DSL 与 stdout 正则扫描器的检测机，是为 inbox 实际所需多得多的机器——表面积与维护成本都不成比例。
- **stdout 正则扫描会漂移**：模式如 `"(y/n)"` 会误命中聊天记录；而一旦对外发布一套正则，就会顺势招来规则编辑器（这正是整套方案里最大的单块）。记录「请在你的工具里发 OSC 9」比永久维护这套正则更便宜。
- **检测与策略必须分离。** 把「把事件翻译成候选」和「决定要不要呈现它」混在一起，正是「设置一加入、检测器就长成一坨内联 `if`」的根源。于是三层拆开：纯翻译器 `DetectionTranslator`、编排器 `NotificationDetector`、唯一策略闸 `NotificationCoordinator`。

代价是覆盖缺口：既不发 OSC 9、也不响铃、也不发 OSC 133 的工具不被覆盖——这是被记录的限制（见「非目标」与「风险」），若实践证明需要，stdout 扫描器可作为增量回归来源补回。

## 检测（`DetectionTranslator`，纯函数）

`translate(_ event: TerminalEvent, context: Context) -> Step` 是纯函数；`Context` 携带 `hasProducedOutput`、`lastUserKeystrokeAt: [PaneID: Date]`、注入的 `now`，以及命令结束相关设置。翻译表：

| 来源事件 | 变成 | Kind |
|---|---|---|
| `desktopNotification(title, body)`（OSC 9） | 该 title/body | 命中小启发式（"permission"/"approval"/"input"/"?"）则 `.waitingForInput`，否则 `.taskFinished` |
| `bellRang` | "Pane rang the bell" | `.waitingForInput` |
| `commandFinished(exitCode, duration)`（OSC 133） | 见下方抑制规则 | `.taskFinished` |
| `paneExited(code, signal)` | "pane exited" + 状态 | `.taskFinished` |
| `paneCrashed(reason)` | "pane crashed: …" | `.taskFinished` |
| `paneIdle(duration)` | "task idle for …" | `.taskFinished`——仅当 `duration ≥ 30s` 且 pane 近期有输出 且 未检测到 shell 提示符 |

**命令结束抑制**——所有判定都在纯层，只依赖注入的 context（击键时间戳是唯一的外部输入）：

1. `commandFinishedEnabled == false` → 丢弃（`commandFinishedDisabled`）。
2. exit `130`（SIGINT）/ `143`（SIGTERM）→ 丢弃（`commandCancelled`）——用户主动取消，他知道结束了。
3. `duration < commandFinishedThresholdSec` → 丢弃（`commandFinishedShort`）。
4. 事件前 **1 秒**内来源 pane 有击键 → 丢弃（`userTypingRecently`）——用户显然正盯着这个 pane。
5. 否则发出，且**非零退出码给出一眼可辨的标题**（"Command failed (exit N)" vs "Command finished"）。

`Step` 带一个可选 `drop: DropReason?`，使抑制与 coordinator 后续的丢弃走同一条日志路径。`DropReason` 放在 `CodansCore`，让纯翻译器和 app 层 coordinator 共享同一个字符串编码枚举。

**击键旁路。** `PaneKeyboardActivityTracker`（`@MainActor`，持有 `[PaneID: Date]`）在每次 `GhosttySurfaceView.sendKey` 时记录，pane 拆除时清理。为什么不用 `TerminalEvent.paneUserInput` 事件：击键节奏是人类尺度（约 10 Hz），且只有检测器关心——新增事件 case 会给每个 `TerminalEvent` 消费者（`RootFeature`、测试、分析）添噪。为什么不用 `Pane.labels` / `@Observable` 字段：labels 会被持久化（每次击键一次 catalog 保存），`@Observable` 字段会让 SwiftUI 每次击键重渲染，而 `GhosttySurfaceView` 刻意避免了这一点。

## 策略闸（`NotificationCoordinator`）

一个 `@MainActor final class`（不是 reducer——它没有 UI 状态；不是 `@Observable`——没有东西绑定它），在 bringup 时构造一次。它消费 `Candidate { entry: InboxEntry, sourceIsFocused: Bool }`，返回 `Decision`（`.posted(…)` / `.dropped(reason:)`），使测试无需检查协作者即可断言行为。Gate 顺序：

1. `sourceIsFocused` → 丢弃。（pane 内输出本身即是提醒。）
2. `inAppEnabled` → 追加 inbox + 重算 Dock 徽标（Dock gate 在内部）。**in-app 与 system 是相互独立的开关**：「仅后台」模式 = in-app 关 + system 开。
3. `systemEnabled && authStatus == .authorized` → `OSNotifier.post(entry, playSound: soundEnabled)`。
4. `moveNotifiedWorktreeToTop` 且该 worktree 的未读刚从 `0 → N` → `reorderWorktrees`。

coordinator 持有 `unreadByWorktree: [WorktreeID: Int]` 缓存（init 时从 inbox 重建，增量更新），使 `0 → N` 边沿无需每次重扫 inbox 即可识别。从这个缓存而非观察 store 来驱动提升，避免了每次 `markRead`/去重合并都重新提升。

`NotificationSettingsReader` 是对接 `SettingsStore` + 缓存授权状态的缝；测试用 fake 驱动。授权状态在 `applicationDidBecomeActive` 时重读，使「系统设置」中的改动无需重启即可生效。

**`OSNotifier.post(_ entry:, playSound:)`** 逐次调用传入音效——若改成有状态的 `playSound` 属性，当一批 post 跨越一次设置翻转时会产生竞态。该 adapter 在其他方面对 `SettingsStore` 一无所知。

## 设置（`NotificationsSettings`）

`Settings`（v3）上的第六个顶层 section，增量式——**不升 schema 版本**，所有字段经 `decodeIfPresent` 可选（v1.1 之前的 `settings.json` 解码为默认值）。字段（默认均为开/合理值）：`inAppEnabled`、`systemEnabled`、`soundEnabled`、`dockBadgeEnabled`、`moveNotifiedWorktreeToTop`、`commandFinishedEnabled`、`commandFinishedThresholdSec`（默认 10，解码与 UI 层都钳到 `[1,3600]`），以及一个仅计数的 `mute` 子结构。

**为何是四个正交布尔而非一个 `level` 枚举**（A5）：用户需要枚举表达不出的交叉组合（in-app 关 + system 开 =「仅后台」）。Sound 与 Dock badge 又是另外两个独立维度。

Settings → Notifications 面板采用**直接视图 + `SettingsStore`**（无 reducer），与 `SettingsGeneralView` 一致。属于耐久契约（而非具体 SwiftUI 布局）的行为：Sound 行在 `systemEnabled` 关时 `.disabled`，但其持久值**保留**（system 重新开启即恢复用户意图）；在 `authStatus == .denied` 时开启 System 会弹一个信息性 alert，含「打开系统设置」深链（`?id=<bundle-id>`，并带顶层面板回退），而开关保持 `true`（它捕获意图，不代表 OS 的拦截状态）；mute 行只是摘要 + Reveal-in-Finder（无规则编辑器）。

## 存储（`NotificationStore` + `InboxFile`）

inbox 在内存中是 `[InboxEntry]`，持久化到 `~/.config/codans/notifications.json`。记录类型是 **`InboxEntry`**，不是 `Notification`——后者在同时 import Foundation 与 CodansCore 的调用点会与 `Foundation.Notification` 冲突（正是它被改名的原因）。纯 inbox 变更（去重/老化/容量）放在 `CodansCore.InboxStorage`（一个 `nonisolated` enum），从而可独立于 `@MainActor` store 测试。`InboxEntry.source` 存原始 ID（`projectID/worktreeID/tabID/paneID`），不存弱引用——catalog 会独立变更，导航在点击时重新解析。

加载时（在 inbox 暴露前）跑 sweep，且每次 append 都强制容量上限：**老化**（丢弃 > 7 天）、**容量**（> 500 → 先逐出最旧的已读，再逐出最旧的未读）。**去重窗口**：30 秒内同 `(paneID, kind)` 更新既有行的 body/时间戳，而非新增。保存在 MainActor 之外防抖 250 ms。

**版本化信封（`InboxFile`）。** 文件形如 `{ version: 1, entries: [...] }`。加载器：文件缺失 → `nil`；解码 `Envelope` → 若 `version > current`，重命名为 `notifications.json.bak-<ISO>` 并返回 `[]`，否则返回 entries；信封解码失败则尝试**遗留裸数组**（向后兼容一个发布周期）；两者都失败则返回 `[]` 且不重命名（可能是部分写入，下一次保存会覆盖）。为什么用版本键而非改文件名（A7）：改名会让每个老用户的 inbox 成为孤儿；版本键在 happy path 上是一次解码尝试、零文件操作。为什么不并入 settings 版本：inbox 是独立文件、有自己的写入节奏——耦合会导致每次 inbox 保存都触发一次 settings 保存。

## 上卷（`RollupIndex`）

在一个 TCA reducer 派生中计算（catalog 是几十个节点；每次输入增量做 O(N) 重算没问题），当两个输入之一变化时重建：未读集合，以及焦点状态（`focusedPaneID`、活跃 tab/worktree、展开集合）。各级指示器为**布尔**，唯一例外是状态栏铃铛——它携带数值型全局未读计数（被 Dock 徽标镜像）。

**不变量——每条未读只贡献给恰好一个层级：最深的隐藏祖先。** L4 Project（折叠）· L3 Worktree（project 展开但 worktree 未活跃）· L2 Tab（worktree 活跃但 tab 未活跃）· L1 Pane（tab 活跃但 pane 未聚焦）。在 L1，未读的 `.waitingForInput`（琥珀）压过 `.taskFinished`（绿）。`globalUnreadCount` 是未经上卷的总数（「每一条未读，无论你能否看到其来源」）。徽标计数必须是**对实时 catalog 的计算读取**，而非缓存字段——缓存会在仅 catalog 变更时变陈旧（例如删除一个非选中、令某条未读成为孤儿的 worktree），因为没有 selection 信号去使其失效。

每个表面（侧栏 Project 点、Worktree 铃铛字形、Tab 点、Pane 顶线）通过一个小的 Equatable 切片读取 `RollupIndex`；L1–L4 仅为视觉。状态栏铃铛是**唯一**的 popover 入口（A5：逐级作用域 popover 被否——层级中的位置本身就回答了「在哪」，而对一个已上卷层级开作用域 popover，会展示其真实来源在更深几层的条目）。

## 导航

`RootFeature.focusHierarchyPath(SourcePath, fallback:)` 沿 Project → Worktree → Tab → Pane 逐级走，在每层设置 selection。**死目标回退**（G3）：若某层已不存在，落到最深的仍存在的祖先；inbox 行保留，并以淡化/删除线的来源标签标记。这是 `RootFeature` 的职责（它拥有 selection），而非 `PaneActionRouter` 的（后者管 pane 内 / tab 内）。

## Worktree 提升

`HierarchyClient.reorderWorktrees(projectID, worktreeID, .moveToFrontWithinUnpinned)` 在某 worktree 首次出现未读（`0 → N` 边沿）时把它移到**未固定（unpinned）**段的最前。**固定的 worktree 永不自动重排**——固定是比「收到通知」更强的显式信号。未读回到 0 时不自动降回（提升是一次离散的过去事件；用户当前的顺序才是权威）。该变更属于 catalog 所有权（单一线性写入面，与 `setWorktreePinned`/`reorderProjects` 同形）；coordinator 只决定*何时*调用。它与 `bumpProjectActivity`（Project 级排序）正交——coordinator **不**重复那次调用，由检测器保留。

## 逐 Pane 静音

静音是 `Pane.labels` 中的字符串标签 `"notifications:muted"`（Codable / 持久化——无需新字段）。Pane 右键「Mute notifications」项通过 `HierarchyClient.setPaneLabel` 切换它（经 `CatalogStore.scheduleSave` 防抖，内存变更立即生效，使重新打开的菜单读到当前状态）。该菜单经 `hierarchy.snapshot()` 而非视图状态读取，故每次打开都反映当前标签。检测器在闸之前就丢弃被静音 pane 的事件。

## 授权

`OSNotifier` 在**第一条**值得发横幅的通知时请求授权（而非启动时）。拒绝仅静默横幅——应用内徽标、inbox、Dock 徽标无条件工作。Settings 暴露 Request / 打开系统设置的恢复路径；状态在 `applicationDidBecomeActive` 时重读。

## 组件边界

```
CodansCore/
  Notifications/{InboxEntry, InboxStorage, DetectionTranslator(+Context),
                 InboxFile, RollupIndex, DropReason}.swift
  Settings/NotificationsSettings.swift
codans/App/Features/Notifications/
  NotificationDetector, NotificationCoordinator, NotificationSettingsReader,
  NotificationStore, OSNotifier, DockBadger, PaneKeyboardActivityTracker
codans/App/Features/Settings/Panes/NotificationsSettingsView.swift
codans/App/Clients/HierarchyClient.swift   // + reorderWorktrees, setPaneLabel
```

依赖方向：`InboxEntry ← DetectionTranslator/Detector → Coordinator → {Store, OSNotifier, DockBadger, HierarchyClient}`；各表面观察 `RollupIndex`。store 在设计上对 UI 与 OS 一无所知；`Notifications/` 除设置面板与 pane 上下文菜单外不 import 任何 UI 类型。

## 备选方案（Alternatives）

- **A1 — stdout 正则扫描器。** 否决：模式会漂移（"(y/n)" 会命中聊天记录），而一旦发一套正则就会招来规则编辑器。记录「请在你的工具里发 OSC 9」比永久维护这套正则更便宜；若真有用户撞上缺口，扫描器可作为增量回归。（根因见「技术决策」。）
- **A2 — 侧栏 inbox 路由。** 否决（已与用户确认）：通知本质是瞬态的（读 → 点进 → 忘掉），常驻路由把它们过度提升。铃铛 + popover 才贴合实际流程。
- **A3 — 基于 hook 的检测。** v1 否决：当前只有 Claude Code 写 c3 hooks；运行时的结构化事件覆盖任何遵守 OSC 9/133 的工具——严格更广。日后可增量加入。
- **A4 — 把闸塞进检测器。** 否决：检测器已经是编排；把策略塞进去会模糊「纯翻译器 / 编排 / 策略」的拆分，并拉长测试矩阵。
- **A5 — 逐级作用域 popover；单一开关枚举。** 均否决（见上文「上卷」与「设置」）。
- **A6 — 由 store 驱动提升。** 否决：store 会需要 import `HierarchyClient` + 一个设置读取器——都是反向依赖；它是叶子类型。

## 风险

| 风险 | 缓解 |
|---|---|
| OSC 9 普及缺口——不发它的工具永不触发「等待输入」。 | 记录为已知限制；bell + 子进程退出 + idle 仍覆盖多数「完成」情形。 |
| 用户 shell 无 OSC 133——无 `commandFinished`。 | `paneExited` 对任何 shell 都覆盖前台进程退出。 |
| 创建与点击之间 catalog 变更。 | 原始 ID 存储 + 死目标回退（G3）；行保留并标记。 |
| 授权被拒。 | 应用内 + Dock + inbox 无条件工作；Settings 有恢复路径。 |
| 1 秒击键窗口 vs IME 批量提交。 | tracker 在每次 `sendKey`（含合成事件）记录；若真有 IME 案例，把该常量提升为设置即可。 |
| `reorderWorktrees` 与手动拖拽竞争。 | 两者均 `@MainActor`，串行化；最后写入胜出——自动提升输给进行中的手动拖拽是正确结果。 |
| 降级时前向版本 inbox 被隔离。 | 隔离是重命名而非删除，可恢复；一条「Inbox reset」条目把它呈现出来。 |

## 参考

- 层级 / 事件：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane,SplitTree,TerminalEvent,PaneInfoDelta}.swift`
- inbox 原语：`apps/mac/CodansCore/Notifications/`
- Settings v3 schema：`apps/mac/CodansCore/Settings/Settings.swift`
- 层级变更面：`apps/mac/codans/App/Clients/HierarchyClient.swift`
- 状态栏宿主：`apps/mac/codans/App/Features/StatusBar/`
