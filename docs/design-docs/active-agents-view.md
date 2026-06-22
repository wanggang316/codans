# 设计文档：AgentState View

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

codans 把编码 agent（Claude Code、Codex CLI、pi、…）当作 Pane 的一等住户来运行。典型会话里用户有 2–8 个 Pane 散布在各 Worktree，多数由 agent 驱动；用户只关注此刻正在工作、刚完成、或正等他输入的那一个。在 AgentState 之前，跨 Pane 表达这一信号的途径只有：(a) 每个 Pane 的 OSC 9;4「busy」顶条；(b) 由同一来源聚合的侧栏 / tab-chip busy 字形；(c) 记录历史 `taskFinished` / `waitingForInput` 事件的 inbox。三者都答不出用户真正会问的那句话——「**现在有哪些 agent 活着、各自在干什么**」。能力与验收标准见 [AgentState 产品规格](../product-specs/active-agents-view.md)。

本设计实现 **AgentState**——一个挂在侧栏底部的常驻面板（`AgentStateSidebarPanel`，标题 "Agents View"），列出当前被识别为运行已知 agent 的每个 Pane 及其派生运行态。这个面板是用户跨所有 worktree 分诊 agent 的唯一去处。

把*单次状态跃迁*分类并呈现为通知的那套系统（见 [notifications.md](notifications.md)）已经存在；AgentState 是同一批原始信号的**并行、独立消费者**——`HierarchyManager` 的前台进程组快照、`TerminalEvent` 流，以及每个 Pane surface 的渲染视口文本。它**不依赖** `NotificationStore`，也不受 mute / 通知设置影响。

## 目标与非目标

**目标**

- 侧栏底部的 AgentState 面板列出所有 worktree 中每个 agent-bearing Pane：agent logo、project + worktree 标签、派生运行态（`working` 带动画指示），以及最近一次状态变化时间。
- 面板顶部有一句话标题（"Agents View"）；超过 4 条时附带 `(N)` 计数 chip。
- 点击行聚焦那个 Pane，按需切换 project / worktree / tab。
- 识别覆盖 `AgentKind` 注册表中的**全部 agent**（当前 11 个：Claude Code、Codex、pi、opencode、Gemini、Cursor Agent、Cline、GitHub Copilot、Kimi、Droid、Amp）。注册表是手维护的 allowlist——新增 agent 是一次代码改动（扩 `AgentKind` + `AgentKindPatterns`），不是配置改动。其余 Pane 不出现在 AgentState 中。
- `AgentStateStore` 拥有每个 Pane 的运行态状态机，由前台进程组快照、`TerminalEvent` 流（视口文本 / idle / teardown）和 `PaneKeyboardActivityTracker` 驱动。纯运行时态——不持久化。
- `Pane` 上两个可选字段（`agentKind`、`agentSessionID`）持久化 Pane 绑定到*哪个* agent。Pane 身份判定跨重启存活；运行态不存活。

**非目标**

- 带丰富跃迁历史的通用 agent FSM。AgentState 只存渲染面板所需的最小派生态，仅此而已（根因见「技术决策」）。
- 识别 allowlist 之外的任意 agent（aider、自研内部 CLI、未来工具）。泛化此能力是 future-work。
- 新 IPC 面或 `codans` 命令。AgentState 仅在 app 内。
- 重新实现通知 inbox 的 UX。两套系统不共享 UI；被 mute 的 Pane 仍出现在 AgentState 中。
- 跨窗口 / 多 app 行为。AgentState 锚定在 codans 主窗口的侧栏。
- macOS 菜单栏 (`NSStatusItem` / Dynamic-Island 风格) 形态。v1 仅 app 内侧栏面板；菜单栏变体是 future work（见 Alternative D）。
- 持久化派生运行态。只有*绑定*（agentKind、agentSessionID）跨重启存活；working / blocked / finished 每次启动从实时事件流重算。

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
                          keyboard tracker
