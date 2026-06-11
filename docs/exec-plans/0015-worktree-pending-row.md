# ExecPlan: Worktree pending row — segment data model + lifecycle (task03)

**Status:** Draft
**Author:** Gump (sub-agent: feat/worktree-pending-row)
**Date:** 2026-04-26

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

> **沿用主 doc，不另写 design.** 本任务的高层设计（四段语义、`PendingWorktree` 形状、cancel/finished guard、不持久化、双重上限拦截、`SidebarRow` 异构渲染）已在 `docs/design-docs/worktree-sidebar-ordering.md`（commit `1f714b3`）中定稿。本 ExecPlan 只承担执行编排：把母 doc §"Pending 段成立所需的实现影响" 的 6 项工程改动按最小可验证切片拆分成 milestones，并补上每一步的具体文件路径、接口签名、acceptance 命令。任何架构性歧义都回查母 doc，**不**在此 doc 内重新决定。

## Purpose

After this change, a user can submit any number of Create Worktree forms without being modally blocked by `wt sw`'s 30-second copy-ignored / fetch-origin pipeline. The Create sheet closes the moment they click Create; a row representing the in-flight creation appears under the Project section in the sidebar with a spinner and the latest progress line. The user can switch projects, switch worktrees, open other tabs, and submit further Create forms (up to 8 per project). When `wt sw` finishes, the pending row dissolves and the real worktree row takes its place; the new tab is automatically opened. If creation fails, the pending row turns red, surfaces a one-line error, and offers Retry / Discard from its right-click menu. If the user clicks Cancel, the row disappears and the underlying `wt` subprocess is terminated. Pending rows are session-only; an app crash leaves no pending rows behind, but any worktrees that did make it to disk before the crash are picked up by the existing reconcile path on next launch.

## Progress

- [x] M1 — Foundation: GitWorktreeErrorMessage.swift created; private humanReadable copies removed from CreateWorktreeFeature + ArchivedWorktreesFeature; PendingWorktree.swift created (no task02 stub to replace) (2026-04-26 file edits in; build verification pending).
- [x] M2 — Reducer extension: pendingWorktrees state added; 7 pending* actions wired with full lifecycle including cancel/finished guard + cosmetic-failure tolerance per D4; CancelID enum + runPendingStream helper in place; parent .beginCreate delegate forwarding wired; .lifecycleScriptResult forward arm at lines 319-324 deleted (D6 scope strict) (2026-04-26 file edits in; build verification pending).
- [x] M3 — Sheet narrowing: CreateWorktreeFeature reduced to form-only; progressLines/isSubmitting state removed; .progressLine/.createFailed/.createSucceeded actions removed; submitted/lifecycleScriptResult delegate cases removed; .beginCreate delegate added with full PendingWorktree payload; currentPendingCountForProject threaded through state + injected from parent's projectAddWorktreeTapped; HierarchyClient dependency dropped (not needed) (2026-04-26 file edits in; build verification pending).
- [x] M4 — Sheet view + row view: CreateWorktreeSheet trimmed (no progress log, no isSubmitting disabled modifiers, cap banner above form, Create button label stays "Create" per D4 / REVISE-3); PendingWorktreeRow.swift created with running spinner / failed red dot + truncated error caption + context menu (2026-04-26 file edits in; build verification pending).
- [ ] M5 — DEFERRED to follow-up PR (Path B chosen): task02's SidebarRow + orderedSidebarRows not yet on origin/main as of 2026-04-26 fetch. View integration lands as a separate one-commit PR after task02 merges.
- [x] M6 — Tests: PendingWorktreeLifecycleTests.swift with 7 tests covering full lifecycle, failure, retry, cancel, cancel/finished race, 8-cap, catalog write failure (keeps row), post-catalog cosmetic failure (still removes row + setup runs); CreateWorktreeFeatureTests updated for new initialState signature, two new tests for .beginCreate delegate emission and cap rejection (2026-04-26 file edits in; build verification pending).
- [ ] M7 — Ship: lint, build, commits, push, PR.

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** — Per master directive 2026-04-26 (Plan phase entry), the high-level design lives entirely in `docs/design-docs/worktree-sidebar-ordering.md`. No task03-specific design doc is created. All architectural decisions referenced below cite the master doc by section.
- **D2** — `lifecycleScriptResult` delegate case on `CreateWorktreeFeature` is **deleted**, not retained as dead code. The setup-script effect now fires from `HierarchySidebarFeature.pendingWorktreeFinished`'s sidecar `.run`, which sends the equivalent `.delegate(.lifecycleScriptResult(...))` directly from the parent reducer. Forward block at `HierarchySidebarFeature.swift:319-324` is updated accordingly.
- **D3** — Pending creation cap (8 per project, master doc Risks table) is enforced in **two places**: the sheet (banner + Create button disable) and the parent reducer's `beginPendingWorktreeCreation` arm (silent reject). Sheet enforcement gives UX feedback; reducer enforcement guards future non-sheet entry points (IPC, command palette).
- **D4** — `pendingWorktreeFinished` treats catalog write as the critical boundary; everything after is cosmetic.
  - `createWorktreeWithGit` is the only call inside a `do/catch`. If it throws, the pending row stays in the list with status flipped to `.failed(.commandFailed(...))`, so Retry / Discard remain available. Retry against the same disk state will fail with `branchExists`, but Discard always works; the master doc Open Items follow-up (hover tooltip with full stderr) will surface this clearly.
  - The moment `createWorktreeWithGit` returns a `WorktreeID`, the pending row is removed from `state.pendingWorktrees`. The real worktree row is now in catalog and rendered by the existing path.
  - `selectWorktree` / `createTab` / `openPane` are then called with `try?` and a log on failure — they are convenience side-effects, not catalog writes. Their failure must NOT roll back the pending removal; otherwise the sidebar would briefly display both the real worktree row (from catalog) and a `.failed` pending row for the same logical creation, double-rendering it.
  - Setup-script effect fires regardless of `selectWorktree` / `createTab` / `openPane` outcome, since the worktree is real on disk + in catalog.

