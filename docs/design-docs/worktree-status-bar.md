# Design Doc: Worktree Status Bar

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-24
**Spec:** [docs/product-specs/worktree-status-bar.md](../product-specs/worktree-status-bar.md)

## 1. Context and Scope

codans 主窗口 titlebar 目前的布局（`WorktreeDetailView.swift:161-218`）为：

```
[leading: 分支标签]  ……(空)……  [primaryAction: 🔔 ⇪ 📖]  [Settings 齿轮 by ContentView]
```

左右两端都有内容，**中间是一个被系统拖拽区占满的空白**。spec 决定把这块空白改造成一个有状态、按优先级切换形态的 **Worktree Status Bar**：motivational 默认态 → PR 徽章 + checks ring → inProgress / success / warning toast。

本设计只关心这个新的中段槽位。左侧分支标签、右侧 🔔/⇪/📖/齿轮 的代码与行为**都不动**。

涉及的已有子系统（按数据流向排列）：

- `RootFeature`（912 行，已聚合 `editor` / `gitHub` / `worktreeHeader` / `sidebar` / `detail` / routers）—— 所有 per-window 全局状态的收口点，也是 `selection` 的来源。
- `GitHubFeature`（per-Worktree `snapshots: [WorktreeID: PullRequestSnapshot]` + `loading` + `lastError`）—— PR 数据来源。
- `GitHubSnapshotCache`（写 `~/.config/codans/github-snapshots.json`）—— 启动时 `seedFromCache` 喂给 `GitHubFeature`，保证首屏有 PR 数据。
- `EditorFeature.lastOpenResult: OpenResultMarker?` —— Editor 打开结果的 Observable 标记，已在 reducer 里赋值（`EditorFeature.swift:131/135`）。
- `MainWindowCommands`（`⌘P` → `commandPaletteToggle`）—— 命令面板唯一的快捷键入口，硬编码为 `.keyboardShortcut("p", modifiers: .command)`。
- `PullRequestPopover`（360pt 已有组件）—— PR 详情弹窗，本设计只在 PR 形态点击时复用它。
- `PullRequestStateColor` / `CheckRollupColor` / `PullRequestBadge.CheckRollup`（已有主题 + 汇总逻辑）—— 色环直接复用它们。

## 2. Goals and Non-Goals

### Goals

- 让 titlebar 中段稳定承载"当前 Worktree 现在怎么样"的单行叙事。
- 五种形态（inProgress / success / warning / PR / motivational）使用统一状态机与切换动画。
- toast 的 auto-clear 与优先级覆盖行为可在 TestStore 里重放。
- 复用 `GitHubFeature.snapshots` 和 `GitHubSnapshotCache`，不新增 `gh` 调用面。
- 不影响左右两侧按钮的位置、大小、行为。

### Non-Goals

- 不设计 `WorktreeHeaderFeature` 的任何升级（bell popover、分组 —— 都保持现状）。
- 不做新的 keybinding 配置系统（命令面板快捷键仍硬编码 ⌘P）。
- 不做持久化 —— toast 与 motivational 纯内存，应用重启全部丢弃。
- 不做菜单栏 / Dock / 通知中心推送。
- 不做多 window 的 broadcast（codans 是单 `WindowGroup`）。
- 不重写 `PullRequestPopover`（只复用）。

## 3. Design

### 3.1 Overview

新增一个独立的 TCA feature：**`StatusBarFeature`**，作为 `RootFeature` 的直接子 scope。它只持有一个字段：`toast: StatusToast?`，承载 inProgress / success / warning 三种瞬态覆盖。PR 形态与 motivational 形态是**视图层的派生**（从 `selection` + `gitHub.snapshots[wt]` + `TimelineView` 直接读），**不进 feature state** —— 因为它们是 pure function of 已有数据，进 state 只会增加一个必须手动维护同步的冗余轴。

中心槽的 SwiftUI 组件 `StatusBarView` 用一个简单的优先级选择函数决定当前渲染哪种形态：

```
toast != nil                      →  toast 形态 (P0 inProgress / P1 success|warning)
toast == nil && 有活跃 PR         →  PR 形态 (P2)
否则                              →  motivational (P3)
```

toast 的生命周期（push / auto-clear / 覆盖）在 reducer 里；PR / motivational 不需要 action 流转，直接 SwiftUI observe。

**关键 trade-off**：*只把 toast 做成 reducer-managed state，派生态做成 view-level projection*，换取 minimum-viable state surface。另一条路是把全部五种形态都 codegen 进一个大 enum state、由 reducer 负责每次推导 —— 会让 RootFeature 每次 `gitHub.snapshots` 变动都要 dispatch 一个 action、TestStore 爆炸式增长测试用例。派生态交给 SwiftUI 的 observe 机制就地渲染，不亏。

