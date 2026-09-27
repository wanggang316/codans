# 设计文档：AgentState View

**状态：** Agents 面板已上线；HAN-167 的 unknown / error、协议与恢复扩展已在本分支实现，尚未发布。
**作者：** Gump（与 Claude）

## 背景与范围

codans 把编码 agent（Claude Code、Codex CLI、pi、…）作为 Pane 运行。AgentState 汇总跨 Worktree 的 agent 身份和运行态，让用户定位正在工作、刚完成或等待输入的 Pane。它与表示终端进度的 OSC 9;4 指示器、记录通知事件的 inbox 分工独立。

**AgentState** 是一个挂在侧栏底部的常驻面板（`AgentStateSidebarPanel`，标题 "Agents View"），列出当前被识别为运行已知 agent 的每个 Pane 及其派生运行态。CLI 的 `agent status` 与 `agent wait` 也读取同一状态源。

把*单次状态跃迁*分类并呈现为通知的那套系统（见 [notifications.md](notifications.md)）已经存在；AgentState 是同一批原始信号的**并行、独立消费者**——`HierarchyManager` 的前台进程组快照、`TerminalEvent` 流，以及每个 Pane surface 的渲染视口文本。它**不依赖** `NotificationStore`，也不受 mute / 通知设置影响。

## 目标与非目标

**目标**

- 侧栏底部的 AgentState 面板列出所有 worktree 中每个 agent-bearing Pane：agent logo、project + worktree 标签、派生运行态（`working` 带动画指示），以及最近一次状态变化时间。
- 面板顶部有一句话标题（"Agents View"）；超过 4 条时附带 `(N)` 计数 chip。
- 点击行聚焦那个 Pane，按需切换 project / worktree / tab。
- 识别范围由 `AgentKind` 与唯一的 `AgentRegistry` 注册表定义；每项组合身份元数据、启动描述、终端解析器和可选会话恢复器。`AgentRuntimeAdapters` 是兼容入口。未匹配注册表的 Pane 不出现在 AgentState 中。
- `AgentStateStore` 保存每个 Pane 的已接受观测并派生显示状态，由前台进程绑定、`TerminalEvent` 流和 `PaneInputCoordinator` 的外部输入修订驱动。高频更新留在内存，退出时保存恢复所需的最近状态快照。
- `Pane` 上两个可选字段（`agentKind`、`agentSessionID`）持久化 Pane 绑定到*哪个* agent。绑定字段写入 `catalog.json`；运行态的退出快照由 `sessions.json` 单独保存。

**非目标**

- 带丰富跃迁历史的通用 agent FSM。AgentState 只存渲染面板所需的最小派生态，仅此而已（根因见「技术决策」）。
- 识别 allowlist 之外的任意 agent（aider、自研内部 CLI、未来工具）。未提供通用识别配置。
- 重新实现通知 inbox 的 UX。两套系统不共享 UI；被 mute 的 Pane 仍出现在 AgentState 中。
- 跨窗口 / 多 app 行为。AgentState 锚定在 codans 主窗口的侧栏。
- macOS 菜单栏 (`NSStatusItem` / Dynamic-Island 风格) 形态。入口仅位于 app 内侧栏，未提供菜单栏变体（见 Alternative D）。
- 持久化逐次状态跃迁或在每次状态更新时写盘。退出快照只为恢复仍存活的 daemon 提供初态，不能代替实时识别。

## 设计

### 总览

三个组件，全部 in-process，单向依赖：

```
   identification           runtime state           UI
 ┌──────────────────┐    ┌─────────────────┐   ┌────────────────────┐
 │  AgentBinder     │───▶│  AgentStateStore  │──▶│ AgentStateSidebar  │
 │  (writes Pane    │    │  (derives state │   │ Panel              │
 │   fields)        │    │   from signals) │   │  (sidebar bottom)  │
 └──────────────────┘    └─────────────────┘   └────────────────────┘
        ▲                       ▲                       │
        │                       │              click ──▶│
        │                       │              focusPane via
        foregroundJob     runningPanes,        HierarchyClient
        snapshots         viewport text,
                          external input revisions
```