- **D5** — `CancelID` is a file-private enum inside `HierarchySidebarFeature` with one case (`.pending(PendingWorktreeID)`) for now. `cancelInFlight: true` is set so a Retry against a still-running effect (edge case) is overwritten safely.

- **D6** — The deletion of `lifecycleScriptResult` forwarding (per D2 + REVISE-2 from master 2026-04-26) is **scoped strictly** to the `case .createWorktreeSheet(.delegate(.lifecycleScriptResult(...)))` arm at `HierarchySidebarFeature.swift:319-324`. The sidebar's own `.delegate(.lifecycleScriptResult(...))` emissions used by Archive (`runArchiveWithLifecycle` at line 815) and Remove (`runRemoveWithDeleteScript` at line 837) MUST stay intact, as must the matching `RootFeature` forward path that surfaces those toasts. The new `pendingWorktreeFinished` sidecar effect emits a sibling `.delegate(.lifecycleScriptResult(phase: .setup, ...))` of its own — it is an additional emitter, not a replacement for the existing two.

## Outcomes & Retrospective

PR #48 shipped on 2026-04-26 with M1–M4 + M6. M5 view integration deferred to a follow-up PR pending task02's `SidebarRow` / `orderedSidebarRows` landing on `main`. Code-reviewer agent verdict: APPROVE; merge-blocking nits S1 (symmetric race guard on `pendingWorktreeFailed`) and N1 (shared `CreateWorktreeFeature.capMessage` constant) addressed in a follow-up commit before merge.

**Deferred (post-merge follow-ups):**

- N3 — `os.Logger` instrumentation on every pending* arm (`info` for begin/finished/discard/cancel; `error` for failed) per master design doc §可观测性. Not added in this PR to keep the scope to "data model + lifecycle"; the race guards now in place (progress / finished / failed all explicit) make logging additions trivially correct when they land.
- M5 — view integration into `HierarchySidebarView` (`ForEach` over `orderedSidebarRows`, dispatch by `SidebarRow` case). Single-commit PR after task02 merges.

## Context and Orientation

**Related documents (read before executing):**

- Master design doc: `docs/design-docs/worktree-sidebar-ordering.md` (commit `1f714b3`) — four-segment ordering, `PendingWorktree` shape, `SidebarRow` enum, cancel/finished guard, 8-cap rule, alternatives B1/B2/B3, Risks table.
- Task spec: `/tmp/codans-bootstrap-03.md` — file-by-file change list (this ExecPlan tracks the same surface area).
- Worktree-management context (M9 in particular): `docs/exec-plans/0010-worktree-management.md` — explains why `CreateWorktreeFeature` owns the stream today and how the setup-script delegate chain works.
- Architecture: `docs/architecture.md` — domain layering rules (HierarchySidebar feature lives in App layer; HierarchyManager in Runtime; GitWorktreeClient in Git/).

**Key source files (read or modify):**

- `apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeFeature.swift` — current sheet reducer with stream consumption (lines 192-220), success sidecar (lines 232-274), private `humanReadable` (lines 287-306). All three blocks move out of this file.
- `apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeSheet.swift` — current sheet view, progress log block at lines 81-94 (deleted in M4).
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — parent reducer; today's `.createWorktreeSheet` delegate handler at lines 314-328 is rewritten in M2 to also handle `.beginCreate`.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — `orderedVisibleWorktrees` at lines 50-56 (replaced via task02's `orderedSidebarRows` in M5); `ForEach` at line 417 switches to heterogeneous rows.
- `apps/mac/codans/App/Features/HierarchySidebar/ArchivedWorktreesFeature.swift` — second copy of `humanReadable` at lines 144-156 (deleted in M1, callers reroute to the shared function).
- `apps/mac/codans/Git/GitWorktreeClient.swift` — `createWorktreeStream` (lines 600-708) and `CreateWorktreeSpec` (lines 24-33). No edits, but the cancel-via-Process-terminate behavior at lines 696-706 is what makes pending Cancel actually kill the child `wt`. `GitWorktreeError` enum (lines 47-56) is the input type to the new `humanReadable` helper.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — `createWorktreeWithGit` (lines 217-221), `selectWorktree`, `createTab`, `openPane`, `runWorktreeLifecycleScript` are called from the new `pendingWorktreeFinished` arm in M2.
- `apps/mac/codans/Tests/CreateWorktreeFeatureTests.swift` — existing TestStore-based tests; assertions on `progressLines` / `isSubmitting` are removed, new `.beginCreate` delegate test is added.

