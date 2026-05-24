# ExecPlan: ActiveAgents View

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-22

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

执行后，用户在 touch-code 主窗口 `WorktreeHeader` 看到一个新的状态条徽章，能一眼分清所有跑在 pane 里的 Agent 当前在干嘛：

- **状态栏**：无 Agent 时徽章隐藏；单个时显示 `<Logo> Claude Code is waiting for input` 这样的整句；多个时按优先级汇总，如 `3 agents working` 或 `2 working · 1 waiting`；任意 `loading` / `waitingForInput` 状态下徽章图标轻微 pulse（遵循 reduce-motion）。
- **悬停 popover**（250 ms 进入 / 150 ms 出延迟、hover bridge）按状态优先级排序列出每条 Agent：左侧 logo、中部 `<Project> / <Worktree>` 路径、右侧状态图标 + 相对时间。状态四态——`waitingForInput`（铃铛 + 琥珀）、`loading`（旋转箭头 + accent）、`finished`（绿勾）、`idle`（空心圆 + 次级色）。
- **点击行**：自动级联 select project → worktree → tab，调用 `HierarchyClient.focusPane(paneID, tabID, worktreeID, projectID)`，popover 关闭。
- **识别覆盖**：Claude Code、OpenAI Codex CLI、Inflection pi 三家。pane 退出时自动解绑；shell 回到 OSC 133 顶层 prompt 且 title 变成另一已知 Agent 时重新绑定。
- **独立性**：与现有通知系统并列消费 `runningPanes` + `TerminalEvent` + `PaneKeyboardActivityTracker`，**不**依赖 `NotificationStore`，muted pane 仍然出现在视图里。

技术上落两层结构：`TouchCodeCore` 新增 `AgentKind` 枚举 + `Pane.agentKind` / `Pane.agentSessionID` 两个 optional 字段（前向兼容旧 catalog）；`apps/mac/touch-code/Runtime/AgentBinder` 在 pane 生命周期内识别并写回字段；`apps/mac/touch-code/App/Features/ActiveAgents/AgentRegistry` 维护派生运行态。完整背景见 design doc。

## Progress

**State:** Draft
**Active worker:** none
**Last handoff:** —
**Cases:** — (project 当前无 `docs/user-tests/`；本计划不带 runtime user-test 验证，详见 §User Test Coverage)

### Task summary

- [ ] T1 — `AgentKind` + `Pane` 字段 + `AgentKindPatterns` 表（TouchCodeCore）— status: not_started
- [ ] T2 — `HierarchyClient.setPaneAgentKind` / `setPaneAgentSessionID` 写入器 — status: not_started
- [ ] T3 — `AgentBinder` 识别器（Runtime 层，订阅 SurfaceInfo + TerminalEvent + 生命周期）— status: not_started
- [ ] T4 — `AgentRegistry` 派生态机（App/Features/ActiveAgents）+ 单测 — status: not_started
- [ ] T5 — `ActiveAgentsPopoverView` + `ActiveAgentsRowView`（命令面板入口可达即视为可见）— status: not_started
- [ ] T6 — `ActiveAgentsBadgeView` 状态栏徽章 + hover bridge + WorktreeHeader 集成 — status: not_started
- [ ] T7 — Logo 资源接入 + 文案优先级 + pulse 动效（含 reduce-motion 分支）— status: not_started
- [ ] T8 — 跨一致性回归测：`DetectionTranslator.classify` 在两个消费者间一致 — status: not_started

### Recent handoffs

（None yet）

### Dismissed items

（None yet）

## Surprises & Discoveries

（None yet — 已知 baseline：libghostty 通过 `SurfaceInfo` **不**暴露前台进程 pid / comm；识别只能走 `initialCommand` + `title` + OSC 9 banner 三段兜底。见 design doc §Agent Identification。）

## Decision Log

- **2026-05-22**：识别字段落到 `Pane.agentKind` / `Pane.agentSessionID`（而非 `Pane.labels` 字符串），换取类型安全与子系统解耦，付一次性 Codable 增量。
- **2026-05-22**：`finished` 仅由 `AgentRegistry` 自己的 `pendingFinished` flag 决定，**不**读 `NotificationStore.readAt`，保留两条消费者独立。
- **2026-05-22**：状态栏入口先做 in-app `WorktreeHeader` 版，`NSStatusItem` 留作后续。`AgentRegistry` 与 `ActiveAgentsBadgeView` 之间走 `@Observable`，前端壳替换不动数据层。
- **2026-05-22**：`agentSessionID` 字段先开但 v1 不实际抓取——避免 banner-parser 与识别耦合在第一版。

## Outcomes & Retrospective

（To be filled at milestone completion）

## Context and Orientation

Related documents:

- Design doc: [docs/design-docs/active-agents-view.md](../design-docs/active-agents-view.md)
- Architecture doc: [docs/architecture.md](../architecture.md)
- Notifications design (parallel consumer，参考其事件流接入方式): [docs/design-docs/notifications.md](../design-docs/notifications.md)
- 已废弃但相关的 C6 v1 FSM 设计（解释为什么 v1 不重启 per-pane FSM）：[docs/design-docs/c6-agent-notifications.md](../design-docs/c6-agent-notifications.md)

Key source files:

