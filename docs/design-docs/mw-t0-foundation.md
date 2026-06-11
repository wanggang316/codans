# Design Doc: Main-Window Redesign — T0 Foundation & Contracts

**Status:** Draft
**Author:** Gump (T0 sub-agent, via Claude)
**Date:** 2026-04-21

## Context and Scope

The main-window UI redesign (see `docs/product-specs/ui-main-window-redesign.md`) is split into four sub-tasks (T0/T1/T2/T3) that land on `feature/main-window`. T0 ("Foundation & Contracts") ships the data-model and API surface the other three tasks depend on; it intentionally does **no** UI redesign itself.

Concretely T0 must:

1. Extend `CodansCore` models so per-Space last-active-Worktree restoration and per-Worktree Git-Viewer visibility can be persisted and mutated through the normal Catalog path.
2. Expose an aggregation API over the existing agent-notification inbox so the Header bell (T2) and Sidebar unread dots (T1) can render unread state at Worktree / Project / Space granularity without either feature duplicating the `PaneID → WorktreeID` join.
3. Remove the current Hierarchy ↔ Inbox Picker from `ContentView` so the sidebar column is unambiguously the hierarchy tree. The C6 InboxSidebar feature is kept as a component (T2 will likely reuse its row-rendering inside the bell popover).

Existing state we build on:

- `Catalog` / `Space` / `Project` / `Worktree` / `Tab` / `Pane` value types in `apps/mac/CodansCore/`. `Catalog` already uses a versioned Codable shape; `Space` and `Worktree` do not yet have custom `init(from:)` / `encode(to:)`, so forward-compatibility is currently "whatever the synthesized Codable does with missing keys" — for optionals that is `nil`, which is lossy if a new required field is added.
- `NotificationInbox` (CodansCore, pure value type) and `InboxStore` (app-side, `@MainActor`, owns debounced persistence + unread signal). `AgentNotification.paneID` is the only hierarchy pointer; the inbox is *not* pre-joined with the Catalog.
- `ContentView.sidebarColumn` switches on `RootFeature.State.sidebarMode` to render either `HierarchySidebarView` or `InboxSidebarView`; the toolbar exposes a `modeTogglePicker` for the user.
- `HierarchyManager` already owns catalog mutations and persistence; new model fields plug into that existing pipeline.

## Goals and Non-Goals

### Goals

- Persist `Space.lastActiveWorktreeID: WorktreeID?` in the Catalog; mutate through a focused API; survive round-trip.
- Persist `Worktree.gitViewerVisible: Bool` in the Catalog; mutate through a focused API; survive round-trip.
- Old catalog JSON without the two new fields must decode cleanly with defaults (`nil` / `false`).
- Provide pure, unit-testable notification aggregation helpers keyed by `WorktreeID` / `ProjectID` / `SpaceID`, plus `markRead(forWorktree:)` and `dismissAll()` mutations on `InboxStore`.
- Delete the Hierarchy ↔ Inbox Picker UI from `ContentView`; the sidebar always renders hierarchy. C6 notification writes and unread counts continue to work.
- New model fields and aggregation helpers have unit tests (CatalogCodableTests / NotificationInboxTests).

### Non-Goals

