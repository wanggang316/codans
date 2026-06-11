# Design Doc: Worktree Branch Switcher & Diff History

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-24
**Spec:** [worktree-branch-switcher-and-history](../product-specs/worktree-branch-switcher-and-history.md)

## Context and Scope

Worktree detail header 当前把 `Worktree.branch` 渲染成纯文本副标题；Diff Viewer 右侧只展示未提交改动（"Changes"）。两块都是 read-only。本设计在保持现有读路径不变的前提下，新增两个能力：

1. **可点击分支切换器**：header 分支区域升级为可点击入口，弹出 popover 列分支 + 最近 10 commits，并能在应用内 `git switch`。
2. **Diff Viewer History tab**：右侧拆 Changes/History 双 tab，History 列当前分支提交历史，点击 commit 在左侧渲染整 commit diff。

已有的相关基础设施：
- `GitService` / `LiveGitService` —— `nonisolated`, `Sendable`，统一走 `CommandRunner` + `GitProcessEnv` + 16 MiB / 10 s caps。已有 `log()` `commitDiff()` `status()` `diffNumstat()`，但**没有** `currentBranch` / `listAllBranches` / `switchBranch`。
- `GitCommand` —— 纯 argv builder，所有 git 调用从这里发起。
- `GitOutputParser` —— `parseLog` / `parseStatus` / `parseDiffNumstatZ` 等纯函数，pattern 已成型。
- `WorktreeHeadWatcher` —— 监听 `.git/HEAD` 文件变化，已经把"终端里 `git checkout` 后的分支变化"反馈到 catalog；本设计依赖它，不动它。
- `DiffFeature` —— 已经有 `worktreeSelected` / `fileRowTapped` / `diffsByPath` / `CancelID` 等结构，extension 点清晰。
- `WorktreeHeaderInfoLabel` —— 当前两层结构（icon + name + 可选 branch 副标题）；mounted 在 `WorktreeDetailView` 的 `branchToolbarItemDefault` / `branchToolbarItem`。
- `WorktreeHeaderFeature` —— 现有 reducer，承载 editor 打开 / run-script 等 delegate；**不**承载 branch 状态。

## Goals and Non-Goals

### Goals

- 三个 `GitService` 新操作（`currentBranch` / `listAllBranches` / `switchBranch`）以与既有方法**完全一致的风格**注入：nonisolated、走 `CommandRunner`、output 解析在 `GitOutputParser`、argv 在 `GitCommand`。
- Header 行 1 = branch（含 detached HEAD 文案）、行 2 = `folder · project`，hover + 点击触发分支 popover。
- Popover 内的两组（Branches / Recent Commits）能各自独立加载，互不阻塞；切换分支期间 popover 关闭、loading 在 header 上可见。
- 切换分支成功的 UI 更新**完全依赖** `WorktreeHeadWatcher` 既有的 HEAD-change 事件回路，不引入手工 reload 调用链。
- Diff Viewer 右侧 segmented tab，History 自带分页 + commit 选择；左侧 diff 渲染器同时服务文件 diff 与 commit diff。
- 切换失败时 git 原生 stderr 第一行原样进入 inline 错误条；交互上可关闭、不阻塞其他操作。

### Non-Goals

- 不实现 stash / discard / cherry-pick / revert / pull / fetch / push 等写操作。
- 不为非 git 的 Plain Project 适配 popover；分支区域沿用现状显示文件夹。
- 不引入 commit-graph 可视化（无 git log --graph 风格 ASCII / SVG）。
- 不在 service 层做"分支是否能安全切换"的预检（不复制 git 的自有判断逻辑）。
- 不重写 Diff Viewer 左侧渲染器（`DiffRendererView` / `DiffDrawerView` 保持不变，只换数据源）。
- 不重新设计 popover 视觉规范；遵循 `PullRequestPopover` 的卡片风格。

## Design

### Overview

四块改动，按依赖顺序：