- `apps/mac/TouchCodeCore/Pane.swift` — 值类型，本计划在此追加 `agentKind` / `agentSessionID` 两个 optional 字段并升级 Codable。
- `apps/mac/TouchCodeCore/Notifications/DetectionTranslator.swift` — pure 分类函数 `classify(title:body:) -> InboxEntry.Kind`，`AgentRegistry` 与 `NotificationDetector` 共享同一份。
- `apps/mac/touch-code/Runtime/HierarchyManager.swift` — 持久化、selection chain、`runningPanes` Set 的归属点；本计划新增 `setPaneAgentKind` / `setPaneAgentSessionID` 写入器，复用既有 debounced save pipeline。
- `apps/mac/touch-code/App/Clients/HierarchyClient.swift` — TCA 依赖注入接口，本计划在 `liveValue` / `testValue` / `unimplemented` 三处分别加两个新方法。
- `apps/mac/touch-code/Runtime/Ghostty/SurfaceInfo.swift` — `@Observable` per-surface 信息载体；`title` / `lastNotificationTitle` / `bellCount` 为识别与 `waitingForInput` 派生的事件源。注意：**没有 process_info / pid**。
- `apps/mac/touch-code/Runtime/TerminalEngine.swift` — `AsyncStream<TerminalEvent>` 入口；`AgentBinder` 与 `AgentRegistry` 通过 RootFeature 已有的 fan-out 接到事件。
- `apps/mac/touch-code/App/Features/Notifications/PaneKeyboardActivityTracker.swift` — 复用同一 tracker 监听键盘活动，用于 `waitingForInput` / `pendingFinished` 的清除。
- `apps/mac/touch-code/App/Features/Root/RootFeature.swift:170-180,420-435,670-690` — `paneProgressBusyChanged` 流向 `runningPanes` 的现成路径；新 `AgentRegistry` 通过同一个 `engineEventReceived` chain 订阅事件。
- `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderView.swift` + `WorktreeHeaderFeature.swift` — 入口宿主；徽章插在既有 `StatusBarBellView`（inbox bell）旁。
- `apps/mac/touch-code/App/Features/StatusBar/StatusBarFeature.swift` — 已有的 toast 状态栏（与本计划的 ActiveAgents 状态栏概念**不同**：toast 是瞬时通知，ActiveAgents 是常驻徽章）；阅读以避免命名混淆。

术语对齐：

- **Agent** — 在 pane 里跑的、被 `AgentKind` 表识别过的命令行 AI 编程工具（v1 = Claude Code / Codex / pi）。
- **Identification（绑定）** — 把 `agentKind` 写到 `Pane` 上的过程；持久、跨重启留存、由 `AgentBinder` 独占写入。
- **Derived state（派生态）** — `loading / waitingForInput / finished / idle`，由 `AgentRegistry` 从事件流推出，纯 in-memory。
- **Sticky binding（粘性绑定）** — 一旦 `agentKind` 设上，仅在 pane teardown 或 OSC 133 prompt + 新 Agent 模式匹配时解绑/换绑。
- **Hover bridge** — popover 在徽章与 popover 之间允许鼠标"过桥"而不消失的常见 UI pattern；250 ms 进入延迟、150 ms 出延迟在 `ActiveAgentsBadgeView` 一处集中可调。

## Plan of Work

按设计稿三层（identification / runtime state / UI）拆三个 milestone。每个 milestone 单独可验证、单独可 commit。

### Milestone M1：数据模型与识别层（T1–T3）

在这个 milestone 结束时，仓库里存在两件以前没有的东西：

1. `Pane` 类型携带 `agentKind: AgentKind?` 与 `agentSessionID: String?`，旧 catalog.json 解码不报错，新写入往返一致。
2. 一个跑在后台的 `AgentBinder` 已经在监听所有 pane 的 SurfaceInfo / TerminalEvent，会在能识别出 Agent 时把字段写回 catalog。

此 milestone 不出 UI；可通过 dev 设置里**单独**新开的开关 `Settings.developer.activeAgentsDebugLogging` 看到识别日志（仅 dev build；commit log 中明示）。

#### T1：`AgentKind` + `Pane` 字段 + 模式表（TouchCodeCore，纯值类型）

在 `apps/mac/TouchCodeCore/` 新建：

- `Agents/AgentKind.swift`：
  ```swift
  public enum AgentKind: String, Codable, Sendable, CaseIterable, Equatable {
    case claudeCode = "claude-code"
    case codex
    case pi

    public var displayName: String { /* "Claude Code" / "Codex" / "pi" */ }
  }
  ```
- `Agents/AgentKindPatterns.swift`：
  ```swift
  public nonisolated enum AgentKindPatterns {
    /// (token-level, case-insensitive) — 首词或 path basename 即可命中
    public static let initialCommand: [AgentKind: [String]] = [
      .claudeCode: ["claude", "claude-code"],
      .codex:      ["codex"],
      .pi:         ["pi"]
    ]
    /// `SurfaceInfo.title` 前缀 / 包含匹配
    public static let title: [AgentKind: [String]] = [
      .claudeCode: ["Claude Code", "claude"],
      .codex:      ["Codex CLI", "Codex"],
      .pi:         ["pi"]
    ]
    /// OSC 9 banner 商标字串（兜底）
    public static let notificationTitle: [AgentKind: [String]] = [
      .claudeCode: ["Claude"],
      .codex:      ["Codex"],
      .pi:         ["pi"]
    ]
    public static func classify(
      initialCommand: String?, title: String?, notificationTitle: String?
    ) -> AgentKind?
  }
  ```