**职责划分。** 身份、运行态和通知分别承担不同的数据与更新契约。

第一是**identification vs. state**：「这个 Pane 到底是不是 agent」是一个缓变、可持久、需要跨重启存活的事实（这样用户带 logo 的行不会在重启后全部消失）。「这个 agent 现在在干什么」是快变、可丢弃的派生。两者拆开后每层都能很小（不拆开的代价见「技术决策」）。

第二是**与 notifications 独立**。通知检测器与 AgentState 消费同一运行时事件源的不同信号，但回答不同问题。强迫一方消费另一方的输出（例如「AgentState 读 InboxStore 来定 `finished` 态」）会把 mute 策略、去重窗口和规则语法耦合进一个本不该关心它们的层。两者都订阅原始信号；输出永不交叉。

第三个、较轻的压力：`Pane.labels` 这个 `Set<String>` 已经携带 `notifications:muted`，它故意是字符串——通知层把 labels 当作正交的用户可见标签。复用它来塞 `agent:claude` 会让两个无关子系统通过同一个无类型集合耦合。我们宁可付出两个显式 `Pane.agentKind` / `Pane.agentSessionID` 字段的小迁移成本（见 Alternative A）。

### 数据存储

catalog 的 `Pane`（`CodansCore/Pane.swift`）包含两个可选绑定字段。两者都持久化，都默认 nil。

```swift
public struct Pane: Equatable, Sendable, Identifiable {
    // … existing fields …

    /// Identifies the agent tool the user is running in this pane.
    /// nil = never identified as an agent (or explicitly cleared).
    /// Once bound, the value sticks across pane lifetime and app
    /// relaunches until AgentBinder observes a rebind condition
    /// (foreground job changes to a different / no agent).
    public var agentKind: AgentKind?

    /// The agent's own session identifier when one can be captured.
    /// The field is declared and persisted, but AgentBinder currently
    /// does not extract a session identifier from the terminal banner.
    public var agentSessionID: String?
}

public enum AgentKind: String, Codable, Sendable, CaseIterable, Equatable {
    case claudeCode = "claude-code"
    case codex
    case pi
    case opencode
    case gemini
    case cursorAgent = "cursor-agent"
    case cline
    case copilot
    case kimi
    case droid
    case amp
    case grok
    case omp
    // displayName maps each to its user-facing label
    // (e.g., .copilot → "GitHub Copilot").
}
```

raw value 是持久进 `catalog.json` 的稳定标识符；`displayName` 是面板里渲染的用户可见标签。

**Codable 向前兼容。** 两字段都可选、仅非 nil 时写出——旧 `catalog.json` 原样解码（`decodeIfPresent`），降级到旧 codans build 静默丢弃这两个字段。无需迁移脚本。

**运行态退出快照。** `AgentStateStore` 在内存里维护最近的 unknown / idle / working / blocked / error / finished 显示状态，不保存跃迁历史。退出时，`AppState` 的 `agentSnapshotProvider` 从 registry 生成 `PersistedAgentRecord`（pane ID、kind/state 的 raw value、PID、采集时间），交给 `SessionLifecycle` 写入 `sessions.json` 的 `SessionCatalog.agents`。`catalog.json` 中的 Pane 绑定字段不承担运行态快照存储。

启动恢复由 `SessionCoordinator.restoredAgents` 提供记录。`selectAgentSeeds` 只保留 **daemon 存活且 kind/state raw value 均可解码**的记录：优先复用启动扫描的 liveness 结果，未覆盖的 Pane 直接探测 daemon socket；`.dead` 和仅有磁盘快照的 `.snapshot` 都不播种 agent 状态。存活检测以 daemon 为单位，不以退出快照中的 PID 为准；daemon 存活也不替代后续前台进程组对 agent 身份的确认。

满足条件的记录交给 `seedRestored` 预填，并等待首次真实分类接管显示。退出快照不包含有效的实例绑定或已接受观测，不能授权自动恢复；未通过恢复门槛的 Pane 等待实时识别，不显示由退出快照推断的 agent badge。

### Agent 识别

