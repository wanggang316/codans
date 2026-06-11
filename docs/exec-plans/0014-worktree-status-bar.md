# ExecPlan: Worktree Status Bar

**Status:** Approved
**Author:** Gump (with Claude)
**Date:** 2026-04-24

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

执行后 titlebar 中段不再是系统拖拽空白：

- 在任意 Worktree，打开 editor（`⌘E`）成功时 titlebar 短暂显示绿 ✓ + `Opened in <editor>`；失败时橙 ▲ + 原因摘要。
- 操作 `gh` 完成 merge / close / markReady / rerunFailedJobs 时同样在 titlebar 回显成功或失败。
- 当前 Worktree 有活跃 PR 时，titlebar 显示 `#编号` 徽章 + 四色 checks ring + 简述；点击弹出既有 `PullRequestPopover`；按住 ⌘ 文字切换为 `Open on GitHub ⌘↵`。
- 空闲时 titlebar 显示当前时间 + 时段图标（🌅/☀️/🌇/🌙）+ `Open Command Palette ⌘P`。
- 窗口过窄时中段按三档退化（完整 → 仅徽章+ring → 隐藏），左右两侧按钮位置稳定。
- 左侧分支标签与右侧 🔔 / ⇪ / 📖 / ⚙︎ 按钮的位置、大小、行为**完全不变**。

## Progress

- [x] 写 ExecPlan（本文件）
- [x] **M1 Skeleton** (2026-04-24)
  - [x] M1.1 StatusToast 值类型（CodansCore/StatusBar/StatusToast.swift） — commit `7e7610c`
  - [x] M1.2 StatusBarFeature reducer + 单测（7/7 绿） — commit `c579d2f`
  - [x] M1.3 StatusBarView 最小实现 + 挂 toolbar
- [x] **M2 Editor hook** (2026-04-24)
- [x] **M3 GitHub hook** (2026-04-24)
- [x] **M4 PR form** (2026-04-24)
  - [x] M4.A ChecksRollupRing（Breakdown struct + 5 unit tests）
  - [x] M4.B CommandKeyObserver — 复用 HierarchySidebar 既有类 + 环境注入
  - [x] M4.C PR 态接入 — click=openURL（popover 整合作为 OQ-7 后续）
- [x] **M5 Motivational** (2026-04-24)
  - [x] M5.A CommandPaletteShortcut 常量 + MainWindowCommands 改写
  - [x] M5.B StatusMotivationalView + 8 个 timeStyle 单测
- [x] **M6 Narrow-width fallback** (2026-04-24) — `ViewThatFits` + per-form `compact: Bool`
- [x] **M7 Polish** (2026-04-24) — status-bar toolbar item 的 macOS 26+ `sharedBackgroundVisibility(.hidden)`；a11y labels 在 M1-M6 子视图里已就位
- [ ] `/codex:review` 全量复查

## Open Questions

- **OQ-7** (added 2026-04-24, M4.C): 把既有 `PullRequestPopover` 的内容构建从 `HierarchySidebarView.gitHubPopoverContent` 抽成独立 helper（预计 60-80 行），以便状态栏 PR 按钮也能在点击后弹出相同的 PullRequestPopover。当前 M4.C 的 click=openURL 是 MVP；spec AC-PR-3 需要这个后续才能完全满足。
- **OQ-8** (added 2026-04-24, post-review B2): `ViewThatFits(in: .horizontal)` placed inside `ToolbarItem(placement: .principal)` may not reliably engage the compact / hidden tiers because the toolbar's `ToolbarSpacer(.flexible)` offers an unbounded width to its principal item. Needs interactive verification: drag the main window from ~1400pt down to ~700pt and ~500pt and confirm the PR / motivational rows actually degrade. If they do not, replace `ViewThatFits` with a `GeometryReader`-driven width threshold (design doc §3.8 calls out 520pt as the fallback constant). Recorded after the post-execution code review (2026-04-24).

## Surprises & Discoveries

- **2026-04-24 (M1.2 → M2.1)** The `codans` test target shares its app binary as the xctest host. When a test run starts, SwiftUI mounts `CodansApp` + `AppState.bringUp()` in the same process, which touches live clients (GitHubClient, EditorClient, …). Under swift-testing's default parallel execution, that bootstrap races with our TestStores and produces non-deterministic `Test crashed with signal trap` on whichever test happens to be on-CPU. Running individual `StatusBarFeatureTests` cases in isolation passes every time; running the whole suite is flaky (observed 7/7, 6/7, 2/7 in three consecutive attempts). This is pre-existing and orthogonal to 0014 — any new TestStore suite in this target is exposed to the same race. **Workaround**: rely on `-only-testing` at the test-function level for deterministic signal during M1-M7 work; do not treat aggregate flakes as code regressions. A follow-up hardening task (add `LSUIElement` + test-mode guard in `AppState.bringUp()`) is a candidate for a separate plan. M2 forwarding tests that touched `RootFeature` + `StatusBarFeature` in one TestStore were retired in favour of a pure-function `shortToastMessage` test; the `.editor(.openSucceeded/.openFailed)` → `.statusBar(.push(...))` forwarding is verified via app-run smoke (M7 step).