- 在 `apps/mac/TouchCodeCore/Pane.swift`：
  - 追加 `public var agentKind: AgentKind?` 与 `public var agentSessionID: String?`
  - `init(...)` 加 defaulted 参数 `agentKind: AgentKind? = nil, agentSessionID: String? = nil`
  - `CodingKeys` 加 `case agentKind, agentSessionID`
  - `init(from:)` 用 `decodeIfPresent`
  - `encode(to:)` 仅在非 nil 时写——保持旧 catalog 一字节兼容。

测试 `apps/mac/touch-code/Tests/TouchCodeCoreTests/AgentKindPatternsTests.swift`：每个 kind 至少 3 个 hit + 3 个 miss 用例（包括大小写、首词、含路径前缀 `/usr/local/bin/claude`、与无关命令 `bash`、`make` 等）。

**fulfills**: —（纯值类型 + 表；无可观察行为）

**preconditions**: 在 `feat/agent-state` 分支顶端；`make mac-build` 当前绿。

**expected_behavior**: `swift test` 跑 `AgentKindPatternsTests` 全绿；`AgentKindPatternsTests.testRoundtripPaneEncoding` 验证 `agentKind == .claudeCode` 的 `Pane` 序列化→反序列化等价；旧 fixture catalog（不含字段）解码后 `agentKind == nil`。

**verification_steps**:
1. `make mac-build` 通过。
2. `make mac-test ARGS="-only-testing:touch-codeTests/AgentKindPatternsTests"` 全绿。
3. 在 `Tests/Fixtures/` 找一份既有 `catalog.json`（不含 `agentKind`），手写测试 decode + encode 后 JSON 等价 → 验证零迁移。

#### T2：`HierarchyClient` 写入器 + `HierarchyManager` 实现

在 `apps/mac/touch-code/App/Clients/HierarchyClient.swift`：

```swift
var setPaneAgentKind: @MainActor @Sendable (_ paneID: PaneID, _ kind: AgentKind?) -> Void
var setPaneAgentSessionID: @MainActor @Sendable (_ paneID: PaneID, _ sessionID: String?) -> Void
```

三处 `liveValue` / 测试 default / `unimplemented` 都补上。`liveValue` 走 `manager.setPaneAgentKind(...)`。

在 `apps/mac/touch-code/Runtime/HierarchyManager.swift` 的 "Pane labels (canonical writer for C3 / C4)" 旁边的 `// MARK: - Pane agent identity` 段加：

```swift
func setPaneAgentKind(_ paneID: PaneID, kind: AgentKind?) {
  guard updatePane(paneID, { $0.agentKind = kind }) else { return }
  store.scheduleSave(catalog)
}
```

`updatePane` 若已存在则复用，否则写一个最小 helper（沿用 worktree / project / tab 树形 walk 的现有 pattern）。同理 sessionID。两个写入器只在值改变时调用 `scheduleSave` —— 设备日常切换 title 会触发频繁识别尝试，但 `classify` 命中后值通常稳定。

**fulfills**: —

**preconditions**: T1 已 commit。

**expected_behavior**: 单测 `HierarchyManagerAgentIdentityTests`：(a) 写入后 catalog snapshot 反映新值；(b) 重复写同值不 schedule save；(c) 写 nil 后字段消失。

**verification_steps**:
1. `make mac-test ARGS="-only-testing:touch-codeTests/HierarchyManagerAgentIdentityTests"` 全绿。

#### T3：`AgentBinder`（Runtime 层）

新建 `apps/mac/touch-code/Runtime/AgentBinder.swift`：

```swift
@MainActor
final class AgentBinder {
  init(client: HierarchyClient, surfaceInfo: @escaping (PaneID) -> SurfaceInfo?,
       paneInitialCommand: @escaping (PaneID) -> String?,
       catalogSnapshot: @escaping () -> Catalog)

  /// 在 pane 创建 / title 变 / 收到 OSC 9 / OSC 133 prompt 时调用
  func consider(paneID: PaneID, trigger: Trigger)
  enum Trigger { case paneCreated, titleChanged, desktopNotification(title: String, body: String), promptReturned }

  /// pane 退出时调用——清空 agentKind / sessionID
  func unbind(paneID: PaneID)
}
```

内部逻辑：

1. 已绑定 (`pane.agentKind != nil`) 时只在 `trigger == .promptReturned` 才考虑重绑；其他 trigger 不动既有值。
2. 未绑定时跑 `AgentKindPatterns.classify(initialCommand:title:notificationTitle:)`；命中 → `client.setPaneAgentKind(paneID, kind)`。
3. 重绑判定：`.promptReturned` 时，若 `classify` 用当前 title 算出的 kind 与已存值不等且非 nil → 改写。

订阅点（不开新 stream，挂到 `RootFeature` 已有的 `engineEventReceived` chain 上）：

- `RootFeature.swift` 在 `paneCreated` / `paneInfoChanged(.title)` / `paneInfoChanged(.desktopNotification)` / `paneInfoChanged(.promptEnd)`（OSC 133 D；如尚不存在，文末"Idempotence and Recovery"列出兜底路径）/ `paneExited` / `paneCrashed` 处插入 `binder.consider(...)` / `binder.unbind(...)` 调用。
- Binder 在 `AppState.bringUp()` 处实例化，注入 `HierarchyClient` 与 catalog 访问闭包。

测试 `AgentBinderTests`：