### 3.2 System Context

```
┌──────────── RootFeature (parent) ─────────────────────────────────┐
│                                                                   │
│   selection ◀───── hierarchyClient.selectionChanges()              │
│   gitHub.snapshots[wt]                                             │
│   editor.lastOpenResult                                            │
│                                                                   │
│   Scope(state: \.statusBar, action: \.statusBar) { StatusBar…() }  │
│                             ▲                                      │
│                             │ .push / .cleared                    │
│                             │                                      │
│   coreReducer listens on:                                          │
│     .editor(.openSucceeded(...))   ────► .statusBar(.push(.success…))│
│     .editor(.openFailed(...))      ────► .statusBar(.push(.warning…))│
│     .gitHub(.mergeCompleted(...))  ────► .statusBar(.push(.success…))│
│     .gitHub(.markReadyCompleted)   ────► .statusBar(.push(.success…))│
│     (future) .runScript(.started/.completed/.failed) ────►  ...    │
│                                                                   │
└──────────────────────┬────────────────────────────────────────────┘
                       │ scoped store
                       ▼
           ┌────────────────────────────┐
           │  StatusBarView (SwiftUI)   │
           │                            │
           │  pick one by priority:     │
           │   toast ?                  │   ← reducer-owned
           │   derived PR from          │   ← observes gitHub.snapshots
           │     gitHub.snapshots[wt]   │
           │   motivational             │   ← TimelineView + const shortcut
           │                            │
           └─────────┬──────────────────┘
                     │ mounted via
                     ▼
           WorktreeDetailView
             .toolbar { worktreeToolbarContent(...) }
```

只有一条**新的**数据入边（RootFeature 把 child Delegate 翻译成 `.statusBar(.push(...))`）和一条**新的**视图（中段 ToolbarItem）。其他都是对既有状态的读。

### 3.3 State & API Design

#### `StatusToast` 值类型（CodansCore 模块）

放在 `CodansCore/StatusBar/StatusToast.swift`。原因：`RootFeature` 和后续 feature（run-script 等）都需要构造 `StatusToast`；放在 core 模块避免交叉依赖。

```
public enum StatusToast: Equatable, Sendable {
  case inProgress(String)   // spinner + message
  case success(String)      // ✓ + message
  case warning(String)      // ▲ + message
}
```

没有 `error` case：致命错误在 codans 里走 sheet / banner，不占这块槽。

#### `StatusBarFeature`

```
@Reducer
struct StatusBarFeature {
  @ObservableState
  struct State: Equatable {
    var toast: StatusToast? = nil
    // internal monotonic token so auto-clear timers cancel each other safely
    var sequence: UInt64 = 0
  }

  enum Action: Equatable {
    case push(StatusToast)
    case cleared(sequence: UInt64)     // fired by auto-clear timer; ignored if stale
    case dismissed                     // manual dismiss (UI X button, optional)
  }

  nonisolated enum CancelID: Sendable { case autoClearTimer }

  // Reducer body (sketched):
  //  .push(toast):
  //     state.toast = toast
  //     state.sequence &+= 1
  //     cancel in-flight timer
  //     if toast is .success -> schedule .cleared after 3s w/ current sequence
  //     if toast is .warning -> schedule .cleared after 8s w/ current sequence
  //     if toast is .inProgress -> no timer
  //  .cleared(seq):
  //     if seq == state.sequence { state.toast = nil }
  //  .dismissed:
  //     state.toast = nil
  //     cancel timer
}
```

**sequence 令牌**解决覆盖覆盖的重入问题：push → push 覆盖时，旧的 `Task.sleep` 仍可能跑完后 fire 一个 `.cleared(oldSeq)`；通过 sequence 比对丢弃。比用 `.cancellable(id:)` 更保险（`cancelInFlight` 的竞态语义在 `Task.sleep` 已 resume 之后窗口依然存在）。

#### RootFeature 的路由层

在 `coreReducer` 新增若干 pass-through 分支，把既有 child delegate / actions 翻译成 toast push：

```
case .editor(.openSucceeded(_, let displayName)):
  // 不覆盖现有行为，只追加 toast 发射
  return .send(.statusBar(.push(.success("Opened in \(displayName)"))))

case .editor(.openFailed(let reason)):
  return .send(.statusBar(.push(.warning(reason))))

case .gitHub(.mergeCompleted(_, let prNumber, .success)):
  return .send(.statusBar(.push(.success("PR #\(prNumber) merged"))))

case .gitHub(.markReadyCompleted(_, .success)):
  return .send(.statusBar(.push(.success("PR marked ready"))))

case .gitHub(.mergeCompleted(_, _, .failure(let e))),
     .gitHub(.closeCompleted(_, .failure(let e))),
     .gitHub(.markReadyCompleted(_, .failure(let e))),
     .gitHub(.rerunFailedJobsCompleted(_, .failure(let e))):
  return .send(.statusBar(.push(.warning(shortMessage(e)))))
```