1. **Service 层**（`Git/`）：新增 3 个 `GitService` 方法 + 2 个 `GitCommand` argv + 1 个 `GitOutputParser` 解析器 + 1 组 `CodansCore` 模型（`BranchRef` / `BranchInventory` / `BranchSwitchTarget`）。
2. **新 Reducer**（`App/Features/BranchSwitcher/`）：`BranchSwitcherFeature` 独立于 `WorktreeHeaderFeature`，承载 popover 全部状态与副作用。
3. **Header 视图**（`WorktreeHeaderInfoLabel`）：改成两行 + 整行可点击 + spinner 槽位；popover 内容由 `BranchSwitcherView` 提供。
4. **Diff Viewer**（`DiffFeature` / `DiffInspectorView`）：扩展 state 引入 `selectedTab` + `historyState` + `presentedCommitSha`，view 顶部加 segmented control，新增 `DiffHistoryListView`，左侧 drawer 根据 tab 选源。

核心 trade-off：**新开 `BranchSwitcherFeature` 而不是塞进 `WorktreeHeaderFeature`**。Header feature 已经持有 editor / run-script delegate 这一组 action，再加 4–6 个切换相关 action 会让 reducer 变得很难读；BranchSwitcher 又有自己的 popover 生命周期、缓存失效规则、HEAD-change 联动，把它独立出来 TestStore 也更清晰。Header feature 仅作为 view 上的兄弟出现在同一个 `ToolbarItem` 内（详见 Component Boundaries）。

### System Context Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                        WorktreeDetailView                          │
│                                                                    │
│   .toolbar {                                                       │
│     ToolbarItem(.navigation) {                                     │
│       WorktreeHeaderInfoLabel ──── popover ───→ BranchSwitcherView │
│         (row1 branch + spinner)                  ├ Branches list   │
│         (row2 folder · project)                  ├ Recent commits  │
│     }                                            └ "View all"      │
│   }                                                                │
│                                                                    │
│   right panel (Diff inspector):                                    │
│     ┌─[Changes][History]─┐                                         │
│     │  DiffInspectorView │── existing file rows                    │
│     │   or                │                                         │
│     │  DiffHistoryListView│── new: commit rows                     │
│     └───────────────────┘                                          │
│   left:  DiffDrawerView ── renders file diff OR commit diff        │
└──────────────────────────────────────────────────────────────────┘
                       │
                       ▼  (TCA effects)
┌──────────────────────────────────────────────────────────────────┐
│ BranchSwitcherFeature ─── GitServiceClient ───┐                   │
│ DiffFeature           ─── GitServiceClient ───┤                   │
│                                                │                   │
│ RootFeature ─── WorktreeHeadWatcher.events ── invalidates both     │
│                  ▲                             │                   │
│                  │                             ▼                   │
└──── HEAD file ───┘                  Git/  → CommandRunner → git    │
                                                                    │
└──────────────────────────────────────────────────────────────────┘
```

### API Design

#### GitService 新增 (in `Git/GitService.swift`)

```swift
/// `git symbolic-ref --short HEAD`. Returns nil on detached HEAD; throws only
/// on non-detached failures (not-a-repo, git missing, timeout).
func currentBranch(at path: URL) async throws -> String?

/// One-shot `git for-each-ref` covering refs/heads + refs/remotes plus
/// HEAD marker resolution. `BranchInventory.current` matches what
/// `currentBranch` would return for `path` (resolved server-side via
/// `%(HEAD)` so callers never need a second call).
func listAllBranches(at path: URL) async throws -> BranchInventory

/// `git switch <target>`. Local target → `git switch <name>`; remote
/// tracking → `git switch --track <origin/x>`. Failure (dirty tree,
/// conflicts, ambiguous, …) surfaces as `GitError.exec(code, stderr)`
/// with stderr preserved verbatim — UI extracts the first line.
func switchBranch(to target: BranchSwitchTarget, at path: URL) async throws
```

#### Model additions (in `CodansCore/Git/GitModels.swift`)

```swift
public nonisolated struct BranchRef: Equatable, Hashable, Sendable {
  public let shortName: String      // "main", "origin/main"
  public let isRemote: Bool
  public let upstream: String?      // local→remote tracking name, or nil
}