**识别由 Pane 的前台进程组背书，而非任何软信号。** 嵌入式终端暴露每个 surface 的前台进程组 id；运行时采样进程表、按该 id 分组，发出 `TerminalEvent.foregroundJobChanged(PaneID, ForegroundJob)`。`ForegroundJob` 携带该组每个进程的真实 `pid` / `processGroupID` / `argv0` / `commandLine`。

`AgentKindPatterns.classify(foregroundJob:) -> AgentKind?` **只**对前台进程组分类，刻意忽略 terminal title、initial command 和 desktop-notification 文本：

- 可执行 basename / 进程名匹配得分最高（`argv0`=80、`processName`=70）；
- 常见运行时 wrapper（`node`、`npx`、`python`、`bun`、shell、`tmux` 等）通过 command-line token 检视（得分 40）——使「子进程名像 agent」压过「仅在命令行里提到 agent 的通用 launcher」；
- 通用 launcher 名（如 `agent` / `cursor`）仅当命令行携带强 agent 专属 token（`cursor-agent` / `cursor.app`）时才映射。

若前台 job 不匹配任何受支持 agent，Pane 不绑定、不出现在 AgentState 中。

**`AgentBinder`** 位于 `apps/mac/codans/Runtime/AgentBinder.swift`（Runtime 层，与 `HierarchyManager` 同列）。它消费前台 job 快照和 Pane 生命周期事件（`paneExited`、`paneCrashed`、`paneClosedByTab`）。每次前台 job 变化跑一次 `classify`；当结果与 `pane.agentKind` 不同，经 `HierarchyClient.setPaneAgentKind(paneID, kind)` 写入。

**绑定与解绑——前台 job 是权威信号：**
- 匹配的 job → 绑定 / 重绑到该 `AgentKind`；
- `paneExited` / `paneCrashed` / `paneClosedByTab` → 清字段；
- 不匹配的 job → **不立即清**，而走一个迟滞计数器：`Presence.releaseMissThreshold = 6`，连续 6 次有效采样未命中才释放绑定。已有验证实例时，空 OS 探测只暂停绑定有效性，不累计为实例退出。任意一次命中把计数清零。这避免了 agent 短暂把前台让给子进程（git、build、pager）时绑定被反复抖掉。