- No Sidebar / Header / GitViewer UI redesign (T1 / T2 / T3).
- No read-mark propagation policy beyond what the exposed APIs allow (debouncing, etc. remain T2's call).
- No new data migrations for existing on-disk catalogs beyond "defaults apply for missing keys".
- No changes to how `AgentNotification` is keyed (still `PaneID`).
- No deletion of `InboxSidebarFeature` or its view/reducer — kept for T2 reuse.

## Design

### Overview

The Catalog extensions are small Codable-shape evolutions on `Space` and `Worktree`. Both structs switch from synthesized Codable to explicit `init(from:)` / `encode(to:)` so the new optional fields decode with documented defaults when absent and are written out when set. Mutation goes through `HierarchyManager`, matching the existing path for `Space.selectedProjectID` etc.

Aggregation of notifications by Worktree / Project / Space is implemented as **pure helpers on `NotificationInbox`** that take the `Catalog` as an explicit argument. This keeps CodansCore stateless and unit-testable without MainActor. Mutation helpers (`markRead(forWorktree:in:)`, `dismissAll()`) live on `InboxStore` because they must schedule saves and publish the unread signal. The "signatures listed in the task brief" are honored *semantically*; the concrete signatures take the catalog explicitly because the `PaneID → WorktreeID` join requires it and we prefer an explicit dependency over a hidden one.

The `ContentView` Picker removal is purely a SwiftUI deletion. `RootFeature.State.sidebarMode` is kept as an internal-only property (so existing reducer tests and the hierarchy/inbox scope wiring keep compiling), but its public action `sidebarModeChanged` becomes unused for now — we leave the plumbing rather than remove it, since T2 may choose to repurpose `inbox` state for the bell popover.

### System Context Diagram

```
┌────────────────────┐     ┌──────────────────────┐     ┌──────────────────┐
│ HierarchySidebar   │     │ WorktreeHeader (T2)  │     │ GitViewer (T3)   │
│ (T1, unread dots)  │     │ bell + open-in picker│     │ overlay visible  │
└─────────┬──────────┘     └──────────┬───────────┘     └────────┬─────────┘
          │ reads                     │ reads                     │ reads/writes
          ▼                           ▼                            ▼
┌────────────────────────────────────────────────────────────────────────┐
│ CodansCore (pure)                                                    │
│   Space.lastActiveWorktreeID       NotificationInbox                    │
│   Worktree.gitViewerVisible          .unreadCount(forWorktree:in:)      │
│   Catalog (Codable, versioned)       .hasUnread(forProject:in:)         │
│                                      .hasUnread(forSpace:in:)           │
│                                      .notifications(forWorktree:in:)    │
└──────────────┬───────────────────────────────────────┬──────────────────┘
               │                                       │
               ▼                                       ▼
        ┌─────────────────┐                    ┌─────────────────┐
        │ HierarchyManager│                    │ InboxStore       │
        │ (mutations)     │                    │ (markRead/dismiss│
        │ setSpaceLast…   │                    │  forWorktree:in:)│
        │ setWorktreeGit… │                    └─────────────────┘
        └─────────────────┘
```

### API Design

#### 1. Catalog model extensions

`Space` (CodansCore):

```swift
public struct Space {
  public var id: SpaceID
  public var name: String
  public var projects: [Project]
  public var selectedProjectID: ProjectID?
  public var lastActiveWorktreeID: WorktreeID?   // NEW (default nil)
}
```

Semantics: when the window re-activates this Space, the shell restores this Worktree as selected. `nil` → fall back to `selectedProjectID`'s selected worktree (existing logic). Cleared (set back to `nil`) if the referenced Worktree no longer exists at save time — left as a follow-up for T1; T0 does not prune.

`Worktree` (CodansCore):

```swift
public struct Worktree {
  public var id: WorktreeID
  public var name: String
  public var path: String
  public var branch: String?
  public var tabs: [Tab]
  public var selectedTabID: TabID?
  public var gitViewerVisible: Bool = false     // NEW
}
```

Semantics: whether the right-side Git Viewer overlay is visible for this Worktree. T3 renders the overlay conditionally on this; T0 does not change `ContentView`'s existing `inspectorVisible` toggle (that's a separate state, kept for now).

Both structs switch to explicit `Codable` with `decodeIfPresent` so old JSON → new code decodes with the defaults above and does not throw.

#### 2. Mutation API on `HierarchyManager`

```swift
@MainActor
extension HierarchyManager {
  func setSpaceLastActiveWorktree(spaceID: SpaceID, worktreeID: WorktreeID?)
  func setWorktreeGitViewerVisible(worktreeID: WorktreeID, visible: Bool)
}
```