```

**为什么是这个形状。** 两个设计张力驱动这次拆分。

第一是**identification vs. state**：「这个 Pane 到底是不是 agent」是一个缓变、可持久、需要跨重启存活的事实（这样用户带 logo 的行不会在重启后全部消失）。「这个 agent 现在在干什么」是快变、可丢弃的派生。两者拆开后每层都能很小（不拆开的代价见「技术决策」）。

第二是**与 notifications 独立**。通知检测器与 AgentState 共享三条输入流，但回答不同问题。强迫一方消费另一方的输出（例如「AgentState 读 InboxStore 来定 `finished` 态」）会把 mute 策略、去重窗口和规则语法耦合进一个本不该关心它们的层。两者都订阅原始信号；输出永不交叉。

第三个、较轻的压力：`Pane.labels` 这个 `Set<String>` 已经携带 `notifications:muted`，它故意是字符串——通知层把 labels 当作正交的用户可见标签。复用它来塞 `agent:claude` 会让两个无关子系统通过同一个无类型集合耦合。我们宁可付出两个显式 `Pane.agentKind` / `Pane.agentSessionID` 字段的小迁移成本（见 Alternative A）。

### 数据存储

catalog 在 `Pane`（`CodansCore/Pane.swift`）上新增两个可选字段。两者都持久化，都默认 nil。

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
    /// always writes nil — banner parsing is deferred to a follow-up
    /// so it can land independently.
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
    // displayName maps each to its user-facing label
    // (e.g., .copilot → "GitHub Copilot").
}
```

raw value 是持久进 `catalog.json` 的稳定标识符；`displayName` 是面板里渲染的用户可见标签。

**Codable 向前兼容。** 两字段都可选、仅非 nil 时写出——旧 `catalog.json` 原样解码（`decodeIfPresent`），降级到旧 codans build 静默丢弃这两个字段。无需迁移脚本。

**无新增持久化运行态。** `AgentStateStore` 的派生态（idle / working / blocked / finished）完全在内存，每次启动从事件流重建。为了让重启后面板立刻显示而非空白追赶，启动时用持久 catalog 里的 `(paneID, kind, state)` 做一次 `seedRestored` 预填（seeded 行的 scratch 以 `userInputSeen = true` 初始化，使恢复态不会在任何用户交互前被翻成合成的 finished 信号，下一条真实视口事件再精化它）。

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
- 不匹配的 job → **不立即清**，而走一个迟滞计数器：`Presence.releaseMissThreshold = 6`，连续 6 次未命中才释放绑定。任意一次命中把计数清零。这避免了 agent 短暂把前台让给子进程（git、build、pager）时绑定被反复抖掉。

这意味着重绑由前台进程组变化驱动，**不依赖** OSC 133 prompt-return。一个仍在跑的 agent 始终是其 Pane 的前台进程，因此「Claude 退到 shell、再启动 Codex」会被自然观察到——shell 提示符下前台组只剩 shell（不匹配，开始累计 miss），新 agent 出现则立即重绑。

### 运行态派生

`AgentStateStore`（`App/Features/AgentState/AgentStateStore.swift`，`@MainActor @Observable`）持有：

```swift
struct AgentEntry {
    let kind: AgentKind
    let sessionID: String?
    var state: AgentRuntimeState
    var lastTransitionAt: Date
}

enum AgentRuntimeState: String, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case blocked
    case finished
}
```

`entries: [PaneID: AgentEntry]` 是 `@Observable`-tracked 的；每次变更写回完整 struct 以可靠触发变更追踪。每个 Pane 另有一份 scratch（`rawState`、`seen`、`userInputSeen`、`lastViewportText`、`lastWorkingAt`），即便在 agent 被识别前也保留，使先到的信号在 `onAgentBound` 落地时仍能给出正确初态。

**raw 分类只有三态。** `PaneAttentionInterpreter.classifyAgentActivity(kind:viewportText:) -> AgentActivityState` 返回 `working` / `blocked` / `idle`，对每个 `AgentKind` 跑各自的渲染区启发式（如 Claude 的 spinner / "esc to interrupt"、Codex 的 "• Working ("、各家的批准提示）。`finished` **不是** raw 态——它是 display 派生：一个 Pane 从活动态退回 idle、且用户当时没在看它（`seen == false`）。这条派生与 Gump 给定的语义一致：`finished` 恰是「这个 Pane 曾在工作、由此产生的跃迁尚未被确认」。

输入与反应（一处——系统里唯一的状态机）：