- (a) Pane 携带 `initialCommand="claude"` 创建 → `setPaneAgentKind` 被调用 1 次，值 `.claudeCode`。
- (b) Pane 以空 initialCommand 创建，500ms 后 title 变为 `"Codex CLI v1.2"` → 调用 1 次，值 `.codex`。
- (c) 已绑 `.claudeCode` 的 pane，title 又变 `"Codex CLI"`，无 prompt 事件 → 不调用。
- (d) 上一条之后再发 `.promptReturned` → 调用 1 次，新值 `.codex`。
- (e) `paneExited` → `setPaneAgentKind(paneID, nil)` 调用 1 次。
- (f) 未匹配的 title `"bash"` → 无调用。

**fulfills**: —

**preconditions**: T1、T2 已 commit。`make mac-build` 绿。

**expected_behavior**: 单测全绿；dev build 启动后在 `~/Library/Logs/touch-code` 能看到 `com.touch-code.activeagents` 类别 info 行（识别命中），手动跑一次 `claude --version` 在新建 tab 里 → catalog.json 出现 `"agentKind": "claude-code"`。

**verification_steps**:
1. `make mac-test ARGS="-only-testing:touch-codeTests/AgentBinderTests"` 全绿。
2. **Manual:** `make mac-run-app`；新建 tab → 在 tab 里输入 `claude`（如未安装则 `printf '\e]2;Claude Code\a'` 模拟 title）；等 1 s；退出 app；`cat ~/Library/Application\ Support/touch-code/catalog.json | jq '.. | .agentKind? // empty'` 应输出 `"claude-code"`。

### M1 Exit Gate

- T1–T3 全部 status=`completed`
- `make mac-check`（swift-format + swiftlint --strict）绿
- 上述 T1.1–T3.2 verification 全过
- 至少一次 commit（按 [feedback_commit_cadence](../../../.claude/projects/-Users-wanggang-dev-00-touch-code/memory/feedback_commit_cadence.md)，每个 T 后 commit 一次）
- 静态 review 无 Critical（按 [hs-review-request](../../skills/hs-review-request/SKILL.md)）

---

### Milestone M2：派生态机（T4 + T8）

此 milestone 结束时存在一个 `AgentRegistry`：纯 `@MainActor @Observable`，对每个 `pane.agentKind != nil` 的 pane 维护 `AgentEntry`，由事件流驱动状态转移。无 UI。

#### T4：`AgentRegistry` + 状态机 + 单测

新建 `apps/mac/touch-code/App/Features/ActiveAgents/AgentRegistry.swift`：

```swift
@MainActor @Observable
final class AgentRegistry {
  private(set) var entries: [PaneID: AgentEntry] = [:]

  struct AgentEntry: Equatable {
    let kind: AgentKind
    let sessionID: String?
    var state: AgentRuntimeState
    var lastTransitionAt: Date
  }
  enum AgentRuntimeState: String, CaseIterable, Equatable {
    case waitingForInput, loading, finished, idle
  }

  init(runningPanes: @escaping () -> Set<PaneID>,
       keyboardTracker: PaneKeyboardActivityTracker,
       focusedPane: @escaping () -> PaneID?)

  // 来自事件 fan-out
  func onRunningPanesChanged(_ now: Set<PaneID>)
  func onTerminalEvent(_ event: TerminalEvent)
  func onPaneKeyboardActivity(_ paneID: PaneID)
  func onPaneFocused(_ paneID: PaneID)
  func onAgentBound(_ paneID: PaneID, kind: AgentKind, sessionID: String?)
  func onAgentUnbound(_ paneID: PaneID)
}
```

内部每个 pane 的 scratch：

```swift
private struct Scratch {
  var prevPhase: PrevPhase = .idle    // .idle | .loading
  var pendingFinished: Bool = false
  var waitingForInput: Bool = false
}
private enum PrevPhase { case idle, loading }
```

每次任何 input 来时调 `recompute(paneID)` → 用 design doc §"Runtime State Derivation" 表更新 scratch → `entries[paneID].state = derive(scratch, runningPanes.contains(paneID))` → 若 state 变化更新 `lastTransitionAt`。

`onTerminalEvent` 内部对 `.paneInfoChanged(.desktopNotification(t, b))` 调用 `DetectionTranslator.classify(title: t, body: b)`，若 `.waitingForInput` 置位 `waitingForInput = true`；对 `.bellRang` 走同样路径（与 `NotificationDetector` 一致——验证项在 T8）。

测试 `AgentRegistryStateTests`（pure，无运行时）。每个用例构造一系列事件，断言最终 `state` 与 `lastTransitionAt` 变化次数。最低 12 个用例覆盖：

1. 仅 `onAgentBound` → `idle`。
2. `bound` → `runningPanes` 加入 → `loading`。
3. `loading` → `runningPanes` 移除 → `finished`。
4. `finished` → 新 output → `idle`。
5. `finished` → 键盘活动 → `idle`。
6. `finished` → focused → `idle`。
7. `loading` → `paneIdle` → `finished`。
8. `loading` → `paneExited` → `finished`。
9. `idle` → OSC 9 `desktopNotification` 分类为 waitingForInput → `waitingForInput`。
10. `waitingForInput` → 键盘活动 → `idle`。
11. `waitingForInput` 与 `runningPanes.contains` 同时 → `waitingForInput`（优先级）。
12. `onAgentUnbound` → entry 移除。

**fulfills**: —

**preconditions**: M1 完成；`AgentKind` 与 `Pane.agentKind` 已存在。

**expected_behavior**: 单测全绿；状态机优先级 = `waitingForInput > loading > finished > idle`。