Both mutations:
- No-op (no catalog churn) if the target doesn't resolve or the value is unchanged — matches existing mutation style.
- Go through the existing `mutate { ... }` / debounced-save pipeline so persistence is identical to every other catalog write.
- Do **not** emit a selection change or engine event; they are catalog-shape mutations.

#### 3. Aggregation API on `NotificationInbox`

Pure extension in CodansCore:

```swift
public extension NotificationInbox {
  /// Count of unread, non-dismissed notifications whose resolved Worktree == id.
  func unreadCount(forWorktree worktreeID: WorktreeID, in catalog: Catalog) -> Int

  /// True iff at least one unread, non-dismissed notification resolves to any
  /// Worktree under the given Project.
  func hasUnread(forProject projectID: ProjectID, in catalog: Catalog) -> Bool

  /// True iff at least one unread, non-dismissed notification resolves to any
  /// Worktree under any Project of the given Space.
  func hasUnread(forSpace spaceID: SpaceID, in catalog: Catalog) -> Bool

  /// All notifications whose resolved Worktree == id, time-descending
  /// (createdAt newest first). Includes read and dismissed entries — caller
  /// filters as needed. Stable order for equal createdAt (fallback to id).
  func notifications(forWorktree worktreeID: WorktreeID, in catalog: Catalog) -> [AgentNotification]
}
```

Resolution helper (also on `Catalog`, private-internal visibility):

```swift
extension Catalog {
  /// Resolve a PaneID to the Worktree that currently hosts it, if any.
  /// O(n) across the whole catalog; aggregation callers build a PaneID→WorktreeID
  /// map once per call to amortize.
  func worktreeID(forPane paneID: PaneID) -> WorktreeID?

  /// All PaneIDs that currently live under a given Worktree (flat across all tabs).
  func paneIDs(inWorktree worktreeID: WorktreeID) -> Set<PaneID>
}
```

Implementation detail: aggregation methods build a `[PaneID: WorktreeID]` index once by walking `catalog.spaces → projects → worktrees → tabs → panes`, then scan notifications against it. For O(notifications + panes) cost per call. Good enough at the catalog/inbox sizes in play (catalog ≤ a few hundred panes, inbox ≤ 500).

"Unread" follows `AgentNotification.isUnread` (existing: `readAt == nil && dismissedAt == nil`).

#### 4. Mutation API on `InboxStore`

```swift
@MainActor
extension InboxStore {
  /// Marks every notification whose pane resolves to this worktree (in catalog)
  /// as read (`readAt = now`). Schedules save + publishes unread.
  func markRead(forWorktree worktreeID: WorktreeID, in catalog: Catalog, now: Date = Date())

  /// Dismiss every notification in the inbox (soft-delete). Alias of the
  /// existing `clearAll`, exposed under the name T2 will call it by.
  func dismissAll(now: Date = Date())
}
```

`dismissAll` is a thin forwarder to the existing `clearAll` — keeping both names avoids churning C6 M5 call-sites while giving T2 the name the spec uses.

#### 5. Sidebar mode Picker removal

`ContentView`:
- Delete `modeTogglePicker` and the `.toolbar { ToolbarItem { modeTogglePicker } }` usage on the sidebar column.
- Replace the `@ViewBuilder var sidebarColumn` switch with direct `HierarchySidebarView(...)` invocation. The `store.scope(state:\.inbox,...)` scope stays unused at the sidebar site.

`RootFeature`:
- `SidebarMode` enum, `sidebarMode` state, and `sidebarModeChanged(_:)` action are retained (marked internal / "reserved for T2 bell popover") but no longer driven from the sidebar. No dispatches remain in the app.
- The `Scope(state:\.inbox, action:\.inbox)` wiring stays, so `InboxSidebarFeature` continues to reduce. C6 M5 tests keep passing.