**Term glossary:**

- **Pending row**: a sidebar list row backed by a `PendingWorktree` value (not a real `Worktree`). Renders inside the per-Project section between pinned and unpinned segments.
- **`CancelID.pending(id)`**: the TCA effect cancellation token used to terminate an in-flight `createWorktreeStream` Task when the user clicks Cancel or when Retry overlays a stale effect.
- **Cancel/finished race**: the situation where a user clicks Cancel exactly as `wt sw` reports completion. Resolved by an entry guard on the `pendingWorktreeFinished` arm — see master doc Risks table row 5.
- **8-cap**: per-project soft limit on simultaneously-pending creations (master doc Risks table last row).
- **task01**: `feat/worktree-reorder-catalog` branch — adds `HierarchyClient.reorderWorktrees` + pin/unpin position semantics. Not consumed directly here, but its absence does not block this plan.
- **task02**: `feat/worktree-sidebar-segments` branch — provides `SidebarRow` enum + `orderedSidebarRows(project:pendings:)` + `PendingWorktree` stub fields. M5 depends on it; M1-M4, M6 do not.

**How the parts fit together:** today the `CreateWorktreeSheet` is modal and self-contained — it owns the `wt sw` stream Task and only emits a `.delegate(.submitted)` after catalog write + tab open completes. After this ExecPlan, the sheet emits `.delegate(.beginCreate(PendingWorktree))` immediately on form submission; `HierarchySidebarFeature` accepts that, dismisses the sheet, appends the pending value to `state.pendingWorktrees`, and starts a `.cancellable(id: CancelID.pending(id))` effect that consumes `createWorktreeStream`. The pending row renders from the same `IdentifiedArrayOf<PendingWorktree>` until the effect either yields `.finished` (catalog write inline → row replaced by real worktree) or throws (status flips to `.failed`, row stays).

## Plan of Work