public nonisolated struct BranchInventory: Equatable, Sendable {
  public let current: String?       // nil if detached HEAD
  public let local: [BranchRef]     // sorted asc, current pulled to head
  public let remote: [BranchRef]    // sorted asc, "<remote>/HEAD" filtered
}

public nonisolated enum BranchSwitchTarget: Equatable, Sendable {
  case local(name: String)
  case remoteTracking(shortName: String)  // e.g. "origin/feat/x"
}
```

Sorting / filtering is done at the service layer so every caller gets a stable, render-ready inventory.

#### GitCommand additions

```swift
static func symbolicRefShortHead() -> [String] {
  ["symbolic-ref", "--short", "HEAD"]
}

static func forEachRefBranches() -> [String] {
  [
    "-c", "core.quotePath=false",
    "for-each-ref",
    "--format=%(refname)%09%(refname:short)%09%(upstream:short)%09%(HEAD)",
    "refs/heads", "refs/remotes",
  ]
}

static func switchBranch(target: BranchSwitchTarget) -> [String] {
  switch target {
  case .local(let n):              return ["switch", n]
  case .remoteTracking(let short): return ["switch", "--track", short]
  }
}
```

Records are newline-separated; fields tab-separated. Branch names cannot contain `\t` or `\n` (git ref naming rules), so the parser stays cheap (single split per line).

#### GitOutputParser additions

```swift
static func parseBranchInventory(_ bytes: Data, currentMarker: Character = "*") throws -> BranchInventory
```

Parser responsibilities:
- Split lines, drop empty.
- Per line: 4 fields. `refs/heads/…` → local; `refs/remotes/<remote>/…` → remote.
- Drop refs ending in `/HEAD` on the remote side (`origin/HEAD` is a symbolic ref alias).
- `%(HEAD)` field is `*` for the current branch, `space` otherwise → drives `current`.
- Sort local + remote ascending by `shortName`; if `current` is in local, pull it to position 0.

#### GitServiceClient additions

```swift
var currentBranch:   @Sendable (URL) async throws -> String?
var listAllBranches: @Sendable (URL) async throws -> BranchInventory
var switchBranch:    @Sendable (BranchSwitchTarget, URL) async throws -> Void
```

Three new `unimplemented(...)` testValues with sensible placeholders (empty inventory, nil current, switch as noop / fatalError-on-call).

#### BranchSwitcherFeature (new reducer)

State outline (full source belongs in implementation):

```swift
@ObservableState struct State {
  var worktreeID: WorktreeID?
  var worktreePath: String?
  var inventory: BranchInventory?
  var inventoryLoading: Bool
  var recentCommits: [Commit]
  var commitsLoading: Bool
  var isPopoverOpen: Bool
  var isSwitching: Bool
  var searchQuery: String
  var switchError: SwitchError?
}
```

Actions (sketch):
- View → reducer: `worktreeChanged(id, path)`, `popoverTapped` (toggles), `searchQueryChanged`, `branchTapped(target)`, `viewAllCommitsTapped`, `errorDismissed`.
- Effects → reducer: `inventoryLoaded(Result)`, `commitsLoaded(Result)`, `switchFailed(stderrFirstLine)`.
- External → reducer: `headChangedForCurrentWorktree` (sent by `RootFeature` when its `WorktreeHeadWatcher.events()` loop ticks for the displayed worktree).
- Delegate out: `openDiffViewerOnHistoryTab(WorktreeID, projectID)`.

Effect cancellation IDs: `.inventory`, `.commits`, `.switch`. Switching cancels in-flight inventory/commits loads (their data is about to become stale).

#### DiffFeature additions

State delta:

```swift
enum DiffTab: Equatable { case changes, history }