**verification_steps**:
1. `make mac-test ARGS="-only-testing:touch-codeTests/AgentRegistryStateTests"` 全 12 用例绿。

#### T8：跨消费者一致性回归

新建 `apps/mac/touch-code/Tests/Integration/AgentNotificationConsistencyTests.swift`：构造一个 canned `TerminalEvent` 序列（OSC 9 → bell → OSC 9;4 busy → paneIdle → paneExited），同时喂给 `NotificationDetector` 与 `AgentRegistry`。断言：

- `NotificationDetector` 产出的 inbox kind 序列 == 设计期望
- `AgentRegistry` 终态 == 设计期望
- 两者对 "这是 waitingForInput 还是 taskFinished" 的分类对每个事件**一致**（通过 `DetectionTranslator.classify` 同一个函数，逻辑等价是必然——但跑一遍把保险锁上）

**fulfills**: —

**preconditions**: T4 完成。

**expected_behavior**: 测试绿。

**verification_steps**:
1. `make mac-test ARGS="-only-testing:touch-codeTests/AgentNotificationConsistencyTests"` 绿。

### M2 Exit Gate

- T4、T8 status=`completed`
- `AgentRegistryStateTests` 12+ 用例全绿
- `AgentNotificationConsistencyTests` 绿
- `make mac-check` 绿
- 至少一次 commit
- 静态 review 无 Critical

---

### Milestone M3：UI 与集成（T5–T7）

此 milestone 结束时，用户能看到并使用整个 ActiveAgents。徽章在 `WorktreeHeader`，hover 出 popover，点击行跳 pane。

#### T5：popover + row 视图（先做能看见的，再做精修）

新建：

- `apps/mac/touch-code/App/Features/ActiveAgents/ActiveAgentsPopoverView.swift`：消费 `AgentRegistry` + `HierarchyClient`；用 `SortedEntriesProvider`（局部 helper，纯函数）按状态优先级 + `lastTransitionAt desc` 排序。
- `ActiveAgentsRowView.swift`：logo + `<Project> / <Worktree>` 中间截断 + state icon + 相对时间（`RelativeDateTimeFormatter`，刷新触发用 `TimelineView`）。
- `ActiveAgentsBadgeViewModel.swift`：派生 `headline: String`（"3 agents working" / "Claude Code is waiting for input"）、`pulse: Bool`。

点击行 → 发 RootFeature 动作 `.activeAgents(.rowTapped(PaneID))`，reducer 走 selection chain 后调 `hierarchyClient.focusPane(paneID, tabID, worktreeID, projectID)`，再 dispatch `.activeAgents(.popoverDismissRequested)`。

测试：

- `SortedEntriesProviderTests`（pure 排序）。
- `ActiveAgentsBadgeViewModelTests`（headline 文案在 0/1/同态多/混态四档）。
- snapshot：`ActiveAgentsRowView` 四状态 + dark/light。

**fulfills**: —

**preconditions**: M2 完成。

**expected_behavior**: 单测/snapshot 绿；命令面板（如有 ad-hoc dev 入口）可临时弹出 popover 看一眼。

**verification_steps**:
1. `make mac-test ARGS="-only-testing:touch-codeTests/SortedEntriesProviderTests"` 绿。
2. `make mac-test ARGS="-only-testing:touch-codeTests/ActiveAgentsBadgeViewModelTests"` 绿。
3. `make mac-test ARGS="-only-testing:touch-codeTests/ActiveAgentsRowSnapshotTests"` 绿（snapshot 基线第一次跑会写入，第二次必须复现）。

#### T6：徽章 + hover bridge + WorktreeHeader 集成

新建 `ActiveAgentsBadgeView.swift`（视图）+ hover 控制器（`@State var isHovering` + `@State var hoverIntent` + 250/150 ms `Task.sleep` 取消语义）。

挂到 `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderView.swift`：在 `StatusBarBellView` 之后插入；徽章 `.popover` 锚点指向自身。

测试：

- `ActiveAgentsHoverBridgeTests`：用 `TestClock` 跑 250/150 ms 时序，断言"鼠标快速划过 < 250 ms 不开"、"开后离开 < 150 ms 内回到 popover 仍保持"。

**fulfills**: —

**preconditions**: T5 完成。

**expected_behavior**: `make mac-run-app`；在跑着至少一个 agent pane 时鼠标 hover header 中央徽章 → 250 ms 后 popover 出现；点击行 → 该 pane 被 focus。

**verification_steps**:
1. `make mac-test ARGS="-only-testing:touch-codeTests/ActiveAgentsHoverBridgeTests"` 绿。
2. **Manual:** `make mac-run-app`；在 worktree 新开 tab 输入 `claude --help`（仅启动 1s 也行）；header 出现"Claude Code is finished" 或 idle 状态的徽章；hover → popover；点击行 → 跳到对应 pane（zoom + first responder）。
3. **Manual:** 关闭该 pane → 徽章消失 / 该行消失。

#### T7：Logo 资源 + 文案优先级 + pulse 动效 + a11y

资源：在 `apps/mac/touch-code/Resources/Assets.xcassets/AgentLogos/` 新建 `claude-code.imageset`、`codex.imageset`、`pi.imageset`（light + dark）。SVG → PNG @1x/@2x/@3x 由 `tuist install` 之后人工拖入；commit 二进制。许可问题先用各家**官方 brand mark 中的 glyph**（非 wordmark）；若某家许可不明，先放占位 SF Symbol `brain.head.profile` 并在 OQ-1 跟踪。