RootFeature 已经是现有 action forwarding 的总分流站（`.editor(.setProjectOverride)` 等也在这里翻译），这个扩展与现有风格一致。

未来 `RunScriptFeature` 接入时同样在 RootFeature 里加 3 条分支（`.started` → inProgress / `.completed` → success / `.failed` → warning），不需要改 `StatusBarFeature` 本身。

### 3.4 PR 形态数据读取

`StatusBarView` 在 PR 形态下读 `store.rootState.gitHub.snapshots[currentWorktreeID]`。具体实现：

- `RootFeature.Scope` 时为 status bar 构造一个 scoped store 携带**投影过的视图状态**（只含 toast + 当前 worktree 的 PR snapshot + selection + editor descriptor map），避免 view 直接 import RootFeature 的完整 state surface。
- Scope 的投影函数是纯函数：`(RootState) -> StatusBarViewModel`。`StatusBarViewModel` 是一个纯 value type，只含渲染所需字段：
  - `toast: StatusToast?`
  - `pr: PullRequestSnapshot?`（已经过"非 CLOSED + number 非空"过滤）
  - `isLoadingPR: Bool`（给 motivational 是否要先 defer 的判断用，见 §3.6）

这与 sidebar 的 `WorktreeGitHubBadge` 读 `store.snapshots[worktreeID]` 是**同一个字段**，保证 titlebar 和 sidebar 永远同步 —— 没有第二条"status bar 专属"的 PR 数据通路。

### 3.5 Checks Ring 组件

新建 `StatusBar/Views/ChecksRollupRing.swift`。输入：`checks: [CheckResult]`（snapshot.checkRollup）。

复用已有的 `PullRequestBadge.CheckRollup.from(checks:)` 汇总成 `{passing, failing, pending, neutral}` 四类计数，渲染为一个 14×14 pt 的环形分段图：

- 每段角度 = `count / total * 360°`
- 颜色取自 `CheckRollupColor`（已存在：`passing/failing/pending/neutral` 四个常量）
- `total == 0` 时不渲染（`EmptyView()`）
- merged PR 不渲染（调用方判断）

这个组件不引入任何新的颜色 / 数据模型；纯粹是"已有 rollup 逻辑 + 新的 SwiftUI shape"。如果 sidebar 以后想换 ring 也能直接复用 —— 作为**意外的 bonus**而非设计目标。

### 3.6 Motivational 形态

```swift
private struct StatusMotivationalView: View {
  var body: some View {
    TimelineView(.everyMinute) { context in
      let style = timeStyle(for: Calendar.current.component(.hour, from: context.date))
      HStack(spacing: 8) {
        Image(systemName: style.icon).foregroundStyle(style.color)
        Text("\(context.date, format: .dateTime.hour().minute()) – \(Self.paletteHint)")
          .monospaced().font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  static let paletteHint = "Open Command Palette \(CommandPaletteShortcut.displayString)"
}
```

`CommandPaletteShortcut.displayString` 是**新增的单一常量**（放在 `CodansCore/Shortcuts/CommandPaletteShortcut.swift`）：

```
public enum CommandPaletteShortcut {
  public static let key: Character = "p"
  public static let modifiers: EventModifiers = .command   // ⌘
  public static let displayString: String = "⌘P"
}
```

然后 `MainWindowCommands.swift:37` 也改成读这个常量（`.keyboardShortcut(KeyEquivalent(CommandPaletteShortcut.key), modifiers: CommandPaletteShortcut.modifiers)`），保证 hint 文案永远与菜单绑定一致。这是**本设计唯一对既有代码的主动改动**（除了 RootFeature 加 Scope 和 WorktreeDetailView 加 ToolbarItem）。

回答 OQ-1：采用 (a) 硬编码文案，但通过共享常量消除漂移。不走 (b) 因为命令面板是 titlebar hint 想推荐的核心入口，砍掉 hint 就失去了 motivational 的"推荐"作用。不走 (c) 因为命令面板已经落地。

### 3.7 ⌘-hold 切换文案

PR 形态按住 ⌘ 时文字换成 `Open on GitHub ⌘↵`。codans 还没有命令键观察器。新增 `StatusBar/CommandKeyObserver.swift`：