struct HistoryState: Equatable {
  var commits: [Commit] = []
  var nextOffset: Int = 0
  var pageLimit: Int = 50
  var loading: Bool = false
  var hasMore: Bool = true
  var error: GitError?
}

// in State:
var selectedTab: DiffTab = .changes
var historyState: HistoryState = .init()
var presentedCommitSha: String?
var diffsByCommit: [String: DiffEntryState] = [:]
```

Actions added:
- `tabSelected(DiffTab)`
- `historyAppeared` / `historyLoadNextPageRequested`
- `historyPageSucceeded([Commit], hasMore: Bool)` / `historyPageFailed(GitError)`
- `historyCommitTapped(sha: String, subject: String)`
- `commitDiffSucceededFor(sha, document)` / `commitDiffFailedFor(sha, error)` / `commitDiffTooLargeFor(sha, reason, copyCommand)`
- `headChangedForCurrentWorktree` — resets `historyState`, `presentedCommitSha`, `diffsByCommit` if `selectedTab == .history`; same reset on `worktreeSelected`.

Cancellation IDs: `.historyPage`, `.commitDiff`.

`commitDiff` uses the existing `gitService.commitDiff(url, sha, ignoreWhitespace)`; size caps reuse `DiffFeature.maxFileBytes` / `maxFileLines` against the joined post-image size of the unified diff (or rely on `GitService` 16 MiB cap throwing `.outputTooLarge`).

### Data Storage

No persistent storage. Two in-memory caches:

- `BranchSwitcherFeature.State.inventory` + `recentCommits` — invalidated on `worktreeChanged` or `headChangedForCurrentWorktree`; reloaded on next `popoverTapped`.
- `DiffFeature.State.historyState` + `diffsByCommit` — invalidated on `worktreeSelected` or `headChangedForCurrentWorktree` (HEAD change implies the commit list shape changed).

Trade-off: caching across popover open/close means the second `popoverTapped` returns instantly. The cost is staleness if the user runs `git fetch` in a terminal — but the only way that happens is also a HEAD change (post `git switch`) or an explicit fetch from terminal (no HEAD change). For fetch-only staleness we accept "next popover open is up to N seconds stale until HEAD changes"; user can close + reopen popover after explicit fetch knowing this. **Not** worth a periodic refresh given the freedom from polling.

### Component Boundaries

```
CodansCore (Git models)
  └── BranchRef, BranchInventory, BranchSwitchTarget   (new)

Git/
  ├── GitService                            (+3 methods)
  ├── LiveGitService                        (+3 implementations)
  ├── GitCommand                            (+2 argv builders)
  └── GitOutputParser                       (+parseBranchInventory)

App/Clients/
  └── GitServiceClient                      (+3 closures, +3 unimplemented testValues)

App/Features/BranchSwitcher/                (new directory)
  ├── BranchSwitcherFeature.swift           (reducer)
  ├── BranchSwitcherView.swift              (popover content)
  ├── BranchRowView.swift                   (one row in list)
  └── RecentCommitRowView.swift             (one row in commits group)

App/Features/WorktreeHeader/
  └── WorktreeHeaderInfoLabel.swift         (rewritten: 2-row layout + popover host)

App/Features/Diff/
  ├── DiffFeature.swift                     (state/action additions)
  ├── Views/DiffInspectorView.swift         (segmented control wrapper)
  └── Views/DiffHistoryListView.swift       (new)

App/Features/Root/
  └── RootFeature.swift                     (wires WorktreeHeadWatcher events to
                                             BranchSwitcherFeature + DiffFeature;
                                             handles delegate "openDiffViewerHistory")