## Decision Log

- **2026-04-24** 设计阶段已确认：状态归属 → 新建 `StatusBarFeature`；toast 发射 → RootFeature 路由既有 child actions；PR 数据 → 读 `GitHubFeature.State.snapshots`；快捷键 → 硬编码 + 共享常量；toast 节流 → sequence token + 后到覆盖；窄窗口 → `ViewThatFits` 三档；状态机 → TCA reducer + `TestClock`。详见 design doc §3-4。
- **2026-04-24 (M4.B)** Reused the existing `CommandKeyObserver` from `App/Features/HierarchySidebar/` rather than adding a second class under `App/Features/StatusBar/`. The existing class already self-installs its NSEvent monitor at `init`, handles teardown via a `nonisolated` `MonitorStorage` helper, and exposes `isCommandHeld: Bool`. Its file location is incidental; wiring it through the scene's `.environment` at `CodansApp` level makes it reachable from StatusPullRequestView without a file move. Diverges from Plan §Interfaces: `isPressed` is named `isCommandHeld` and there is no `start()` / `stop()` pair.
- **2026-04-24 (M4.C)** PR form's click action is **opens GitHub URL** (via `.gitHub(.delegate(.openURL))`) rather than the `PullRequestPopover` reuse called out in Plan §Plan of Work > Milestone 4. Hosting the popover on the titlebar anchor would require either (a) sharing `GitHubFeature.State.popoverTarget` with the sidebar badge (produces a single-popover-at-a-time race with ambiguous anchoring) or (b) introducing a new per-status-bar presentation state + extracting a 60-line popover-content builder out of `HierarchySidebarView`. For M4.C the click=URL path delivers the MVP visual surface; the popover integration is tracked as OQ-7 below. Spec AC-PR-3 needs a follow-up amendment.

## Outcomes & Retrospective

**2026-04-24 — M1-M7 complete, 13 commits, all green builds.**

What shipped:

- A new `StatusBarFeature` (TCA) owning a single `toast: StatusToast?` slot with 3 s / 8 s / never auto-clear windows and a `sequence`-token race guard.
- Priority-driven SwiftUI `StatusBarView` with three forms — toast, PR, motivational — and a `ViewThatFits` three-tier narrow-width fallback.
- Cross-feature toast routing in `RootFeature` translating `.editor(.openSucceeded/.openFailed)` and `.gitHub(...Completed)` into status-bar pushes.
- Reusable `ChecksRollupRing` view with a pure `Breakdown` struct (5 tests) and shared `CommandPaletteShortcut` constant consumed by both the menu binding and the motivational hint (single-source-of-truth refactor).
- `CommandKeyObserver` reused from the existing sidebar implementation via scene-level `.environment` injection — no duplicate class.

Deviations from plan:

- Popover reuse on the PR badge click (AC-PR-3) was deferred: `StatusPullRequestView` dispatches `.openURL` instead of hosting `PullRequestPopover`. Tracked as OQ-7; a follow-up plan is the appropriate home for the popover-content helper extraction.
- `SharedBackgroundHidden` ViewModifier extraction dropped: `.sharedBackgroundVisibility` is a `ToolbarContent` modifier, not `View` modifier, so a single ViewModifier cannot capture both branch-label and status-bar call sites. Left as two inline `if #available` blocks.

Tests:

- `StatusBarFeatureTests` — 7 cases passing in isolation
- `ChecksRollupRingBreakdownTests` — 5 cases passing
- `StatusMotivationalTimeStyleTests` — 8 cases passing
- `RootFeatureTests.shortToastMessage…` — 1 case passing
- Aggregate suite runs are subject to a pre-existing host-app test-bootstrap race (see Surprises 2026-04-24 M1.2→M2.1); orthogonal to 0014.

Commits (oldest first): `83a14be` (docs), `7e7610c` (M1.1), `c579d2f` (M1.2), `5d? ` M1.3 landed as `…m1.3` SHA, `008f934` (M2), `4d9cb79` (M3), `M4.A`, `2c7a237` (M4.B), `5ca1754` (M5.A), `6fbe8b8` (M4.C), `M5.B`, `1b3922e` (M6), M7 pending commit.