Six narrative milestones. M1 lays foundations; M2-M4 implement the reducer + sheet contract change; M5 wires the view (gated on task02); M6 ships tests; M7 builds, lints, opens PR. Each milestone produces a /commit-able state, even if downstream consumers are not yet wired (M2's reducer changes compile and pass existing tests before the view consumes them in M5).

### Milestone 1: Foundations — shared error message + complete `PendingWorktree`

**Goal:** A single `humanReadable(GitWorktreeError) -> String` exists project-wide, and `PendingWorktree.swift` carries the full struct shape. Both are pure, no behavior change to existing flows.

Create `apps/mac/codans/Git/GitWorktreeErrorMessage.swift` with one top-level `internal func humanReadable(_ error: GitWorktreeError) -> String` covering all 8 `GitWorktreeError` cases. The exhaustive switch matches the version currently in `CreateWorktreeFeature.swift:287-306` (master doc §Cross-Cutting Concerns describes the merge — pick the more operational text per case, e.g. `executableMissing → "The bundled wt helper is missing. Reinstall codans."`). The function is `nonisolated` and pure.

Delete the private `humanReadable` from `CreateWorktreeFeature.swift` (lines 287-306) and from `ArchivedWorktreesFeature.swift` (lines 144-156). Both files now reference the new top-level function unqualified (Swift module-internal lookup).

Replace `apps/mac/codans/App/Features/HierarchySidebar/PendingWorktree.swift`. If task02 has merged its stub by the time this milestone runs, replace the file's contents in place. If task02 has not merged, create the file fresh. Either way the final shape is:

```swift
import Foundation
import CodansCore

nonisolated struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init() { raw = UUID() }
  init(_ raw: UUID) { self.raw = raw }
}

struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let spaceID: SpaceID
  let spec: CreateWorktreeSpec
  let displayName: String
  var status: Status
  var lastProgressLine: String?
  let startedAt: Date

  enum Status: Equatable {
    case running
    case failed(GitWorktreeError)
  }
}
```

Verify build green and the existing 855-test suite still passes before moving on. M1 changes are purely refactor + new value type; no logic drift.

### Milestone 2: Reducer extension — pending state + actions + cancellable effect

**Goal:** `HierarchySidebarFeature` owns `pendingWorktrees: IdentifiedArrayOf<PendingWorktree>`, the 7 pending* actions, and the cancellable streaming effect. Parent forwarding for `CreateWorktreeFeature.delegate.beginCreate` is in place. View layer is not yet consuming any of this.

Add to `State`:

```swift
var pendingWorktrees: IdentifiedArrayOf<PendingWorktree> = []
```

Add the action cases (action set verbatim from the bootstrap spec):

```swift
case beginPendingWorktreeCreation(PendingWorktree)
case pendingWorktreeProgress(PendingWorktreeID, String)
case pendingWorktreeFinished(PendingWorktreeID, URL)
case pendingWorktreeFailed(PendingWorktreeID, GitWorktreeError)
case pendingWorktreeRetryTapped(PendingWorktreeID)
case pendingWorktreeDiscardTapped(PendingWorktreeID)
case pendingWorktreeCancelTapped(PendingWorktreeID)
```

Add `@Dependency(GitWorktreeClient.self) private var gitWorktreeClient` to the reducer.

Define inside the reducer struct:

```swift
private enum CancelID: Hashable {
  case pending(PendingWorktreeID)
}

private func runPendingStream(_ pending: PendingWorktree) -> Effect<Action> {
  let client = gitWorktreeClient
  let id = pending.id
  return .run { send in
    do {
      for try await event in client.createWorktreeStream(pending.spec) {
        switch event {
        case .progressLine(let line):
          await send(.pendingWorktreeProgress(id, line))
        case .finished(let url):
          await send(.pendingWorktreeFinished(id, url))
          return
        }
      }
      await send(.pendingWorktreeFailed(
        id, .commandFailed(command: "wt sw", stderr: "stream ended without finishing")))
    } catch let err as GitWorktreeError {
      await send(.pendingWorktreeFailed(id, err))
    } catch is CancellationError {
      return
    } catch {
      await send(.pendingWorktreeFailed(
        id, .commandFailed(command: "wt sw", stderr: error.localizedDescription)))
    }
  }
  .cancellable(id: CancelID.pending(id), cancelInFlight: true)
}
```

Implement the 7 action arms in `coreReduce`:

- `beginPendingWorktreeCreation(let pending)`:
  - Hard cap guard: `let count = state.pendingWorktrees.filter { $0.projectID == pending.projectID }.count; guard count < 8 else { return .none }`
  - `state.pendingWorktrees.append(pending)`; return `runPendingStream(pending)`.
- `pendingWorktreeProgress(let id, let line)`:
  - Race guard (same shape as the finished arm): `guard state.pendingWorktrees[id: id] != nil else { return .none }`. Update `state.pendingWorktrees[id: id]?.lastProgressLine = line`. Return `.none`.
- `pendingWorktreeFinished(let id, let path)`: implements the master doc §pending 段 success path with **catalog write as the critical boundary** (D4 + REVISE-1 from master 2026-04-26). The structure is:
  ```swift
  case .pendingWorktreeFinished(let id, let path):
    guard let pending = state.pendingWorktrees[id: id] else { return .none }   // race guard
    let pid = pending.projectID
    let sid = pending.spaceID
    let branch = pending.spec.branch
    let directoryName = pending.spec.name
    let pathString = path.standardizedFileURL.path(percentEncoded: false)

    // Critical: catalog write. Failure → keep pending row as .failed for Retry/Discard.
    let worktreeID: WorktreeID
    do {
      worktreeID = try hierarchyClient.createWorktreeWithGit(pid, sid, branch, directoryName, pathString)
    } catch {
      state.pendingWorktrees[id: id]?.status = .failed(
        .commandFailed(command: "catalog", stderr: error.localizedDescription))
      return .none
    }

    // Catalog now has the real worktree row. Remove pending IMMEDIATELY so the
    // sidebar doesn't double-render (real worktree row + .failed pending row for
    // the same logical creation). Anything below this line is cosmetic.
    state.pendingWorktrees.remove(id: id)

    // Convenience side-effects: try? + log, never roll back the pending removal.
    try? hierarchyClient.selectWorktree(worktreeID, pid, sid)
    if let tabID = try? hierarchyClient.createTab(worktreeID, pid, sid, nil) {
      _ = try? hierarchyClient.openPane(tabID, worktreeID, pid, sid, pathString, nil)
    }

    let client = hierarchyClient
    return .run { send in
      let result = await client.runWorktreeLifecycleScript(.setup, worktreeID, pid)
      await send(.delegate(.lifecycleScriptResult(phase: .setup, worktreeName: branch, result: result)))
    }
  ```
  Note: setup-script effect always fires after a successful catalog write — the worktree exists on disk + in catalog regardless of the cosmetic step outcomes, so its setup script should run. Logging on the `try?`-swallowed failures is fine but optional; existing reducer arms in this file rely on this pattern (e.g. `try? hierarchyClient.selectProject` at line 361).
- `pendingWorktreeFailed(let id, let err)`:
  - `state.pendingWorktrees[id: id]?.status = .failed(err)`. Return `.none`.
- `pendingWorktreeRetryTapped(let id)`:
  - Guard the row exists and is `.failed`. Mutate status to `.running`. Read the row, call `runPendingStream(row)` to start a fresh effect (cancelInFlight covers any zombie).
- `pendingWorktreeDiscardTapped(let id)`:
  - `state.pendingWorktrees.remove(id: id)`. Return `.none`.
- `pendingWorktreeCancelTapped(let id)`:
  - `state.pendingWorktrees.remove(id: id)`. Return `.cancel(id: CancelID.pending(id))`.

Update the parent-side `createWorktreeSheet` delegate handler block (lines 314-328 today):

- Add a new arm: `case .createWorktreeSheet(.delegate(.beginCreate(let pending)))`. Set `state.createWorktreeSheet = nil`, return `.send(.beginPendingWorktreeCreation(pending))`.
- **Delete** the `case .createWorktreeSheet(.delegate(.lifecycleScriptResult(...)))` forward at lines 319-324 — and ONLY that one arm. Per D6, the sidebar's own `.delegate(.lifecycleScriptResult(...))` emissions from `runArchiveWithLifecycle` (line 815) and `runRemoveWithDeleteScript` (line 837) MUST stay, as must the `RootFeature` forwarder that surfaces those toasts. After this milestone the only emitters of `.delegate(.lifecycleScriptResult(...))` from `HierarchySidebarFeature` are: archive (unchanged), remove (unchanged), and the new `pendingWorktreeFinished` setup-script sidecar.
- Keep the existing `.dismissed` / `.submitted` arm wiring; `.submitted` is no longer emitted by the child after M3, but leaving the no-op match harmless against re-introduction.

Build, run existing tests. Reducer compiles, no view consumes the new state yet — should be a green diff.

### Milestone 3: Sheet narrowing — `CreateWorktreeFeature` becomes form-only

**Goal:** `CreateWorktreeFeature` no longer holds stream state, no longer runs setup scripts, and emits `.delegate(.beginCreate(PendingWorktree))` on submit.

Remove from `State`: `var progressLines: [String] = []`, `var isSubmitting: Bool = false`. Add:

```swift
let currentPendingCountForProject: Int
```

This field is read-only in the sheet; the parent injects it at sheet construction. Update `HierarchySidebarFeature.projectAddWorktreeTapped` (lines 430-450) to compute the count from `state.pendingWorktrees.filter { $0.projectID == projectID }.count` and pass it into the new `CreateWorktreeFeature.State` initializer parameter.

Remove from `Action`: `.progressLine`, `.createFailed`, `.createSucceeded`. Remove the corresponding arms.

Remove the `Delegate.lifecycleScriptResult` case entirely (D2).

Add to `Delegate`:

```swift
case beginCreate(PendingWorktree)
```

Rewrite the `.createButtonTapped` arm: keep all existing validation and predetection (trimmed branch name, validation error, base ref check, sanitized directory name, file existence check). After predetection passes:

```swift
guard state.currentPendingCountForProject < 8 else {
  state.submitError = "Up to 8 worktree creations can be queued. Wait for one to finish."
  return .none
}

let spec = CreateWorktreeSpec(...)  // unchanged
let pending = PendingWorktree(
  id: PendingWorktreeID(),
  projectID: state.projectID,
  spaceID: state.spaceID,
  spec: spec,
  displayName: trimmed,
  status: .running,
  lastProgressLine: nil,
  startedAt: Date()
)
return .send(.delegate(.beginCreate(pending)))
```

Drop the `state.isSubmitting = true` and `state.progressLines = []` lines (state fields no longer exist).

Remove the `@Dependency(GitWorktreeClient.self)` and `@Dependency(HierarchyClient.self)` on `CreateWorktreeFeature` if no longer used after the deletion (`branchRefs` etc. still need `GitWorktreeClient`; verify with `grep` after edits).

Verify build. `CreateWorktreeFeatureTests` will fail loudly on the deleted state fields and actions — that's expected; M6 rewrites them.

### Milestone 4: Views — sheet trim + new `PendingWorktreeRow`

**Goal:** `CreateWorktreeSheet` no longer shows the progress log; cap banner appears when full. `PendingWorktreeRow` exists and renders both states.

In `apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeSheet.swift`:

- Delete the progress log block (lines 81-94).
- Above the form (or just below the title), add a banner shown only when `store.currentPendingCountForProject >= 8`:

  ```swift
  if store.currentPendingCountForProject >= 8 {
    Text("Up to 8 worktree creations are queued for this project. Wait for one to finish.")
      .font(.caption)
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  ```

- Remove `.disabled(store.isSubmitting)` modifiers (state field gone).
- Update Create button `.disabled(...)` predicate: drop `store.isSubmitting`, add `|| store.currentPendingCountForProject >= 8`.
- **Button label stays literal `"Create"`.** Do NOT introduce a `"Creating…"` swap or any animated busy-state — the sheet dismisses synchronously on submit (no in-sheet busy interval to communicate). The previous "Creating…" UX is replaced by the spinning pending row in the sidebar.

Create `apps/mac/codans/App/Features/HierarchySidebar/PendingWorktreeRow.swift`:

```swift
import SwiftUI
import CodansCore

struct PendingWorktreeRow: View {
  let pending: PendingWorktree
  let onCancel: () -> Void
  let onRetry: () -> Void
  let onDiscard: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      icon
      VStack(alignment: .leading, spacing: 0) {
        Text(pending.displayName).lineLimit(1)
        Text(secondaryLine)
          .font(.caption)
          .foregroundStyle(secondaryColor)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    .contextMenu {
      switch pending.status {
      case .running:
        Button("Cancel", action: onCancel)
      case .failed:
        Button("Retry", action: onRetry)
        Button("Discard", role: .destructive, action: onDiscard)
      }
    }
  }

  @ViewBuilder
  private var icon: some View {
    switch pending.status {
    case .running:
      ProgressView()
        .controlSize(.small)
        .frame(width: 14, height: 14)
    case .failed:
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)
        .frame(width: 14, height: 14)
    }
  }

  private var secondaryLine: String {
    switch pending.status {
    case .running:
      return pending.lastProgressLine ?? "Creating…"
    case .failed(let err):
      let raw = humanReadable(err)
      return raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
    }
  }

  private var secondaryColor: Color {
    switch pending.status {
    case .running: return .secondary
    case .failed:  return .red
    }
  }
}
```

Build green; the view is not yet inserted into the List (that's M5).

### Milestone 5: View integration — pending rows render in the sidebar

**Goal:** Pending rows appear in the correct sidebar segment, hot-key enumeration skips them, and `wt sw` runs in the background after sheet dismissal.

This milestone depends on task02 (`feat/worktree-sidebar-segments`) being merged into `main`. Two paths:

- **Path A — task02 already merged.** Rebase `feat/worktree-pending-row` onto current `main` (`git fetch origin && git rebase origin/main`), pick up `SidebarRow` + `orderedSidebarRows` + the `ForEach` reshape, and complete this milestone in the same PR.
- **Path B — task02 still in-flight.** Skip this milestone in the initial PR. The reducer changes from M2-M4 still ship usable behavior (sheet dismiss is now non-blocking; `wt sw` runs to completion in background; on success, real worktree row appears via `createWorktreeWithGit` writing to catalog + the existing `orderedVisibleWorktrees` consumer rendering it; on failure, the pending state is invisible — degraded but not broken). The view wiring lands as a one-commit follow-up PR after task02 merges. Note the deferral in the PR body and on master.

For Path A, edits in `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`:

- Replace the `ForEach(Self.orderedVisibleWorktrees(in: project))` at line 417 with `ForEach(Self.orderedSidebarRows(project: project, pendings: store.pendingWorktrees.elements))`. Inside the closure, switch on `SidebarRow`:

  ```swift
  switch row {
  case .worktree(let worktree):
    worktreeRow(worktree, in: project, space: space, paneIndex: paneIndex, inbox: inbox, hotkeySlot: hotkeyIndex[worktree.id])
  case .pending(let pending):
    PendingWorktreeRow(
      pending: pending,
      onCancel: { store.send(.pendingWorktreeCancelTapped(pending.id)) },
      onRetry: { store.send(.pendingWorktreeRetryTapped(pending.id)) },
      onDiscard: { store.send(.pendingWorktreeDiscardTapped(pending.id)) }
    )
    .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 0))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }
  ```

- Verify the `hotkeyIndex` builder at lines 278-289 — if task02 rewrote it to enumerate `SidebarRow` instead of `Worktree`, ensure the `.pending` case is skipped (continues without consuming a slot). If it still iterates `Project.worktrees` directly, no change needed (pending rows aren't in catalog).

Acceptance: launch the app, open Create Worktree on a real repo, click Create with `Copy ignored files` toggled on (slow path). Sheet dismisses immediately; pending row appears under the Project with a spinner; clicking other tabs / projects still works; when `wt sw` finishes the row dissolves into a real worktree row and a tab opens.

### Milestone 6: Tests

**Goal:** TestStore-driven coverage for the lifecycle, race, retry, cancel, cap. `CreateWorktreeFeatureTests` updated to current shape.

Create `apps/mac/codans/Tests/PendingWorktreeLifecycleTests.swift`. Use a controlled `gitWorktreeClient.createWorktreeStream` test value: an `AsyncThrowingStream` whose continuation is accessible to the test so events / errors / termination can be driven manually. Pattern follows existing `Tests/HierarchySidebarFeatureTests.swift` setup. Stub `hierarchyClient.createWorktreeWithGit` etc. with TestStore-friendly values (a synthesized `WorktreeID`, no-throw default).

Tests to add (one `@Test` each):

1. `pendingFullLifecycle` — `beginPendingWorktreeCreation(p)` → assert state has the row in `.running` → `pendingWorktreeProgress(id, "1/3 fetching")` → `pendingWorktreeFinished(id, url)` → assert pending removed, mock catalog client received `createWorktreeWithGit` with the expected branch, setup-script delegate fires.
2. `pendingFailureSurfacedAsFailedStatus` — drive stream throw of `.branchExists("foo")` → assert status flips to `.failed(.branchExists("foo"))`, row stays.
3. `pendingFailedRetryRestartsStream` — start from (2)'s end-state → `pendingWorktreeRetryTapped(id)` → assert status back to `.running` and a new effect runs → drive `.finished` → row removed.
4. `pendingCancelRemovesRowAndCancelsEffect` — begin → progress → `pendingWorktreeCancelTapped(id)` → assert row removed, then `await store.finish()` to assert no zombie effects.
5. `pendingCancelFinishedRaceFinishedIsNoop` — begin → cancelTapped → manually send `pendingWorktreeFinished(id, url)` (simulating the race) → assert no catalog write, no state mutation.
6. `pendingCapRejectsBeyondEight` — preload state with 8 same-project pending rows → `beginPendingWorktreeCreation(9th)` → assert row not appended, no effect.
7. `pendingCatalogWriteFailureKeepsRowAsFailed` — stub `createWorktreeWithGit` to throw → drive `pendingWorktreeFinished` → assert row remains with `.failed(.commandFailed(...))`. (Validates D4's catalog-write-as-critical-boundary: failure here keeps the pending row.)
8. `pendingOpenPaneFailureStillRemovesRow` — stub `createWorktreeWithGit` to succeed (returns a synthesized `WorktreeID`) but stub `openPane` (or `createTab`) to throw → drive `pendingWorktreeFinished` → assert pending row is removed AND no `.failed` pending lingers; setup-script effect still fires. (Validates D4's "post-catalog steps are cosmetic" rule: `try?` swallowing must not roll back the pending removal.)

Update `apps/mac/codans/Tests/CreateWorktreeFeatureTests.swift`:

- Drop assertions on `progressLines` and `isSubmitting` (state fields removed).
- Update `initialState()` factory to pass `currentPendingCountForProject: 0`.
- Add `createButtonTappedEmitsBeginCreateDelegate` — set valid form state, send `.createButtonTapped`, expect `.delegate(.beginCreate(let pending))` with `pending.spec.branch == "feature/new-idea"` etc. Use `store.exhaustivity = .off` + `await store.receive(\.delegate.beginCreate)` pattern.
- Add `createButtonTappedRejectedAtCap` — initial state with `currentPendingCountForProject: 8` → send `.createButtonTapped` → assert `submitError` set, no delegate emitted.

Run `xcodebuild test` (via `make mac-build` + manual test invocation, or `xcrun xcodebuild -scheme codans -destination 'platform=macOS' test` if test target is configured).

### Milestone 7: Ship

Run `make mac-lint` (swiftlint clean), `make mac-build` (debug build green). For each milestone-equivalent slice already committed, the working tree is clean. Push to `feat/worktree-pending-row`, open PR via `gh pr create --base main` with body referencing master design doc + this ExecPlan + bootstrap task and (if Path B) noting the M5 deferral. Post `PR_READY: <url>` to master.

## Concrete Steps

Run all commands from the worktree root `/Users/wanggang/.worktree/repos/codans/feat/worktree-pending-row`.

**Setup (once, before M1):**

```bash
git fetch origin
git status   # expect clean, on feat/worktree-pending-row
git log --oneline -3
# expect 1f714b3 docs: worktree sidebar ordering...
```

**After each milestone — small commit:**

```bash
make mac-lint            # expect: no output (success), exit 0
make mac-build           # expect: ** BUILD SUCCEEDED **
# stage only the touched files (no git add -A):
git add apps/mac/codans/App/Features/HierarchySidebar/<files...>
/commit                  # use the slash command per project memory
```

(Project memory feedback: "invoke `/commit` after each small feature change in codans". Do not run raw `git commit`.)

**M1-specific verification:**

```bash
grep -n "humanReadable" apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeFeature.swift
# expect: no private func humanReadable, but multiple call sites referencing the global function
grep -rn "private func humanReadable" apps/mac/codans
# expect: no matches (both private copies deleted)
```

**M5 view-integration check (Path A only):**

```bash
git fetch origin
git log --oneline origin/main -10 | head -3
# expect a commit referencing SidebarRow / orderedSidebarRows
git rebase origin/main
```

**Final pre-PR checks:**

```bash
make mac-lint
make mac-build
# Manual smoke test (Path A only):
# 1. open the app
# 2. open a real repo project, click '+' on its row
# 3. enable "Copy ignored files", type "test/pending", click Create
# 4. verify sheet dismisses immediately and a spinner row appears
# 5. switch to another worktree while spinner runs
# 6. verify pending row dissolves into real row when wt sw finishes
git push -u origin feat/worktree-pending-row
gh pr create --base main --title "feat(worktree): pending segment data model + lifecycle (task03)" \
  --body-file - <<'EOF'
... (PR body — see Validation and Acceptance below for the contract)
EOF
```

## Validation and Acceptance

A reviewer should be able to verify this PR with the following observations:

1. **Build + lint:** `make mac-lint && make mac-build` green.
2. **Test suite:** the existing 855+-test suite still green; the 7 new pending-lifecycle tests pass; the updated `CreateWorktreeFeatureTests` pass. Run via the project's standard test invocation (Xcode scheme `codans` test action, or equivalent xcodebuild command).
3. **Behavioral demo (only fully verifiable on Path A):**
   - Open a real git repo Project. Click `+` to open Create Worktree. Toggle "Copy ignored files" on. Type a fresh branch name. Click Create.
   - **Expected:** sheet dismisses immediately. A spinner row appears under the Project with text `Creating…` then progress lines from `wt sw`.
   - Switch to another worktree, then switch back. Pending row still there, still spinning.
   - When `wt sw` completes, the pending row is gone and a real worktree row with the new branch appears, selected, with one tab + pane opened in the new directory.
4. **Failure path:** open Create with the same branch name as an existing one but bypass the sheet's local validation by editing the spec (or simply target a name that the sanity check passes but `wt sw` rejects — e.g. simulate by pre-creating the directory). Pending row turns red with a one-line error; right-click offers Retry / Discard.
5. **Cancel path:** start a slow create; right-click the pending row → Cancel. Row disappears within a frame. `pgrep -f 'wt sw'` shows no zombie subprocess (the `continuation.onTermination` path in `GitWorktreeClient.swift:696-706` already terminates the child).
6. **Cap path:** queue 8 creates on the same project (use a small repo so they're fast but not instant). Open Create again → banner reads "Up to 8 worktree creations are queued…" and Create button is disabled.

Path B PRs note that 3-6 are not visually verifiable (view layer not connected) and reference the follow-up PR for visual acceptance.

## Idempotence and Recovery

All edits are file-level; re-running an interrupted milestone's edits is safe (Edit tool fails fast on stale `old_string`). `/commit` only commits staged files, so a partial milestone cleanly stops mid-way.

For M1's PendingWorktree.swift: the file may be a stub (task02 merged) or absent. The `Write` tool overwrites; the resulting struct shape is unconditional, so running M1 against either starting state yields the same end state.

For M5 Path A: if `git rebase origin/main` produces a conflict in `HierarchySidebarView.swift`, prefer the incoming (task02) version of `orderedSidebarRows` and re-apply the M5 ForEach edit on top. Do not blindly take theirs for the whole file — the task02 changes should be confined to the orderedSidebarRows function and the ForEach call site.

For M5 Path B: skipping is reversible — the reducer state field stays unused but harmless until a follow-up PR connects the view.

If `make mac-build` fails after an Edit, do not try to "patch around" the build error — re-read the file, identify the broken reference, and either revert the edit or extend it. Do not add `// TODO` or commented-out code as a placeholder.

## Artifacts and Notes

Examples of expected `humanReadable` callsites after M1 (rough — not literal, just shape):

```swift
// in PendingWorktreeRow
let raw = humanReadable(err)

// in ArchivedWorktreesFeature reducer
state.banner = humanReadable(gitError)
```

Example of the new sheet construction call site after M3 (in `HierarchySidebarFeature.projectAddWorktreeTapped`):

```swift
let pendingCount = state.pendingWorktrees.filter { $0.projectID == projectID }.count
state.createWorktreeSheet = CreateWorktreeFeature.State(
  projectID: projectID,
  spaceID: spaceID,
  repoRoot: URL(fileURLWithPath: gitRoot),
  worktreesDirectory: defaultWtDir,
  currentPendingCountForProject: pendingCount
)
```

## Interfaces and Dependencies

The following symbols must exist and have the listed shapes at end of this work:

In `apps/mac/codans/Git/GitWorktreeErrorMessage.swift`:

```swift
internal func humanReadable(_ error: GitWorktreeError) -> String
```

In `apps/mac/codans/App/Features/HierarchySidebar/PendingWorktree.swift`:

```swift
nonisolated struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init()
  init(_ raw: UUID)
}

struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let spaceID: SpaceID
  let spec: CreateWorktreeSpec
  let displayName: String
  var status: Status
  var lastProgressLine: String?
  let startedAt: Date

  enum Status: Equatable {
    case running
    case failed(GitWorktreeError)
  }
}
```

In `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`:

```swift
extension HierarchySidebarFeature.State {
  var pendingWorktrees: IdentifiedArrayOf<PendingWorktree> { get set }
}

extension HierarchySidebarFeature.Action {
  case beginPendingWorktreeCreation(PendingWorktree)
  case pendingWorktreeProgress(PendingWorktreeID, String)
  case pendingWorktreeFinished(PendingWorktreeID, URL)
  case pendingWorktreeFailed(PendingWorktreeID, GitWorktreeError)
  case pendingWorktreeRetryTapped(PendingWorktreeID)
  case pendingWorktreeDiscardTapped(PendingWorktreeID)
  case pendingWorktreeCancelTapped(PendingWorktreeID)
}
```

In `apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeFeature.swift`:

```swift
extension CreateWorktreeFeature.State {
  let currentPendingCountForProject: Int
  // removed: var progressLines: [String]
  // removed: var isSubmitting: Bool
}

extension CreateWorktreeFeature.Action.Delegate {
  case beginCreate(PendingWorktree)
  // removed: case lifecycleScriptResult(...)
  // unchanged: case dismissed, case submitted (submitted may go unused; keep for safety)
}
```

In `apps/mac/codans/App/Features/HierarchySidebar/PendingWorktreeRow.swift`:

```swift
struct PendingWorktreeRow: View {
  let pending: PendingWorktree
  let onCancel: () -> Void
  let onRetry: () -> Void
  let onDiscard: () -> Void

  var body: some View
}
```

No new external dependencies (no Swift Package additions, no Tuist target changes). The work is contained to existing modules: `codans` (App + Git layers) and the existing `CodansCore` types are referenced but not modified.

`HierarchyClient`'s public surface is unchanged — `createWorktreeWithGit`, `selectWorktree`, `createTab`, `openPane`, `runWorktreeLifecycleScript` are called as today, just from the parent reducer instead of from the sheet child. `GitWorktreeClient.createWorktreeStream` is consumed identically; the `continuation.onTermination`-driven cancellation already in place is what makes Cancel actually kill the `wt` subprocess.

Strict no-go list (per bootstrap spec):

- `apps/mac/codans/Runtime/HierarchyManager.swift` (task01).
- `apps/mac/codans/App/Clients/HierarchyClient.swift` (task01).
- `SidebarRow.swift` shape (task02). If a need to extend appears, escalate to master with a `QUESTION:` message before touching it.