### Data Storage

On-disk shape at `~/.config/codans/catalog.json`:

- Top-level `Catalog.version` stays at `1`. The two new fields are additive keys on `spaces[].…` (`lastActiveWorktreeID`) and `spaces[].projects[].worktrees[].…` (`gitViewerVisible`). Older readers (if any) that don't know these keys simply drop them on re-save — acceptable since the on-disk contract is "one writer per install".
- We do **not** bump `Catalog.currentVersion`. Bump would force users' existing catalogs through a migration path for a zero-risk additive change — disproportionate. Forward-compat: when a field with the *same* name but different shape is introduced, that's when we bump.

Backward-compat tests go in `CatalogCodableTests` (new file or appended): decode a pre-T0 JSON fixture → Catalog value with `lastActiveWorktreeID == nil` and `gitViewerVisible == false` on every worktree, no throw.

`NotificationInbox` on-disk shape is unchanged.

### Component Boundaries

| Component | Owns | Does not own |
|---|---|---|
| `CodansCore/Space` | Model fields + Codable | Runtime mutation / persistence |
| `CodansCore/Worktree` | Model fields + Codable | Runtime mutation / persistence |
| `CodansCore/Catalog` | Pane→Worktree resolution helpers | Mutation API |
| `CodansCore/NotificationInbox` | Pure aggregation helpers | Mutation (those are on `InboxStore`) |
| `apps/mac/.../HierarchyManager` | `setSpaceLastActiveWorktree`, `setWorktreeGitViewerVisible` | UI, notifications |
| `apps/mac/.../InboxStore` | `markRead(forWorktree:in:)`, `dismissAll` | Catalog shape |
| `apps/mac/.../ContentView` | Sidebar/Detail composition | `sidebarMode` toggle UI (deleted) |
| `apps/mac/.../RootFeature` | Reserves `SidebarMode` enum for T2 | Actively dispatches mode changes |

Dependency direction stays: `app-side` → `CodansCore`, never the other way.

## Alternatives Considered

**(A) Add aggregation API directly on `InboxStore` only, no pure helpers.**
Rejected: `InboxStore` is MainActor, which forces every test to `@MainActor` just to exercise aggregation logic. The aggregation is pure given `(inbox, catalog)` — putting it in CodansCore gives free unit coverage and lets T2 compose it (e.g. on a snapshot inside a reducer) without crossing the MainActor boundary.

**(B) Pre-join notifications with WorktreeID at append time and store `worktreeID` on `AgentNotification`.**
Rejected: panes can move between tabs, and tabs between worktrees; the pointer would go stale and would also require a migration of existing inbox JSON. The current "paneID + render-time join" is the simpler invariant; we keep it and pay the O(n) cost at aggregation time, which is bounded by the 500-row cap.

**(C) Fold `lastActiveWorktreeID` into `Project.selectedWorktreeID`.**
Rejected (and explicitly forbidden by the task brief): the two have different semantics. `Project.selectedWorktreeID` is the "most recently selected worktree under this Project" (global). `Space.lastActiveWorktreeID` is "when returning to this Space from another Space, restore this worktree"; it may be under any Project within the Space, and may differ from that Project's `selectedWorktreeID` when the user Space-hops within the same Project. Merging them loses the distinction.

**(D) Bump `Catalog.version` to 2 for the additive fields.**
Rejected: a version bump implies a migration contract. Additive optional fields that default to `nil` / `false` need only `decodeIfPresent`; the existing `version == 1` check continues to catch a genuinely incompatible shape.

**(E) Delete `SidebarMode` / `sidebarMode` / inbox scope from RootFeature entirely.**
Rejected for now: T2 has not committed to a specific re-use of `InboxSidebarFeature` for the bell popover, but the task brief says "InboxSidebarView remains as a component" and "RootFeature's sidebarMode state/action may be retained as internal implementation detail". Deleting now and adding back later is churn; keep the plumbing, remove only the UI.