Next: `/codex:review` over the branch.

## Context and Orientation

**Related documents**（读这份计划前先看）：

- Product spec: `docs/product-specs/worktree-status-bar.md`
- Design doc: `docs/design-docs/worktree-status-bar.md`（尤其 §3 设计、§4 备选对比、§6 分期、§7 风险）
- Architecture doc: `docs/architecture.md`

**Key source files**（本计划要读 / 改的文件）：

- `apps/mac/codans/App/Features/Root/RootFeature.swift` — 912 行总聚合 reducer。新 `StatusBarFeature` scope 与 toast 路由分支都挂在它的 `headerAndEditorScopes` / `coreReducer` 里。
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift:161-218` — 现有 titlebar toolbar 内容，本计划在 navigation group 和 primaryAction group 之间插入中段槽。
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift:33-36,131-135` — `OpenResultMarker` 枚举 + `openSucceeded/.openFailed` action，是 M2 的上游信号。
- `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift` — `snapshots[WorktreeID]` 是 M4 读源，`mergeCompleted/.closeCompleted/.markReadyCompleted/.rerunFailedJobsCompleted` 是 M3 的上游信号。
- `apps/mac/CodansCore/GitHub/PullRequestSnapshot.swift` — `PullRequestState` / `checkRollup: [CheckResult]` / `state` 字段形状。
- `apps/mac/codans/App/Features/HierarchySidebar/WorktreeGitHubBadge.swift:38` — `PullRequestBadge.CheckRollup.from(checks:)` 既有 rollup 汇总函数，M4.A 复用它，不重写。
- `apps/mac/codans/App/Features/GitHub/Theme/PullRequestStateColors.swift` — `PullRequestStateColor` / `CheckRollupColor` 已有颜色常量，M4 / M4.A 直接读。
- `apps/mac/codans/App/Features/GitHub/Views/PullRequestPopover.swift` — 360pt 已有 popover，M4 只复用不修改。
- `apps/mac/codans/App/Commands/MainWindowCommands.swift:37` — `⌘P` 硬编码处，M5.A 迁移到共享常量。
- `apps/mac/codans/App/CodansApp.swift` — bootstrap；注入 `CommandKeyObserver` environment 和把 `gitHubStore` 透传。
- `apps/mac/codans/App/ContentView.swift` — `WorktreeDetailView` 构造 / store scoping 入口。

**术语定义**：

- **Toast**：本计划里特指中段的 inProgress / success / warning 瞬态消息，不是 macOS 通知中心的 toast。
- **Sequence token**：`StatusBarFeature.State.sequence: UInt64`，每次 `.push` 自增；`.cleared(seq:)` timer 用 seq 比对过滤 stale 触发。
- **Scope projection**：TCA `.scope(state:action:)` 把父 state 投影成子 store 可见的 value type，view 只看见投影后的字段。
- **ViewThatFits**：SwiftUI 声明式自适应容器，按给出的候选顺序挑第一个能塞下的渲染。

## Plan of Work

七个 milestone，每个对应 1-3 个 commit。milestone 间为严格依赖（M2 → M1，M3 → M1，M4 → M1 + M4.A + M4.B，M5 → M1 + M5.A，M6 → M4 + M5，M7 → M6），milestone 内部的可并行 subtask 单独标注。

### Milestone 1 — Skeleton

**目的**：让 titlebar 多出一个可见的中段槽，reducer 能接收 toast push、3s 后自动清 success / 8s 自动清 warning。其他形态本 milestone 不实现；`toast == nil` 时中段渲染 `EmptyView()`。

- **M1.1**（commit #1） 新建 `apps/mac/CodansCore/StatusBar/StatusToast.swift`：
  ```
  public enum StatusToast: Equatable, Sendable {
    case inProgress(String)
    case success(String)
    case warning(String)
  }
  ```
  需要编辑 `apps/mac/CodansCore/Sources/...` 的模块导出（如果 Tuist 用 source glob 可跳过）。commit message: `feat(statusbar): add StatusToast value type`。
  