重绑由前台进程组变化驱动，**不依赖** OSC 133 prompt-return。本地自动恢复还要求 `AgentBinding`：实际 Agent PID、进程启动时间、PGID、surface generation 和实例 ID。即使 `AgentKind` 不变，进程或 surface 替换也会创建新实例并隔离旧观测；暂时无法确认身份时暂停自动恢复。完整身份与替换约束见 [Agent integration contracts](agent-integration-protocols.md#instance-ownership-precedes-observation)。

### 运行态派生

`AgentStateStore`（`App/Features/AgentState/AgentStateStore.swift`，`@MainActor @Observable`）保存 `entries: [PaneID: AgentEntry]`。每项包含显示状态、最近变化时间、可选实例绑定和已接受观测；逐 Pane scratch 保存 `TerminalObservationTracker`、文本与解析缓存、采样序号、working 迟滞和 `seen` 标记。

纯 `AgentTerminalParser` 返回 `TerminalParseResult`，状态为 `unknown`、`idle`、`working`、`blocked` 或 `error(AgentFailure)`；tracker 处理证据归属及旧错误抑制后形成 `AgentObservation`。`unknown` 表示证据不足，不等于 idle 或可输入。UI / IPC 投影保留错误状态名称，并额外提供注意力状态 `finished`：

```swift
enum AgentRuntimeState: String, CaseIterable, Equatable, Sendable {
    case unknown, idle, working, blocked, error, finished
}
```

主要输入与显示行为：

| 信号 | 效果 |
|---|---|
| `paneAgentSnapshot` | 仅接受匹配当前绑定且采样序号递增的观测 |
| `paneViewportChanged` | 只供没有验证绑定的显示路径使用，不能授权本地自动恢复 |
| 外部输入修订 | 当前观测失效为 unknown、抑制旧错误证据并标 seen；下一次采样重新分类 |
| Pane 获得焦点 | 标 seen，清除 finished 注意力；不撤销 error 或 blocked 事实 |
| `paneIdle` | 按已有观测刷新显示迟滞，不凭空证明任务完成 |
| `paneExited` / `paneCrashed` / `paneClosedByTab` / `onAgentUnbound` | 丢弃 entry 与 scratch |

`stabilizeAgentActivity` 对 working→idle 应用 `agentWorkingHold = 1.2s` 的迟滞；unknown、blocked 和 error 不经过该保持。只有未被观察的 working→idle 跃迁产生 `finished`。error→idle 不表示成功，unknown / blocked / error 也会清除先前的 finished 注意力。Title 仅用于展示；OSC 9、bell、OSC 9;4 进度和 `paneOutput` 不作为此处的 Agent 执行状态证据。

`AgentStateStore` 自己保存 `seen`，不读取通知 inbox。自动恢复消费已接受的观测和验证绑定，不读取显示迟滞或 finished。解析、证据生命周期、实例替换和输入协调契约统一记录在 [Agent integration contracts](agent-integration-protocols.md)；策略与用户操作见 [Agent Error Recovery](agent-error-recovery.md)。

### IPC 与 CLI

`agent.listStates` 对应 `codans agent status`，按 Project → Worktree → Tab → Pane 顺序返回 registry 中的条目，包括 agent、派生状态、最近变化时间、层级 ID、临时 Pane handle 与焦点标记。`codans agent list` 列出启动配置，与运行态列表不同。

`agent.wait` 对应 `codans agent wait <pane> --until <condition>`，在服务端按 200 ms 间隔读取同一状态源。条件为 `unknown`、`idle`、`working`、`blocked`、`error`、`finished`、`changed` 或 `exit`：`changed` 比较起始条目的 state 与 kind，`exit` 在 entry 消失或 Pane 移除时满足。开始等待时 Pane 必须存在；已存在但无 agent 的 Pane 可立即满足 `exit`。CLI 默认等待 60 秒，允许 1–600 秒；超时返回 `WAIT_TIMEOUT`（exit 11）。这些结果是屏幕与前台进程的派生状态，不是 agent 协议提供的任务完成确认。

退出确认同样读取该状态：`working` 与 `blocked` 视为任务未结束，与终端命令 / progress 的忙碌信号共同决定 `quitConfirmation = auto` 是否弹窗。

Source: [AgentHandlers.swift](../../apps/mac/codans/App/Features/Socket/AgentHandlers.swift), [AgentCommands.swift](../../apps/mac/codans-cli/Commands/AgentCommands.swift), [SessionLifecycle.swift](../../apps/mac/codans/Runtime/SessionLifecycle.swift).

### UI

**侧栏底部面板** `AgentStateSidebarPanel` 锚在侧栏的 bottom safe-area inset，由 `HierarchySidebarView` 在 `agentStatePanelOpen` 时挂载。面板高度可拖拽（顶边 resize strip），由宿主经 `@AppStorage` 持久化。背景是桥接的 `NSVisualEffectView`（`.popover` 材质 + `.behindWindow` 混合），因为 SwiftUI 的 `Material` 是基于图层的模糊、够不到宿主窗口之外。

布局（上→下）：resize strip（hover 才淡入 capsule）· 标题行（"Agents View" + 仅当 N > 4 时的 `(N)` chip）· divider · `AgentStateRowView` 的可滚动列表，顺序由 `SortedEntriesProvider` / `AgentStateOrderCoordinator` 给出。点击行经宿主的 `onTapRow` 派发聚焦；**面板在点击后刻意保持打开**，便于用户在 agent 间 fan-jump。

每行：
- 左侧 16pt agent logo（资源缺失回落到 SF Symbol）。
- 标题行 `<ProjectName> / <WorktreeName>`（中段截断）；解析不到来源时显示 em-dash `—`（catalog 已移除该 Pane 的「ghost」行）。
- 副标题：状态图标 + 状态标签 + 相对时间（"working · 12s" / "blocked · 4m" / "finished · just now" / "idle · 1h"）。
- 状态图标集：`.error` → 红色感叹号；`.blocked` → 琥珀暂停；`.working` → 动画活动指示；`.finished` → 绿勾；`.idle` → 次级灰圈；`.unknown` → 次级问号。
- 行密度（两行 `normal` / 一行 `compact`）与 auto-sort 由 `Settings → General → Agents View` 控制。

**行 hover 摘要卡** `AgentSessionSummaryCard`：指针在一行上停留 500ms 后，以 popover（`arrowEdge: .trailing`）弹出该会话的速览——agent logo + 名称、状态 chip、`<project> / <worktree>` 面包屑 + 状态停留时长、session 任务标题（该 worktree 内该 agent 最近一次会话的首条用户 prompt）、可选 activity 行（Pane 的 OSC 标题，仅在其信息量超过 agent 自身名字时显示）、以及 `<short id> · <相对时间>` 页脚。

卡片内容是**开卡前解析好的快照**（`AgentSessionSummarySnapshot`），session 扫描（本地 detached / Server 项目走 SSH）在 hover dwell 之后、popover 弹出之前完成，而非弹出后异步填充：popover 在 presented 状态下改变内容尺寸，会让 SwiftUI 在显示周期内发起带动画的窗口 resize，从而在 CATransaction commit handler 里再嵌套一个 run loop，踩到已释放的 run-loop observer 而崩溃（见 [lessons-learned](../lessons-learned/2026-08-20-agents-view-row-click-segfault-in-popover.md)）。代价是远程项目的卡片要等 SSH 扫描才出现。点击行会先撤下卡片，再把聚焦级联交给下一个 main-loop turn。

排序由 `SortedEntriesProvider` 给出：先按 `error > blocked > finished > working > idle > unknown` 分桶，桶内按 `lastTransitionAt` 降序；`AgentStateOrderCoordinator` 对状态驱动的重排做防抖，使列表不随 agent 状态翻动而闪烁（reduce-motion 用户拿到无动画的重排）。

> **附注：** 另有一个 `AgentStateView`（width 320 的 popover 变体，标题 "Active Agents (N)"）保留在 feature 目录中，但当前装配的宿主是侧栏面板，不是 popover。

**Logo 资源** 放在 `apps/mac/codans/Resources/Assets.xcassets/AgentLogos/`，每个已识别 kind 一个 imageset（light/dark 双变体）。来源是各 agent 官方 press / brand kit；license 风险记在 Risks。回落 SF Symbol 覆盖任何尚无资源的 kind。

### 组件边界

| 层 | 模块 | 职责 | 禁止 import |
|---|---|---|---|
| `CodansCore` | `Agents/{AgentRegistry, AgentKindPatterns, ForegroundJob, ForegroundJobClassifier}`、`Agents/Observation/`、`Pane.agentKind/agentSessionID` | 注册、值类型、渲染区解析与证据接受 | 无 |
| `apps/mac/codans/Runtime` | `AgentBinder.swift`、`TerminalEngine`、`PaneInputCoordinator` | 验证实例身份、采集绑定快照、协调输入及写 Pane 绑定字段 | App features 层 |
| `apps/mac/codans/App/Features/AgentState` | `AgentStateStore`、`AgentStateSidebarPanel`、`AgentStateRowView`、`AgentStateOrderCoordinator`、`SortedEntriesProvider`、`AgentLogoView` | 派生态、UI | Runtime internals；**不 import** `NotificationStore` |
| `apps/mac/codans/App/Features/HierarchySidebar` | 更新的 `HierarchySidebarView` | 宿主 `AgentStateSidebarPanel` | — |

**依赖方向。** `AgentState → CodansCore`、`AgentState → HierarchyClient`（读 + 聚焦）、`AgentState → catalog`（只读）；外部输入修订由装配层转发。AgentState 不依赖通知存储；`PaneAttentionInterpreter` 仅保留兼容分类入口和共享显示迟滞。

`HierarchyClient` 提供两个绑定写入方法，背后是走标准防抖保存管线的 `HierarchyManager` writer：

```swift
var setPaneAgentKind: @MainActor @Sendable (PaneID, AgentKind?) -> Void
var setPaneAgentSessionID: @MainActor @Sendable (PaneID, String?) -> Void
```

`AgentStateStore` 经 `reconcileMembership(livePaneIDs:)` 兜底——对每次结构性 catalog 变更（`hierarchyMutated`）丢弃已不在 catalog 中的 entry，斩断「ghost 行被再持久化进 quit snapshot、下次启动又被 seed」的回路。它收一个扁平 `Set<PaneID>` 而非 `Catalog`，使 store 不沾 hierarchy import（catalog 遍历留在 wiring 层）。

## 技术决策

**为何不持久化跃迁、不建通用 agent FSM。** AgentState 的高频派生在内存中运行，退出只保存最近状态供受 liveness 约束的恢复使用，跃迁历史不落盘。理由：

- AgentState 恰好只需「现在是哪个态」来渲染一份永远反映当下的列表，而非一份跃迁日志。带丰富跃迁历史的 per-Pane FSM 会为这个目标翻倍其表面积，且需要持久化与迁移。
- identification（缓变、可持久）与 runtime state（快变、可丢弃）一旦混在同一台状态机里，那台机器就会被迫同时承担「跨重启存活」与「每信号高频更新」两套相互冲突的要求，从而膨胀。`AgentBinder` 写持久 Pane 绑定字段，`AgentStateStore` 负责内存派生，`SessionLifecycle` 负责退出快照。存储节奏与高频状态派生分离，派生层在纯 Swift 里零 I/O 可测。
- 跃迁历史确有价值，但那是通知 inbox 的领域（它消费 OSC 9 / bell delta 并持久化）。让 AgentState 也存一份会与 inbox 的职责重叠。

**为何与 notifications 共享原始信号但输出永不交叉。** 通知检测器从结构化终端事件派生候选，AgentState 结合前台进程与渲染区派生活动状态；两者回答不同问题——「刚发生了什么」vs「现在正在发生什么」。强迫一方消费另一方的输出（如「AgentState 读 `InboxStore` 来定 `finished` 态」）会把 mute 策略、去重窗口与规则语法耦合进一个本不该关心它们的层。因此两者各自从原始信号派生，`AgentStateStore` 不 import `NotificationStore`。

## 备选方案（Alternatives）

- **A — 复用 `Pane.labels` 的 `agent:<kind>` 字符串键。** 不采用：字符串键在字段层不被类型检查、鼓励读写双方漂移，并把两个无关子系统（通知 mute 与 agent 识别）混进一个无类型袋。两个可选字段的迁移成本很小；长期清晰度收益很大。
- **B — per-Pane `AgentStateTracker` FSM 并持久化跃迁。** 否决：AgentState 恰好只需最近一个态，而非跃迁日志；持久化跃迁会让一个「永远反映当下的列表」翻倍其表面积。上面基于标志的派生在纯 Swift 里零 I/O 可测。
- **C — 把 `finished` 耦合到 `InboxEntry.readAt`。** 否决：(i) 它会从一个 UI feature 强行引一条依赖边进通知存储层，正是「双消费者—单信号源」拆分要避免的耦合；(ii) mute / 去重策略随之漏进 AgentState 语义；(iii) 本地标志配以相同的清除触发（focus、keystroke、新 output）产出相同的可观察行为，却无耦合。
- **D — macOS `NSStatusItem`（菜单栏）取代 app 内面板。** 不采用：入口位于主窗口侧栏，未提供 `NSStatusItem`。`AgentStateStore` 与视图分离，状态派生不依赖侧栏布局。
- **E — 实时前台 job 轮询。** 采纳。运行时通过嵌入式终端 API 读 PTY 前台进程组，每周期为所有 Pane 采一次进程表快照。这避开了 title 启发式，同时仍覆盖从已开 shell 启动的 agent 与经运行时 wrapper 启动的 agent。
- **F — 自动纳入所有 Pane（无识别步骤），未证实前显示为 `generic`。** 否决：那样面板会列出每个 shell、build 脚本和 REPL，淹没真正的 agent。产品价值就在这份策展。

## 横切关注（Cross-Cutting）

**测试。**
- `AgentKindPatterns` 是纯表 → `CodansCoreTests` 对每个模式跑穷举单测（fixture 前台 job）。
- 各 Agent 终端解析器、证据 tracker 与兼容入口 → `AgentObservationParserTests`、`PaneAttentionInterpreterTests` 对视口文本与状态契约跑 fixture。
- `AgentStateStore` 派生 → `Tests/Features/AgentState/AgentStateStoreTests` 用手搓信号序列（无实时运行时）驱动 (scratch, signal) → new state → derived state。
- `AgentBinder` → 对一个记录 `setPaneAgentKind` 调用的 in-memory `HierarchyClient` spy 测：bind / rebind / no-op / release（含 miss-threshold 迟滞）。
- 排序：`SortedEntriesProviderTests`、`AgentRowOrderingTests`、`AgentStateOrderCoordinatorTests`。

**性能。** `entries` 按 `PaneID` 键控；典型会话 <20 个 Pane。每信号派生是 O(1) hashing + 查表。面板至多 ~20 行，`LazyVStack` 在此规模上已绰绰有余。

**可观测性。** `Logger(subsystem: "com.gumpw.codans.agentstate")` 在识别（`binder` category，单行 `action=… pane=… kind=old→new pgid=… procs=… misses=m/t`，进程名只取 basename、绝不记 commandLine——argv 可能含密钥）与每次状态跃迁（`store` category）发日志。无 counter / metric。

**无障碍。** 行 `accessibilityLabel` 组合 agent / worktree / 状态 / 时间；状态图标 `accessibilityHidden(true)`（标签已编码状态）；pulse 动画尊重 `accessibilityReduceMotion`。

**持久化兼容性。** Pane 绑定字段是可选字段；文件中缺失时解码为 nil。关闭侧栏面板不改变绑定字段、运行态派生或 CLI 查询。

**设置。** `Settings → General` 提供 Agents View 的 display mode（normal / compact）与 auto-sort 开关；无独立 enable/disable 开关（面板自身可折叠）。

## 风险

| 风险 | 缓解 |
|---|---|
| 渲染区启发式随某个 agent 改版 TUI 而失配 | 分类表在代码、非配置；每个 `AgentKind` 有视口 fixture 锁住当前模式，更新是一行 PR。 |
| 前台 job 在 agent 短暂让出前台（git / build / pager）时误清绑定 | `releaseMissThreshold = 6` 的迟滞：连续 6 次未命中才释放，任一命中清零。 |
| 多个 writer 竞争 `Pane.agentKind`（binder + 未来手动 reset 路径） | 写入均经 `HierarchyManager` 的 `@MainActor`；既有防抖保存管线已串行化 catalog 变更。 |
| Claude / Codex / 各 agent 的 logo 受 brand-mark license 约束 | 用官方 press / brand kit 与 brand glyph；条款含糊则该 kind 在 v1 回落通用 glyph，商用发布前复审。 |
| `paneIdle` 阈值把工具调用间安静的 agent 误标 `finished` | 与 inbox `taskFinished` 同款权衡；若实践证伪，两个消费者都可在 `DetectionTranslator.idleThreshold` 一处抬高阈值受益。 |
| `AgentStateStore` 与 `NotificationStore` 对「同一事件」判定分歧 | 记录为预期行为——两系统回答不同问题、仅共享原始信号；`AgentStateStore` 纯渲染派生，`NotificationStore` 消费 OSC 9 / bell delta。 |
| OSC 133 不可用时无法用 prompt-return 触发重评 | 已不再依赖它——重绑由前台进程组变化驱动；prompt-return 不再是必要信号。 |

## 参考

- AgentKind / 识别：`apps/mac/CodansCore/Agents/{AgentKind,AgentKindPatterns,ForegroundJob,ForegroundJobClassifier}.swift`
- 渲染区分类器：`apps/mac/CodansCore/Notifications/PaneAttentionInterpreter+Agents.swift`
- 绑定：`apps/mac/codans/Runtime/AgentBinder.swift`
- 运行态 store + UI：`apps/mac/codans/App/Features/AgentState/`
- 侧栏宿主：`apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`
- 层级变更面：`apps/mac/codans/App/Clients/HierarchyClient.swift`