文案：

- 单数：`<DisplayName> is <verb>`（`"Claude Code is waiting for input"` / `"working"` / `"finished"` / `"idle"`）。
- 多数同态：`<count> agents <verb>`。
- 混态：`<n1> <verb1> · <n2> <verb2>`（最多两段，依 priority 排序）。

pulse：`SwiftUI` `.opacity` 1.0 ↔ 0.6 `.easeInOut(1.2)` repeatForever；`@Environment(\.accessibilityReduceMotion)` 为 true 时禁用。

a11y：徽章 `accessibilityLabel(headline) + accessibilityHint("Open active agents popover")`；行 `accessibilityLabel("\(DisplayName), \(project) \(worktree), \(state), \(time)")`，state icon `accessibilityHidden(true)`。

**fulfills**: —

**preconditions**: T6 完成。

**expected_behavior**: 视觉上有正确 logo；pulse 在 working/waiting 下动、reduce-motion 下静止；VoiceOver 朗读完整状态。

**verification_steps**:
1. **Manual:** `make mac-run-app`；hover 徽章看 logo 渲染正确（light & dark）。
2. **Manual:** System Settings → Accessibility → Display → Reduce Motion ON；hover 徽章 → pulse 应停止。
3. **Manual:** VoiceOver ON（`fn+⌘+F5`）；focus 徽章 → 朗读 headline + hint；focus 一行 → 朗读完整 row 描述。

### M3 Exit Gate

- T5–T7 status=`completed`
- 所有单测 / snapshot 绿
- 三条 Manual 验证通过（M3 不引入 user-test markdown，但执行人需在 PR 描述里贴一张 popover 截图）
- `make mac-check` 绿
- 至少一次 commit per task
- 静态 review 无 Critical

## User Test Coverage

| Task | fulfills | Reason if `—` |
|------|----------|---------------|
User-tests now live at [docs/user-tests/active-agents-view.md](../user-tests/active-agents-view.md) (23 cases across 6 journeys). Coverage bindings approved 2026-05-22:

| Task | fulfills | Reason if `—` |
|------|----------|---------------|
| T1 | — | 纯值类型 + 模式表；无 UI surface 可探。Unit-test only. |
| T2 | — | Client/Manager 写入器；无 UI surface 可探。Unit-test only. |
| T3 | — | Binder 副作用只能在 M3 UI 起来后端到端探测；cases UT-AA-I-* 在 T6 整合后才完整可 probe。 |
| T4 | — | 派生态机；无 UI surface，行为通过 `AgentRegistryStateTests` 12+ 单测覆盖。 |
| T5 | UT-AA-P-003, UT-AA-P-004 | popover content + within-bucket sort，T5 引入 popover/row 后即可探。 |
| T6 | UT-AA-B-001, UT-AA-B-002, UT-AA-B-003, UT-AA-B-004, UT-AA-B-005, UT-AA-B-006, UT-AA-B-007, UT-AA-P-001, UT-AA-P-002, UT-AA-C-001, UT-AA-C-002, UT-AA-I-001, UT-AA-I-002, UT-AA-I-003, UT-AA-I-004, UT-AA-N-001, UT-AA-N-002, UT-AA-N-003 | T6 整合 badge + hover bridge + WorktreeHeader 后，绝大多数端到端 case 同时可探；一并落在此处。 |
| T7 | UT-AA-B-008, UT-AA-A-001, UT-AA-A-002 | reduce-motion + VoiceOver 两条 a11y/动效专用 case。 |
| T8 | — | 一致性回归；integration test 覆盖，无新增 user-test。 |

并集 = 23 cases ✓ 完整覆盖 `docs/user-tests/active-agents-view.md`，无 case 重复声明。

## Concrete Steps

工作目录：repo 根目录（`/Users/wanggang/.touch-code/repos/touch-code/feat/agent-state`）除非另注明。

### Bootstrap check

```bash
git status
# 期望：clean，HEAD = feat/agent-state
make mac-build
# 期望：BUILD SUCCEEDED (~30s 增量；首次约 5min)
```

### M1 — T1

```bash
# 创建文件后：
make mac-check
make mac-test ARGS="-only-testing:touch-codeTests/AgentKindPatternsTests"
# 期望：‖ Test Suite 'AgentKindPatternsTests' passed ‖
```

提交：`git add apps/mac/TouchCodeCore/Agents apps/mac/TouchCodeCore/Pane.swift apps/mac/touch-code/Tests/...` → `/commit`。

### M1 — T2

```bash
make mac-check
make mac-test ARGS="-only-testing:touch-codeTests/HierarchyManagerAgentIdentityTests"
```

提交：仅 `apps/mac/touch-code/App/Clients/HierarchyClient.swift` + `apps/mac/touch-code/Runtime/HierarchyManager.swift` + 新测。

### M1 — T3

```bash
make mac-check
make mac-test ARGS="-only-testing:touch-codeTests/AgentBinderTests"
make mac-run-app
# Manual：见 T3 verification_steps
```

提交：`apps/mac/touch-code/Runtime/AgentBinder.swift` + `apps/mac/touch-code/App/Features/Root/RootFeature.swift` 集成 + 测试。

### M2 — T4

```bash
make mac-test ARGS="-only-testing:touch-codeTests/AgentRegistryStateTests"
```

### M2 — T8

```bash
make mac-test ARGS="-only-testing:touch-codeTests/AgentNotificationConsistencyTests"
```