- **M1.2**（commit #2） 新建 `apps/mac/codans/App/Features/StatusBar/StatusBarFeature.swift` 与 `apps/mac/codans/Tests/StatusBarTests/StatusBarFeatureTests.swift`：
  - reducer 维护 `toast: StatusToast?` + `sequence: UInt64`
  - `.push(toast)`：替换 `state.toast`，`sequence &+= 1`，取消旧 timer；success 调度 3s `.cleared(currentSeq)`，warning 调度 8s，inProgress 无 timer
  - `.cleared(seq)`：若 `seq == state.sequence` 才清空，否则吞掉
  - `.dismissed`：立即清空并取消 timer
  - 依赖：`@Dependency(\.continuousClock) var clock`（TCA 自带，TestStore 里可换 `TestClock`）
  - 单测覆盖：success 3s 自动清 / warning 8s 自动清 / inProgress 不自动清 / 连续 push 使旧 timer 的 `.cleared` 被 sequence 丢弃 / dismissed 即时清
  - commit: `feat(statusbar): add StatusBarFeature reducer with TestClock-driven auto-clear`
  
- **M1.3**（commit #3） 挂在 RootFeature 与 View 层：
  - `RootFeature.swift`：`State` 追加 `var statusBar: StatusBarFeature.State = .init()`；`Action` 追加 `case statusBar(StatusBarFeature.Action)`；`headerAndEditorScopes` 追加 `Scope(state: \.statusBar, action: \.statusBar) { StatusBarFeature() }`。
  - 新建 `apps/mac/codans/App/Features/StatusBar/StatusBarView.swift`：顶层 SwiftUI 视图，现阶段 body 为：
    ```
    if let toast = store.toast {
      StatusToastView(toast: toast)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: toast)
    } else {
      Color.clear.frame(width: 1, height: 1)
    }
    ```
  - 新建 `apps/mac/codans/App/Features/StatusBar/Views/StatusToastView.swift`：根据 case 渲染 spinner / 绿 ✓ / 橙 ▲ + secondary 文本。
  - `WorktreeDetailView.swift:161-218` 的 `worktreeToolbarContent(address:info:)`：在 `branchToolbarItem` 之后、`ToolbarItemGroup(placement: .primaryAction)` 之前插入：
    ```
    ToolbarSpacer(.flexible)
    ToolbarItem(placement: .principal) {
      StatusBarView(store: statusBarStore)
    }
    ToolbarSpacer(.fixed)
    ```
  - `WorktreeDetailView` 构造函数追加 `let statusBarStore: StoreOf<StatusBarFeature>`；`ContentView` 从 RootStore 投影并传入。
  - **验证**：在 `RootFeature.swift` 的 `onLaunch` 或临时 debug menu 里 `.send(.statusBar(.push(.success("Hello"))))`，运行 `make mac-run-app`，观察 titlebar 中段 ~3s 可见绿 ✓ + Hello 后消失。
  - commit: `feat(statusbar): mount StatusBarView in toolbar between branch label and header buttons`

**完成标志**：`make mac-run-app` 后手动 push 一个 success toast，titlebar 可见 3s 回显；左右按钮位置无变化；TestStore 所有单测绿。

### Milestone 2 — Editor hook

**目的**：`⌘E` 打开 editor 的成败结果从"只写 `EditorFeature.lastOpenResult`"扩展为"同时在 titlebar 回显"。

- **M2.1**（commit #4） 在 `RootFeature.coreReducer` 的 `switch action` 里新增两条分支：
  ```
  case .editor(.openSucceeded(_, let displayName)):
    return .merge(
      // 保留原有对 .editor(.openSucceeded) 的 scope 处理由 headerAndEditorScopes 完成
      .send(.statusBar(.push(.success("Opened in \(displayName)"))))
    )
  case .editor(.openFailed(let reason)):
    return .send(.statusBar(.push(.warning(Self.shortMessage(reason)))))
  ```
  注意：这两个 action 已经被 `Scope(state: \.editor, ...)` 消费过，这里是新增的**父级监听**，不会影响 child 的 state 变更。
  
  新增 `private static func shortMessage(_ s: String) -> String`：取首行、截断 80 字符。
  
  单测 `RootFeatureTests`：`TestStore.send(.editor(.openSucceeded(...)))` 收到 `.receive(.statusBar(.push(.success(...))))`。
  
  commit: `feat(statusbar): surface editor-open results as toasts`

**完成标志**：`⌘E` 打开 Xcode 成功后 titlebar 弹绿 ✓ 3s；把 editor 改为不存在的路径触发失败，出现橙 ▲ 8s。

### Milestone 3 — GitHub hook

**目的**：PR 写操作（merge / close / markReady / rerunFailedJobs）完成后 titlebar 回显。