```
@Observable
final class CommandKeyObserver: NSObject {
  var isPressed: Bool = false
  private var monitor: Any?

  func start() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
      self?.isPressed = ev.modifierFlags.contains(.command)
      return ev
    }
  }
  func stop() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
}
```

在 `CodansApp` 启动时实例化一次，通过 `.environment(commandKeyObserver)` 注入；`StatusPullRequestView` 用 `@Environment(CommandKeyObserver.self)` 读。只监听 local events（我们的进程 focus 时），不需要 AppKit 的 Accessibility 权限。

### 3.8 窄窗口隐藏

首选 SwiftUI 的 `ViewThatFits`：

```
ViewThatFits(in: .horizontal) {
  FullStatusBarView(vm: vm)     // 完整宽度：徽章 + ring + 简述
  CompactStatusBarView(vm: vm)  // 压缩：徽章 + ring 或徽章 + 时间
  Color.clear                   // 彻底不够：什么都不显示
}
```

`ViewThatFits` 原生测量且零 GeometryReader 侵入性，是**最小化**的宽度自适应方案。不设硬编码 pt 阈值 —— 设计阶段不用定数值；实现阶段如果发现 SwiftUI 测量在 toolbar 上抽风（个别 macOS 版本已知问题），回退到 GeometryReader + 一个经验阈值（暂定 520pt 为窗口宽度下限）。

Toolbar 的 `ToolbarSpacer(.flexible)` 夹在 navigation group 与 primaryAction group 之间，保证即使中段是 `Color.clear` 右侧按钮也不会左移。

### 3.9 Toolbar 集成

现有 `worktreeToolbarContent` 结构（`WorktreeDetailView.swift:161-218`）只有 navigation + primaryAction 两组。修改后：

```swift
@ToolbarContentBuilder
private func worktreeToolbarContent(address: Address, info: WorktreeInfo?) -> some ToolbarContent {
  if let info {
    if info.project.supportsWorktrees {
      branchToolbarItem(info: info)          // 保持不变
    }
    ToolbarSpacer(.flexible)                  // 新增
    ToolbarItem(placement: .principal) {      // 新增
      StatusBarView(
        store: store.scope(state: \.statusBar, action: \.statusBar),
        worktreeID: address.worktree,
        gitHubStore: gitHubStore,             // 新增依赖注入
        editorStore: editorStore              // 已有
      )
      .accessibilityLabel("Status")
    }
    .modifier(SharedBackgroundHidden())       // macOS 26+ 时 .hidden
    ToolbarSpacer(.fixed)                     // 新增
    ToolbarItemGroup(placement: .primaryAction) {
      HeaderBellView(store: headerStore)       // 保持不变
      HeaderOpenSplitButton(...)               // 保持不变
      HeaderGitViewerToggle(...)               // 保持不变
    }
  }
}
```

`WorktreeDetailView` 的构造函数多一个 `gitHubStore: StoreOf<GitHubFeature>` 参数 —— 由 `ContentView` 注入，和现有的 `editorStore`/`headerStore` 同一层。

`SharedBackgroundHidden` 是一个 `@ViewModifier` 包装，复用现有 branch label 的 `if #available(macOS 26.0, *)` 分支（`WorktreeDetailView.swift:213-218`）—— 提取成一个命名 modifier 避免重复。

### 3.10 State Machine（完整）

```
                    Reducer-managed (toast slot)
         ┌─────────────────────────────────────────┐
         │                                         │
         ▼                                         │
     toast=nil ──push(inProgress m)──►  toast=.inProgress(m)
         ▲                                 │    ▲
         │                                 │    │ push(inProgress m')
         │                                 │    └─replaces─┘
         │                                 │
         │                    push(success m)  push(warning m)
         │                                 │                │
         │                                 ▼                ▼
         │                         toast=.success(m)   toast=.warning(m)
         │                               │                 │
         │         .cleared(seq) after 3s│                 │.cleared(seq) after 8s
         └───────────────────────────────┴─────────────────┘

                    View-level derivations (no reducer state)

       toast == nil
          │
          ├── snapshots[wt] is .open|.merged (not closed)  ──► PR form
          └── otherwise                                    ──► motivational
```

### 3.11 Component Boundaries

