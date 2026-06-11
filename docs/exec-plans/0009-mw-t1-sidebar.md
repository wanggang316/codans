# ExecPlan: Main-Window T1 — Sidebar & Space Switcher

**Status:** Draft
**Author:** Gump (T1 sub-agent, via Claude Code)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a user opening codans sees the new Sidebar layout from the spec: a toolbar with `+ Add Project`, the active Space's Projects as collapsible sections whose headers reveal `+` / `⋯` on hover, Worktree rows marked active with `●` and inactive with `○` plus a trailing dot when there are unread agent notifications, and a pinned Space footer that opens a popover for switching between Spaces or creating a new one. Right-clicking a Worktree gives them three real actions — Remove Worktree (with confirmation), Reveal in Finder, Open in default editor — each wired to a real side effect rather than a stub. Switching Spaces remembers where the user was: leaving Space A writes its current Worktree to `Space.lastActiveWorktreeID`, and returning to A restores that Worktree as selected (falling back to the Project's selected Worktree if the remembered one was removed while the user was away). Creating a new Space from the popover auto-generates a unique `"Untitled Space [N]"` name so the user can tell fresh Spaces apart before renaming.

## Progress

- [ ] M1 — HierarchyManager.renameProject + HierarchyClient.renameProject / setSpaceLastActiveWorktree closures; unit coverage
- [ ] M2 — FinderClient dependency (liveValue + testValue); registered on app startup
- [ ] M3 — Catalog.panelWorktreeIndex() visibility bump to public; CodansCore re-export confirmed via test
- [ ] M4 — nextUntitledSpaceName pure helper + 4-branch unit test
- [ ] M5 — HierarchySidebarFeature state/action expansion (popover, sheet stubs, confirmation, context-menu actions, delegate) + reducer logic
- [ ] M6 — HierarchySidebarFeature reducer tests (Space switch write/restore/stale, worktree-tap idempotence, context-menu, rename Project, new-Space creation)
- [ ] M7 — HierarchySidebarView rewrite (toolbar, Project section hover chrome, Worktree row dots + context menu, Space footer + popover, empty-Space state, stub sheets, confirm dialog) + InboxStore env injection
- [ ] M8 — RootFeature: route sidebar delegates (openInDefaultEditor → editor.openRequested; revealInFinder → FinderClient); delete SidebarMode / state.inbox / Scope / .sidebarModeChanged / .inbox cases
- [ ] M9 — Test target sweep: update RootFeatureTests for deletions; HierarchySidebarFeatureTests augmented; NotificationInboxTests sidebar-call-pattern case
- [ ] M10 — Local verification (lint, three test schemes); push; open PR to feature/main-window; post PR_READY

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** (from design doc §Alternatives A): Space-switch choreography sits in `HierarchySidebarFeature.Reducer.spaceRowTapped`, not in `RootFeature.selectionChanged`. `selectionChanged` runs after the catalog has mutated and can no longer read the outgoing `worktreeID`.
- **D2** (from design doc §Alternatives D): Worktree-row `Open in default editor` routes through `.delegate(.openInDefaultEditor)` → `RootFeature` → `editor.openRequested(editorID: nil, ...)`. A second `EditorClient` call site would fragment toast state (`editor.lastOpenResult`).
- **D3** (from design doc §Alternatives E + master coordination 2026-04-21): T1 **deletes** `SidebarMode`, `RootFeature.State.sidebarMode`, `.sidebarModeChanged`, `state.inbox`, and the `.inbox` `Scope` / action cases. T2 is building the Header bell from scratch on `WorktreeHeader` and does not reuse these. T1 merges first; T2 rebases.
- **D4** (from design doc §New-Space naming + master revision 2026-04-21): `+ New Space` uses a pure helper `nextUntitledSpaceName(in: [Space])` that treats bare `"Untitled Space"` as the `N=1` slot and returns the smallest-index unused `"Untitled Space [N]"` name. Helper lives file-private in `HierarchySidebarFeature.swift` and is reached from tests via `@testable import`.
- **D5** (from design doc §Action Surface, reinforced by master revision 2026-04-21): `.worktreeRowTapped` skips the `setSpaceLastActiveWorktree` call when the active Space's current `lastActiveWorktreeID` already equals the tapped worktreeID. Keeps reducer-level trace clean; does not rely solely on T0's manager-side dedup.
- **D6** (from design doc §View Composition): the active Space's Projects render at the root level of the tree — no outer Space-level `DisclosureGroup`. `expandedSpaceIDs` state and its prune path stay (dead but cheap; removing touches too many tests for zero user-visible gain).
- **D7** (from design doc §Alternatives G): stub sheets use plain `Optional<Struct>` state rather than `@Presents` + child reducer. Sheet bodies are TODO placeholders (spec Won't-Have); the extra boilerplate has no test payoff.
- **D8** (from design doc §Alternatives H, extended during M5 convergence): Remove Worktree AND Remove Project each present a `.confirmationDialog` before calling the respective `HierarchyClient` remover. Both paths transitively kill every pane's running process via `runtime.closeSurface` (`HierarchyManager.removeProject` calls `removeWorktree` for every child). State carries symmetric `pendingWorktreeRemoval` / `pendingProjectRemoval` payloads.
- **D9** (per master revision 2026-04-21, post-PLAN): `EditorFeature.Action.openRequested(editorID:worktreePath:projectID:)` takes a non-optional `EditorID`, so the sidebar→Root→Editor delegate path cannot pass `nil`. `RootFeature.sidebar(.delegate(.openInDefaultEditor))` inlines the per-Project-override → global-default → `EditorRegistry.finderID` resolution chain (mirroring `WorktreeHeaderOpenButton.currentDefaultLabel`), accepting each tier only if the descriptor is `isInstalled`. T2 will later hoist the chain into an `EditorFeature.resolveDefault(...)` helper; inlining now keeps T1 self-contained and doesn't touch `EditorFeature.Action`, which is T2's boundary. Adds `EditorRegistry.finderID: EditorID` constant to centralize the magic string.
- **D10** (docs hygiene, per master revision 2026-04-21): M5 in-plan discussion artifacts on Remove-Project confirmation and Reveal-in-Finder routing were collapsed into their final decisions (D8 and D2 respectively). The living ExecPlan reads as instructions, not as a debate transcript.
- **D11** (M9 discovery, 2026-04-21): the `.send(.editor(.onAppear))` eager prime added to `RootFeature.onLaunch` in M8 was reverted in M9. The live `EditorService.describe()` path executes `MainActor.assumeIsolated { ... }` inside a `.run`-spawned background Task; under the xctest host that assertion fails with `dispatch_assert_queue_fail` (Signal 5) during test bootstrap, crashing the test process before any test runs. The sidebar context-menu "Open in default editor" path tolerates an empty descriptor cache: its inline resolution chain falls through to `EditorRegistry.finderID`, which is always installed. **Follow-up**: a MainActor-safe eager prime is still desirable (so the first-right-click-before-header-render shows the user's configured editor instead of Finder) — likely dispatched from `ContentView.task` or a dedicated `@MainActor` hop inside the reducer effect rather than through `.run`. Not in T1 scope.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:
- Product spec: `docs/product-specs/ui-main-window-redesign.md`
- Design doc (this plan's source of truth): `docs/design-docs/mw-t1-sidebar.md`
- Upstream (T0) design doc: `docs/design-docs/mw-t0-foundation.md`
- T0 ExecPlan (retrospective + contracts reference): `docs/exec-plans/0008-mw-t0-foundation.md`
- Architecture doc: `docs/architecture.md`

Key source files (full repository-relative paths):

- `apps/mac/CodansCore/Notifications/NotificationInboxAggregation.swift` — Pure aggregation helpers `unreadCount(forWorktree:in:)`, `hasUnread(forProject:in:)`, `hasUnread(forSpace:in:)`, `notifications(forWorktree:in:)` plus the `Catalog.panelWorktreeIndex()` / `paneIDs(inWorktree:)` resolvers. M3 promotes `panelWorktreeIndex()` from default-`internal` to `public`.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — `@MainActor @Observable` owner of catalog mutations; exposes `createSpace`, `renameSpace`, `removeSpace`, `addProject`, `removeProject`, `selectProject`, `createWorktree`, `removeWorktree`, `selectWorktree`, `setSpaceLastActiveWorktree`, `setWorktreeGitViewerVisible`. M1 adds `renameProject(_:in:name:)`.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — TCA dependency-injection wrapper exposing closures that the reducers call. M1 adds `renameProject` and `setSpaceLastActiveWorktree` closures + their `liveValue` / `testValue` / `unimplemented(...)` entries (three edits per closure, mechanical).
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — Current reducer holding `expandedSpaceIDs` / `expandedProjectIDs` + row-tap forwarders. M4 adds the file-private `nextUntitledSpaceName(in:)` helper; M5 expands state/actions/reducer.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — Current SwiftUI view rendering two `DisclosureGroup` layers from `hierarchyManager.catalog`. M7 rewrites the body.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — TCA composition root. M8 removes `SidebarMode`, `state.sidebarMode`, `.sidebarModeChanged` action, `state.inbox`, the `.inbox` Scope, `case .inbox(...)` branches, and the `.onAppear` doc-comment referring to them. Adds the sidebar `.delegate` handler.
- `apps/mac/codans/App/ContentView.swift` — Host view; already renders `HierarchySidebarView` unconditionally since T0. M7 adds `.environment(inboxStore)` so the sidebar view can read the inbox directly. M8-follower: delete `.onChange(of: store.selection)` references that depend on `state.sidebarMode` (none — T0 already cleared those).
- `apps/mac/codans/App/CodansApp.swift` — App startup; registers dependency closures via `.withDependencies`. M2 adds the `FinderClient` registration; M7 passes `inboxStore` into `ContentView.environment(inboxStore)`.
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift` — Existing editor-open reducer; sidebar delegate routes into its `.openRequested(editorID: nil, worktreePath: ..., projectID: ...)` action. No edits to this file.
- `apps/mac/codans/Notifications/InboxStore.swift` — `@MainActor @Observable` store. No code edits; M7 references it through SwiftUI `@Environment(InboxStore.self)`.
- `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` — Existing `TestStore` coverage using Swift Testing (`@Test`, `@MainActor`, `LockIsolated` recorders). M6 augments with the new reducer branches.
- `apps/mac/codans/Tests/RootFeatureTests.swift` — Covers the Root reducer; M9 prunes any assertions that reference the deleted `SidebarMode` / `.sidebarModeChanged` / `state.inbox`.
- `apps/mac/CodansCoreTests/NotificationInboxAggregationTests.swift` — Existing pure-aggregation coverage. M9 adds one case mirroring the sidebar's concrete call pattern.

Terms of art (defined where first used in this plan):

- **Space-switch choreography** — the three-step sequence the sidebar reducer runs when `.spaceRowTapped` fires with a different Space than the current one: (1) write the outgoing Space's `lastActiveWorktreeID`, (2) call `selectSpace(newID)`, (3) either call `selectWorktree(newSpace.lastActiveWorktreeID, ...)` if that worktree still exists or clear the stale pointer and let the existing fallback to `Project.selectedWorktreeID` take effect.
- **Hover chrome** — the `+` / `⋯` buttons on a Project section header that only appear while the mouse is over the row. Implemented via SwiftUI's `.onHover` + per-row `@State var isHovering`.
- **Stub sheet** — a SwiftUI `.sheet` whose body is intentionally a placeholder (spec Won't-Have). The action path presenting and dismissing it is fully exercised; the body contains a title, a one-line TODO explanation, and a `Done` button that dismisses.
- **Delegate action (TCA)** — a nested action enum inside a child reducer (`HierarchySidebarFeature.Action.Delegate`) that the parent `RootFeature` pattern-matches in its own reducer to route side effects. The child emits it; the child's own reducer returns `.none` for delegates so only the parent reacts.
- **Snapshot-scoped index** — a `[PaneID: WorktreeID]` dictionary built once per SwiftUI `body` pass from the current catalog snapshot, reused by multiple aggregation calls inside that pass to avoid the per-call rebuild cost called out in `NotificationInboxAggregation.swift`'s doc-comments.

## Plan of Work

The work is organized as ten milestones, sliced vertically so each milestone ends on a green build + passing tests. Milestones M1–M4 add the plumbing the sidebar will consume; M5–M7 are the core feature implementation; M8 wires the integration; M9 fixes collateral tests; M10 verifies end-to-end and opens the PR. Commits land one per milestone via `/commit` so review can step through the stack.

### Milestone 1: HierarchyManager and HierarchyClient gain renameProject + setSpaceLastActiveWorktree

At the end of this milestone the feature reducer will be able to call `hierarchyClient.renameProject(projectID, inSpace: spaceID, name: "New")` and `hierarchyClient.setSpaceLastActiveWorktree(spaceID, worktreeID)` without touching `HierarchyManager` directly. The manager's existing mutation shape (`findProjectIndices` + `store.scheduleSave(catalog)`) extends cleanly.

Edit `apps/mac/codans/Runtime/HierarchyManager.swift`. Add the following method in the `// MARK: - Project mutations` block, immediately after `func removeProject`:

```swift
func renameProject(_ id: ProjectID, in spaceID: SpaceID, name: String) throws {
  guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: id, spaceID: spaceID) else {
    throw HierarchyError.notFound("Project \(id)")
  }
  guard catalog.spaces[spaceIndex].projects[projectIndex].name != name else { return }
  catalog.spaces[spaceIndex].projects[projectIndex].name = name
  store.scheduleSave(catalog)
}
```

No trimming / empty-string validation — the reducer does that before calling. Matches `renameSpace`'s contract (empty strings are the caller's problem).

Edit `apps/mac/codans/App/Clients/HierarchyClient.swift`. Insert two closure properties between `removeProject` and `createWorktree` so the Project-mutation group stays contiguous:

```swift
var renameProject: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String
) throws -> Void

var setSpaceLastActiveWorktree: @MainActor @Sendable (
  _ spaceID: SpaceID, _ worktreeID: WorktreeID?
) -> Void
```

In the `live(manager:)` initializer add the two corresponding forwarders. In both `liveValue` and `testValue` static properties add the matching stubs — `fatalError("HierarchyClient.liveValue not configured")` and `unimplemented("HierarchyClient.renameProject")` / `unimplemented("HierarchyClient.setSpaceLastActiveWorktree")`. Pattern is identical to existing entries; no new file.

Extend `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` with one smoke test that `renameProject` forwarding works (will be superseded by reducer tests in M6 but serves as the dependency-shape check here). Skip until M6 if the reducer integration already covers it.

Acceptance: build `codans` scheme succeeds; the new closures appear in the client definition and testValue; `xcodebuild test -scheme codans` still passes (no regressions).

### Milestone 2: FinderClient dependency

After this milestone the reducer can call `finderClient.reveal(path)` and the live implementation opens Finder to the given directory.

Create `apps/mac/codans/App/Clients/FinderClient.swift`:

```swift
import AppKit
import ComposableArchitecture
import Foundation

/// Thin TCA dependency over NSWorkspace.activateFileViewerSelecting. Exists so
/// HierarchySidebarFeature can dispatch a "Reveal in Finder" action without
/// importing AppKit into the reducer and so TestStore can verify the call path.
nonisolated struct FinderClient: Sendable {
  var reveal: @MainActor @Sendable (_ path: String) -> Void
}

extension FinderClient: DependencyKey {
  static let liveValue = FinderClient(
    reveal: { path in
      let url = URL(fileURLWithPath: path)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  )

  static let testValue = FinderClient(
    reveal: unimplemented("FinderClient.reveal")
  )
}

extension DependencyValues {
  var finderClient: FinderClient {
    get { self[FinderClient.self] }
    set { self[FinderClient.self] = newValue }
  }
}
```

`liveValue` is a concrete bridge rather than the `fatalError(...)` pattern used by clients that need runtime wiring — `NSWorkspace.shared` is always available on macOS so we avoid unnecessary `.withDependencies` ceremony. Follows the "pattern matches need, not ritual" principle in CLAUDE.md.

Add the new file to `apps/mac/Project.swift`'s `codans` target `buildableFolders` if the existing `codans/App/Clients` folder isn't already recursively included — check by running `xcodebuild -workspace codans.xcworkspace -scheme codans -list` after `make mac-generate`. In practice the folder is buildable (see T0 adding `HierarchyClient` there without Project.swift edits); expect no change.

Acceptance: `make mac-generate && xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans -configuration Debug build` succeeds.

### Milestone 3: Catalog.panelWorktreeIndex() becomes public

After this milestone `HierarchySidebarView` can build the `[PaneID: WorktreeID]` index once per render pass and feed it into inline aggregation code, amortizing the rebuild across Worktree and Project dots.

Edit `apps/mac/CodansCore/Notifications/NotificationInboxAggregation.swift`. Change:

```swift
extension Catalog {
  nonisolated func panelWorktreeIndex() -> [PaneID: WorktreeID] {
```

to:

```swift
extension Catalog {
  /// Public so render-hot callers can build the index once per snapshot and
  /// feed it into inline aggregation, sidestepping the per-call rebuild the
  /// `NotificationInbox.*(forWorktree:in:)` helpers do. Keep using the helpers
  /// when you only need one or two lookups; reach for this when you're
  /// iterating over many worktrees/projects in the same render pass.
  public nonisolated func panelWorktreeIndex() -> [PaneID: WorktreeID] {
```

The two resolver helpers `worktreeIDs(inProject:)` / `worktreeIDs(inSpace:)` stay `internal` — they're internal-only conveniences.

Acceptance: `xcodebuild -scheme CodansCore build` succeeds and `xcodebuild test -scheme CodansCore` passes. Touching accessibility only.

### Milestone 4: nextUntitledSpaceName pure helper

After this milestone the sidebar reducer computes unique names for `+ New Space` without touching disk; four unit tests cover the naming rule.

Append to `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` (file-private, below the reducer struct):

```swift
/// Returns the smallest-index unused "Untitled Space [N]" name given the
/// current list of Spaces. Treats bare "Untitled Space" as the N=1 slot;
/// the first new Space gets bare, the second gets "Untitled Space 2", and
/// so on, filling holes before extending the tail.
///
/// Pure. No disk I/O, no MainActor. Exposed to tests via `@testable import`.
func nextUntitledSpaceName(in spaces: [Space]) -> String {
  let bare = "Untitled Space"
  var occupied: Set<Int> = []
  for space in spaces {
    if space.name == bare {
      occupied.insert(1)
      continue
    }
    guard space.name.hasPrefix(bare + " ") else { continue }
    let suffix = space.name.dropFirst(bare.count + 1)
    // Reject leading zeros / plus signs / whitespace — only a clean positive integer counts.
    guard !suffix.isEmpty,
          suffix.allSatisfy(\.isNumber),
          suffix.first != "0",
          let n = Int(suffix),
          n > 0
    else { continue }
    occupied.insert(n)
  }
  var candidate = 1
  while occupied.contains(candidate) { candidate += 1 }
  return candidate == 1 ? bare : "\(bare) \(candidate)"
}
```

Add tests in `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` (same file, new `@Suite` or top-level `@Test`s; match existing style with standalone `@Test func xxx()` declarations):

1. Empty catalog → `"Untitled Space"`.
2. One `Space(name: "Untitled Space")` → `"Untitled Space 2"`.
3. `"Untitled Space"` + `"Untitled Space 3"` → `"Untitled Space 2"` (hole fill).
4. `"Untitled Space 2"` only, no bare → `"Untitled Space"` (bare wins).

Acceptance: `xcodebuild test -scheme codans` runs and the four new tests pass.

### Milestone 5: HierarchySidebarFeature reducer expansion

After this milestone the reducer exposes all the new state and actions the view needs, and its reducer body implements every branch — Space switch, worktree-tap with dedup, context menu paths, Project mutations, stub-sheet presentation, Space popover, and delegate emission. No view changes yet.

Edit `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`. Add the new struct types (`AddProjectSheet`, `AddWorktreeSheet`, `RenameProjectSheet`, `PendingWorktreeRemoval`) as top-level declarations inside the same file (keeps them colocated with the feature they serve). Extend `State` with the five new properties from the design doc §State Shape. Add the new `Action` cases from §Action Surface, including `Delegate` and its two cases.

The reducer keeps only `@Dependency(HierarchyClient.self)`. `FinderClient` and `EditorClient` are NOT injected here — side effects for Reveal in Finder and Open in default editor route through `.delegate` to `RootFeature`, which holds those dependencies.

Implement each action branch in the Reduce block. Guidance per branch:

- `.spaceRowTapped(spaceID)` — short-circuit if `hierarchyClient.snapshot().selectedSpaceID == spaceID`. Otherwise capture the outgoing selection (old spaceID + current worktreeID from the snapshot walk), call `hierarchyClient.setSpaceLastActiveWorktree(oldSpaceID, oldWorktreeID)` (the T0 manager-side dedup makes this a cheap no-op if nothing changed), `hierarchyClient.selectSpace(spaceID)`, then compute the new Space's target worktree: if its `lastActiveWorktreeID` is non-nil and still resolves to a Worktree in the catalog snapshot after the select, dispatch `selectWorktree(lastID, projectID, spaceID)` via the client (scanning the new catalog to locate its project); if the pointer is stale, call `setSpaceLastActiveWorktree(spaceID, nil)` to clear and do not send a `selectWorktree` — let the existing `Project.selectedWorktreeID` fallback take over on the next selection observation. All client calls happen on the MainActor synchronously within the action handler; return `.none`.
- `.worktreeRowTapped(worktreeID, inProject: projectID, inSpace: spaceID)` — keep the existing `selectWorktree` forward. Before or after, read `snapshot.spaces.first(where: $0.id == spaceID)?.lastActiveWorktreeID`; if unequal to `worktreeID`, call `setSpaceLastActiveWorktree(spaceID, worktreeID)`. If equal, skip. Return `.none`.
- `.toolbarAddProjectTapped` — set `state.addProjectSheet = .init(spaceID: snapshot.selectedSpaceID!)`. If no Space is selected the action is a no-op (defensive — UI only shows the button inside a Space context). Return `.none`.
- `.toolbarMenuTapped` — `.none` for now; left as an intentional placeholder with a `// TODO(T1-followup)` comment so a future iteration can hang menu items off it.
- `.projectAddWorktreeTapped(projectID, inSpace: spaceID)` — `state.addWorktreeSheet = .init(projectID: projectID, spaceID: spaceID)`.
- `.projectRenameTapped(projectID, inSpace: spaceID, currentName)` — `state.renameProjectSheet = .init(projectID: projectID, spaceID: spaceID, draft: currentName)`.
- `.projectRenameDraftChanged(newDraft)` — `state.renameProjectSheet?.draft = newDraft`.
- `.projectRenameConfirmed` — pull sheet payload; if `trimmed.isEmpty` dismiss without calling the client; otherwise `try? hierarchyClient.renameProject(projectID, inSpace: spaceID, name: trimmed)`; clear `state.renameProjectSheet`.
- `.projectRenameCancelled` — `state.renameProjectSheet = nil`.
- `.projectRemoveTapped(projectID, inSpace: spaceID, name)` — populates `state.pendingProjectRemoval = .init(projectID:, spaceID:, displayName: name)`. Removing a Project removes every Worktree under it, killing their pane processes — same risk class as `Remove Worktree`, so we gate it with the same confirmation pattern (see D8).
- `.projectRemoveConfirmed` — pull payload; `try? hierarchyClient.removeProject(projectID, inSpace: spaceID)`; clear `state.pendingProjectRemoval`.
- `.projectRemoveCancelled` — `state.pendingProjectRemoval = nil`.
- `.worktreeRemoveTapped(worktreeID, inProject, inSpace, name)` — `state.pendingWorktreeRemoval = .init(worktreeID: worktreeID, projectID: projectID, spaceID: spaceID, displayName: name)`.
- `.worktreeRemoveConfirmed` — pull payload; `try? hierarchyClient.removeWorktree(worktreeID, inProject: projectID, inSpace: spaceID)`; clear state.
- `.worktreeRemoveCancelled` — `state.pendingWorktreeRemoval = nil`.
- `.worktreeRevealInFinderTapped(path)` — emit `.delegate(.revealInFinder(path: path))`. The sidebar reducer does NOT hold `@Dependency(FinderClient)`; the dependency lives only on `RootFeature`, matching the editor-open delegate pattern (D2). Both Finder-reveal and editor-open are routed through parent delegation for consistency.
- `.worktreeOpenInDefaultEditorTapped(worktreeID, projectID, path)` — emit `.delegate(.openInDefaultEditor(worktreePath: path, projectID: projectID))`.
- `.addProjectSheetDismissed` / `.addWorktreeSheetDismissed` — clear the corresponding optional.
- `.spaceFooterTapped` — `state.isSpacePopoverPresented.toggle()`.
- `.spacePopoverDismissed` — `state.isSpacePopoverPresented = false`.
- `.spacePopoverSpaceSelected(spaceID)` — dismiss popover and dispatch `.spaceRowTapped(spaceID)` via `.send` so all the switch choreography runs through one branch.
- `.spacePopoverNewSpaceTapped` — compute name via `nextUntitledSpaceName(in: snapshot.spaces)`; call `let newID = hierarchyClient.createSpace(name)`; call `hierarchyClient.selectSpace(newID)`; set `state.isSpacePopoverPresented = false`. No Worktree restore — the new Space is empty by construction.
- `.toggleSpaceExpansion` / `.toggleProjectExpansion` / `.pruneExpansionSets` — unchanged from pre-T1.
- `.delegate` — `.none` (the parent handles it).

Net file delta: one ~250-line feature file becomes a ~450-line one. No test regressions; existing test file still compiles against the expanded `Action` enum because no existing cases are removed.

Acceptance: build `codans` scheme green; existing tests in `HierarchySidebarFeatureTests` still pass (no new assertions yet).

### Milestone 6: HierarchySidebarFeature reducer tests

After this milestone TestStore drives every new action path and asserts correct dependency calls.

Augment `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` with the seven test cases in the design doc §Testing strategy:

1. `spaceSwitchWritesOldAndRestoresNew` — catalog fixture with Space A (W1 selected) and Space B (`lastActiveWorktreeID = W4`); `spaceRowTapped(B)` triggers a recorder chain: `setSpaceLastActiveWorktree(A, W1)`, `selectSpace(B)`, `selectWorktree(W4, Q, B)`.
2. `spaceSwitchWithStaleLastActiveClearsAndFallsBack` — Space B's `lastActiveWorktreeID` is a fresh random `WorktreeID` not in the catalog; assert `setSpaceLastActiveWorktree(B, nil)` is called and `selectWorktree` is NOT called (`Project.selectedWorktreeID` path handles the rest via the existing snapshot observation).
3. `worktreeRowTappedFirstTimeWritesLastActive` — recorder confirms one `setSpaceLastActiveWorktree(spaceID, worktreeID)` call + one `selectWorktree` call.
4. `worktreeRowTappedSecondTimeDoesNotRewriteLastActive` — two consecutive identical taps; recorder counts: `setSpaceLastActiveWorktree` == 1, `selectWorktree` == 2 (selecting the same worktree twice is still a legitimate UI action).
5. `worktreeContextMenuPaths` — three sub-tests:
   - `worktreeRemoveTapped` populates `pendingWorktreeRemoval`; `worktreeRemoveConfirmed` calls `removeWorktree` once.
   - `worktreeRevealInFinderTapped` emits `.delegate(.revealInFinder(path:))`.
   - `worktreeOpenInDefaultEditorTapped` emits `.delegate(.openInDefaultEditor(worktreePath:projectID:))`.
6. `projectRenamePath` — `projectRenameTapped` populates sheet; `projectRenameDraftChanged("New")` mutates draft; `projectRenameConfirmed` calls `renameProject(_, _, "New")` and clears sheet; `projectRenameCancelled` alone clears without calling.
7. `newSpaceCreation` — three sub-fixtures mirroring §New-Space naming: empty / one bare / bare + N=3. Recorder asserts `createSpace(expectedName)` + `selectSpace(newID)` + `isSpacePopoverPresented == false`.

Each test follows the existing Swift Testing pattern (`@MainActor`, `@Test func xxx() async`, `LockIsolated<...>()` recorders, `withDependencies` overrides). `hierarchyClient.snapshot` gets overridden to return a hand-crafted `Catalog` per case; all other closures are overridden with recorders as needed.

Acceptance: `xcodebuild test -scheme codans` runs and all seven new tests pass in addition to the existing four.

### Milestone 7: HierarchySidebarView rewrite

After this milestone the sidebar UI matches the spec. This is the largest single file change but mostly mechanical SwiftUI composition.

Rewrite `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`. The target structure is the one laid out in the design doc §View Composition:

```
VStack(spacing: 0) {
  sidebarToolbar
  Divider()
  List { ... } (active Space only)
  Divider()
  spaceFooter
}
.popover(isPresented: ...) { spacePopover }
.sheet(item: addProjectSheet) { _ in addProjectStub }
.sheet(item: addWorktreeSheet) { _ in addWorktreeStub }
.sheet(item: renameProjectSheet) { payload in renameProjectSheetBody(payload) }
.confirmationDialog(item: pendingWorktreeRemoval) { ... }
```

Specifics to get right:

1. Add `@Environment(InboxStore.self) private var inboxStore` alongside the existing `@Environment(HierarchyManager.self)`. This will fail to resolve until M7-follower adds `.environment(inboxStore)` in `ContentView`; write M7 as a single commit that includes that line so the worktree builds.
2. Build the snapshot-scoped index at the top of `body`:
   ```swift
   let catalog = hierarchyManager.catalog
   let panelIndex = catalog.panelWorktreeIndex()
   let inbox = inboxStore.inbox
   ```
   Reuse `panelIndex` inside inline unread-count helpers defined as private `func unreadCount(forWorktree:) -> Int` / `func projectHasUnread(_:) -> Bool` methods on the view struct (they capture the index closure-free via `self` — acceptable for SwiftUI `View` methods).
3. Project section: each Project renders as a custom `DisclosureGroup` whose expanded binding reads/writes `store.expandedProjectIDs`. The label is a button row containing `Text(project.name)` + `Spacer()` + hover chrome. Hover state is per-row; use a wrapping `ProjectHeaderRow` subview with `@State private var isHovering = false` and `.onHover { isHovering = $0 }`. The hover chrome is `HStack { addButton; menuButton }.opacity(isHovering ? 1 : 0)` — that keeps layout stable instead of collapsing width as the buttons appear/disappear.
4. Worktree row: leading SF Symbol is `circle.fill` when `worktree.id == currentSelection.worktreeID`, else `circle`. Font scaled down (`.font(.caption)`) so the dot is small. Trailing unread dot uses a `Circle().fill(.tint).frame(width: 6, height: 6)` rendered only when `unreadCount(forWorktree: worktree.id) > 0`. Wrap the row's `Button` in `.contextMenu { ... }` with three items: "Remove Worktree" (destructive role, dispatches `worktreeRemoveTapped`), "Reveal in Finder", "Open in default editor". Pass the worktree path and name into the actions.
5. Project header hover chrome: the `+` button dispatches `.projectAddWorktreeTapped`. The `⋯` is a `Menu` with two items — "Rename Project" (dispatches `.projectRenameTapped(..., currentName: project.name)`) and "Remove Project" (dispatches `.projectRemoveTapped`). Styling: `Menu { ... } label: { Image(systemName: "ellipsis").accessibilityLabel("Project options") }.menuStyle(.borderlessButton)`.
6. Empty-Space state: when `activeSpace.projects.isEmpty`, render a centered `VStack` with a title "No projects yet." and a prominent `Button("Add Project", systemImage: "plus") { store.send(.toolbarAddProjectTapped) }.buttonStyle(.borderedProminent)`.
7. Sidebar toolbar: horizontal `HStack` inside `HStack { Button("+ Add Project") { ... }; Spacer(); Menu { ... } label: { ellipsis } }.padding(.horizontal, 12).padding(.vertical, 8)`. The menu is a stub with no items (just `EmptyView` inside — an empty `Menu` still renders as a disabled dropdown; acceptable placeholder per §Non-Goals). Alternative: omit the button entirely and add it back when T1-follow-up defines items.
8. Space footer: `HStack` with `Image(systemName: "square.stack.3d.up")` + `Text(activeSpace?.name ?? "No Space")` + `Spacer()` + `Image(systemName: "chevron.down")`. Wrap in a `Button { store.send(.spaceFooterTapped) } label: { ... }.buttonStyle(.plain).padding(12)`. The `.popover(isPresented: $store.isSpacePopoverPresented.toBinding(on: store))` attaches to this button. SwiftUI's `@Bindable var store` already supports `$store.isSpacePopoverPresented` directly if we mark the property in state as `@Observable`-observable — which `@ObservableState` does. No custom binding shim.
9. Space popover content: `VStack(alignment: .leading, spacing: 0) { ForEach(catalog.spaces) { row }; Divider(); newSpaceRow }.padding(6).frame(minWidth: 220)`. Each `row` is a `Button` dispatching `.spacePopoverSpaceSelected(space.id)` with a leading `Image(systemName: space.id == activeSpaceID ? "checkmark" : "").frame(width: 14)` and the space name.
10. Stub sheets: `AddProjectStubSheet` / `AddWorktreeStubSheet` are a `VStack { Text("Add Project (coming soon)").font(.headline); Text("UI ships in a follow-up."); Button("Done") { store.send(.addProjectSheetDismissed) } }.padding(24).frame(width: 320, height: 140)`.
11. Rename-Project sheet: `TextField("Project name", text: <binding>)` bound via `Binding(get: { store.renameProjectSheet?.draft ?? "" }, set: { store.send(.projectRenameDraftChanged($0)) })` + `HStack { Button("Cancel") { store.send(.projectRenameCancelled) }; Button("Rename") { store.send(.projectRenameConfirmed) }.keyboardShortcut(.defaultAction).disabled(emptyDraft) }`.
12. Confirmation dialogs: use `.confirmationDialog("Remove Worktree", isPresented: ...)` with `Button("Remove", role: .destructive) { store.send(.worktreeRemoveConfirmed) }`. Bind `isPresented` to a computed `Binding` over `state.pendingWorktreeRemoval != nil`.

Commit in M7 also updates `apps/mac/codans/App/ContentView.swift` with:
```swift
.environment(hierarchyManager)
.environment(settingsStore)
.environment(inboxStore)
```
and threads `inboxStore` down from `CodansApp.bringUp()` where `ContentView` is instantiated. Check `CodansApp.swift` for the instantiation site — T0 already wires `hierarchyManager` and `settingsStore` the same way; follow the pattern.

Add three `#Preview` blocks at the bottom of the file (empty Space, populated with unread, Space popover open). These don't need to assert anything; they serve as smoke previews and exercise the view's dependency on an `InboxStore` fixture.

Acceptance: `make mac-generate && make mac-build` succeeds. Running the app shows the new sidebar layout. `xcodebuild test -scheme codans` still passes.

### Milestone 8: RootFeature delegate routing + SidebarMode deletion

After this milestone the sidebar's delegate actions produce real effects and all T0-era dead plumbing is gone.

Edit `apps/mac/codans/App/Features/Root/RootFeature.swift`:

1. Delete `nonisolated enum SidebarMode: String, Equatable, CaseIterable, Sendable { case hierarchy; case inbox }` and the long comment block preceding it (lines 15-26).
2. Remove `var sidebarMode: SidebarMode = .hierarchy` from `State`.
3. Remove `var inbox: InboxSidebarFeature.State = .init()` from `State` (plus its doc-comment block).
4. Remove `case sidebarModeChanged(SidebarMode)` from `Action`.
5. Remove `case inbox(InboxSidebarFeature.Action)` from `Action`.
6. Remove `Scope(state: \.inbox, action: \.inbox) { InboxSidebarFeature() }` from the body.
7. Remove the two `case .inbox(...)` branches from the `Reduce` switch (including the `deeplinkRequested` placeholder no-op).
8. Remove `case .sidebarModeChanged(let mode):` branch.
9. Add `@Dependency(FinderClient.self) private var finderClient` under the existing dependency declarations.
10. Add a new switch branch catching the sidebar delegate. It's a nested case — `case .sidebar(.delegate(let delegateAction)):` — so the existing `case .sidebar:` catch-all (which returns `.none`) must come *after* this more-specific one.

    `EditorFeature.Action.openRequested(editorID:worktreePath:projectID:)` takes a **non-optional** `EditorID` (see `apps/mac/codans/App/Features/Editor/EditorFeature.swift:58`). The sidebar delegate carries no editor ID — "Open in default editor" implies "resolve the chain first". We inline the resolution in the delegate handler. T2 will later hoist this into an `EditorFeature.resolveDefault(...)` helper when it rebases; for now, keep it inline with a one-line comment pointing to that follow-up.

    Resolution chain (mirrors `WorktreeHeaderOpenButton.currentDefaultLabel` at `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift:106`): per-Project `defaultEditor` → `state.editor.globalDefault` → Finder. Each tier is accepted only if a matching descriptor is in `state.editor.descriptors` and reports `isInstalled == true`; otherwise fall through.

    ```swift
    case .sidebar(.delegate(.openInDefaultEditor(let path, let projectID))):
      // Inline default-editor resolution: project override → global default → Finder.
      // T2 will hoist this into EditorFeature.resolveDefault when it rebases.
      let descriptors = state.editor.descriptors
      let globalDefault = state.editor.globalDefault
      let overrideID: EditorID? = projectID.flatMap { pid in
        let catalog = hierarchyClient.snapshot()
        for space in catalog.spaces {
          for project in space.projects where project.id == pid {
            return project.defaultEditor
          }
        }
        return nil
      }
      func installed(_ id: EditorID?) -> EditorID? {
        guard let id,
              descriptors.contains(where: { $0.id == id && $0.isInstalled })
        else { return nil }
        return id
      }
      let resolved: EditorID = installed(overrideID)
        ?? installed(globalDefault)
        ?? EditorRegistry.finderID
      return .send(.editor(.openRequested(
        editorID: resolved,
        worktreePath: path,
        projectID: projectID
      )))

    case .sidebar(.delegate(.revealInFinder(let path))):
      let client = finderClient
      return .run { _ in
        await MainActor.run { client.reveal(path) }
      }
    ```
    `FinderClient.reveal` is `@MainActor @Sendable`, so the `MainActor.run` hop is mandatory from within the effect closure.

    This branch depends on `state.editor.descriptors` and `state.editor.globalDefault` being populated. Both are hydrated by `EditorFeature.onAppear`, which `WorktreeHeaderOpenButton.task` dispatches lazily on first view mount. If the user triggers the context menu before the header has ever been rendered, `descriptors` will be empty and the resolution chain falls through to `EditorRegistry.finderID` — always installed, safe. M8 originally added `return .send(.editor(.onAppear))` to `RootFeature.onLaunch`'s `.merge(...)` to prime the cache eagerly, but **this was reverted in M9** (see Decision Log D11): the live `EditorService.describe()` path runs `MainActor.assumeIsolated { ... }` on a background Task, and under the xctest host that assertion trips `dispatch_assert_queue_fail` (Signal 5) during test bootstrap before any test runs. The `finderID` fallback covers the worst-case context-menu-before-header-render path; investigating a MainActor-safe way to prime the cache (e.g. await-based refresh off the view's `.task`) is a follow-up.

    Add the `EditorRegistry.finderID` constant in `apps/mac/codans/App/Clients/Editor/EditorRegistry.swift`:

    ```swift
    extension EditorRegistry {
      /// Canonical ID for the Finder builtin. Always-installed; the ultimate
      /// fallback in every default-editor resolution chain.
      static let finderID: EditorID = "finder"
    }
    ```

Edit `apps/mac/codans/App/ContentView.swift`: no structural change is needed for M8 — `ContentView` didn't read `sidebarMode` or `state.inbox` directly. Re-verify by searching the file after the RootFeature edits and fixing any dangling reference.

`CodansApp.swift` currently passes `.finderClient` nowhere; the `DependencyKey.liveValue` default is non-fatal (it's a concrete `NSWorkspace` bridge), so no `.withDependencies { $0.finderClient = ... }` line is strictly required. Leave it as the dependency-system default. Document this with a one-line comment near the other client registrations so future maintainers can see the intentional omission.

Acceptance: full workspace build succeeds; `xcodebuild test -scheme codans` passes.

### Milestone 9: Collateral test sweep

After this milestone every test target builds and passes; no references to deleted RootFeature surface area remain.

Edit `apps/mac/codans/Tests/RootFeatureTests.swift`: delete any `@Test` that references `sidebarMode`, `.sidebarModeChanged`, `state.inbox`, or `.inbox(...)` actions. Keep any tests that cover other Root reducer behavior (onLaunch streams, selectionChanged → gitViewer forward, inspectorVisibilityToggled). Search by `grep -n "sidebarMode\|sidebar.*Mode\|\\.inbox\\|state.inbox" apps/mac/codans/Tests/RootFeatureTests.swift` and remove one test at a time, re-running the scheme after each deletion to confirm no other tests rely on a shared fixture.

Edit `apps/mac/CodansCoreTests/NotificationInboxAggregationTests.swift`: add one new `@Test` `aggregationMatchesSidebarRenderCallPattern` that rebuilds the `panelWorktreeIndex` once from the catalog fixture and then calls `unreadCount(forWorktree:)` + `hasUnread(forProject:)` for every Worktree / Project in the fixture, asserting the counts match an expected tuple. Serves as a canary that the public-visibility bump actually works through the module boundary.

Acceptance: all three schemes green (`CodansCore`, `codans`, `codans`). `make mac-lint` passes.

### Milestone 10: Verify + PR

After this milestone the branch is pushed and a PR is open against `feature/main-window`.

1. Run `make mac-generate` to refresh the Tuist-generated workspace (in case a new file was added and the project didn't pick it up in earlier milestones).
2. Run `make mac-lint` (must be clean). If T0-era `async_without_await` suppressions are still in place that's fine.
3. Run the three test schemes in parallel:
   ```
   xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme CodansCore -configuration Debug
   xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans -configuration Debug
   xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme CodansKit -configuration Debug
   ```
4. Smoke-test the app manually: `make mac-run-app`. Verify by hand: Space footer popover opens, clicking `+ New Space` creates `"Untitled Space 2"` the second time, switching between two Spaces (each with a Worktree) restores the last-active Worktree, right-click a Worktree → Remove shows confirmation, Reveal opens Finder, Open in default editor opens the configured editor. Unread dots: write a test notification via `codans` CLI or by manipulating the inbox file directly — acceptable to skip this if the bell integration is deferred to T2's own verification.
5. Stage and `/commit` any last changes per milestone (if not already committed each milestone).
6. `git push -u origin feat/mw-sidebar`.
7. `gh pr create --base feature/main-window --title "T1: sidebar redesign + Space switcher" --body-file <path>` — body references the design doc and this ExecPlan, lists T0 contracts consumed (Space.lastActiveWorktreeID, notification aggregation helpers, HierarchyManager setters), lists integration points with T2/T3 (none; HierarchySidebarView is isolated), and includes the verification transcript.
8. Post `PR_READY: <url>` to master.

## Concrete Steps

Run from the worktree root `/Users/wanggang/.worktree/repos/codans/feat/mw-sidebar`.

Baseline verification before starting (to catch pre-existing breakage):
```
make mac-generate
make mac-lint
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans -configuration Debug -quiet
```
Expected: lint clean (T0 suppressions are in place); `codans` scheme passes with 11 `HierarchySidebarFeature` tests.

After each milestone:
```
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme <scheme> -configuration Debug -quiet
```
Expected output tail: `** TEST SUCCEEDED **`.

Commit after each milestone via `/commit` — message format:
```
feat(mw-t1): <milestone title>
```

At M10, PR body template:
```
T1 — sidebar redesign + Space switcher

Design: docs/design-docs/mw-t1-sidebar.md
Plan:   docs/exec-plans/0009-mw-t1-sidebar.md

Consumes T0 contracts:
- Space.lastActiveWorktreeID (read + write)
- HierarchyManager.setSpaceLastActiveWorktree
- NotificationInbox.unreadCount/hasUnread (per-Worktree + per-Project)
- Catalog.panelWorktreeIndex (promoted to public in M3)

Coordination:
- T1 merges before T2. T2 rebases over the SidebarMode / .inbox scope deletion.

Verification:
- make mac-lint                     → clean
- xcodebuild test ... CodansCore → ** TEST SUCCEEDED **
- xcodebuild test ... codans    → ** TEST SUCCEEDED **
- xcodebuild test ... CodansKit         → ** TEST SUCCEEDED **

Manual walkthrough: [fill in from M10 step 4].
```

## Validation and Acceptance

The feature is accepted iff **all** of the following hold:

1. `make mac-lint` exits 0 with no new findings relative to T0's baseline.
2. Each of the three test schemes ends with `** TEST SUCCEEDED **`.
3. `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` contains at least eleven tests (pre-existing four + seven new), all passing.
4. `apps/mac/CodansCoreTests/NotificationInboxAggregationTests.swift` gains one new test and it passes.
5. Manual walkthrough (scripted in M10 step 4) completes without regression. Specifically:
   - Creating a second new Space yields a name `"Untitled Space 2"` distinct from the first.
   - Switching between two Spaces, each holding a distinct selected Worktree, restores the right Worktree on return.
   - Right-click on a Worktree → Remove shows a confirmation; confirming removes the Worktree and its tabs; cancel leaves it alone.
   - Right-click → Reveal opens a Finder window rooted at the Worktree's directory.
   - Right-click → Open in default editor opens the Worktree in the user's configured editor (or Finder fallback).
   - Writing an unread notification whose pane resolves to a Worktree puts a trailing dot on that Worktree row and a dot on its Project header; marking read clears both.
6. PR opens against `feature/main-window` (not `main`). PR description links both `docs/design-docs/mw-t1-sidebar.md` and `docs/exec-plans/0009-mw-t1-sidebar.md`.

## Idempotence and Recovery

- All `xcodebuild test` and `make` commands are re-runnable without side effects beyond build caches.
- `make mac-generate` regenerates the Tuist workspace from `Project.swift`; running it after edits is required but safe — existing derived data is reused.
- If a commit needs to be reworked, prefer a new follow-up commit rather than `git commit --amend`. Pre-commit hooks re-run on each new commit and a failed hook means the commit did not land (no amend trap).
- If the SidebarMode deletion in M8 breaks an integration test in M9 that's not covered by the sweep, the fallback is to add the minimal piece back with a `// TODO(T1-followup): re-evaluate after T2` comment. Do not roll back M8 wholesale — it's the unblock for T2.
- If M7's UI turns out not to match the spec on manual walkthrough (M10 step 4), reopen the design doc before editing — the issue is likely upstream. Record the discrepancy in §Surprises.

## Artifacts and Notes

No prototyping was required — the design doc resolves the trade-offs and every dependency (SwiftUI `.popover` / `.sheet` / `.confirmationDialog`, `NSWorkspace.activateFileViewerSelecting`, `@Observable` environment injection, TCA delegate actions) is already exercised elsewhere in the codebase. Live examples to imitate:

- `WorktreeHeaderOpenButton.swift` for menu composition with disabled states.
- `InboxSidebarView.swift` for a `List` with `.contextMenu` and `.swipeActions` (style template; we keep only `.contextMenu`).
- `ContentView.swift` for `.sheet(item: $store.scope(...))` — our plain `Optional`-backed sheets use the simpler `.sheet(item:)` form, but the integration into `ContentView` is analogous.

The worktree's base branch is `feature/main-window` — PRs target it, not `main`.

## Interfaces and Dependencies

In `apps/mac/codans/Runtime/HierarchyManager.swift`, the following method must exist:

```swift
func renameProject(_ id: ProjectID, in spaceID: SpaceID, name: String) throws
```

In `apps/mac/codans/App/Clients/HierarchyClient.swift`, the struct gains:

```swift
var renameProject: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String
) throws -> Void

var setSpaceLastActiveWorktree: @MainActor @Sendable (
  _ spaceID: SpaceID, _ worktreeID: WorktreeID?
) -> Void
```

with matching entries in `liveValue`, `testValue`, and `live(manager:)`.

In `apps/mac/codans/App/Clients/FinderClient.swift` (new file):

```swift
nonisolated struct FinderClient: Sendable {
  var reveal: @MainActor @Sendable (_ path: String) -> Void
}
```

with `DependencyKey.liveValue` bound to `NSWorkspace.activateFileViewerSelecting` and `testValue` bound to `unimplemented("FinderClient.reveal")`. Exposed via `DependencyValues.finderClient`.

In `apps/mac/CodansCore/Notifications/NotificationInboxAggregation.swift`:

```swift
extension Catalog {
  public nonisolated func panelWorktreeIndex() -> [PaneID: WorktreeID]
}
```

In `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`, at file scope:

```swift
// File-private pure helper. Exposed to tests via @testable import.
func nextUntitledSpaceName(in spaces: [Space]) -> String
```

The reducer's `State` must gain `isSpacePopoverPresented`, `addProjectSheet`, `addWorktreeSheet`, `renameProjectSheet`, `pendingWorktreeRemoval`, `pendingProjectRemoval` (added mid-plan when symmetry demanded it), all `Equatable`.

The reducer's `Action` must gain every case listed in §Action Surface of the design doc plus the Project-remove-confirmation pair. The nested `enum Delegate: Equatable` has two cases: `openInDefaultEditor(worktreePath: String, projectID: ProjectID?)` and `revealInFinder(path: String)`.

In `apps/mac/codans/App/Features/Root/RootFeature.swift`:

- The `SidebarMode` enum, `state.sidebarMode`, `state.inbox`, the `.inbox` `Scope`, `case sidebarModeChanged`, and `case inbox(...)` branches are **removed**.
- A `@Dependency(FinderClient.self)` is added.
- Two new reducer branches handle `.sidebar(.delegate(.openInDefaultEditor(...)))` and `.sidebar(.delegate(.revealInFinder(...)))`. The open-in-editor branch inlines the per-Project-override → global-default → `EditorRegistry.finderID` resolution chain and dispatches `.editor(.openRequested(editorID: resolved, ...))` — `editorID` is non-optional (D9).
- `.onLaunch` was planned to gain a `.send(.editor(.onAppear))` in its `.merge(...)` to prime `state.editor.descriptors` / `.globalDefault` before the sidebar's first context-menu invocation. **Reverted in M9** due to an xctest-host crash on `LiveEditorService.describe`'s `MainActor.assumeIsolated` from a background Task (see D11). The sidebar's context-menu "Open in default editor" path already tolerates an empty descriptor cache by falling through to `EditorRegistry.finderID` (always installed). Follow-up: investigate a MainActor-safe eager prime (e.g. dispatched from the view's `.task` rather than the reducer's launch effect).

In `apps/mac/codans/App/Clients/Editor/EditorRegistry.swift`, the extension adds:

```swift
extension EditorRegistry {
  static let finderID: EditorID = "finder"
}
```

In `apps/mac/codans/App/ContentView.swift`, `.environment(inboxStore)` is added to the modifier chain attached to `NavigationSplitView`. `CodansApp.bringUp()` passes `inboxStore` into the `ContentView(...)` initializer alongside `hierarchyManager` and `settingsStore` — the `ContentView` init signature gains an `inboxStore: InboxStore` parameter.