- **M3.1**（commit #5） 在 `RootFeature.coreReducer` 新增四组成功 / 失败分支：
  ```
  case .gitHub(.mergeCompleted(_, let prNumber, .success)):
    return .send(.statusBar(.push(.success("PR #\(prNumber) merged"))))
  case .gitHub(.closeCompleted(_, .success)):
    return .send(.statusBar(.push(.success("PR closed"))))
  case .gitHub(.markReadyCompleted(_, .success)):
    return .send(.statusBar(.push(.success("PR marked ready"))))
  case .gitHub(.rerunFailedJobsCompleted(_, .success)):
    return .send(.statusBar(.push(.success("Re-ran failed jobs"))))
  case .gitHub(.mergeCompleted(_, _, .failure(let e))),
       .gitHub(.closeCompleted(_, .failure(let e))),
       .gitHub(.markReadyCompleted(_, .failure(let e))),
       .gitHub(.rerunFailedJobsCompleted(_, .failure(let e))):
    return .send(.statusBar(.push(.warning(Self.shortMessage(String(describing: e))))))
  ```
  这些 action 也已被 `Scope(state: \.gitHub)` 消费过，新增的是父级监听，不影响既有 reducer 行为。
  
  单测：四个成功 + 一个失败 case，共 5 条 TestStore assertion。
  
  commit: `feat(statusbar): surface gh mutation results as toasts`

**完成标志**：在一个活跃 PR 的 Worktree 上，从 sidebar badge popover 里 Merge，titlebar 绿 ✓ "PR #N merged" 3s。故意跑一次会冲突的 merge（或断网），出现橙 ▲。

### Milestone 4 — PR form

**目的**：`toast == nil` 且当前 Worktree 有活跃 PR 时，中段渲染 PR 徽章 + checks ring + 简述 + popover + ⌘-hold 文案切换。

本 milestone 三个 subtask 可并行：**M4.A、M4.B、M5.A**（M5.A 虽属 M5 范畴但独立度高，和 M4 一起放到 Agent teams 批次里）。

- **M4.A**（commit #6，**可并行**） 新建 `apps/mac/codans/App/Features/StatusBar/Views/ChecksRollupRing.swift`：
  - 输入 `let checks: [CheckResult]`；内部调用既有 `PullRequestBadge.CheckRollup.from(checks: checks)`
  - 渲染 14×14 pt `Canvas` 四色环；段色来自 `CheckRollupColor.{passing,failing,pending,neutral}`
  - `total == 0` → `EmptyView`
  - 单测用例（纯函数 layout）：`{passing:4, failing:0, pending:0, neutral:0}` → 单段绿；`{passing:2, failing:1, pending:1, neutral:0}` → 三段顺时针 180° / 90° / 90°
  - commit: `feat(statusbar): add ChecksRollupRing view`

- **M4.B**（commit #7，**可并行**） 新建 `apps/mac/codans/App/Features/StatusBar/CommandKeyObserver.swift`：
  - `@Observable final class CommandKeyObserver: NSObject` + `var isPressed: Bool`
  - `start()` 调 `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`，capture weak self；更新 `isPressed = ev.modifierFlags.contains(.command)`
  - `stop()` 调 `NSEvent.removeMonitor`
  - `CodansApp` 用 `@State private var commandKeyObserver = CommandKeyObserver()`，`WindowGroup.onAppear { commandKeyObserver.start() }.onDisappear { commandKeyObserver.stop() }`，`.environment(commandKeyObserver)` 注入
  - 单测：触发一个合成 `.flagsChanged` event 验证 `isPressed` 翻转
  - commit: `feat(statusbar): add CommandKeyObserver for ⌘-hold detection`

- **M4.C**（commit #8，依赖 M4.A + M4.B） 把 PR 态接入 `StatusBarView`：
  - 扩展 `StatusBarView`：新增 `let gitHubStore: StoreOf<GitHubFeature>` 参数 + `let worktreeID: WorktreeID` 参数
  - 优先级函数（纯 function）：
    ```
    enum StatusBarForm { case toast(StatusToast), pr(PullRequestSnapshot), motivational, none }
    static func resolve(toast: StatusToast?, pr: PullRequestSnapshot?) -> StatusBarForm {
      if let toast { return .toast(toast) }
      if let pr, pr.state != .closed { return .pr(pr) }
      return .motivational
    }
    ```
  - 新建 `apps/mac/codans/App/Features/StatusBar/Views/StatusPullRequestView.swift`：
    - 徽章：`#N` + `PullRequestStateColor.<state>Fill`
    - 点击：`store.send(.gitHub(.presentPopover(worktreeID, worktreePath)))`，popover 内容 = 既有 `PullRequestPopover`（从 sidebar 那边已有的 binding 复用 / 或从 GitHubFeature scope 里读 `store.popoverTarget == worktreeID`）
    - `⌘+click`：`NSWorkspace.shared.open(snapshot.url)` 或者走 `.delegate(.openURL(snapshot.url))`
    - 按住 `⌘`（读 `commandKeyObserver.isPressed`）切换文字为 `Open on GitHub ⌘↵`
    - 简述文本优先级：`mergeStateStatus.blocking` > checks 汇总（`breakdown.summaryText + " checks"`）> `(Drafted)` > `snapshot.title`
    - ChecksRollupRing（M4.A）嵌在徽章右侧
  - `ContentView` / `WorktreeDetailView`：追加 `gitHubStore` 透传
  - 纯函数 `StatusBarForm.resolve` 附带单测矩阵（toast × pr × closed）
  - commit: `feat(statusbar): render PR badge + checks ring + ⌘-hold hint`