| 信号 | 效果 |
|---|---|
| `paneViewportChanged`：渲染区分类为 `working`（在观察到用户输入后） | raw 态变 `working` |
| `paneViewportChanged`：渲染区分类为 `blocked`（agent 专属启发式） | raw 态变 `blocked` |
| `paneIdle`：活动→idle 且该 Pane 当时未被观察 | display 态变 `finished` |
| `paneExited` / `paneCrashed` / `paneClosedByTab` | 丢弃 entry 与 scratch（teardown） |
| `PaneKeyboardActivityTracker` 在该 Pane 记到按键 | 标 seen；乐观清除 `blocked` 态 |
| Pane 获得焦点（selection 链指向它且 app 在前台） | 标 seen；乐观清除 `blocked` 态 |
| `agentKind` 变 nil / `onAgentUnbound` | 从注册表丢弃 entry |

Desktop notification（OSC 9）与终端 bell **不**在此表。bell 或 OS 通知是 inbox 值当的*事件*，而非实时活动信号——bell 为完成提示音、错误音、命令结束响起的频率，和为真正提示响起的频率一样高。通知检测器独立消费那些 delta；实时 agent 态以渲染区此刻所说为准。这让 `blocked` 不会在屏幕上没有真正提示时粘住。

`paneOutput` 也**刻意**不在表中。libghostty bridge 当前不把子进程字节转发到引擎的 output 流（见 `PaneSurface.onOutput`——deferred），故该事件在生产中实际是死的，绑在它上面会是虚假依赖。读稳定的视口快照而非原始字节，也让 TUI 重绘噪音不会把 Pane 钉在 `.working`。

`working` 仅在绑定的 agent 已观察到用户输入、且其渲染区匹配 agent 专属 working cue 后才触发。Title 变化在运行态派生中被忽略。对 Claude Code，`stabilizeAgentActivity` 加一个 `claudeWorkingHold = 1.2s` 的迟滞：working→idle 的瞬时抖动在 1.2 秒内仍按 working 计，避免 recap 重渲染期间的 done→working→done 闪烁。

最终态是 scratch 字段的纯函数：

```
derive(pane) =
    .blocked     if rendered region classifies as blocked
    .working     if rendered region classifies as working (after user input)
    .finished    if first active → idle transition is unobserved (seen == false)
    .idle        otherwise
```

`AgentStateStore` 在本地拥有这个 observed/acknowledged 标志——它**不读** `NotificationStore.readAt`，使两个子系统保持独立。

一道防御性的 15s auto-reset 在更低一层的 `PaneSurface`：任何非 REMOVE 的 OSC 9;4 状态会安排一个 per-surface 任务，若无新的 progress 事件抵达就合成一个 REMOVE，使崩溃或卡死的发射器无法把 badge 整个会话钉在 `.working`。

显示优先级为 `blocked > working > finished > idle`。

### UI

**侧栏底部面板** `AgentStateSidebarPanel` 锚在侧栏的 bottom safe-area inset，由 `HierarchySidebarView` 在 `agentStatePanelOpen` 时挂载。面板高度可拖拽（顶边 resize strip），由宿主经 `@AppStorage` 持久化。背景是桥接的 `NSVisualEffectView`（`.popover` 材质 + `.behindWindow` 混合），因为 SwiftUI 的 `Material` 是基于图层的模糊、够不到宿主窗口之外。

布局（上→下）：resize strip（hover 才淡入 capsule）· 标题行（"Agents View" + 仅当 N > 4 时的 `(N)` chip）· divider · `AgentStateRowView` 的可滚动列表，顺序由 `SortedEntriesProvider` / `AgentStateOrderCoordinator` 给出。点击行经宿主的 `onTapRow` 派发聚焦；**面板在点击后刻意保持打开**，便于用户在 agent 间 fan-jump。

每行：
- 左侧 16pt agent logo（资源缺失回落到 SF Symbol）。
- 标题行 `<ProjectName> / <WorktreeName>`（中段截断）；解析不到来源时显示 em-dash `—`（catalog 已移除该 Pane 的「ghost」行）。
- 副标题：状态图标 + 状态标签 + 相对时间（"working · 12s" / "blocked · 4m" / "finished · just now" / "idle · 1h"）。
- 状态图标集：`.blocked` → 琥珀；`.working` → accent 旋转；`.finished` → 绿勾；`.idle` → 次级灰圈。
- 行密度（两行 `normal` / 一行 `compact`）与 auto-sort 由 `Settings → General → Agents View` 控制。

排序由 `SortedEntriesProvider` 给出：先按状态优先级桶（triage 顺序），桶内按 `lastTransitionAt` 降序；`AgentStateOrderCoordinator` 对状态驱动的重排做防抖，使列表不随 agent 状态翻动而闪烁（reduce-motion 用户拿到无动画的重排）。