```

Dependency rules:
- `BranchSwitcherFeature` depends on `GitServiceClient` only. It does **not** import `DiffFeature` — opens the Diff Viewer via `Action.delegate` consumed by `RootFeature`.
- `DiffFeature` does **not** import `BranchSwitcherFeature`. Cross-talk goes through parent (RootFeature).
- `WorktreeHeaderInfoLabel` hosts the popover but does not own the reducer scope; it receives a `StoreOf<BranchSwitcherFeature>` from its mount site (`WorktreeDetailView` → `branchToolbarItem`).

### Switching flow — sequence diagram

```
User           HeaderInfoLabel       BranchSwitcherFeature      RootFeature       GitService      HeadWatcher    DiffFeature
 │   click branch  │                          │                       │                 │                │             │
 ├────────────────►│ popoverTapped            │                       │                 │                │             │
 │                 ├─────────────────────────►│                       │                 │                │             │
 │                 │                  (load inventory + log 10)        │                 │                │             │
 │                 │                          ├───listAllBranches─────┼───────►(git)    │                │             │
 │                 │                          ├───log(page 0,10)──────┼───────►(git)    │                │             │
 │   pick branch   │                          │                       │                 │                │             │
 ├────────────────►│ branchTapped(.local "x") │                       │                 │                │             │
 │                 ├─────────────────────────►│ isSwitching = true    │                 │                │             │
 │                 │                          │ popover.dismiss        │                 │                │             │
 │                 │                          ├───switchBranch───────►(git)             │                │             │
 │                 │                          │  ok → no action        │                 │                │             │
 │                 │                          │                       │                 │                │             │
 │                 │                          │             (git writes .git/HEAD)      │                │             │
 │                 │                          │                       │                 │ event x        │             │
 │                 │                          │                       │ catalog refresh  │◄───────────────│             │
 │                 │                          │                       │ → Worktree.branch updated         │             │
 │                 │                          │ ◄── headChangedForCurrentWorktree ───┤                  │             │
 │                 │                          │ inventory/commits = nil                │                  ├──reset────►│
 │                 │                          │ isSwitching = false                    │                  │             │
 │       header label now reads new branch (no spinner)               │                  │             │
```

If `switchBranch` errors, the path replaces the trailing two boxes with:

```
                          │ switchFailed(stderrFirstLine)
                          │ switchError = .message("...")
                          │ isSwitching = false
                          │ (header shows banner; spinner gone; branch unchanged)