| Module | 新增 / 改动 | 依赖方向 |
|---|---|---|
| `CodansCore/StatusBar/StatusToast.swift` | 新增（public value type） | 被 app 层 + 未来 Feature 导入 |
| `CodansCore/Shortcuts/CommandPaletteShortcut.swift` | 新增（public constant） | 被 `MainWindowCommands` + `StatusBarView` 共用 |
| `codans/App/Features/StatusBar/StatusBarFeature.swift` | 新增 reducer | 仅依赖 `CodansCore` |
| `codans/App/Features/StatusBar/StatusBarView.swift` | 新增 view（顶层） | 读取 scoped store 和注入的 `gitHubStore` |
| `codans/App/Features/StatusBar/Views/{StatusToastView,StatusPullRequestView,StatusMotivationalView,ChecksRollupRing}.swift` | 新增子视图 | 无横向依赖 |
| `codans/App/Features/StatusBar/CommandKeyObserver.swift` | 新增 `@Observable` | 被 `CodansApp` 实例化、`StatusPullRequestView` 读 |
| `codans/App/Features/Root/RootFeature.swift` | 改动：新增 `statusBar` scope + 4-8 条 action pass-through 分支 | 已存在的 `Scope` 模式 |
| `codans/App/Features/WorktreeDetail/WorktreeDetailView.swift` | 改动：toolbar content 新增 3 项 (Spacer/Item/Spacer) + 多一个 store 参数 | 视图层 |
| `codans/App/CodansApp.swift` / `ContentView.swift` | 改动：注入 `CommandKeyObserver` environment，向 `WorktreeDetailView` 传 `gitHubStore` | bootstrap |
| `codans/App/Commands/MainWindowCommands.swift` | 改动：改为读 `CommandPaletteShortcut.key/modifiers` | 视图层 |
| `codans/Tests/StatusBarTests/StatusBarFeatureTests.swift` | 新增 | TestStore |

**依赖方向**：`Views → Feature → Core`。`Feature` 不 import 任何 View；`Views` 不新增横向跨 feature import（读 `gitHubStore` 通过注入而非 `@Dependency`）。

## 4. Alternatives Considered

对 9 个核心决策各列备选 + 否决理由。

### 4.1 状态归属（决策 1）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. 新 `StatusBarFeature`（推荐）** | 独立 reducer，RootFeature scope | 只关心 toast 这一件事；TestStore 用例最少；未来加多 window / 多发射源时迁移点单一 | 多一个 scope（但 RootFeature 已经有 8 个，增量成本可忽略） | **选它** |
| B. 挂在 `WorktreeHeaderFeature` | 和 bell 同一个 feature | 复用既有 scope | Header 在概念上是"右侧按钮",mixing toast 让两件事的 action enum 混杂；TestStore 中 bell 测试要被迫 assert 无 toast 事件；未来 Header 重构牵连 toast | 否 |
| C. 挂 `RootFeature` 顶层 | 直接在 RootState 加 `toast` 字段 | 不新建 reducer | RootFeature 已 912 行；toast 的 timer effect 加进去更难测；toast 的局部修改也牵动 Root 的大量类型推断 | 否 |

### 4.2 Toast 发射协议（决策 2）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. RootFeature 路由既有 child actions（推荐）** | 在 `coreReducer` 里 pattern match `.editor(.openSucceeded)` 等并 `.send(.statusBar(.push…))` | 零新协议；现有 Delegate/Action 足够；TestStore 可以完整重放 | RootFeature 多 4-8 行 | **选它** |
| B. 新 `StatusBusClient: DependencyKey` | 各 feature 直接 `@Dependency(StatusBusClient.self)` 推消息 | 解耦：feature 不依赖 RootFeature 的知识 | TestStore 看不见 bus 事件（出了 reducer 系统）；在 reducer effect 里推送反而比 `.send` 更复杂；引入新的"侧信道"模式与既有"delegate up, action down"风格矛盾 | 否 |
| C. 各 feature 直接 `.send(.statusBar(...))` | child 直接发父 action | 和 TCA 理念相反（child 不应该知道 sibling 的 action namespace） | 耦合、违反架构；child 单独测试变难 | 否 |

### 4.3 PR 数据读取路径（决策 3）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. 订阅 `GitHubFeature.State.snapshots[wt]`（推荐）** | Scope 投影出 `pr: PullRequestSnapshot?` | 和 sidebar 同源；loading/error 语义已经在 feature 层；无额外 effect | 需要在 WorktreeDetailView 把 `gitHubStore` 多传一层 | **选它** |
| B. 订阅 `GitHubSnapshotCache` 文件流 | 用 `FSEventStream` 或 `GitHubSnapshotCacheClient.observe()` | 视图层与 feature 解耦 | 缓存只反映"上次成功批量 fetch"，**不反映会话内 mid-session 更新**（例如 merge 完成后的乐观刷新）—— 会导致 titlebar 落后于 sidebar；文件读/解码成本；增加一个订阅管理点 | 否 |
| C. 新建 `PRSnapshotProvider: AsyncSequence` 混合层 | 包装 feature state + cache 作为 fallback | 兼顾两者 | 过度工程；只有两个消费者（sidebar + titlebar），都能直接读 feature state | 否 |