### M3 — T5

```bash
make mac-test ARGS="-only-testing:touch-codeTests/SortedEntriesProviderTests"
make mac-test ARGS="-only-testing:touch-codeTests/ActiveAgentsBadgeViewModelTests"
make mac-test ARGS="-only-testing:touch-codeTests/ActiveAgentsRowSnapshotTests"
# 第一次跑 snapshot 会写基线，二次跑应稳定
```

### M3 — T6 & T7

```bash
make mac-test ARGS="-only-testing:touch-codeTests/ActiveAgentsHoverBridgeTests"
make mac-run-app
# Manual：见 T6 / T7 verification_steps
```

## Validation and Acceptance

**静态层：**

1. `make mac-check` 整库绿（swift-format + swiftlint --strict）。
2. `make mac-test`（全量套件）通过；本计划新增的 8 个 test suites 全绿。
3. `make mac-build` 通过；无 warning 增量（项目 `-warnings-as-errors` 由 Tuist 配置——若有，需保持零增量）。

**运行时层（Manual）：**

执行 `make mac-run-app` 之后逐项观察：

- **AA-1（识别）**：新建 tab 输入 `claude`（或模拟 title）→ 1s 内 catalog.json 出现 `agentKind: claude-code`。
- **AA-2（loading）**：让 Claude Code 跑一个 tool call（OSC 9;4 busy）→ header 徽章变 `"Claude Code is working"`，logo 处 pulse。
- **AA-3（finished）**：tool call 结束 30s 内徽章变 `"Claude Code is finished"`，行右侧绿勾；focus 该 pane → 立刻变 idle。
- **AA-4（waitingForInput）**：让 Claude Code 弹一个 permission prompt（OSC 9 desktop notification 分类为 waitingForInput）→ 徽章变 `"Claude Code is waiting for input"`，铃铛琥珀色；在 pane 里按任意键 → 状态变 idle。
- **AA-5（多 agent）**：新开 tab 跑 `codex`，并发跑 → 徽章变 `"2 agents working"`；popover 列出两行，按 worktree 分组。
- **AA-6（点击聚焦）**：popover 点击 pi 的行 → 项目/worktree/tab 都切到 pi 所在；pane 拿到 first responder。
- **AA-7（清场）**：关掉所有 agent pane → 徽章隐藏，popover hover 不触发。

**未做 user-test markdown**——所有 AA-* 行 ad-hoc 走 Manual。完成时把执行记录粘到 Outcomes & Retrospective。

## Idempotence and Recovery

- 所有写入器（`setPaneAgentKind` / `setPaneAgentSessionID`）值不变时不 schedule save → 安全重复调用。
- `AgentBinder` `consider` / `unbind` 是幂等的：重复 `consider` 同 trigger 不重复写；重复 `unbind` 同 pane 在第二次时是 no-op（pane 已无字段或已不存在）。
- `AgentRegistry` 所有事件入口都 idempotent：重复同 `onRunningPanesChanged(now)`、相同 `onTerminalEvent`、重复 `onAgentBound` 不改变 entry（除非值确实变化）。
- **OSC 133 不可达时的兜底**：若 `paneInfoChanged(.promptEnd)` 在当前 libghostty 版本上从未发出（shell 无 integration），重绑路径自然退化为永不触发——这是设计稿明示的"sticky once"行为。后续若需要兜底，可在 `AgentBinder` 加一个 30s title-stable + classify ≠ existing kind 的二级触发（Risk 表已记），但 v1 不做。
- **catalog migration**：因新字段是 optional，旧 catalog 解码即 nil；写回时仅在非 nil 才编码 → 用户回滚到旧 touch-code 版本，字段被无视且不会破坏 schema。
- **panic recovery**：若 `AgentRegistry` 某分支出错（理论上不会，纯值），手动重启 app；entries 全部从空重新 derive，最差结果是几秒钟所有 agent 显示 `idle`，下一次事件来时自动归正。

## Artifacts and Notes

参考已有产物：

- `apps/mac/touch-code/App/Features/Notifications/NotificationDetector.swift` —— 事件 → InboxEntry 的现成 fan-out 写法，`AgentRegistry` 的 `onTerminalEvent` 复用 `DetectionTranslator.classify`，与之并列消费但不依赖之。
- `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarView.swift:637-660` —— 现成的"是否 executing"汇总指标 + busy glyph 渲染逻辑，可作为 `ActiveAgentsBadgeView` 的视觉风格参考。
- `apps/mac/touch-code/App/Features/StatusBar/StatusBarFeature.swift` —— hover bridge 风格（不是同一个东西，但 `ViewThatFits` + 时序状态机的写法可借鉴）。

无原型阶段——所有事件源、`HierarchyClient` 路径、`SurfaceInfo` 字段在现有代码里都已可访问，本计划只是组合它们。**唯一一处需要确认**的是 `paneInfoChanged(.promptEnd)`：design doc 已假设它存在，T3 落地时需先 `grep -rn promptEnd apps/mac/touch-code` 验证；若不存在，按 Idempotence 段的"sticky once"策略落地，OQ-1 跟踪。

## Interfaces and Dependencies

在 `apps/mac/TouchCodeCore/` 终态新增：

```swift
public enum AgentKind: String, Codable, Sendable, CaseIterable, Equatable {
  case claudeCode = "claude-code"
  case codex
  case pi
  public var displayName: String { … }
}

public nonisolated enum AgentKindPatterns {
  public static func classify(initialCommand: String?, title: String?, notificationTitle: String?) -> AgentKind?
}
```