**完成标志**：选中有活跃 PR 的 Worktree，`toast == nil` 时 titlebar 中段显示 `#123` + 彩色 ring + 简述；点击弹 `PullRequestPopover`；按住 ⌘ 文字变 `Open on GitHub`；`⌘+click` 打开浏览器。切到无 PR 的 Worktree，中段目前仍渲染 `EmptyView`（留给 M5）。

### Milestone 5 — Motivational

**目的**：无 toast、无 PR 时 titlebar 显示时间 + 时段图标 + `Open Command Palette ⌘P`。

- **M5.A**（commit #9，**可并行**，与 M4.A / M4.B 一同进 agent teams 批次） 新建 `apps/mac/CodansCore/Shortcuts/CommandPaletteShortcut.swift`：
  ```
  public enum CommandPaletteShortcut {
    public static let keyChar: Character = "p"
    public static let displayString: String = "⌘P"
  }
  ```
  （SwiftUI 的 `EventModifiers` 依赖 SwiftUI import —— 若 CodansCore 不 link SwiftUI，就只放 keyChar + displayString，modifier 在 app 层硬编码 `.command`。）
  
  改 `apps/mac/codans/App/Commands/MainWindowCommands.swift:37`：
  ```
  .keyboardShortcut(KeyEquivalent(CommandPaletteShortcut.keyChar), modifiers: .command)
  ```
  验证 `⌘P` 打开命令面板仍正常工作（纯重构，零行为变化）。
  
  commit: `refactor(shortcuts): extract CommandPaletteShortcut shared constant`

- **M5.B**（commit #10） 新建 `apps/mac/codans/App/Features/StatusBar/Views/StatusMotivationalView.swift`：
  - `TimelineView(.everyMinute)` 取当前 `Date`，`Calendar.current.component(.hour, ...)`
  - 纯函数 `static func timeStyle(for hour: Int) -> (icon: String, color: Color)`，断言：`6..<12 → sunrise.fill / orange`，`12..<17 → sun.max.fill / yellow`，`17..<21 → sunset.fill / pink`，其他 → `moon.stars.fill / indigo`
  - 文案：`"\(date, format: .dateTime.hour().minute()) – Open Command Palette \(CommandPaletteShortcut.displayString)"`，`.font(.footnote).monospaced().foregroundStyle(.secondary)`
  - 接入 `StatusBarView` 的 `.motivational` 分支
  - 单测：`timeStyle(for: 6)` → sunrise；`timeStyle(for: 5)` → moon（早 6 前是夜）；11/12/16/17/20/21 四个边界各一条
  - commit: `feat(statusbar): add StatusMotivationalView as default form`

**完成标志**：打开一个无 PR 的空 Worktree，titlebar 中段显示形如 `🌅 14:02 – Open Command Palette ⌘P` 的文本；`⌘P` 仍能打开命令面板。

### Milestone 6 — Narrow-width fallback

**目的**：收窄窗口时中段按 `完整 → 紧凑 → 隐藏` 退化；左右按钮位置不漂移。

- **M6.1**（commit #11） `StatusBarView.body` 外层包 `ViewThatFits(in: .horizontal) { full; compact; Color.clear }`：
  - `full`：当前形态的完整渲染
  - `compact`：PR 态只显示徽章 + ring；toast 态只显示图标 + 首 6 词；motivational 态只显示图标 + 时间（去掉 hint 后半句）
  - hidden：`Color.clear.frame(height: 0)`
  - **R1 回退**：若 macOS 26 toolbar 内 `ViewThatFits` 测量失真（表现为三档闪烁），回退到 `GeometryReader` 包裹 + 硬阈值 `520pt`（窗口宽 < 520 隐藏），并在 `Decision Log` 记录回退原因。
  - 手工验证：`make mac-run-app`，拖 window 从 1400 → 800 → 500，观察三档切换；分别检查 PR 态 / motivational 态 / toast 态三种主形态下的退化。
  - commit: `feat(statusbar): ViewThatFits three-tier narrow-width fallback`