### 4.4 Checks Ring 组件（决策 4）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. 独立 `ChecksRollupRing` 视图 + 复用 `PullRequestBadge.CheckRollup`（推荐）** | 视图新，汇总函数复用 | 小、单职责、可复用 | 多一个文件 | **选它** |
| B. 在 `StatusPullRequestView` 内联 | 不建子组件 | 文件少 | 如果 sidebar 后续想换 ring 就得抽；现在抽的成本几乎为零 | 否 |
| C. 与 `WorktreeGitHubBadge` 合并成统一视图 | 两个消费者用同一个视图 | 理论上最"统一" | sidebar badge 和 titlebar ring 的视觉要求不同（badge 是胶囊 + 文本、ring 是纯圆环），强行合并会变成 `style: enum` 分支怪物 | 否 |

### 4.5 Motivational 快捷键来源（决策 5）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. 硬编码 + 共享常量 `CommandPaletteShortcut`（推荐）** | 菜单绑定和 hint 文案读同一个常量 | 零新系统；无漂移；后续做 keybinding 配置时单点替换 | 写死 ⌘P，用户无法自定义 | **选它** |
| B. 新建 `AppShortcutsRegistry` 协议 | 全局可配置键位表 | 未来可扩展 | 与本 spec 范围不符（不是 keybinding 设计）；deferred 更合适 | 否 |
| C. 砍掉 hint 只显示时间 | motivational = `"HH:mm"` + 图标 | 零修改 | 放弃了"推荐主要入口"的动机；titlebar 就变成了装饰钟表 | 否 |

### 4.6 Toast 节流策略（决策 6）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. 后到覆盖先到，无队列，用 sequence 令牌去除 stale timer（推荐）** | 最近的 push 获胜；定时器用 monotonic seq 验证自己是否过时 | 简单、可预测、TestStore 好写；复合序列 `inProgress→success→inProgress` 也只是三次 push 依次生效 | 快速多 push 可能视觉闪烁（但实际发射源每事件至少几百 ms 间隔） | **选它** |
| B. 同 message 合并（dedup） | 同一 message 重复 push 不重置 timer | 防抖 | emitters 自己控制即可；做在 reducer 里增加特例分支 | 否（首版不做，列入 future） |
| C. success/warning 按 severity 排队 | 堆栈式显示 | 最少丢失信息 | 严重过度设计；titlebar 是瞬态反馈区不是日志；队列会让显示滞后于事件 | 否 |

### 4.7 窄窗口隐藏（决策 7）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. `ViewThatFits`（推荐）** | SwiftUI 声明式宽度自适应 | 零几何计算；自带退化链；macOS 13+ 可用 | 在极端情况下 SwiftUI 测量被 toolbar 内部 padding 污染（已知偶发 bug） | **选它；必要时回退到 B** |
| B. GeometryReader + 阈值常量 | 显式读 width，与预设 pt 比较 | 行为完全可控 | 侵入式；阈值硬编码；多一处可能漂移的魔法数字 | 回退方案 |
| C. `.toolbar(removing:)` / 让 SwiftUI 溢出到菜单 | 让系统决定 | 零代码 | spec 明确禁止塌缩到 overflow 菜单 | 否 |

### 4.8 状态机实现形态（决策 8）

| 方案 | 描述 | 利 | 弊 | 结论 |
|---|---|---|---|---|
| **A. TCA reducer + `.run` effect + sequence（推荐）** | 见 §3.3 | TestStore 能完整重放 timer 行为（通过 `TestClock`）；sequence 令牌覆盖 `Task.sleep` race | timer 要依赖注入 clock | **选它** |
| B. SwiftUI `@State` + `.task(id:)` | 纯 view 层管理 timer | 代码最少 | TestStore 无法 reach；timer 跨视图重建会丢失；无法在 feature 层对 toast 做业务规则 | 否 |
| C. 全局 `Timer.publish` 单例 | Combine 驱动 | — | 退化成 A 的弱化版，还要自己管生命周期；不与 TCA 的 effect 系统协作 | 否 |

### 4.9 文件划分（决策 9）

见 §3.11 的表格；已与现有 Feature 组织（`App/Features/<Name>/`, Views 子目录，Core 共享 value types）保持一致。无重大替代方案。

## 5. Cross-Cutting Concerns

### 5.1 Testing Strategy

- **`StatusBarFeature` 单元测试**（TestStore + `TestClock`）：
  - `push(.success)` → 3s 后自动 clear
  - `push(.warning)` → 8s 后自动 clear
  - `push(.inProgress)` → 不自动 clear
  - `push(.success)` 再 `push(.success)` 前者的 timer 被旧 sequence 令牌丢弃
  - `push(.inProgress)` 再 `push(.success)` 切换