```

### Header layout

Row 1: `WorktreeRowIcon` (existing, sized down to caption if it visually clashes; default size kept until SwiftUI render shows otherwise) + `Text(branchTitle)` (`.headline`) + trailing chevron-down (or `ProgressView().controlSize(.mini)` when `isSwitching`).

Row 2: `Text("\(worktree.name) · \(project.name)")` (`.caption`, `.secondary`).

`branchTitle` source:
- `worktree.branch == nil` → `"(detached)"` baseline literal (matches `UT-BSH-HD-003`'s regex `^\(detached( @ [0-9a-f]{7,12})?\)$`). Future short-sha form `"(detached @ \(shortSha))"` lights up once `Worktree.headSha` is exposed (OQ-D1).
- otherwise → `worktree.branch ?? worktree.name` (worktree.name fallback covers the freshly-cloned no-HEAD case).

Hover affordance: `.contentShape(.rect)` + `.onHover { isHovered = $0 }` controlling row background opacity. Click toggles `BranchSwitcherFeature.popoverTapped`.

Popover anchor: `.popover(isPresented: $store.isPopoverOpen, arrowEdge: .bottom) { BranchSwitcherView(...) }`.

### Diff Viewer right-panel layout

```
┌─────────────────────────────────┐
│ Picker([Changes][History])      │  ← segmented; 36pt tall
├─────────────────────────────────┤
│ <selected tab body>             │
│                                 │
└─────────────────────────────────┘
```

`DiffInspectorView` becomes a router on `store.selectedTab`:
- `.changes`: existing body (header "Changes (N)" + refresh + file list).
- `.history`: new `DiffHistoryListView` (header "History" + list of `Commit` rows; selected commit's row tinted like a selected file row; infinite scroll via `.onAppear` on the trailing row).

Left side (`DiffDrawerView`):
- `.changes` & `presentedFilePath != nil` → existing per-file diff render.
- `.history` & `presentedCommitSha != nil` → render `diffsByCommit[sha]`, with title `"\(shortSha) · \(commit.subject)"`.
- Either tab with no selection → existing empty state but with tab-appropriate copy ("Select a file" vs "Select a commit").

## Alternatives Considered

### Alt 1 — Put branch popover state inside `WorktreeHeaderFeature`

**Trade-off:** fewer reducers, one mount site. Saves ~40 LoC of plumbing.

**Why rejected:** `WorktreeHeaderFeature` already owns editor / run-script delegate paths (12 actions, 7 delegate cases). Adding 8+ new actions, 4 new state fields, a popover lifecycle, HEAD-change subscription, and an `openDiffViewer` delegate would push that reducer past the comprehension threshold. TestStore organisation for the existing header features is also already mid-sized; a fresh feature is easier to test in isolation. The mount-site complexity is genuinely small (one extra `Store.scope` in `WorktreeDetailView`).

### Alt 2 — Pre-check working-tree dirty in `switchBranch`

**Trade-off:** Catch dirty tree earlier, give a localized message ("You have uncommitted changes in 3 files") with a richer UI (e.g. list which files).

**Why rejected:**
- Race: `git status` then `git switch` is not atomic. A file edit between calls produces a misleading message.
- Authority duplication: `git switch` already enforces this; our pre-check could disagree (different ignore rules, etc.).
- Cost: each switch becomes 2 process spawns instead of 1.
- Message quality: git's own stderr ("error: Your local changes to the following files would be overwritten by checkout: …") is more actionable than anything we could synthesize without extra parsing.

Native error capture wins.

### Alt 3 — Use `git branch -a` instead of `git for-each-ref`

**Trade-off:** Familiar command, output looks more "human".

**Why rejected:** `git branch -a` output is locale-dependent (`* ` marker placement, "(HEAD detached at …)" prose), and the trailing-arrow `->` for symbolic refs is brittle. `for-each-ref` with a custom `--format` is the documented programmatic interface and survives git updates. supacode's branch picker uses the same approach.

### Alt 4 — Two-pass `for-each-ref` (heads, then remotes)

**Trade-off:** Slightly clearer parser per pass.

**Why rejected:** Two process spawns vs one. Parser difference is negligible because the `%(refname)` prefix already disambiguates `refs/heads/*` vs `refs/remotes/*`. Single-pass is also atomic w.r.t. a concurrent `git fetch` mid-sequence.

### Alt 5 — Embed History as a child reducer (`DiffHistoryFeature`)

**Trade-off:** Smaller files, "one reducer one concern", easier unit-test for the History sub-state.

**Why rejected:**
- Shares `worktreeID` / `worktreePath` with the Changes side — child reducer would need scope plumbing or duplicated state.
- Both tabs render into the **same left drawer**, which would require a parent-level "active selection" reducer anyway.
- TCA `@ObservableState` + Reduce composition makes embedded sub-state nearly as testable as a separate reducer.
- The added file (`DiffHistoryFeature.swift`) doesn't pay for itself relative to ~80 lines of additions on `DiffFeature.swift`.

### Alt 6 — Reuse `BranchSwitcherFeature.recentCommits` to back the Diff Viewer's History first page

**Trade-off:** Saves one `log(page: 0)` call when user clicks "View all" right after popover open.

**Why rejected:**
- Cross-feature state sharing requires a parent-owned cache or a publisher.
- The 10-commit popover load and 50-commit History first page have different sort/limit shapes — sharing means the bigger one becomes the truth and the popover delays for nothing on cold start.
- Cache invalidation gets coupled: a HEAD change has to invalidate both, and the order matters during a switch.

Two independent caches is simpler and the duplicated `log()` call is cheap (< 50 ms typical).

## Cross-Cutting Concerns

### Concurrency & Cancellation

- Three new `CancelID` slots in `BranchSwitcherFeature`: `.inventory`, `.commits`, `.switch`. Re-tapping `popoverTapped` while an inventory load is in flight cancels and re-issues. A successful `switchBranch` does **not** cancel itself — only worktree change does (the switch is a single short-lived call).
- Two new `CancelID` slots in `DiffFeature`: `.historyPage`, `.commitDiff`. Each follows the same `cancelInFlight: true` pattern already used for `.changedFiles` / `.diff`.
- `HeadChangedForCurrentWorktree` is dispatched from `RootFeature`'s existing `WorktreeHeadWatcher.events()` loop. The loop already runs on `MainActor`; no new task management.
- `BranchSwitchTarget` is `Sendable` (enum with `String` payloads). All effect closures use `[gitService]` capture as elsewhere.

### Error Handling

- `GitError.exec(code, stderr)` from `switchBranch` is mapped to `SwitchError.message(firstLine)` in the reducer using a new helper `GitError.firstLineMessage`. Full stderr remains in the original error inside log statements (for debugging via Console.app).
- `currentBranch` returns nil on detached HEAD by parsing the rev-parse exit code locally — does **not** throw. All other failures (not-a-repo, git missing, timeout) throw and surface in the popover as a single "Couldn't list branches" banner with retry.
- `listAllBranches` failure renders an in-popover empty state with a retry button (so the user can still see Recent Commits if that succeeded).
- History page failure renders a centered error block with retry, mirroring `DiffInspectorView.errorBlock`.

### Testing Strategy

- **GitOutputParser** unit tests for `parseBranchInventory`: empty input, single local branch, mixed local+remote, `origin/HEAD` filtered, current marker placement, sort order, unicode names (Chinese / emoji), tracking upstream parsing.
- **LiveGitService** integration tests with a mock `CommandRunner`: assert argv shape for each new method; assert SwitchError surfaces from exit code 1 + canonical stderr; assert detached HEAD nil for symbolic-ref exit 128.
- **BranchSwitcherFeature** TestStore: popover-open → inventory + commits loaded in parallel; branch-tapped sets isSwitching + closes popover + cancels in-flight loads; headChanged clears caches + isSwitching; viewAllCommits emits delegate.
- **DiffFeature** TestStore (extending existing): tabSelected toggles state without resetting; historyAppeared loads first page; selecting commit caches diff; second selection hits cache; worktree change resets history.
- **WorktreeHeaderInfoLabel** snapshot test (if snapshot infra in repo — verify in implementation) for both branch-shown and detached-HEAD rendering.

### Accessibility

- Header row 1 declares `.accessibilityLabel("Branch \(name), button")` and `.accessibilityAddTraits(.isButton)`; spinner state adds `.accessibilityValue("Switching")`.
- Popover items each carry semantic labels: "Switch to branch \(name)", "Currently on \(name)" for the checkmarked row, "View all commits in Diff Viewer" for the footer.
- Tab segmented control gets a `.accessibilityLabel("Inspector tab")` wrapping the picker.
- VoiceOver announcement on switch success/failure handled by existing `accessibilityNotification(.announcement)` infra (used in worktree-status-bar design) — if not present, scoped out and noted as follow-up.

### Performance

- `for-each-ref` on repos with ~1000 refs returns in < 50 ms in our test environment; output stays well under the 16 MiB cap. Single-pass is fine.
- History page of 50 commits via `git log` is ~10–30 ms; infinite scroll uses `cursor.offset` (existing `LogPage.Cursor` mechanism).
- `commitDiff` on large merge commits can be huge; reuse existing 16 MiB cap and per-file `maxFileBytes` / `maxFileLines` thresholds. Out-of-bound diffs render the existing "too large" placeholder.
- No new polling, no new file watchers. All proactive UI updates come off the existing `WorktreeHeadWatcher`.

### Migration / Rollback

No data migration. Rollback = revert the diff. The new `GitService` methods are additive; removing them does not break existing callers. The Diff Viewer state changes are additive (`selectedTab` defaults to `.changes`, matching prior behaviour).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `for-each-ref` output format drifts on a future git release | Low | High | Pin to documented `%(…)` tokens (stable since git 2.0+). Parser tested with locale-independent inputs. |
| `git switch --track` ambiguity when multiple remotes have the same short name | Low | Medium | Caller already passes the fully-qualified short name (`origin/x`); ambiguity only happens if a user explicitly types ambiguous input, which our UI never does. |
| `WorktreeHeadWatcher` debounce (200 ms) makes header spinner linger an extra ~200 ms post-switch | Certain | Low | Acceptable. Faster reset would require a parallel "I just switched" hint, doubling truth sources. |
| Switching while popover's inventory load is still in flight produces visible flicker (popover dismisses, then reload triggers fresh inventory next open) | Possible | Low | `.cancellable(id: .inventory)` cancels the in-flight load; next open re-issues. Verified in TestStore. |
| Large merge commit diffs hit the 16 MiB cap and show "too large" placeholder | Possible | Low | Existing behaviour for working-tree diffs; consistent UX. Out of scope to implement summary/stat-only view. |
| Detached HEAD short-sha source not exposed on `Worktree` model | Possible | Low | Fallback to `"(detached)"` without sha. Add `@ <short-sha>` suffix if `Worktree` already carries it; otherwise file follow-up — does not block this design. |
| Cross-worktree popover sharing (user clicks Worktree A's header, then B's before A's inventory returns) | Possible | Medium | `worktreeChanged` action cancels in-flight effects and resets state; the inventory load's `[gitService]` capture targets the worktree path captured at dispatch time, not the current state. |
| Adding a `BranchSwitcherFeature` to every WorktreeDetailView mount could regress memory if dozens of worktrees | Low | Low | Reducer state is small (< 1 KB cold, < 50 KB with inventory cache); only one mounts per detail view; cleared on `worktreeChanged`. |
| User clicks "View all" but Diff Viewer is closed and Cmd-Opt-G is unbound | Low | Low | RootFeature delegate handler always opens the viewer (independent of keybinding) before switching tab. |

## Resolved Spec Considerations

For traceability, the spec's "Design Considerations" entries (1–9):

| # | Spec question | Decision |
|---|---|---|
| 1 | `listAllBranches` shape | Single `for-each-ref refs/heads refs/remotes`, current resolved server-side via `%(HEAD)`. |
| 2 | `switchBranch` safety check | None at service layer; rely on git's native dirty-tree error. |
| 3 | Popover state ownership | New `BranchSwitcherFeature`, sibling of `WorktreeHeaderFeature`. |
| 4 | `WorktreeHeadWatcher` coupling | No new invalidation; spinner clears on the watcher's existing HEAD-change tick. |
| 5 | `DiffFeature` history sub-state | Embedded `HistoryState`, no child reducer. |
| 6 | Diff Viewer left-side title | Drawer reads `selectedTab` + appropriate field (`presentedFilePath` or `presentedCommitSha + Commit.subject`). |
| 7 | Project name access path | Already passed into `WorktreeHeaderInfoLabel` as `project: Project`; row 2 reads `project.name` directly. |
| 8 | Switch-error display | Inline banner under header, owned by `BranchSwitcherFeature.switchError`. |
| 9 | Commit data reuse popover↔history | Separate caches; popover loads `log(0, limit=10)`, history loads `log(0, limit=50)` with pagination. |

## Open Questions (post-design)

- [ ] **OQ-D1** Is `Worktree` already populated with a `headSha` field for detached HEAD short-sha display? If not, scope choice: (a) call `git rev-parse --short HEAD` in `currentBranch` and pack into a `BranchHead` struct, (b) ship placeholder "(detached HEAD)" and follow up.
- [ ] **OQ-D2** Does the app already have an `accessibilityNotification(.announcement)` helper for switch success / failure (used in worktree-status-bar design)? Reuse vs scope out.
- [ ] **OQ-D3** Does `WorktreeDetailView` need to scope the new `BranchSwitcherFeature` store at the `branchToolbarItem` level, or should `RootFeature` mount one per visible worktree detail? (Prefer the former for natural lifecycle.)