**完成标志**：拖窄到 ~500pt 时中段隐藏，左侧分支标签与右侧按钮相对位置稳定。

### Milestone 7 — Polish

**目的**：可访问性 + 代码卫生。

- **M7.1**（commit #12） `SharedBackgroundHidden` `ViewModifier`：
  - 新建 `apps/mac/codans/App/Features/StatusBar/SharedBackgroundHidden.swift`（或更广的 `Theme/`）
  - 定义：
    ```
    struct SharedBackgroundHidden: ViewModifier {
      func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.sharedBackgroundVisibility(.hidden) }
        else { content }
      }
    }
    extension View { func sharedBackgroundHidden() -> some View { modifier(SharedBackgroundHidden()) } }
    ```
  - 把现有 `WorktreeDetailView.swift:213-218` 的 `if #available(macOS 26.0, *)` 内联块替换为 `.sharedBackgroundHidden()`
  - `StatusBarView` 的 ToolbarItem 同样调用
  - 可访问性：`StatusBarView` 外层 `.accessibilityElement(children: .contain).accessibilityIdentifier("status.bar")`；每子视图 `.accessibilityLabel("Status")` + `.accessibilityValue(<形态文本>)`
  - commit: `refactor(statusbar): extract SharedBackgroundHidden modifier + a11y labels`

**完成标志**：`WorktreeDetailView` 里 `if #available(macOS 26.0, *)` 的重复 inline 分支归零；VoiceOver 在中段切换形态时朗读一次。

## Concrete Steps

### 每一步都走这个循环

```bash
# 在 worktree 根目录
cd /Users/wanggang/.prowl/repos/codans/feature/status-bar

# 编辑 → 编译
make mac-build             # 首轮从头编可能 ~2min；增量 ~10s
# → 期望：exit 0，无 warning

# 跑测试
# 首轮用 xcodebuild 全量：
cd apps/mac && xcodebuild test \
  -workspace codans.xcworkspace \
  -scheme codans \
  -only-testing:codansTests/StatusBarFeatureTests 2>&1 | xcbeautify
# → 期望："Test Suite StatusBarFeatureTests passed"

# 风格检查
make mac-lint
# → 期望：exit 0
```

### 每个 commit 之后

```bash
git status
git add -p                 # 只加真正要的
git diff --cached          # 确认没有混入无关文件（.DS_Store、调试代码）
git commit -m "feat(statusbar): <one-line description>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

# 不 push；累到 milestone 结束再一次推远程（或让用户决定何时 push）
```

### Agent teams 批次（M4.A + M4.B + M5.A 并行）

启动三个独立子 agent，每个在 isolated worktree 完成一个 subtask，完成后回主 worktree 合并。由主 agent 分派 + 最终合并：

```
# 主 agent 分派（伪代码，见下面 Plan of Work 主 agent 指令）
Agent({
  description: "ChecksRollupRing view",
  subagent_type: "general-purpose",
  isolation: "worktree",
  prompt: "<M4.A 任务详情 + context>"
})
Agent({ description: "CommandKeyObserver", ... prompt: "<M4.B 任务详情>" })
Agent({ description: "CommandPaletteShortcut", ... prompt: "<M5.A 任务详情>" })
```

三个子 agent 独立产出 commit，主 agent 在全部完成后 cherry-pick 回本 branch。

## Validation and Acceptance

本 ExecPlan 对齐 spec 的 19 条 Acceptance Criteria（`docs/product-specs/worktree-status-bar.md` §Acceptance Criteria）。验证方式按 milestone 分：

- **M1 完成**：`xcodebuild test -only-testing:StatusBarFeatureTests` 全绿；手工 `.push(.success)` 可见 titlebar 回显 3s。
- **M2 完成**：`⌘E` 成功 → titlebar 绿 ✓；`⌘E` 失败 → 橙 ▲。对应 spec AC-IP-1。
- **M3 完成**：PR popover 里点 Merge 成功 → titlebar "PR #N merged" 绿 ✓。
- **M4 完成**：对应 spec AC-PR-1..5。手动切到有 PR / 无 PR / merged PR / closed PR 四种 Worktree，逐一验证渲染。
- **M5 完成**：对应 spec AC-MV-1/2。打开 app 等 1 分钟，观察时间变化。
- **M6 完成**：对应 spec AC-VS-2。Window 1400 → 500pt 三档。
- **M7 完成**：对应 spec AC-VS-1/3/4。启 VoiceOver 走一圈。

全部完成后再走 `/codex:review` 做最终复查。