**(F) Require an explicit resolver closure on `InboxStore` at init (`panelResolver: (PaneID) -> WorktreeID?`).**
Rejected: the closure would need the catalog, and the catalog changes every time the user adds/removes a tab — wiring that as a captured reference in `InboxStore` is extra lifecycle for no test-ergonomic gain, since pure `(inbox, catalog)` helpers already test cleanly.

## Cross-Cutting Concerns

**Testing strategy.** Three test surfaces:
1. `CatalogCodableTests` — decode pre-T0 JSON fixture; assert defaults. Encode → decode round-trip with the new fields set; assert equality.
2. `NotificationInboxTests` — a tiny catalog with 1 space / 2 projects / 3 worktrees / 4 panes + a handful of `AgentNotification`s: covers (a) unread count on single worktree, (b) hasUnread on project with two worktrees (mixed read/unread), (c) hasUnread on space spanning projects, (d) notifications(forWorktree:) time-ordering and read/dismissed inclusion.
3. `InboxStoreTests` — `markRead(forWorktree:in:)` on a catalog+inbox fixture asserts `unreadCount → 0` for that worktree, unread on the sibling worktree unchanged; `dismissAll()` delegates to `clearAll`.

**Observability.** No new log categories. Existing `inbox` and `hierarchy` loggers already cover persistence/load paths.

**Migration.** None required. `decodeIfPresent` is the entire forward-compat story. Users who roll back to a pre-T0 binary will lose the two fields on next save; acceptable since both default cleanly.

**Rollback.** Revert the commits; on-disk catalog stays valid for pre-T0 binaries because both new fields were optional/defaulted.

**Contracts for T1/T2/T3 (what this PR freezes):**

- `Space.lastActiveWorktreeID: WorktreeID?` (read by T1 Space-switch popover; written by T1 when switching Spaces)
- `Worktree.gitViewerVisible: Bool` (read by T3 overlay visibility; written by T3 toggle)
- `HierarchyManager.setSpaceLastActiveWorktree(spaceID:worktreeID:)`, `setWorktreeGitViewerVisible(worktreeID:visible:)` (T1/T3 mutation entry points)
- `NotificationInbox.unreadCount(forWorktree:in:)` / `.hasUnread(forProject:in:)` / `.hasUnread(forSpace:in:)` / `.notifications(forWorktree:in:)` (T1 unread dots, T2 bell popover list)
- `InboxStore.markRead(forWorktree:in:)` / `.dismissAll()` (T2 bell popover actions)
- `ContentView` no longer owns a sidebar-mode toggle; T2 hangs the bell off `WorktreeHeader`, not the sidebar toolbar

## Risks

**R1: Pane-to-Worktree index rebuild cost if the aggregation helpers are called per-row during render.**
Mitigation: the helpers build the index per-call; a naive `ForEach Project { hasUnread(forProject:in:) }` over N projects does N scans. Document in doc-comments that callers who render many rows per frame should build one snapshot-scoped cache. Concrete values: 500 notifications × 200 panes = ~100K ops worst-case ≈ sub-millisecond; deferred optimization until profiled.

**R2: `decodeIfPresent` silently swallowing a typo in the new key.**
Mitigation: round-trip tests (encode then decode) catch typos where the encode side writes a different key than the decode side expects.

**R3: Leaving dead `SidebarMode` machinery in `RootFeature` causes future confusion.**
Mitigation: doc-comment on `sidebarMode` updated to "reserved for T2 bell popover; not currently driven by UI" so the next reader isn't misled. If T2 lands and doesn't reuse it, T2's PR deletes it then.

**R4: `markRead(forWorktree:in:)` races with a concurrent `append` from the notification pipeline.**
Mitigation: `InboxStore` is `@MainActor`; both mutations serialize on the main actor. No additional locking needed.
