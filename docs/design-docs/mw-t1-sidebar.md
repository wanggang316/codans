---
name: mw-t1-sidebar
description: Main-Window T1 — Sidebar redesign, Space switcher, Worktree context menu, unread aggregation
type: design-doc
---

# Design Doc: Main-Window Redesign — T1 Sidebar & Space Switcher

**Status:** Draft
**Author:** Gump (T1 sub-agent, via Claude Code)
**Date:** 2026-04-21

## Context and Scope

The main-window UI redesign (`docs/product-specs/ui-main-window-redesign.md`) is split
into four sub-tasks. T0 ("Foundation & Contracts",
`docs/design-docs/mw-t0-foundation.md`) has landed on `feature/main-window` and frozen
the data-model and aggregation contracts:

- `Space.lastActiveWorktreeID: WorktreeID?` (per-Space restoration anchor)
- `Worktree.gitViewerVisible: Bool` (T3 owns the toggle)
- `HierarchyManager.setSpaceLastActiveWorktree(spaceID:worktreeID:)`
- `HierarchyManager.setWorktreeGitViewerVisible(worktreeID:visible:)`
- `NotificationInbox.unreadCount(forWorktree:in:)`,
  `.hasUnread(forProject:in:)`, `.hasUnread(forSpace:in:)`,
  `.notifications(forWorktree:in:)`
- `InboxStore.markRead(forWorktree:in:)` / `.dismissAll()`
- `ContentView` sidebar is unconditionally `HierarchySidebarView`

T1 redesigns the sidebar itself: its visual tree, hover chrome, Worktree context
menu with *real* actions (remove, reveal in Finder, open in default editor), an
always-visible Space footer with a popover, real Space-switch semantics backed
by `lastActiveWorktreeID`, and unread dots sourced from the T0 aggregation API.