> **附注：** 另有一个 `AgentStateView`（width 320 的 popover 变体，标题 "Active Agents (N)"）保留在 feature 目录中，但当前装配的宿主是侧栏面板，不是 popover。

**Logo 资源** 放在 `apps/mac/codans/Resources/Assets.xcassets/AgentLogos/`，每个已识别 kind 一个 imageset（light/dark 双变体）。来源是各 agent 官方 press / brand kit；license 风险记在 Risks。回落 SF Symbol 覆盖任何尚无资源的 kind。

### 组件边界

| 层 | 模块 | 职责 | 禁止 import |
|---|---|---|---|
| `CodansCore` | `Agents/{AgentKind, AgentKindPatterns, ForegroundJob, ForegroundJobClassifier}`、`Pane.agentKind/agentSessionID`、`Notifications/PaneAttentionInterpreter+Agents`（raw 分类器） | 值类型、模式表、渲染区分类 | 无 |
| `apps/mac/codans/Runtime` | `AgentBinder.swift` | 识别 agent kind、经 `HierarchyClient` 写 Pane 字段 | App features 层 |
| `apps/mac/codans/App/Features/AgentState` | `AgentStateStore`、`AgentStateSidebarPanel`、`AgentStateRowView`、`AgentStateOrderCoordinator`、`SortedEntriesProvider`、`AgentLogoView` | 派生态、UI | Runtime internals；**不 import** `NotificationStore` |
| `apps/mac/codans/App/Features/HierarchySidebar` | 更新的 `HierarchySidebarView` | 宿主 `AgentStateSidebarPanel` | — |

**依赖方向。** `AgentState → CodansCore`、`AgentState → HierarchyClient`（读 + 聚焦）、`AgentState → catalog`（只读）、`AgentState → PaneKeyboardActivityTracker`（读）。AgentState **不** import `Notifications/*`。

`HierarchyClient` 新增两个方法，背后是走标准防抖保存管线的 `HierarchyManager` writer：

```swift
var setPaneAgentKind: @MainActor @Sendable (PaneID, AgentKind?) -> Void
var setPaneAgentSessionID: @MainActor @Sendable (PaneID, String?) -> Void
```

`AgentStateStore` 经 `reconcileMembership(livePaneIDs:)` 兜底——对每次结构性 catalog 变更（`hierarchyMutated`）丢弃已不在 catalog 中的 entry，斩断「ghost 行被再持久化进 quit snapshot、下次启动又被 seed」的回路。它收一个扁平 `Set<PaneID>` 而非 `Catalog`，使 store 不沾 hierarchy import（catalog 遍历留在 wiring 层）。

## 技术决策

**为何不持久化跃迁、不建通用 agent FSM。** AgentState 只在内存里保留每个 Pane 的最近一个派生态，跃迁历史不落盘。理由：

- AgentState 恰好只需「现在是哪个态」来渲染一份永远反映当下的列表，而非一份跃迁日志。带丰富跃迁历史的 per-Pane FSM 会为这个目标翻倍其表面积，且需要持久化与迁移。
- identification（缓变、可持久）与 runtime state（快变、可丢弃）一旦混在同一台状态机里，那台机器就会被迫同时承担「跨重启存活」与「每信号高频更新」两套相互冲突的要求，从而膨胀。拆成 `AgentBinder`（写持久 Pane 字段）+ `AgentStateStore`（纯内存派生）后，每层都很小，且派生层在纯 Swift 里零 I/O 可测。
- 跃迁历史确有价值，但那是通知 inbox 的领域（它消费 OSC 9 / bell delta 并持久化）。让 AgentState 也存一份会与 inbox 的职责重叠。

**为何与 notifications 共享原始信号但输出永不交叉。** 通知检测器与 AgentState 订阅同三条输入流（前台进程组快照、`TerminalEvent`、视口文本），但回答不同问题——「刚发生了什么」vs「现在正在发生什么」。强迫一方消费另一方的输出（如「AgentState 读 `InboxStore` 来定 `finished` 态」）会把 mute 策略、去重窗口与规则语法耦合进一个本不该关心它们的层。因此两者各自从原始信号派生，`AgentStateStore` 不 import `NotificationStore`。

## 备选方案（Alternatives）