- **路由测试**：RootFeature 收到 `.editor(.openSucceeded)` 时发出 `.statusBar(.push(.success…))`。
- **视图层**：`StatusBarView` 的优先级选择用纯函数 `StatusBarForm.resolve(toast:, pr:, …)` 承载，附带单测（case 矩阵：toast × pr × selection）。
- **Snapshot 测试**（可选）：五种形态各一张 snapshot，验证视觉不回退（`swift-snapshot-testing` 已在 Tuist 依赖中）。
- **Live smoke**：`make mac-run-app`，手工触发 `⌘E → Opened` 看 success toast，切换到 PR worktree 看徽章/环，⌘-hold 文案切换。

### 5.2 Accessibility

- `StatusBarView` 外层 `accessibilityElement(children: .contain)`；每种形态内部 `.accessibilityLabel("Status: …")` + `.accessibilityValue(<当前文本>)`。
- 切换形态时不做 AX 通告（避免打扰 VoiceOver 用户在终端里的输入焦点）；spec AC-VS-3 的"朗读一次"通过 `.accessibilityValue` 变化时系统默认行为实现。
- motivational 的 `TimelineView` 每分钟刷新一次 —— 每次 AX tree rebuild 可能触发朗读；用 `.accessibilityIdentifier("status.motivational")` 稳定节点让 VoiceOver 识别成同一元素，避免被当新元素反复念。

### 5.3 性能

- `StatusBarView` 的 scoped store 投影函数返回 value type，SwiftUI 的等值比较决定重绘频率。投影包含的字段都是小 value type，比较成本可忽略。
- `TimelineView(.everyMinute)` 每分钟一次 view body 调用，开销极小。
- `CommandKeyObserver` 是一个 `NSEvent.addLocalMonitorForEvents`，每次 flagsChanged 才 fire —— 不 poll。
- 无额外 `gh` 调用；所有 PR 数据都是现有订阅的派生。

### 5.4 Observability

- `StatusBarFeature` 的 Logger subsystem：`"com.gumpw.codans.statusbar"`，category 按 action 命名（`push` / `cleared`）。
- 生产中只打 warning toast 的 message 字符串（帮助排查"为什么看到橙色"），不打 success / inProgress（降噪）。

### 5.5 Migration / Rollback

- 无持久化 → 无迁移。
- 功能隐藏开关：feature flag `StatusBarFeature.isEnabled` 放在 `SettingsStore.developer`？**不做** —— 新增按钮的 UI 一向不加 flag；真要回滚直接 revert 中段 3 行 toolbar content 即可。
- 如果 `ViewThatFits` 上线后出现宽度 bug，临时方案是将中段包裹 `.frame(minWidth: 0, maxWidth: .infinity, minHeight: 22, maxHeight: 28)`，让 toolbar 给它至少一个稳定高度。

### 5.6 Security / Privacy

toast message 由 app 内部字符串构成，不携带用户密码 / token / 路径。PR title 来自 GitHub，已是用户自己的 repo 的公开信息。motivational 只展示本地时间。无 PII 新增。

## 6. Implementation Phasing

按"最小可见 → 加 PR 态 → 加 toast → 加 motivational 高亮"递进，每步都可独立 merge：

- **M1 Skeleton**：新增 `StatusToast` + `StatusBarFeature`（仅 toast state）+ RootFeature scope + `StatusBarView` 内只渲染 `toast` 非 nil 的形态；toolbar 插入中段槽。手工发 `.statusBar(.push(.success("Hello")))` 验证。
- **M2 Editor hook**：RootFeature 路由 `.editor(.openSucceeded/.openFailed)` → toast。`⌘E` 打开 editor 时 titlebar 回显。
- **M3 GitHub hook**：RootFeature 路由 `.gitHub(.mergeCompleted / .markReadyCompleted / … Completed)` → toast。
- **M4 PR form**：`StatusPullRequestView` + `ChecksRollupRing` + PR popover 复用 + ⌘-hold 切文案 + `CommandKeyObserver`。
- **M5 Motivational**：`StatusMotivationalView` + `CommandPaletteShortcut` 常量 + `MainWindowCommands` 改读常量。
- **M6 Narrow width**：`ViewThatFits` 三档退化；手工拖窗测验。
- **M7 Polish**：AX label、snapshot tests、macOS 26+ `SharedBackgroundHidden` 提取。

每个 M 提交一条 `feat(statusbar): …` commit；M1 上线后已经可以在 titlebar 看到 toast，用户体验正向。

## 7. Risks