`Pane` 新增字段 + Codable 升级（见 T1 章节）。

在 `apps/mac/touch-code/App/Clients/HierarchyClient.swift`：

```swift
struct HierarchyClient {
  // …既有字段…
  var setPaneAgentKind: @MainActor @Sendable (PaneID, AgentKind?) -> Void
  var setPaneAgentSessionID: @MainActor @Sendable (PaneID, String?) -> Void
}
```

在 `apps/mac/touch-code/Runtime/HierarchyManager.swift`：

```swift
func setPaneAgentKind(_ paneID: PaneID, kind: AgentKind?)
func setPaneAgentSessionID(_ paneID: PaneID, sessionID: String?)
```

在 `apps/mac/touch-code/Runtime/AgentBinder.swift`：

```swift
@MainActor final class AgentBinder {
  enum Trigger { case paneCreated, titleChanged, desktopNotification(title: String, body: String), promptReturned }
  init(client: HierarchyClient,
       surfaceInfo: @escaping (PaneID) -> SurfaceInfo?,
       paneInitialCommand: @escaping (PaneID) -> String?,
       catalogSnapshot: @escaping () -> Catalog)
  func consider(paneID: PaneID, trigger: Trigger)
  func unbind(paneID: PaneID)
}
```

在 `apps/mac/touch-code/App/Features/ActiveAgents/`：

```swift
@MainActor @Observable
final class AgentRegistry {
  private(set) var entries: [PaneID: AgentEntry] = [:]
  struct AgentEntry: Equatable { let kind: AgentKind; let sessionID: String?; var state: AgentRuntimeState; var lastTransitionAt: Date }
  enum AgentRuntimeState: String, CaseIterable, Equatable { case waitingForInput, loading, finished, idle }
  init(runningPanes: @escaping () -> Set<PaneID>,
       keyboardTracker: PaneKeyboardActivityTracker,
       focusedPane: @escaping () -> PaneID?)
  func onRunningPanesChanged(_ now: Set<PaneID>)
  func onTerminalEvent(_ event: TerminalEvent)
  func onPaneKeyboardActivity(_ paneID: PaneID)
  func onPaneFocused(_ paneID: PaneID)
  func onAgentBound(_ paneID: PaneID, kind: AgentKind, sessionID: String?)
  func onAgentUnbound(_ paneID: PaneID)
}

struct ActiveAgentsBadgeView: View {  /* observes AgentRegistry, builds headline */ }
struct ActiveAgentsPopoverView: View { /* list rows, hover bridge */ }
struct ActiveAgentsRowView: View {    /* logo + path + state icon + time */ }
```

`RootFeature` 新增 child actions：

```swift
case activeAgents(ActiveAgentsAction)
enum ActiveAgentsAction: Equatable {
  case rowTapped(PaneID)
  case popoverDismissRequested
  case binderTriggered(PaneID, AgentBinder.Trigger)   // 内部 fan-out
}
```

依赖关系：

- `ActiveAgents → TouchCodeCore`（AgentKind / Pane / DetectionTranslator）
- `ActiveAgents → HierarchyClient`（read snapshot + focusPane）
- `ActiveAgents → PaneKeyboardActivityTracker`（read keystroke timestamp）
- `Runtime/AgentBinder → HierarchyClient`（write agentKind / sessionID）
- `Runtime/AgentBinder → SurfaceInfo`（read title）
- **绝不**: `ActiveAgents → Notifications/*`、`Notifications/* → ActiveAgents/*`

## Open Questions

- **OQ-1（T7 / T3）**：libghostty 当前版本是否发 `paneInfoChanged(.promptEnd)`（OSC 133 D）？T3 落地时 `grep` 验证；若不发，AgentBinder rebind 路径只能 sticky-once；若发，按设计稿走正常 rebind。无论哪种都不阻塞 v1。
- **OQ-2（T7）**：Anthropic Claude / OpenAI Codex / Inflection pi 的 brand mark 使用条款；若任何一家 glyph 受限，临时回落到 `brain.head.profile` SF Symbol。完成 T7 前确认。

## Risks

| Risk | Mitigation |
|---|---|
| `paneInfoChanged(.promptEnd)` 在当前 libghostty 版本里未实现，导致重绑路径死代码 | 见 OQ-1；fallback 是 sticky-once，v1 可接受。Idempotence 段记录。 |
| 新增 `Pane` 字段影响某个 catalog 序列化路径（旧 build 读不到新字段或反之） | optional + `encodeIfPresent` + 显式 fixture 测试（T1 verification 第 3 步）。 |
| `AgentBinder` 与 RootFeature 现有 fan-out 顺序差异导致漏事件 | 在 RootFeature 既有的 `engineEventReceived` 拦截链上插入 binder 调用，与 `NotificationDetector.handle` 紧邻放置；单测覆盖 binder 各 trigger。 |
| pulse 动效在 prefers-reduced-motion 下未禁用，触发可访问性投诉 | `@Environment(\.accessibilityReduceMotion)` 显式分支，T7 Manual 验证步骤里专门跑一遍。 |
| logo 资源 license 风险 | 设计稿 Risks 段已述；T7 占位 SF Symbol 保底。 |

---

设计稿与本计划对照点：每个 task 的 `fulfills` 字段为 `—`（无 user-test markdown 文件 → coverage 表全部以 reason 列说明）。