- **A — 复用 `Pane.labels` 的 `agent:<kind>` 字符串键。** 否决（Gump 明确提出的理由）：字符串键在字段层不被类型检查、鼓励读写双方漂移，并把两个无关子系统（通知 mute 与 agent 识别）混进一个无类型袋。两个可选字段的迁移成本很小；长期清晰度收益很大。
- **B — per-Pane `AgentStateTracker` FSM 并持久化跃迁。** 否决：AgentState 恰好只需最近一个态，而非跃迁日志；持久化跃迁会让一个「永远反映当下的列表」翻倍其表面积。上面基于标志的派生在纯 Swift 里零 I/O 可测。
- **C — 把 `finished` 耦合到 `InboxEntry.readAt`。** 否决：(i) 它会从一个 UI feature 强行引一条依赖边进通知存储层，正是「双消费者—单信号源」拆分要避免的耦合；(ii) mute / 去重策略随之漏进 AgentState 语义；(iii) 本地标志配以相同的清除触发（focus、keystroke、新 output）产出相同的可观察行为，却无耦合。
- **D — macOS `NSStatusItem`（菜单栏）取代 app 内面板。** v1 否决（Gump 拍板）：deferring `NSStatusItem` 把工作留在既有 SwiftUI 宿主内。`AgentStateStore` 与视图的拆分刻意 UI-agnostic，故菜单栏变体是未来的一次替换、而非重写。
- **E — 实时前台 job 轮询。** 采纳。运行时通过嵌入式终端 API 读 PTY 前台进程组，每周期为所有 Pane 采一次进程表快照。这避开了 title 启发式，同时仍覆盖从已开 shell 启动的 agent 与经运行时 wrapper 启动的 agent。
- **F — 自动纳入所有 Pane（无识别步骤），未证实前显示为 `generic`。** 否决：那样面板会列出每个 shell、build 脚本和 REPL，淹没真正的 agent。产品价值就在这份策展。

## 横切关注（Cross-Cutting）

**测试。**
- `AgentKindPatterns` 是纯表 → `CodansCoreTests` 对每个模式跑穷举单测（fixture 前台 job）。
- `PaneAttentionInterpreter+Agents` 的渲染区分类 → `PaneAttentionInterpreterTests` 对每个 `AgentKind` 跑视口文本 fixture。
- `AgentStateStore` 派生 → `Tests/Features/AgentState/AgentStateStoreTests` 用手搓信号序列（无实时运行时）驱动 (scratch, signal) → new state → derived state。
- `AgentBinder` → 对一个记录 `setPaneAgentKind` 调用的 in-memory `HierarchyClient` spy 测：bind / rebind / no-op / release（含 miss-threshold 迟滞）。
- 排序：`SortedEntriesProviderTests`、`AgentRowOrderingTests`、`AgentStateOrderCoordinatorTests`。

**性能。** `entries` 按 `PaneID` 键控；典型会话 <20 个 Pane。每信号派生是 O(1) hashing + 查表。面板至多 ~20 行，`LazyVStack` 在此规模上已绰绰有余。

**可观测性。** `Logger(subsystem: "com.gumpw.codans.agentstate")` 在识别（`binder` category，单行 `action=… pane=… kind=old→new pgid=… procs=… misses=m/t`，进程名只取 basename、绝不记 commandLine——argv 可能含密钥）与每次状态跃迁（`store` category）发日志。无 counter / metric。

**无障碍。** 行 `accessibilityLabel` 组合 agent / worktree / 状态 / 时间；状态图标 `accessibilityHidden(true)`（标签已编码状态）；pulse 动画尊重 `accessibilityReduceMotion`。

**迁移 / 回滚。** 无 schema 迁移（可选字段）。停用 AgentState 即从 `HierarchySidebarView` 摘掉面板；持久 `agentKind` 字段原地保留、停用时忽略——无数据丢失。

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

- 产品规格：[active-agents-view.md](../product-specs/active-agents-view.md)
- AgentKind / 识别：`apps/mac/CodansCore/Agents/{AgentKind,AgentKindPatterns,ForegroundJob,ForegroundJobClassifier}.swift`
- 渲染区分类器：`apps/mac/CodansCore/Notifications/PaneAttentionInterpreter+Agents.swift`
- 绑定：`apps/mac/codans/Runtime/AgentBinder.swift`
- 运行态 store + UI：`apps/mac/codans/App/Features/AgentState/`
- 侧栏宿主：`apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`
- 层级变更面：`apps/mac/codans/App/Clients/HierarchyClient.swift`