| 风险 | 可能性 | 影响 | 缓解 |
|---|---|---|---|
| R1 | `ViewThatFits` 在 macOS 26 toolbar 内测量失真 | 中 | 中（中段在某些窗口尺寸闪烁或误隐藏） | 回退到 GeometryReader + 520pt 阈值；AC-VS-2 的验证放在 M6 |
| R2 | `TimelineView(.everyMinute)` 每分钟触发 SwiftUI diff，偶发情况下 AX tree 抖动 | 低 | 低（VoiceOver 重复朗读） | `accessibilityIdentifier` 稳定节点；如仍有问题改成 5 分钟刻度或纯字符串不带分钟 |
| R3 | RootFeature 路由分支增多后 `coreReducer` 继续膨胀 | 高 | 中（可维护性） | 把 toast 路由分支抽成 `private var statusToastRouting: some Reducer` 单独 ReducerBuilder 方法（和 `sidebarAndDetailScopes` 同一风格） |
| R4 | `CommandKeyObserver` 未停止导致 local monitor 泄漏 | 低 | 低（事件开销） | `start()` 在 `CodansApp` onAppear，`stop()` 在 onDisappear；加 weak-self capture；附单元测试 |
| R5 | `success` toast 的 3s 对用户太短 / 太长 | 中 | 低（UX 调整） | 常量放 `StatusBarFeature.Constants`，后续在 Settings 暴露即可 |
| R6 | `EditorFeature.openFailed(reason:)` 里的 `reason` 字段未脱敏可能带路径 | 中 | 低（隐私） | `shortMessage(_:)` 路由函数只取第一行 + 截断 80 字符 |
| R7 | PR `url` 为 `file://` 或非 https（数据污染） | 低 | 低 | `⌘+click` 的 URL 构造时 `scheme == "https"` 断言；失败则降级为不响应 |
| R8 | Scope 投影未覆盖某个字段导致 `Equatable` 比较过于宽松，view 不刷新 | 中 | 中 | `StatusBarViewModel` 明确 Equatable 比较所有字段；附 `@Observable` + 投影单元测试 |

## 8. Open Questions — Resolutions

| ID（spec） | 原问题 | 设计给出的答案 / 下一步 |
|---|---|---|
| OQ-1 | 命令面板快捷键是否已有解析 API | **已答**：没有 keybinding DB，直接用硬编码 + 新增 `CommandPaletteShortcut` 共享常量（§3.6）。`MainWindowCommands` 同步改造。 |
| OQ-2 | `checkRollup` 是否已含 `skipped / neutral` | **已答**：`PullRequestBadge.CheckRollup.from` 已产出 `{passing, failing, pending, neutral}` 四分类，neutral 吸收 skipped。色环直接复用；不需要扩 schema。 |
| OQ-3 | `EditorFeature.lastOpenResult` 能否被订阅 | **已答**：`@ObservableState` + `.openSucceeded/.openFailed` action 已经是 observable、reducer 可 intercept 的事件；RootFeature 直接监听这两个 action 翻译成 toast。不需要改 `EditorFeature`。 |
| OQ-4 | run-script 生命周期事件 | **延后**：当前 codans 没有 `RunScriptFeature`（grep 零命中）。设计保留 inProgress 形态作为扩展点；真正接入时在 RootFeature 加 3 行分支即可。不阻塞本设计。 |
| OQ-5 | Plain Project 的 motivational 是否定制 | **答**：首版**不定制**。motivational 文案是 `HH:mm – Open Command Palette ⌘P`，对 Plain Project 同样适用（命令面板始终可用）。未来若 Plain Project 有专属 hint，扩展一个 `motivationalHint(for: project)` 纯函数即可。 |
| OQ-6 | 多 toast 是否需要队列 | **答**：首版**不做队列**（方案 A，§4.6）。后到覆盖先到。Could Have 清单中保留"inProgress 多任务聚合"作为未来增量。 |

## 9. Glossary

- **StatusBarFeature**：本设计新增的 TCA reducer，只管 toast 槽位
- **StatusToast**：`inProgress` / `success` / `warning` 三态值类型
- **StatusBarView**：titlebar 中段 SwiftUI 组件，按优先级挑选形态
- **StatusBarViewModel**：scoped store 投影出来的视图数据（toast + pr + selection 字段）
- **ChecksRollupRing**：14pt 四色饼环视图，消费 `[CheckResult]`
- **CommandPaletteShortcut**：`⌘P` 的共享常量命名空间（key / modifiers / displayString）
- **CommandKeyObserver**：`@Observable` NSEvent 本地 monitor，追踪 `.command` modifier
- **sequence token**：`StatusBarFeature.State.sequence` 单调 ID，用于 `.cleared` timer 的陈旧判定