## Idempotence and Recovery

**每个 commit 都是独立 revertable 边界**，失败时：

- M1 任一 commit 出错 → `git reset --hard HEAD~1`（本地还没推远程）；修复后重新 commit。
- M4.A/B/5.A 走 Agent teams；若某个 agent 失败，主 agent 在 worktree 里手动完成即可，无需重启批次。
- `ViewThatFits` 若在 M6 暴露 toolbar 测量 bug（R1），切到 GeometryReader + 520pt 方案，更新 Decision Log 与本文件 §Surprises。
- Tuist 若因新文件需要 `make mac-generate` → 每次加新 Swift 文件后跑一次。若忘记，`make mac-build` 会直接报 "Cannot find X in scope"；重新 generate 即可。
- 如果 M4 的 `gitHubStore` 透传破坏了既有 `WorktreeDetailView` 构造函数签名，把新参数加默认值 `nil` 先让编译通过，再在 ContentView 里补上，可分两个 commit 安全推进。

## Artifacts and Notes

**Scope projection 草图**（M1.3 / M4.C 都要这个投影）：

```
extension StatusBarView {
  struct ViewState: Equatable {
    let toast: StatusToast?
    let pr: PullRequestSnapshot?    // 已过滤掉 closed
  }
  static func project(root: RootFeature.State, worktreeID: WorktreeID?) -> ViewState {
    let pr = worktreeID.flatMap { root.gitHub.snapshots[$0] }
      .flatMap { $0.state == .closed ? nil : $0 }
    return ViewState(toast: root.statusBar.toast, pr: pr)
  }
}
```

**ViewThatFits 草图**（M6）：

```swift
ViewThatFits(in: .horizontal) {
  HStack(spacing: 10) { form.full }          // badge + ring + detail
  HStack(spacing: 6)  { form.compact }       // badge + ring
  Color.clear.frame(width: 0, height: 0)
}
```

## Interfaces and Dependencies

**必须在本计划结束后存在的类型与签名**：

在 `apps/mac/CodansCore/StatusBar/StatusToast.swift`：

```
public enum StatusToast: Equatable, Sendable {
  case inProgress(String)
  case success(String)
  case warning(String)
}
```

在 `apps/mac/CodansCore/Shortcuts/CommandPaletteShortcut.swift`：

```
public enum CommandPaletteShortcut {
  public static let keyChar: Character = "p"
  public static let displayString: String = "⌘P"
}
```

在 `apps/mac/codans/App/Features/StatusBar/StatusBarFeature.swift`：

```
@Reducer
struct StatusBarFeature {
  @ObservableState
  struct State: Equatable { var toast: StatusToast?; var sequence: UInt64 }
  enum Action: Equatable {
    case push(StatusToast); case cleared(sequence: UInt64); case dismissed
  }
  nonisolated enum CancelID: Sendable { case autoClearTimer }
  @Dependency(\.continuousClock) var clock
  var body: some Reducer<State, Action> { /* … */ }
}
```

`RootFeature.State` 追加：

```
var statusBar: StatusBarFeature.State = .init()
```

`RootFeature.Action` 追加：

```
case statusBar(StatusBarFeature.Action)
```

`RootFeature.headerAndEditorScopes` 追加：

```
Scope(state: \.statusBar, action: \.statusBar) { StatusBarFeature() }
```

`RootFeature.coreReducer` 追加的 pass-through 分支（见 M2 / M3 详细列表）。

`WorktreeDetailView` 构造器追加：

```
let statusBarStore: StoreOf<StatusBarFeature>
let gitHubStore: StoreOf<GitHubFeature>
```

`StatusBarView` 公开接口：

```
struct StatusBarView: View {
  @Bindable var store: StoreOf<StatusBarFeature>
  let worktreeID: WorktreeID?
  let gitHubStore: StoreOf<GitHubFeature>
  var body: some View { /* 优先级挑选 + ViewThatFits */ }
}
```

`ChecksRollupRing` 公开接口：

```
struct ChecksRollupRing: View {
  let checks: [CheckResult]
  var body: some View { /* 14pt 四色饼环 or EmptyView */ }
}
```

`CommandKeyObserver`：

```
@Observable final class CommandKeyObserver: NSObject {
  var isPressed: Bool
  func start(); func stop()
}
```

**依赖（已在项目中，不新增 SPM）**：
- `ComposableArchitecture`（已）
- `SwiftUI` / `AppKit`（已）
- `swift-snapshot-testing`（已，M7 可选使用）

本计划**不新增**：外部 SPM 包、protobuf / IPC、新的 `gh` 子进程、新的磁盘持久化路径。