Out of scope for T1: Header / Git Viewer / keyboard shortcuts (T2 / T3) and the
`Add Project` / `Add Worktree` sheet bodies (spec Won't-Have).

Existing pieces T1 builds on:

- `HierarchySidebarFeature` (`@Reducer`) currently holds `expandedSpaceIDs` /
  `expandedProjectIDs` only, and forwards row taps through `HierarchyClient`.
- `HierarchySidebarView` reads `hierarchyManager.catalog` directly from
  `@Environment` and renders two nested `DisclosureGroup`s (Space → Project →
  Worktree). The current design pushes structural data *out of* TCA state on
  purpose (already documented as a state-ownership trade-off in the T0-era
  doc-comments).
- `HierarchyClient` already exposes `createSpace`, `renameSpace`, `removeSpace`,
  `addProject`, `removeProject`, `createWorktree`, `removeWorktree`,
  `selectSpace`, `selectProject`, `selectWorktree`, and related pane/tab verbs.
  It **does not** yet expose `setSpaceLastActiveWorktree` or `renameProject`.
- `EditorFeature` owns the "Open in …" dispatch path (`openRequested` →
  `openSucceeded` / `openFailed`) with toast wiring in `ContentView`. The
  sidebar context menu should reuse this path — not a second `EditorClient`
  call site — so toasts behave consistently.
- `NotificationInbox` aggregation helpers are pure and build a
  `[PaneID: WorktreeID]` index per call. The doc-comment says "callers that
  render many rows per frame should cache a snapshot-scoped index".

## Goals and Non-Goals

### Goals

- Visual overhaul of `HierarchySidebarView` to match the spec: sidebar toolbar,
  Project section hover chrome (`+` / `⋯`), filled/empty Worktree dots, trailing
  unread dots, empty-Space placeholder, always-visible Space footer.
- Real Worktree right-click context menu: **Remove Worktree**, **Reveal in
  Finder**, **Open in default editor** — all three wired to real side effects.
- Real Project section `⋯` menu: **Rename Project**, **Remove Project** — wired
  to new `HierarchyManager.renameProject` and existing `removeProject`.
- Space footer + popover: lists every Space (active marked), click-to-switch,
  `+ New Space` creates a minimally-named Space and activates it.
- Real Space-switch semantics end-to-end:
  1. Before leaving Space A, write `A.lastActiveWorktreeID` = current selection.
  2. On entering Space B, read `B.lastActiveWorktreeID` and restore it (or fall
     back to `project.selectedWorktreeID` if stale / nil).
  3. Selecting a Worktree in place also updates the active Space's
     `lastActiveWorktreeID` (so user doesn't lose their last selection after
     hopping away and back).
- Unread dots:
  - Worktree row trailing dot iff
    `NotificationInbox.unreadCount(forWorktree:in:) > 0`.
  - Project section header aggregate dot iff
    `NotificationInbox.hasUnread(forProject:in:) == true`.
- Delete the obsolete `SidebarMode`-backed plumbing that T0 left as "reserved
  for T2": after T1 the sidebar no longer needs it and T2's bell will live on
  `WorktreeHeader`, not the sidebar. (Decision point — see Alternatives E.)
- Tests:
  - `HierarchySidebarFeatureTests` coverage for the Space-switch reducer
    (writes old Space's `lastActiveWorktreeID`, restores target Space's), the
    Worktree-context-menu reducer paths (Remove / Reveal / Open), and the
    new-Space creation path.
  - `NotificationInboxTests` coverage for the sidebar's concrete aggregation
    call patterns (Worktree count; Project hasUnread mixed read/unread).
  - `CatalogCodableTests` already covers `lastActiveWorktreeID` — no
    duplication.

### Non-Goals

- `WorktreeDetailView` / `ContentView` detail column (T2).
- Git Viewer overlay presentation or persistence (T3).
- Keyboard shortcuts other than popover-internal arrow-key navigation (T3).
- The `Add Project` / `Add Worktree` sheet contents (spec Won't-Have). The
  buttons *must* dispatch a real action and present a minimal empty/TODO sheet
  so reducer paths are exercised and a future agent can drop sheet bodies in
  without re-plumbing.
- Drag-and-drop Worktree reordering (spec Could-Have).
- Sidebar filter field (spec Could-Have).
- Rename-Space UI (task brief mentions renameProject specifically; Space
  rename is not called out and the existing `HierarchyClient.renameSpace`
  already exists if T2 wants it for the Space popover).

## Design

### Overview

`HierarchySidebarFeature` grows from "local expansion state + row-tap
forwarders" to the full sidebar controller:

1. New state fields for the Space-switcher popover visibility and three
   transient sheet presentations (add-project, add-worktree, rename-project).
2. New actions for every spec-required interaction — Space popover open/close,
   Space switch, create-Space, context-menu items, and hover-chrome buttons.
3. Real side effects through `HierarchyClient` (new `setSpaceLastActiveWorktree`
   and `renameProject` entries added), `EditorFeature` (routed through the
   parent via a delegate action — see Alternatives D), and a thin
   `FinderClient` dependency for `NSWorkspace.activateFileViewerSelecting`.
4. View rewrite: `HierarchySidebarView` re-renders the tree with the visual
   chrome the spec requires, adds the Space footer + popover, and renders the
   hover/context-menu affordances. Structural data stays read directly from
   `@Environment(HierarchyManager.self)` — the state-ownership trade-off from
   the pre-T1 design stands.

Space-switch semantics are implemented in a single reducer branch
(`.spaceRowTapped` extended with a write-old/read-new/send-select chain)
instead of split across RootFeature + sidebar — see Alternatives A.

### System Context Diagram

```
┌───────────────────────────────────────────────────────────────────────┐
│                       HierarchySidebarView                            │
│  ┌───────────────────────────────────────────────────────────────┐    │
│  │ Sidebar toolbar   [+ Add Project]      [⋯]                    │    │
│  │ ─────────────────────────────────────────────────────────     │    │
│  │ ▼ Project A  (hover → [+] [⋯])                                │    │
│  │    ● main                                (unread dot)         │    │
│  │    ○ feature/login  ▸ right-click → Remove / Reveal / Open    │    │
│  │ ─────────────────────────────────────────────────────────     │    │
│  │ 🗂 MySpace  ⌄  ←────── popover: switch / + New Space          │    │
│  └───────────────────────────────────────────────────────────────┘    │
└──────┬──────────────────────────┬─────────────────────────┬───────────┘
       │ dispatch                 │ read catalog            │ read inbox
       ▼                          ▼                         ▼
┌──────────────────────┐  ┌────────────────┐      ┌──────────────────┐
│ HierarchySidebar     │  │ HierarchyMgr   │      │ InboxStore       │
│ Feature (TCA)        │  │ (@Observable)  │      │ (@MainActor)     │
│ ── selects,          │  │ catalog +      │      │ observes         │
│    mutates,          │  │ setSpaceLast…  │      │ aggregation      │
│    opens popover     │  │ setWorktree…   │      │ helpers on       │
│    routes to Editor  │  │ renameProject  │      │ NotificationInbox│
└──┬──┬──┬─────────────┘  └────────────────┘      └──────────────────┘
   │  │  │
   │  │  └─→ FinderClient.reveal(path)
   │  └───── RootFeature delegates editor-open to EditorFeature
   └──────── HierarchyClient (all catalog mutations)
```

### State Shape

```swift
// HierarchySidebarFeature.State additions only
struct State: Equatable {
  // Retained from pre-T1
  var expandedSpaceIDs: Set<SpaceID> = []
  var expandedProjectIDs: Set<ProjectID> = []

  // NEW — transient UI
  var isSpacePopoverPresented: Bool = false

  // NEW — stub sheets (spec Won't-Have bodies). Presence == shown; body is
  // a TODO placeholder that just dismisses. Non-Optional enum-free so we can
  // keep Equatable cheap and not drag PresentationState through an M1 view.
  var addProjectSheet: AddProjectSheet? = nil
  var addWorktreeSheet: AddWorktreeSheet? = nil
  var renameProjectSheet: RenameProjectSheet? = nil

  // Remove-Worktree confirmation dialog payload. Non-nil == visible.
  var pendingWorktreeRemoval: PendingWorktreeRemoval? = nil
}

struct AddProjectSheet: Equatable { var spaceID: SpaceID }
struct AddWorktreeSheet: Equatable { var projectID: ProjectID; var spaceID: SpaceID }
struct RenameProjectSheet: Equatable { var projectID: ProjectID; var spaceID: SpaceID; var draft: String }
struct PendingWorktreeRemoval: Equatable { var worktreeID: WorktreeID; var projectID: ProjectID; var spaceID: SpaceID; var displayName: String }
```

Rationale:
- Popover, sheets, and confirmation live in reducer state so TestStore can
  exercise them, matching existing `@Presents`-free patterns elsewhere in the
  codebase (the full `@Presents` ceremony is overkill for stub bodies).
- `RenameProjectSheet.draft` is mutated through an action as the user types so
  the sheet's text-field binding flows through the reducer (testable).

### Action Surface

```swift
enum Action: Equatable {
  // Retained
  case spaceRowTapped(SpaceID)
  case projectRowTapped(ProjectID, inSpace: SpaceID)
  case worktreeRowTapped(WorktreeID, inProject: ProjectID, inSpace: SpaceID)
  case toggleSpaceExpansion(SpaceID)
  case toggleProjectExpansion(ProjectID)
  case pruneExpansionSets(currentSpaceIDs: Set<SpaceID>, currentProjectIDs: Set<ProjectID>)

  // Toolbar
  case toolbarAddProjectTapped
  case toolbarMenuTapped  // `⋯`, currently no-op placeholder

  // Project section hover chrome
  case projectAddWorktreeTapped(projectID: ProjectID, inSpace: SpaceID)
  case projectRenameTapped(projectID: ProjectID, inSpace: SpaceID, currentName: String)
  case projectRenameDraftChanged(String)
  case projectRenameConfirmed
  case projectRenameCancelled
  case projectRemoveTapped(projectID: ProjectID, inSpace: SpaceID)

  // Worktree row context menu
  case worktreeRemoveTapped(worktreeID: WorktreeID, inProject: ProjectID, inSpace: SpaceID, name: String)
  case worktreeRemoveConfirmed
  case worktreeRemoveCancelled
  case worktreeRevealInFinderTapped(path: String)
  case worktreeOpenInDefaultEditorTapped(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    path: String
  )

  // Sheet stubs — presenting + dismissing
  case addProjectSheetDismissed
  case addWorktreeSheetDismissed

  // Space footer + popover
  case spaceFooterTapped
  case spacePopoverDismissed
  case spacePopoverSpaceSelected(SpaceID)
  /// Creates a Space with an auto-generated name (see §New-Space naming) and
  /// activates it. The reducer computes the name synchronously from the
  /// current catalog snapshot right before calling `hierarchyClient.createSpace`.
  case spacePopoverNewSpaceTapped

  // Delegate up to RootFeature for editor-open (cleaner than the sidebar
  // owning an EditorClient dep; see Alternatives D).
  case delegate(Delegate)
  enum Delegate: Equatable {
    case openInDefaultEditor(worktreePath: String, projectID: ProjectID?)
    case revealInFinder(path: String)
  }
}
```

Design notes:
- `.worktreeRowTapped` keeps its pre-T1 semantic (select the Worktree) *and*
  gains a new side effect: write the currently-active Space's
  `lastActiveWorktreeID = worktreeID` so that later Space-hop restores target
  the user's real last choice, not just whatever `Project.selectedWorktreeID`
  says. **Skip the write if the current value already equals `worktreeID`** —
  don't fire a debounced save for a no-op. `HierarchyManager
  .setSpaceLastActiveWorktree` already no-ops on unchanged value (T0 design §2),
  but we short-circuit on the reducer side as well so TestStore traces stay
  clean (no phantom dependency call) and we don't rely on the manager's
  dedup alone.
- `.spaceRowTapped` is the Space-switch entry point. It:
  1. Reads current selection from `hierarchyClient.snapshot()`.
  2. If the current spaceID is the tapped spaceID → no-op (don't churn catalog).
  3. Else: writes current `spaceID`'s `lastActiveWorktreeID` = current
     `worktreeID` (could be nil).
  4. Calls `hierarchyClient.selectSpace(tappedSpaceID)`.
  5. Reads the tapped Space from the new snapshot. If
     `lastActiveWorktreeID` points at a Worktree that still exists →
     dispatch `selectWorktree` for it; else fall back to the tapped Space's
     current `selectedProjectID` → that project's `selectedWorktreeID` (no
     action needed beyond `selectSpace` in that case — existing code path).
  6. Also clear `lastActiveWorktreeID` if it was stale. This is the "T1
     follow-up" noted in T0's design.
- `.worktreeRemoveTapped` opens the confirmation dialog; `.worktreeRemoveConfirmed`
  calls `hierarchyClient.removeWorktree(...)`. Rationale for a confirm step:
  removing a Worktree drops its tabs and kills its terminal surfaces — the user
  can lose running processes. Spec doesn't forbid confirmation.
- `.worktreeRevealInFinderTapped` hits a new `FinderClient` dep (see below) —
  the reducer doesn't do the UIKit / AppKit call itself.
- `.worktreeOpenInDefaultEditorTapped` does NOT call `EditorClient` directly.
  It fires `.delegate(.openInDefaultEditor(...))`; `RootFeature` catches the
  delegate and forwards to `.editor(.openRequested(editorID: nil, …))`. `nil`
  editorID means "use resolution chain" — `EditorFeature` already resolves the
  default via its `resolve` path. This keeps toast wiring single-site.

### New-Space naming

This iteration does not ship Space rename, so the auto-generated name for
`+ New Space` must be unique at creation time — otherwise the user sees two
"Untitled Space" rows and can't tell them apart. The naming rule:

- Scan the current catalog's Spaces and collect every name that matches
  `"Untitled Space"` or `"Untitled Space <N>"` (N is a positive integer, no
  leading zeros, single space separator).
- Reserve `N = 1` for the bare name `"Untitled Space"` (i.e. treat "Untitled
  Space" and "Untitled Space 1" as the same slot; the first one written goes
  in bare). Find the smallest positive N not in the occupied set:
  - Empty catalog → `"Untitled Space"`.
  - Only `"Untitled Space"` exists → `"Untitled Space 2"`.
  - `"Untitled Space"` + `"Untitled Space 3"` exist → `"Untitled Space 2"`
    (fills the hole).
  - `"Untitled Space 2"` exists but not `"Untitled Space"` → `"Untitled Space"`
    (bare takes the smallest slot).

Implementation: pure free function in `HierarchySidebarFeature.swift`
(file-private, pulled into the test target through `@testable import`):

```swift
/// Pure. Returns the smallest-index unused "Untitled Space [N]" name in `spaces`,
/// using the bare form for the first slot.
func nextUntitledSpaceName(in spaces: [Space]) -> String
```

Trade-off vs. alternatives:
- Putting the helper on `HierarchyClient` would need a closure + testValue + a
  live bridge for what is a pure string computation — over-engineered.
- Putting it on `HierarchyManager` as a non-mutating helper conflates
  "catalog mutations" with "view-model naming"; wrong owner.
- Unit-testable as-is via `@testable` import; no actor isolation.

Covered in `HierarchySidebarFeatureTests` by three cases: empty / one existing
bare / a hole (`"Untitled Space"` + `"Untitled Space 3"` → fills `2`). The
reducer test for `.spacePopoverNewSpaceTapped` asserts that the computed name
is what gets passed to `hierarchyClient.createSpace`.

### Dependencies (new / extended)

`HierarchyClient`:

```swift
// NEW closures — mirror existing pattern (MainActor @Sendable, `throws` where manager throws)
var renameProject: @MainActor @Sendable (_ projectID: ProjectID, _ inSpace: SpaceID, _ name: String) throws -> Void
var setSpaceLastActiveWorktree: @MainActor @Sendable (_ spaceID: SpaceID, _ worktreeID: WorktreeID?) -> Void
```

Live wiring forwards to `HierarchyManager.renameProject` (new — straight
mutation scoped to `findProjectIndices` pattern) and
`HierarchyManager.setSpaceLastActiveWorktree` (already exists from T0).
`testValue` uses `unimplemented(...)` matching the rest of the file.

`FinderClient`:

```swift
nonisolated struct FinderClient: Sendable {
  var reveal: @MainActor @Sendable (_ path: String) -> Void
}

extension FinderClient: DependencyKey {
  static let liveValue = FinderClient(reveal: { path in
    let url = URL(fileURLWithPath: path)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  })
  static let testValue = FinderClient(
    reveal: unimplemented("FinderClient.reveal")
  )
}
```

Rationale: tiny surface, mirrors the pattern of the other clients
(`HierarchyClient`, `InboxClient`, `EditorClient`). Keeps the reducer pure +
TestStore-drivable without pushing AppKit into it.

### View Composition

`HierarchySidebarView` replaces its current body with:

```
VStack(spacing: 0) {
  sidebarToolbar           // + Add Project, ⋯ menu
  Divider()
  List {                   // scrollable tree
    if catalog.spaces.isEmpty { globalEmpty }
    else {
      ForEach(activeSpace.projects) { projectSection($0) }  // ← NOT all spaces
      if activeSpace.projects.isEmpty { emptySpaceState }
    }
  }
  Divider()
  spaceFooter              // pinned; always visible
    .popover(isPresented: ...) { spacePopover }
}
.sheet(isPresented: ...) { addProjectStub }
.sheet(isPresented: ...) { addWorktreeStub }
.sheet(isPresented: ...) { renameProjectSheet }
.confirmationDialog(...)   { worktreeRemoveDialog }
```

Key deltas vs. pre-T1:
- Tree renders the **active Space only**, not every Space. The visual mock in
  the spec never shows multiple Spaces expanded simultaneously; the Space
  footer switches between Spaces. The outer Space-level `DisclosureGroup`
  disappears — `expandedSpaceIDs` stays in state but is unused for now
  (cheap to leave; removing cascades into tests and the prune path).
  *Decision:* keep `expandedSpaceIDs` in state + prune still operating, but
  don't render Space-level disclosure. Dead state is better than churned tests.
- Project section uses a custom `DisclosureGroup`-styled row where the label is
  an `HStack` containing the Project name, a `Spacer`, and the hover-only
  `+` / `⋯` buttons. We gate visibility with `@State private var isHovering`
  on each row using `.onHover`.
- Worktree row gets a leading `●` / `○` SF Symbol (`circle.fill` /
  `circle`) and a trailing unread dot (`circlebadge.fill` or a plain 6pt
  `Circle().fill(.tint)`). The row itself is wrapped in `.contextMenu` with
  the three Worktree-context items.
- Space footer is an `HStack` with a folder/space icon, the active Space's
  name, and a `chevron.down`. Tap toggles
  `isSpacePopoverPresented`. The popover is a simple `VStack` listing each
  Space row (with a leading check on the active Space), a `Divider`, then a
  `+ New Space` row.
- `emptyState` (pre-T1) is replaced by two states:
  - Global empty (no Spaces at all) — basically can't happen at runtime today
    (bootstrap always creates a default Space) but we render a graceful
    "No Spaces" message.
  - Empty-Space state (active Space has zero Projects) — prominent
    `+ Add Project` button + a short "No projects yet." line.

#### Unread-dot index caching

Inside `body`, before rendering the Project list, we compute one
snapshot-scoped index:

```swift
let panelIndex = hierarchyManager.catalog.panelWorktreeIndex()
// … but panelWorktreeIndex() is currently `nonisolated` yet not `public`.
```

`Catalog.panelWorktreeIndex()` is `nonisolated func` with no access modifier
→ defaults to `internal`. CodansCore exposes it across the module boundary
iff we mark it `public`. T1 bumps it to `public` (trivial change, strictly
additive) so the sidebar can build the index once per render pass. Worktree
and Project aggregation helpers on `NotificationInbox` then become one-line
inline sums that read from the shared index, avoiding the per-row rebuild that
the doc-comment warns against.

Alternative: keep the helpers closed-over the index internally, as they do
today, and accept the rebuild cost — the catalog is small. See Alternatives F.

#### Observing the inbox

`InboxStore` is `@MainActor`. T1 adds a minimal environment injection so the
view can read `inbox.inbox` directly:

```swift
@Environment(InboxStore.self) private var inboxStore
```

`InboxStore` already conforms to `@Observable` (see `ContentView` wiring of
other observable stores). `CodansApp.bringUp` injects it alongside
`HierarchyManager` and `SettingsStore`.

Rationale: mirrors how `HierarchyManager` is consumed by `HierarchySidebarView`
today — we keep structural data read out of TCA state. The `NotificationInbox`
lives on the store and is already republished on mutation, so SwiftUI
re-renders when new agent pings arrive.

### Root Integration

`RootFeature`:
- Add `case sidebar(.delegate(let d))` branches in the reducer:
  - `.openInDefaultEditor(worktreePath, projectID)` → `.send(.editor(
    .openRequested(editorID: nil, worktreePath: worktreePath, projectID: projectID)))`
  - `.revealInFinder(path)` → `.run { _ in finderClient.reveal(path) }`
    (adds a `@Dependency(FinderClient.self)` on `RootFeature`).
  - Alternative considered and rejected: put the dependency inside the sidebar
    reducer. See Alternatives D.
- Remove `SidebarMode`, `state.sidebarMode`, `case .sidebarModeChanged`, the
  `Scope(state:\.inbox, action:\.inbox)` wiring, `state.inbox`, and the
  `case .inbox(...)` branches (including the dead `deeplinkRequested` no-op).
  Rationale: T0 explicitly marked this as "T2 must either reuse or remove".
  T2 is building a new bell popover from scratch on `WorktreeHeader`; it does
  not need the `InboxSidebarFeature` reducer scoped into the root state.
  Removing now prevents drift and shrinks state. If T2 disagrees we restore in
  one PR; rebasing T2 over that deletion is trivial.
  `InboxSidebarFeature` / `InboxSidebarView` source files stay in the tree —
  T2 may want their row-renderer shape as a reference, but they're no longer
  mounted.

`ContentView`:
- No structural changes expected — still renders `HierarchySidebarView` in the
  leading column. The sidebar feature's `.pruneExpansionSets` forwarding
  stays on `store.selection` change, which is still emitted by `RootFeature`.
- Add the `InboxStore` and (if we accept the delegation pattern) keep Editor
  wiring untouched — `ContentView` already observes `editor.lastOpenResult`.

### Data Storage

No new on-disk shapes. T1 writes exclusively to existing fields:
`Space.lastActiveWorktreeID`, `Project.name` (rename), and schedules saves
through the existing `CatalogStore.scheduleSave` pipeline that T0's mutations
already use.

### Component Boundaries

| Component | Owns | Does not own |
|---|---|---|
| `HierarchySidebarFeature` | Expansion sets, popover + sheet state, context-menu dispatch, Space-switch choreography, delegate emission | Editor open side effect (delegated to RootFeature/EditorFeature), Finder reveal side effect (behind FinderClient), catalog mutation (HierarchyClient) |
| `HierarchySidebarView` | Visual tree, hover chrome, row dots, Space footer + popover, sheets | Selection logic, catalog state (reads `hierarchyManager.catalog`), inbox state (reads `inboxStore.inbox`) |
| `HierarchyClient` | Adds `renameProject`, `setSpaceLastActiveWorktree` closures | Business logic (forwards to manager) |
| `HierarchyManager` | Adds `renameProject(_:in:name:)` method | — |
| `FinderClient` | `reveal(path:)` via `NSWorkspace` | Editor open (different client) |
| `RootFeature` | Routes sidebar delegate → `EditorFeature` / `FinderClient`; deletes `SidebarMode` plumbing | Reducer state for inbox (gone) |
| `InboxStore` | Environment injection to sidebar | Sidebar render decisions |

Dependency direction unchanged: app → CodansCore. FinderClient is app-side,
CodansCore never imports AppKit.

## Alternatives Considered

**(A) Space-switch choreography in `RootFeature.selectionChanged`.**
Rejected: `selectionChanged` is driven by the hierarchy client's selection
*stream*, which yields *after* the catalog has already mutated. Writing
`oldSpace.lastActiveWorktreeID` in the stream handler is too late — the old
selection is already gone from the snapshot. The choreography has to sit
*before* `selectSpace` is called, i.e. on the intent (`spaceRowTapped`) side.
Keeping it in the sidebar reducer colocates intent and effect.

**(B) Popover state managed by SwiftUI `@State` in the view only.**
Rejected: TestStore cannot exercise the popover-open path without a state
projection, and the `+ New Space` creation flow needs to close the popover
from an action (not user click). Putting the bool in reducer state costs one
property for real testability.

**(C) Always-visible Project `+` / `⋯` buttons instead of hover-reveal.**
Rejected by spec ("hover-only add"). Hover keeps the tree compact and avoids
visual noise for users who only select rows. Accessibility: hover-reveal means
keyboard-only users can't trigger the buttons. Mitigation: both buttons are
also reachable via the row's `.contextMenu` (right-click works from keyboard
via macOS's keyboard context-menu key); documented in code comments. Full
key-equivalent support is a Should-Have deferred to T3's shortcut pass.

**(D) Sidebar reducer holds `@Dependency(EditorClient.self)` directly and
dispatches `.openRequested` to itself.**
Rejected: `EditorFeature` already owns the open path, including toast-friendly
state (`lastOpenResult`) and failure-reason mapping. A second call site fragments
that state. Delegating up to `RootFeature`, which forwards into
`.editor(.openRequested)`, keeps one canonical path. The cost is one more action
definition and one `case` in `RootFeature`; cheap.

**(E) Keep `SidebarMode` / `inbox` scoped state in `RootFeature` "for T2".**
Rejected at the T1/T2 coordination boundary: T2 is building the bell popover
on `WorktreeHeader`, not the sidebar. The T0 doc-comment explicitly says "T2
must either reuse or remove". T1 is where the decision becomes concrete — the
sidebar will never again mount `InboxSidebarView`. Keeping dead state invites
bit-rot and makes the sidebar reducer's state larger than it needs to be in
tests. Deletion is reversible in one commit if T2 disagrees.

**(F) Leave `Catalog.panelWorktreeIndex()` `internal` and pay the per-call
rebuild cost in the sidebar aggregation helpers.**
Rejected (mildly): at worst we rebuild the index N times per render pass
(N = number of Projects + number of Worktrees). For catalogs with ≤ 200
panes and ≤ 20 worktrees that's ≤ 4000 ops per frame — measurable on slow
hardware and easy to avoid with a one-line access-level bump. Chose the
public-bump option. The helpers themselves still accept `Catalog` rather than
pre-built index so their API doesn't change for other callers.

**(G) Use `@Presents` + child reducer for each stub sheet.**
Rejected: the sheet bodies are literally TODO placeholders (spec Won't-Have).
Wiring `@Presents` + a child `Feature` for each pulls a lot of boilerplate for
no test value. Plain optional state + bound `isPresented: $store.isSheetShown`
gets us everything we need: state-driven present/dismiss, TestStore coverage
on the action path, and a two-line rewrite when the real sheets land.

**(H) Skip the `Remove Worktree` confirmation dialog.**
Rejected: removing a Worktree kills all its tab panes and their running
processes (see `HierarchyManager.removeWorktree` calling `runtime.closeSurface`
for every pane). Losing an interactive agent session to a misclick is a bad
first-run experience. The spec's acceptance criterion is "context menu
includes at minimum: Remove Worktree" — it doesn't forbid a confirm step. We
add one; it's a single `.confirmationDialog` and two actions.

## Cross-Cutting Concerns

**Testing strategy.** TestStore drivers (all `@MainActor`, Swift Testing
`@Test` style matching the existing `HierarchySidebarFeatureTests.swift`):

1. **Space switch writes old, restores new.** Catalog fixture: Space A with
   Project P, worktrees W1 (selected) and W2; Space B with Project Q, worktree
   W3 (selected) and W4; `B.lastActiveWorktreeID = W4`. After
   `spaceRowTapped(B.id)`: assert `setSpaceLastActiveWorktree(A.id, W1)` was
   called, then `selectSpace(B.id)`, then `selectWorktree(W4, Q, B)`.
2. **Space switch with stale `lastActiveWorktreeID`.** `B.lastActiveWorktreeID`
   = `WorktreeID()` (not in catalog). Assert post-switch fallback to
   Project.selectedWorktreeID and that the stale field is cleared via
   `setSpaceLastActiveWorktree(B.id, nil)`.
3. **Worktree selection updates active Space's `lastActiveWorktreeID`.** Two
   sub-cases:
   a. First tap on a new Worktree writes through `hierarchyClient
      .setSpaceLastActiveWorktree(spaceID, worktreeID)` once.
   b. **Idempotence.** A second identical `.worktreeRowTapped` against the
      already-active Worktree does NOT call `setSpaceLastActiveWorktree`
      again. Assert via a recorder that capture-count stays at 1 across two
      successive identical taps.
4. **Worktree context menu paths.** `worktreeRemoveTapped` populates
   `pendingWorktreeRemoval`; `worktreeRemoveConfirmed` calls
   `hierarchyClient.removeWorktree(...)`. `worktreeRevealInFinderTapped` calls
   `finderClient.reveal(path)`. `worktreeOpenInDefaultEditorTapped` emits
   `.delegate(.openInDefaultEditor(...))`.
5. **New-Space creation.** `spacePopoverNewSpaceTapped` calls
   `hierarchyClient.createSpace(<computed-name>)` and dispatches
   `selectSpace` with the returned id; asserts popover dismissed. The
   `<computed-name>` is verified in three fixtures:
   a. Empty catalog → `"Untitled Space"`.
   b. Catalog with one `"Untitled Space"` → `"Untitled Space 2"`.
   c. Catalog with `"Untitled Space"` + `"Untitled Space 3"` →
      `"Untitled Space 2"` (hole-fill).
   Also a standalone pure-function test for `nextUntitledSpaceName(in:)`
   covering the same three cases plus the "`Untitled Space 2` exists but
   bare doesn't" → bare case.
6. **Project rename.** `projectRenameTapped` populates the sheet;
   `projectRenameConfirmed` calls `hierarchyClient.renameProject(...)` with
   the trimmed draft (empty draft = dismiss without call).
7. **Unread aggregation.** In `NotificationInboxTests`: Worktree-scoped
   count and Project-scoped hasUnread across a 1-space / 2-project / 3-worktree
   fixture (T0 already covers the multi-space case; we add a case that mirrors
   the sidebar's exact call pattern).

Preview / snapshot surface: we do not have snapshot infra on this repo today.
Instead, three SwiftUI previews (`#Preview`) in `HierarchySidebarView.swift`
covering (a) empty Space, (b) populated with unread dots, (c) Space popover
open. They compile under tests but don't assert.

**Accessibility.**
- Filled / empty Worktree dot carries `accessibilityLabel("active")` when
  active; unread dot carries `accessibilityLabel("has unread notifications")`.
- Hover chrome `+` / `⋯` buttons carry `.accessibilityLabel` and are also
  reachable through the row's context menu so keyboard users don't need the
  hover state.
- Space footer is a `Button` with a clear label; its popover is navigable by
  arrow-key and Enter (native SwiftUI `List` default).

**Observability.** No new log categories. Reducer side effects route through
existing clients that already log (`HierarchyManager` persistence, `EditorFeature`
open).

**Migration.** None — T1 writes only to already-present catalog fields.

**Rollback.** Revert; no on-disk changes beyond
`Space.lastActiveWorktreeID` values (already tolerated by pre-T1 binaries).

## Risks

**R1: Stale `lastActiveWorktreeID` after a Worktree is removed in another
Space.** If the user removes a Worktree while in a different Space, the owning
Space's `lastActiveWorktreeID` still references it. Next Space-switch-in finds
it missing.
*Mitigation:* the switch-in path already validates existence and falls back to
`Project.selectedWorktreeID`, clearing the stale pointer
(`setSpaceLastActiveWorktree(spaceID, nil)`). The invariant "only self-healing
on touch" is documented.

**R2: `panelWorktreeIndex()` visibility bump is a cross-module change.** Other
callers of CodansCore might start depending on it.
*Mitigation:* doc-comment the method as "prefer the per-scope aggregation
helpers; use raw index only when you're rendering many rows per frame over the
same snapshot". We don't forbid broader use — the helper is pure and cheap.

**R3: Delete of `SidebarMode` / `inbox` from `RootFeature` conflicts with T2.**
T2 is in parallel and may decide to reuse `InboxSidebarFeature` for the bell
popover.
*Mitigation:* `InboxSidebarFeature` / `InboxSidebarView` source files stay —
only the *scoping into `RootFeature`* goes. If T2 wants it, they add their own
`Scope(state:\.inbox, ...)` in T2's own PR. Coordinate via master.

**R4: `FinderClient.testValue` being `unimplemented` breaks the "revealInFinder
calls the dep" test if we forget to override.** Standard TestStore pattern;
every other test in the repo already lives with this risk.
*Mitigation:* override with a `LockIsolated` recorder, exactly like the
existing `selectWorktree` test.

**R5: The unread-dot aggregation is read directly from
`inboxStore.inbox`, which republishes on every `append`. If an agent storm
floods 50 notifications/sec, the sidebar re-lays out that often.**
*Mitigation:* SwiftUI diffs aggressively; each aggregation call is bounded
by the 500-row inbox cap. If profiling shows churn, add a coarse debounce on
`inboxStore` (not in scope for T1).

**R6: Hover-revealed buttons are invisible to a user discovering the UI.**
*Mitigation:* the same actions are available from the context menu on the row.
The spec explicitly prescribes hover; we honour it. A secondary keyboard path
is a future T3 shortcut concern.

## Follow-ups (not T1)

- Rename Space from the footer popover — trivial when the sheet pattern is in
  place; not spec-required.
- Drag-reorder Worktrees within a Project (Could-Have).
- Sidebar filter field (Could-Have).
- Replace stub Add-Project / Add-Worktree sheets with real flows (separate
  ticket, past this iteration).
