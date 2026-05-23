import ComposableArchitecture
import Foundation
import OSLog
import Observation
import TouchCodeCore

/// Logger for the background reconcile path. Matches the project's
/// `com.touch-code.<area>` subsystem convention (see SettingsStore,
/// CatalogStore, the IPC handlers, etc.). Category `reconcile` isolates
/// these events from the rest of the hierarchy subsystem so operators
/// can filter with `log stream --predicate 'category == "reconcile"'`.
private let reconcileLogger = Logger(
  subsystem: "com.touch-code.hierarchy",
  category: "reconcile"
)

/// Diagnostics for the user-script dispatch path. Useful when a user
/// configures `.split` / `.focused` and gets a fresh tab instead — the
/// breadcrumb names which fallback fired and why.
private let runScriptLogger = Logger(
  subsystem: "com.touch-code.hierarchy",
  category: "runScript"
)

/// TCA dependency-injection bridge over `HierarchyManager`. Features depend
/// on this struct's closures, not on the manager directly; the `liveValue`
/// binds each closure to a concrete `HierarchyManager` instance at app
/// startup via `.withDependencies`.
///
/// Narrow by design: every command is a one-line forward into the manager,
/// and `snapshot` plus `selectionChanges` provide the read paths TCA
/// features need without exposing the `@Observable` manager surface.
///
/// **M2 surface inversion**: per `docs/exec-plans/project-tags.md` §M2.4 the
/// append-only convention is waived for this milestone. Space-named closures
/// are removed and Tag-shaped closures replace them. Append-only resumes in
/// M5+.
nonisolated struct HierarchyClient: Sendable {
  // MARK: - Tag mutations

  /// Appends a new Tag and returns its id. Persists.
  var createTag: @MainActor @Sendable (_ name: String, _ color: TagColor) -> TagID
  /// Renames the Tag in place. Silent no-op for unknown ids / unchanged values.
  var renameTag: @MainActor @Sendable (_ id: TagID, _ name: String) -> Void
  /// Recolors the Tag. Silent no-op for unknown ids / unchanged values.
  var recolorTag: @MainActor @Sendable (_ id: TagID, _ color: TagColor) -> Void
  /// Removes the Tag and cascades: strips the id from every project's
  /// `tagIDs`, normalizes `activeTagFilter` (drops the id from `.tags(set)`;
  /// empty set falls back to `.all`). Silent no-op for unknown ids.
  var removeTag: @MainActor @Sendable (_ id: TagID) -> Void
  /// Replaces the Project's tag membership.
  var setProjectTags:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ tags: Set<TagID>
    ) -> Void
  /// Replaces the catalog-wide active tag filter. Empty `.tags(set)` is
  /// normalized to `.all`.
  var setActiveTagFilter: @MainActor @Sendable (_ filter: TagFilter) -> Void

  // MARK: - Project mutations

  var addProject:
    @MainActor @Sendable (
      _ name: String, _ rootPath: String, _ gitRoot: String?
    ) -> ProjectID
  var removeProject: @MainActor @Sendable (_ projectID: ProjectID) throws -> Void
  var renameProject:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ name: String
    ) throws -> Void

  // MARK: - Worktree mutations

  var createWorktree:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ name: String, _ path: String, _ branch: String?
    ) throws -> WorktreeID
  var removeWorktree:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  var selectProject: @MainActor @Sendable (_ id: ProjectID?) -> Void
  var selectWorktree:
    @MainActor @Sendable (
      _ id: WorktreeID?, _ inProject: ProjectID
    ) throws -> Void

  var createTab:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ name: String?
    ) throws -> TabID
  var closeTab:
    @MainActor @Sendable (
      _ id: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void
  var selectTab:
    @MainActor @Sendable (
      _ id: TabID?, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  // MARK: - Tab mutations (tab-bar uplift)

  var renameTab:
    @MainActor @Sendable (
      _ id: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ name: String?
    ) throws -> Void
  var setTabColor:
    @MainActor @Sendable (
      _ id: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ color: TabColor?
    ) throws -> Void
  var reorderTabs:
    @MainActor @Sendable (
      _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ orderedIDs: [TabID]
    ) throws -> Void
  var closeOtherTabs:
    @MainActor @Sendable (
      _ keeping: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void
  var closeTabsToRight:
    @MainActor @Sendable (
      _ of: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void
  var closeAllTabs:
    @MainActor @Sendable (
      _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void
  var selectAdjacentTab:
    @MainActor @Sendable (
      _ direction: TabAdjacency,
      _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> TabID?

  // MARK: - Runtime state (tab-bar uplift, M3)

  /// Read path for the chip's dirty (running-command) spinner. Always
  /// returns `false` until a writer — likely a C3 hook — starts calling
  /// `markPaneRunning` / `markPaneIdle`. The reader is exposed now so
  /// `TabChipLabel` can bind to it without another feature sweep.
  var tabIsDirty: @MainActor @Sendable (_ tabID: TabID) -> Bool
  /// Worktree-scoped variant of `tabIsDirty`. Sidebar rows surface a busy
  /// glyph when any pane in any tab of the worktree is marked running.
  var worktreeIsDirty: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Bool
  /// Returns the Pane the user most recently focused in `tabID`, or nil.
  /// Mirrors `HierarchyManager.lastFocusedPane(in:)`.
  var lastFocusedPane: @MainActor @Sendable (_ tabID: TabID) -> PaneID?
  /// Dormant writer — calls `HierarchyManager.markPaneRunning`. No caller
  /// today; lands a real writer with the C3 hooks plan.
  var markPaneRunning: @MainActor @Sendable (_ paneID: PaneID) -> Void
  /// Dormant writer — calls `HierarchyManager.markPaneIdle`. No caller
  /// today; lands a real writer with the C3 hooks plan.
  var markPaneIdle: @MainActor @Sendable (_ paneID: PaneID) -> Void

  var openPane:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ workingDirectory: String, _ initialCommand: String?
    ) throws -> PaneID
  var splitPane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: SplitTree<PaneID>.NewDirection,
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ workingDirectory: String, _ initialCommand: String?
    ) throws -> PaneID
  var closePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ tabID: TabID, _ inWorktree: WorktreeID,
      _ inProject: ProjectID
    ) throws -> Void
  var focusPane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ tabID: TabID, _ inWorktree: WorktreeID,
      _ inProject: ProjectID
    ) throws -> Void
  /// View-level first-responder focus. Unlike `focusPane` this does
  /// NOT mutate the catalog (no zoom flag, no persistence) — it only
  /// asks the runtime to call `makeFirstResponder` on the pane's
  /// surface view. Used post-split (focus the new pane) and post-close
  /// (transfer focus to the surviving sibling per ghostty's policy).
  var focusSurfaceView: @MainActor @Sendable (_ paneID: PaneID) -> Void
  var resizeSplit:
    @MainActor @Sendable (
      _ path: SplitTree<PaneID>.Path, _ ratio: Double,
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  // Per-Project editor / worktrees-directory writers were retired in v3: the values
  // live on `Settings.projects[pid]` and every consumer routes through
  // `SettingsStore.mutateProject` (`SettingsWriter.setProjectDefaultEditor` /
  // `SettingsWriter.setProjectWorktreesDirectory`). HierarchyClient is read-only for
  // per-Project preferences (see `snapshot` / `kind`).

  /// Flips `Worktree.diffInspectorVisible` for the given Worktree. Silent no-op on
  /// unknown `worktreeID`; persists through the standard debounced
  /// `store.scheduleSave(catalog)` pipeline (T0 §D5). Consumed by the T2
  /// Header Git Viewer toggle and by T3's overlay presentation binding.
  var setWorktreeDiffInspectorVisible:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ visible: Bool
    ) -> Void

  var snapshot: @MainActor @Sendable () -> Catalog

  /// Emits whenever the selection chain `(projectID, worktreeID)` changes
  /// in the catalog. Deduped against the previous snapshot. Consumers
  /// (C6 inbox, C7 git-viewer, M4 detail-column swap) subscribe without
  /// needing a reference to the `@Observable` `HierarchyManager`. The stream
  /// finishes only when the engine shuts down.
  var selectionChanges: @MainActor @Sendable () -> AsyncStream<HierarchySelection>

  // MARK: - Worktree Management additions (feat/worktree-mgmt)

  /// Flips `Worktree.archived` for the given Worktree.
  var setWorktreeArchived:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ archived: Bool
    ) throws -> Void

  /// Flips `Worktree.isPinned` for the given Worktree. Silent for unknown ids / unchanged
  /// values. Persists via the standard debounced save pipeline.
  var setWorktreePinned:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ isPinned: Bool
    ) -> Void

  /// Flips `Project.isExpanded` (sidebar disclosure state). Silent no-op for
  /// unknown ids and unchanged values. Persists through the standard debounced
  /// save pipeline so the open / closed choice survives restart.
  var setProjectExpanded:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ isExpanded: Bool
    ) -> Void

  /// Reads the Project's git root, calls `GitWorktreeClient.lsWorktrees`
  /// off the main actor, and merges on-disk worktrees into the catalog.
  /// Append-only — never removes catalog rows. Swallows errors. Consumed
  /// by `ProjectReconciler` on feat/project-mgmt.
  var reconcileDiscoveredWorktrees:
    @MainActor @Sendable (
      _ projectID: ProjectID
    ) async -> Void

  /// Catalog-append step for Create Worktree.
  var createWorktreeWithGit:
    @MainActor @Sendable (
      _ projectID: ProjectID,
      _ name: String, _ branch: String, _ path: String
    ) throws -> WorktreeID

  /// End-to-end Remove Worktree. Tears down all surfaces (panes /
  /// notifications) for the worktree, runs the git client's
  /// relocate-then-prune removal, then drops the catalog row. The git
  /// step sidesteps git's "uncommitted changes" and "submodule" guards
  /// by relocating the working dir before pruning, so this is a
  /// single-step destructive call — the caller's first confirmation
  /// dialog is the only protection.
  var removeWorktreeWithGit:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID
    ) async throws -> Void

  /// Forwards `HierarchyManager.runningPaneCount`.
  var runningPaneCount: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Int

  // MARK: - Project Management (pm) — added on feat/project-mgmt.

  /// Transient Project health signal. Written by `ProjectReconciler` only.
  var setProjectLoadState:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ state: ProjectLoadState
    ) -> Void

  /// Reorder Projects at the catalog top level. Mirrors `ForEach.onMove`'s signature.
  var reorderProjects:
    @MainActor @Sendable (
      _ from: IndexSet, _ to: Int
    ) -> Void

  /// Sidebar bottom-bar sort-mode write. Persisted on the catalog;
  /// the manual array is left intact.
  var setProjectSortMode: @MainActor @Sendable (_ mode: ProjectSortMode) -> Void

  /// Commit the manual-sort sheet result: rewrites `catalog.projects`
  /// to match `orderedIDs` and switches `projectSortMode` to `.manual`.
  var applyManualProjectOrder: @MainActor @Sendable (_ orderedIDs: [ProjectID]) -> Void

  /// Record an activity tick on a Project. Invoked by the notification
  /// pipeline (new inbox entry → host project) and the input pipeline
  /// (`TerminalInputSink.sendInput` → pane's host project).
  var bumpProjectActivity: @MainActor @Sendable (_ projectID: ProjectID) -> Void

  /// Duplicate-add guard. Caller canonicalizes before querying.
  var isPathRegistered: @MainActor @Sendable (_ canonicalPath: String) -> ProjectID?

  /// Containing-project lookup (subdirectory-aware). Returns the deepest
  /// Project whose `rootPath` contains the canonical path (root or descendant).
  /// Used by the `editor.open` IPC so `tc open` inside a subdirectory still
  /// resolves the parent Project's default editor. Caller canonicalizes.
  var projectContaining: @MainActor @Sendable (_ canonicalPath: String) -> ProjectID?

  /// Derived `ProjectKind` lookup — scans `catalog.projects` for the Project
  /// and returns its kind, or `nil` if the Project is not in the catalog.
  /// The Settings sidebar consults this to choose which sub-rows to render
  /// under a Project. Read-only; the app never writes kind — it flows from
  /// `gitRoot` set at project-discovery time.
  var kind: @MainActor @Sendable (_ projectID: ProjectID) -> ProjectKind?

  // MARK: - Pane Action Routing (0008 M5)

  /// Resolves a `PaneID` to the hierarchy address needed to service
  /// pane-scoped intents (target resolution for `closeTab`, `moveTab`,
  /// `selectTab`, `equalizeTabSplits`, etc.). Returns `nil` when the pane
  /// is not in the catalog — expected during teardown races on the action
  /// callback thread.
  var addressOf: @MainActor @Sendable (PaneID) -> PaneAddress?

  /// Moves a Tab by a relative offset within its Worktree. Positive shifts
  /// right, negative shifts left. Clamped to the Worktree's tab-array
  /// bounds by `HierarchyManager.moveTab`.
  var moveTab:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ offset: Int
    ) throws -> Void

  /// Sets every split node's ratio in the Tab's SplitTree to 0.5 so sibling
  /// panes render at equal sizes. Leaf-only trees are a silent no-op.
  var equalizeTabSplits:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  /// Resizes a Pane in the SplitTree along the given direction by `amount`.
  /// `amount` is interpreted as a ratio delta (clamped by SplitTree) — the
  /// ghostty RESIZE_SPLIT action carries pixel amounts but touch-code's
  /// tree only stores ratios.
  var resizePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: ResizeDirection, _ amount: Double
    ) throws -> Void

  /// Clears the Tab's zoomed-pane flag. Paired with `focusPane` (which
  /// sets the zoom) to service `PaneActionRequest.toggleSplitZoom`.
  var unzoomTab:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  // MARK: - Project Settings Phase 2

  /// Runs a user-defined `ScriptDefinition` from `Settings.projects[pid].scripts`.
  /// Looks up the script + worktree, opens a fresh tab whose name is the
  /// script's `displayName`, and types the script's `command` into the new
  /// pane's PTY. Project envVars get injected through the M8 spawn-path env
  /// hook. Throws `RunScriptError.unknownScript` when the id is not in the
  /// project's scripts (deleted between user click and effect dispatch);
  /// throws `RunScriptError.missingWorktree` when the worktree disappears.
  var runScript:
    @MainActor @Sendable (
      _ scriptID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) async throws -> Void

  // MARK: - Worktree lifecycle wrappers

  /// Sets `Worktree.archived`. On `archived: true`, if the project has an
  /// `archiveScript` configured, the script first materializes in a fresh
  /// tab on the worktree as that pane's `initialCommand`; the archived
  /// flag flips only after the pane's child process exits. `archived:
  /// false` is a plain flag flip (no unarchive script hook).
  var setWorktreeArchivedWithLifecycle:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ archived: Bool
    ) async throws -> Void

  /// Removes a worktree from the sidebar list. If the project has a
  /// `deleteScript` configured, it materializes in a fresh tab on the
  /// worktree as that pane's `initialCommand`; the worktree teardown
  /// (relocate-then-prune via `removeWorktreeWithGit`) waits for the
  /// pane's child to exit. Removal of an already-archived worktree
  /// goes through `removeWorktreeWithGit` directly and skips this hook.
  var removeWorktreeWithLifecycle:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID
    ) async throws -> Void

  // MARK: - Worktree sidebar ordering (worktree-sidebar-ordering.md task01)

  /// Moves a single worktree according to `mode` (notifications-v1-1
  /// worktree-promote primitive). Silent no-op on unknown ids and on pinned
  /// targets — pinned ordering is treated as the user's explicit preference
  /// and is never auto-mutated. Persists via the standard debounced save
  /// pipeline. Consumed by `NotificationCoordinator` on the 0→N unread edge
  /// when `moveNotifiedWorktreeToTop` is enabled.
  var promoteWorktree:
    @MainActor @Sendable (
      _ projectID: ProjectID,
      _ worktreeID: WorktreeID,
      _ mode: WorktreePromotionMode
    ) -> Void

  /// Inserts or removes `label` from `Pane.labels` (Set semantics → idempotent
  /// on repeated calls with the same `present`). Silent no-op on unknown
  /// `paneID`. In-memory state changes immediately so the next read sees the
  /// new label; only the disk write is debounced via the standard catalog
  /// save pipeline. Consumed by the pane right-click "Mute notifications"
  /// menu in notifications-v1-1 (`notifications:muted` label).
  var setPaneLabel:
    @MainActor @Sendable (
      _ paneID: PaneID,
      _ label: String,
      _ present: Bool
    ) -> Void

  /// Writes the pane's live `workingDirectory` so restart restores it at the
  /// cwd the user last `cd`'d to instead of the creation-time cwd. Driven by
  /// libghostty `OSC 7` deltas routed through `RootFeature.engineEvents`. The
  /// manager-side mutator is idempotent on equal paths and silent on unknown
  /// ids, so a noisy shell that re-asserts the same pwd every prompt never
  /// touches the catalog file.
  var updatePaneWorkingDirectory:
    @MainActor @Sendable (
      _ paneID: PaneID,
      _ newPath: String
    ) -> Void

  /// Reorder worktrees within a single sidebar segment under a Project.
  /// `from` is a segment-relative `IndexSet`; `to` is the segment-relative
  /// destination offset, both in SwiftUI `ForEach.onMove` convention. Out-of-
  /// range offsets, an out-of-range destination, or an empty `IndexSet`
  /// drop the whole reorder silently (staleness guard). Throws
  /// `HierarchyError.notFound` for unknown project ids.
  var reorderWorktrees:
    @MainActor @Sendable (
      _ projectID: ProjectID,
      _ segment: WorktreeSegment, _ from: IndexSet, _ to: Int
    ) throws -> Void
}

enum RunScriptError: Error, Equatable, Sendable {
  case unknownScript(UUID)
  case missingWorktree(WorktreeID)
  case missingProject(ProjectID)
}

/// Full hierarchy address a `PaneID` resolves to. Carries the IDs of every
/// ancestor so `HierarchyClient` mutations that require the full chain
/// (`closeTab`, `selectTab`, `equalizeTabSplits`, …) can be called without a
/// second catalog walk.
nonisolated struct PaneAddress: Sendable, Equatable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let paneID: PaneID
}

/// Coarse selection payload. `nil` for any level means "no selection at that
/// level" — e.g. a Project may be implied by the worktree without an explicit
/// project-level selection store.
///
/// `projectID` resolves from `Catalog.selectedProjectID` (the v3 top-level
/// authoritative field, set by `HierarchyManager.selectProject`); when that
/// is nil it falls back to the first Project carrying a non-nil
/// `selectedWorktreeID` (the initial-load path before the user's first
/// click). `worktreeID` reads off the resolved Project's
/// `selectedWorktreeID`.
nonisolated struct HierarchySelection: Equatable, Sendable {
  let projectID: ProjectID?
  let worktreeID: WorktreeID?

  static let empty = HierarchySelection(projectID: nil, worktreeID: nil)
}

// MARK: - Live bridge

extension HierarchyClient {
  @MainActor
  // swiftlint:disable:next function_body_length
  static func live(
    manager: HierarchyManager,
    settings: SettingsStore? = nil,
    gitWorktreeClient: GitWorktreeClient = .makeLive(),
    gitCLI: GitWorktreeCLI = GitWorktreeCLI(),
    terminalClient: TerminalClient? = nil
  ) -> HierarchyClient {
    HierarchyClient(
      createTag: { name, color in
        manager.createTag(name: name, color: color)
      },
      renameTag: { id, name in manager.renameTag(id, to: name) },
      recolorTag: { id, color in manager.recolorTag(id, to: color) },
      removeTag: { id in manager.removeTag(id) },
      setProjectTags: { projectID, tags in
        manager.setProjectTags(projectID, tags: tags)
      },
      setActiveTagFilter: { filter in manager.setActiveTagFilter(filter) },
      addProject: { name, rootPath, gitRoot in
        manager.addProject(name: name, rootPath: rootPath, gitRoot: gitRoot)
      },
      removeProject: { projectID in try manager.removeProject(projectID) },
      renameProject: { projectID, name in
        try manager.renameProject(projectID, name: name)
      },
      createWorktree: { projectID, name, path, branch in
        try manager.createWorktree(in: projectID, name: name, path: path, branch: branch)
      },
      removeWorktree: { worktreeID, projectID in
        try manager.removeWorktree(worktreeID, from: projectID)
      },
      selectProject: { id in manager.selectProject(id) },
      selectWorktree: { worktreeID, projectID in
        try manager.selectWorktree(worktreeID, in: projectID)
      },
      createTab: { worktreeID, projectID, name in
        try manager.createTab(in: worktreeID, in: projectID, name: name)
      },
      closeTab: { tabID, worktreeID, projectID in
        try manager.closeTab(tabID, in: worktreeID, in: projectID)
      },
      selectTab: { tabID, worktreeID, projectID in
        try manager.selectTab(tabID, in: worktreeID, in: projectID)
      },
      renameTab: { tabID, worktreeID, projectID, name in
        try manager.renameTab(tabID, in: worktreeID, in: projectID, name: name)
      },
      setTabColor: { tabID, worktreeID, projectID, color in
        try manager.setTabColor(tabID, in: worktreeID, in: projectID, color: color)
      },
      reorderTabs: { worktreeID, projectID, orderedIDs in
        try manager.reorderTabs(
          in: worktreeID, in: projectID, orderedIDs: orderedIDs)
      },
      closeOtherTabs: { keepID, worktreeID, projectID in
        try manager.closeOtherTabs(
          keeping: keepID, in: worktreeID, in: projectID)
      },
      closeTabsToRight: { pivotID, worktreeID, projectID in
        try manager.closeTabsToRight(
          of: pivotID, in: worktreeID, in: projectID)
      },
      closeAllTabs: { worktreeID, projectID in
        try manager.closeAllTabs(in: worktreeID, in: projectID)
      },
      selectAdjacentTab: { direction, worktreeID, projectID in
        try manager.selectAdjacentTab(
          direction: direction, in: worktreeID, in: projectID)
      },
      tabIsDirty: { tabID in manager.tabIsDirty(tabID) },
      worktreeIsDirty: { worktreeID in manager.worktreeIsDirty(worktreeID) },
      lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) },
      markPaneRunning: { paneID in manager.markPaneRunning(paneID) },
      markPaneIdle: { paneID in manager.markPaneIdle(paneID) },
      openPane: { [weak settings] tabID, worktreeID, projectID, cwd, initial in
        // Defensive guard against stale catalog state: when a worktree
        // is deleted outside the app (`git worktree remove`) before
        // reconcile catches up, libghostty crashes if it tries to spawn
        // a shell in a non-existent cwd. Reject here so callers'
        // `try?` swallows the error instead of bringing down the app.
        var isDir: ObjCBool = false
        guard
          FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
          isDir.boolValue
        else {
          throw HierarchyError.notFound("Worktree path missing: \(cwd)")
        }
        // M8: resolve project envVars from the SettingsStore so every
        // user-flow openPane (TabBar new-tab, SplitViewport new-tab,
        // CreateWorktree, IPC openPane) inherits Project-defined env. When
        // the live wiring omits a SettingsStore (legacy callers, headless
        // tests) the env defaults to empty and the pane spawns with the
        // raw process env — same behaviour as before M8.
        let env: [String: String] =
          settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) }
          ?? [:]
        return try manager.openPane(
          in: tabID, in: worktreeID, in: projectID,
          workingDirectory: cwd, initialCommand: initial, env: env
        )
      },
      splitPane: { [weak settings] paneID, direction, tabID, worktreeID, projectID, cwd, initial in
        // Splits inherit the same Project envVars as the parent pane —
        // the new pty is forked from a fresh shell, not the existing one,
        // so the env hook still has to run.
        let env: [String: String] =
          settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) }
          ?? [:]
        return try manager.splitPane(
          paneID, direction: direction,
          in: tabID, in: worktreeID, in: projectID,
          workingDirectory: cwd, initialCommand: initial, env: env
        )
      },
      closePane: { paneID, tabID, worktreeID, projectID in
        try manager.closePane(paneID, in: tabID, in: worktreeID, in: projectID)
      },
      focusPane: { paneID, tabID, worktreeID, projectID in
        try manager.focusPane(paneID, in: tabID, in: worktreeID, in: projectID)
      },
      focusSurfaceView: { paneID in
        manager.focusSurfaceView(for: paneID)
      },
      resizeSplit: { path, ratio, tabID, worktreeID, projectID in
        try manager.resizeSplit(
          at: path, ratio: ratio,
          in: tabID, in: worktreeID, in: projectID
        )
      },
      setWorktreeDiffInspectorVisible: { worktreeID, visible in
        manager.setWorktreeDiffInspectorVisible(worktreeID: worktreeID, visible: visible)
      },
      snapshot: { manager.catalog },
      selectionChanges: { makeSelectionStream(manager: manager) },
      setWorktreeArchived: { worktreeID, archived in
        try manager.setWorktreeArchived(worktreeID: worktreeID, archived: archived)
      },
      setWorktreePinned: { worktreeID, isPinned in
        manager.setWorktreePinned(worktreeID: worktreeID, isPinned: isPinned)
      },
      setProjectExpanded: { projectID, isExpanded in
        manager.setProjectExpanded(projectID: projectID, isExpanded: isExpanded)
      },
      reconcileDiscoveredWorktrees: { projectID in
        await reconcile(
          projectID: projectID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient,
          gitCLI: gitCLI
        )
      },
      createWorktreeWithGit: { projectID, name, branch, path in
        try manager.createWorktree(
          in: projectID,
          name: name, path: path, branch: branch
        )
      },
      removeWorktreeWithGit: { worktreeID, projectID in
        try await removeWorktreeWithGit(
          worktreeID: worktreeID,
          projectID: projectID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient
        )
      },
      runningPaneCount: { worktreeID in
        manager.runningPaneCount(worktreeID: worktreeID)
      },
      setProjectLoadState: { projectID, state in
        manager.setProjectLoadState(state, projectID: projectID)
      },
      reorderProjects: { from, to in
        manager.reorderProjects(from: from, to: to)
      },
      setProjectSortMode: { mode in
        manager.setProjectSortMode(mode)
      },
      applyManualProjectOrder: { orderedIDs in
        manager.applyManualProjectOrder(orderedIDs)
      },
      bumpProjectActivity: { projectID in
        manager.bumpProjectActivity(projectID)
      },
      isPathRegistered: { canonicalPath in
        manager.isPathRegistered(canonical: canonicalPath)
      },
      projectContaining: { canonicalPath in
        manager.project(containing: canonicalPath)
      },
      kind: { projectID in
        manager.catalog.projects.first(where: { $0.id == projectID })?.kind
      },
      addressOf: { paneID in
        guard let (projectID, worktreeID, tabID) = manager.addressOf(paneID: paneID)
        else { return nil }
        return PaneAddress(
          projectID: projectID,
          worktreeID: worktreeID,
          tabID: tabID,
          paneID: paneID
        )
      },
      moveTab: { tabID, worktreeID, projectID, offset in
        try manager.moveTab(
          tabID, in: worktreeID, in: projectID, offset: offset
        )
      },
      equalizeTabSplits: { tabID, worktreeID, projectID in
        try manager.equalizeTabSplits(tabID, in: worktreeID, in: projectID)
      },
      resizePane: { paneID, direction, amount in
        try manager.resizePane(paneID, direction: direction, amount: amount)
      },
      unzoomTab: { tabID, worktreeID, projectID in
        try manager.unfocusPane(in: tabID, in: worktreeID, in: projectID)
      },
      runScript: { [weak settings] scriptID, projectID, worktreeID in
        try await runScript(
          scriptID: scriptID,
          projectID: projectID,
          worktreeID: worktreeID,
          manager: manager,
          settings: settings,
          terminalClient: terminalClient
        )
      },
      setWorktreeArchivedWithLifecycle: { [weak settings] worktreeID, projectID, archived in
        let snapshot = settings?.settings ?? .default
        if archived,
          let command = snapshot.projects[projectID]?.git?.archiveScript?.command,
          !command.isEmpty
        {
          await openNewTabAndAwaitExit(
            worktreeID: worktreeID, projectID: projectID,
            command: command, tabName: "Archive",
            manager: manager, terminalClient: terminalClient,
            settings: snapshot
          )
        }
        try manager.setWorktreeArchived(worktreeID: worktreeID, archived: archived)
      },
      removeWorktreeWithLifecycle: { [weak settings] worktreeID, projectID in
        let snapshot = settings?.settings ?? .default
        if let command = snapshot.projects[projectID]?.git?.deleteScript?.command,
          !command.isEmpty
        {
          await openNewTabAndAwaitExit(
            worktreeID: worktreeID, projectID: projectID,
            command: command, tabName: "Delete",
            manager: manager, terminalClient: terminalClient,
            settings: snapshot
          )
        }
        try await removeWorktreeWithGit(
          worktreeID: worktreeID, projectID: projectID,
          manager: manager, gitWorktreeClient: gitWorktreeClient
        )
      },
      promoteWorktree: { projectID, worktreeID, mode in
        manager.promoteWorktree(in: projectID, worktreeID: worktreeID, mode: mode)
      },
      setPaneLabel: { paneID, label, present in
        manager.setPaneLabel(paneID: paneID, label: label, present: present)
      },
      updatePaneWorkingDirectory: { paneID, newPath in
        manager.updatePaneWorkingDirectory(paneID, to: newPath)
      },
      reorderWorktrees: { projectID, segment, from, to in
        try manager.reorderWorktrees(
          in: projectID,
          segment: segment, from: from, to: to
        )
      }
    )
  }

  /// Resolves the script + worktree, then dispatches according to the
  /// script's `target`:
  ///   - `.newTab` : open a fresh tab and run as the new pane's
  ///                 `initialCommand`.
  ///   - `.focused`: write the command (with trailing newline) to the
  ///                 worktree's last-focused pane via `TerminalClient`.
  ///                 No new pane / tab is created.
  ///   - `.split`  : split the focused pane in `script.direction` and run
  ///                 as the split's `initialCommand`.
  ///
  /// `.focused` and `.split` fall back to `.newTab` when no anchor pane is
  /// available (empty worktree, no focused pane in the selected tab).
  ///
  /// When `target` spawned a pane and `resolvedOnFinished` is non-`.none`,
  /// a detached observer waits for that pane's child to exit and then
  /// applies the policy (`.closePane` / `.closeTab`).
  @MainActor
  private static func runScript(
    scriptID: UUID,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    settings: SettingsStore?,
    terminalClient: TerminalClient?
  ) async throws {
    let snapshot = settings?.settings ?? .default
    guard let project = snapshot.projects[projectID],
      let script = project.scripts.first(where: { $0.id == scriptID })
    else {
      throw RunScriptError.unknownScript(scriptID)
    }
    var foundWorktreePath: String?
    outer: for project in manager.catalog.projects where project.id == projectID {
      for worktree in project.worktrees where worktree.id == worktreeID {
        foundWorktreePath = worktree.path
        break outer
      }
    }
    guard let cwd = foundWorktreePath else {
      throw RunScriptError.missingWorktree(worktreeID)
    }
    let env = HierarchyManager.resolvedEnv(for: projectID, in: snapshot)

    // Subscribe before spawn: events() is broadcast and does not
    // replay. A one-shot script that exits before scheduleOnFinishedAction
    // calls events() would otherwise miss the paneExited and the
    // onFinished policy would never fire.
    let onFinishedNeeded = script.resolvedOnFinished != .none
    let preSubscribedStream: AsyncStream<TerminalEvent>? =
      onFinishedNeeded ? terminalClient?.events() : nil

    let spawnedPaneID = try dispatchScript(
      script: script,
      worktreeID: worktreeID,
      projectID: projectID,
      cwd: cwd,
      env: env,
      manager: manager,
      terminalClient: terminalClient
    )

    if let spawnedPaneID, let stream = preSubscribedStream {
      scheduleOnFinishedAction(
        paneID: spawnedPaneID,
        policy: script.resolvedOnFinished,
        manager: manager,
        eventStream: stream
      )
    }

    // Neither `.newTab` nor `.split` auto-focuses the spawned surface:
    // - `.split`: splitPane leaves first-responder on the source pane.
    // - `.newTab`: createTab sets selectedTabID before openPane adds the
    //   pane, so the tab switch happens against an empty tab and the
    //   subsequent openPane never grabs focus on its own.
    // Honour the script's `focus` by dispatching `focusSurfaceView` async,
    // the same way the manual ⌘D / ⌘T paths do — the surface view needs
    // to attach to the hosting window before `makeFirstResponder` takes.
    if script.focus,
      script.target == .split || script.target == .newTab,
      let spawnedPaneID
    {
      Task { @MainActor in
        manager.focusSurfaceView(for: spawnedPaneID)
      }
    }
  }

  /// Materializes a `ScriptDefinition` into a runtime action and returns the
  /// spawned `PaneID` if a new pane was created (`.newTab` / `.split`), or
  /// `nil` for `.focused` (which writes into an existing pane). Falls back to
  /// `.newTab` for `.focused` / `.split` when there is no anchor pane.
  @MainActor
  private static func dispatchScript(
    script: ScriptDefinition,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    cwd: String,
    env: [String: String],
    manager: HierarchyManager,
    terminalClient: TerminalClient?
  ) throws -> PaneID? {
    // initialCommand is replayed by TerminalEngine via `sendInput(command + "\n")`
    // into an interactive shell, so the shell stays at a prompt after the user's
    // command finishes and `paneExited` never fires. When the script has an
    // onFinished policy (closeTab / closePane), append `; exit` so the shell
    // exits as soon as the script's last statement completes — same trick the
    // archive/delete lifecycle uses in `openNewTabAndAwaitExit`. Without it,
    // "Close tab when finished" silently never triggers (HAN-36).
    let spawnCommand = wrapForOnFinished(
      command: script.command,
      policy: script.resolvedOnFinished
    )

    func openInNewTab() throws -> PaneID {
      let tabID = try manager.createTab(
        in: worktreeID, in: projectID,
        name: script.displayName,
        select: script.focus
      )
      return try manager.openPane(
        in: tabID, in: worktreeID, in: projectID,
        workingDirectory: cwd,
        initialCommand: spawnCommand,
        env: env
      )
    }

    switch script.target {
    case .newTab:
      return try openInNewTab()

    case .focused:
      // sendInput needs the focused pane and the terminal runtime; absent
      // either, fall back to a fresh tab so the user always sees output.
      if let terminalClient,
        let anchor = focusedAnchor(worktreeID: worktreeID, in: manager)
      {
        terminalClient.sendInput(anchor.paneID, script.command + "\n")
        return nil
      }
      runScriptLogger.info(
        "target=.focused fell back to .newTab — \(terminalClient == nil ? "no TerminalClient" : "no focused pane in worktree", privacy: .public)"
      )
      return try openInNewTab()

    case .split:
      if let anchor = focusedAnchor(worktreeID: worktreeID, in: manager) {
        return try manager.splitPane(
          anchor.paneID,
          direction: mapSplitDirection(script.direction),
          in: anchor.tabID, in: worktreeID, in: projectID,
          workingDirectory: cwd,
          initialCommand: spawnCommand,
          env: env
        )
      }
      runScriptLogger.info(
        "target=.split fell back to .newTab — no focused pane in worktree"
      )
      return try openInNewTab()
    }
  }

  /// Appends `; exit` so the spawned shell terminates after the user's
  /// command finishes, which is what makes `paneExited` fire and the
  /// onFinished policy actually trigger. No-op when policy is `.none`
  /// (the user wants an interactive shell to remain).
  nonisolated private static func wrapForOnFinished(
    command: String,
    policy: ScriptOnFinished
  ) -> String {
    guard policy != .none else { return command }
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "exit" : "\(trimmed); exit"
  }

  /// Picks the worktree's selected (or first) tab and returns its
  /// last-focused pane — the anchor for `.focused` / `.split` dispatch.
  /// Falls back to the tab's first leaf when no pane has gained focus
  /// since the tab was created.
  @MainActor
  private static func focusedAnchor(
    worktreeID: WorktreeID,
    in manager: HierarchyManager
  ) -> (tabID: TabID, paneID: PaneID)? {
    var foundWorktree: Worktree?
    outer: for project in manager.catalog.projects {
      if let wt = project.worktrees.first(where: { $0.id == worktreeID }) {
        foundWorktree = wt
        break outer
      }
    }
    guard let worktree = foundWorktree else { return nil }
    let tabID = worktree.selectedTabID ?? worktree.tabs.first?.id
    guard let tabID else { return nil }
    if let paneID = manager.lastFocusedPane(in: tabID) {
      return (tabID, paneID)
    }
    if let tab = worktree.tabs.first(where: { $0.id == tabID }),
      let firstPane = tab.panes.first
    {
      return (tabID, firstPane.id)
    }
    return nil
  }

  /// Maps the settings-layer `ScriptSplitDirection` onto the runtime's
  /// `SplitTree.NewDirection`. The two enums are kept separate so the
  /// JSON schema does not couple to the internal split-tree wire type.
  nonisolated private static func mapSplitDirection(
    _ direction: ScriptSplitDirection
  ) -> SplitTree<PaneID>.NewDirection {
    switch direction {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
  }

  /// Subscribes to terminal events and, when the spawned pane's child
  /// exits / crashes / is closed by tab-autoclose, applies the
  /// `onFinished` policy on the main actor. Closes the pane only — for
  /// `.closeTab` the address-resolved `tabID` is closed instead. Silent
  /// no-op when the pane is no longer in the catalog by the time the
  /// exit lands (already torn down by the user, etc.). The caller is
  /// responsible for subscribing to `events()` *before* the pane spawn
  /// so a one-shot script's `paneExited` is not missed.
  @MainActor
  private static func scheduleOnFinishedAction(
    paneID: PaneID,
    policy: ScriptOnFinished,
    manager: HierarchyManager,
    eventStream: AsyncStream<TerminalEvent>
  ) {
    Task.detached(priority: .userInitiated) {
      for await event in eventStream {
        switch event {
        case .paneExited(let pid, _, _) where pid == paneID,
          .paneCrashed(let pid, _) where pid == paneID:
          await MainActor.run {
            applyOnFinished(policy: policy, paneID: paneID, manager: manager)
          }
          return
        case .paneClosedByTab(let pid, _) where pid == paneID:
          // Already torn down by tab-autoclose — pane no longer exists,
          // so neither closePane nor closeTab has anything to do.
          return
        default:
          continue
        }
      }
    }
  }

  @MainActor
  private static func applyOnFinished(
    policy: ScriptOnFinished,
    paneID: PaneID,
    manager: HierarchyManager
  ) {
    guard let address = manager.addressOf(paneID: paneID) else { return }
    let (projectID, worktreeID, tabID) = address
    switch policy {
    case .none:
      return
    case .closePane:
      try? manager.closePane(paneID, in: tabID, in: worktreeID, in: projectID)
    case .closeTab:
      try? manager.closeTab(tabID, in: worktreeID, in: projectID)
    }
  }

  /// Opens a fresh tab on the worktree, runs `command` as the new pane's
  /// `initialCommand`, and suspends until that pane's child process exits
  /// (or crashes). Returns immediately as a no-op when the worktree is
  /// gone, the tab/pane could not be created, or no `TerminalClient` is
  /// wired. Used by archive / delete lifecycle wrappers — both must wait
  /// for the user's script to finish before mutating catalog state.
  ///
  /// `initialCommand` is delivered to the pane via `sendInput`, i.e. it
  /// is typed into an interactive shell rather than passed through
  /// `sh -c`. A bare `npm install\n` would therefore leave the shell at
  /// an interactive prompt and the await would block until the user
  /// manually `exit`s — the archive flag would never flip. To make
  /// lifecycle scripts terminate deterministically, the command is
  /// wrapped as `<trimmed>; exit\n` so the shell exits after running
  /// the user's script regardless of its outcome. The pane stays open
  /// just long enough for the user to read any output before it
  /// disappears with the worktree teardown.
  @MainActor
  private static func openNewTabAndAwaitExit(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    command: String,
    tabName: String,
    manager: HierarchyManager,
    terminalClient: TerminalClient?,
    settings: Settings
  ) async {
    var foundWorktreePath: String?
    outer: for project in manager.catalog.projects where project.id == projectID {
      for worktree in project.worktrees where worktree.id == worktreeID {
        foundWorktreePath = worktree.path
        break outer
      }
    }
    guard let cwd = foundWorktreePath else { return }
    guard let terminalClient else { return }
    let env = HierarchyManager.resolvedEnv(for: projectID, in: settings)

    // Subscribe before spawn: events() is broadcast and does not
    // replay. A one-shot script that exits between createTab + openPane
    // and a later events() call would otherwise be missed and the
    // archive/delete await would hang forever.
    let stream = terminalClient.events()

    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let wrapped = trimmed.isEmpty ? "exit" : "\(trimmed); exit"

    let paneID: PaneID
    do {
      let tabID = try manager.createTab(
        in: worktreeID, in: projectID, name: tabName
      )
      paneID = try manager.openPane(
        in: tabID, in: worktreeID, in: projectID,
        workingDirectory: cwd,
        initialCommand: wrapped,
        env: env
      )
    } catch {
      return
    }

    for await event in stream {
      switch event {
      case .paneExited(let pid, _, _) where pid == paneID,
        .paneCrashed(let pid, _) where pid == paneID,
        .paneClosedByTab(let pid, _) where pid == paneID:
        return
      default:
        continue
      }
    }
  }

  /// Factored out so the closure body stays one-line-callable. Resolves
  /// the Project's git root, lists on-disk worktrees via `wt ls --json`,
  /// and hands the result to `manager.reconcileDiscoveredWorktrees`.
  /// Each entry's `path` is passed through `HierarchyManager.canonicalPath`
  /// so `wt ls`'s `/var/...` output matches the symlink-resolved form
  /// T-PROJECT stores for `Project.rootPath` — without this normalization
  /// the main checkout would duplicate on every reconcile under `/tmp`
  /// and `/var`. Swallows and logs `GitWorktreeError` — this path is
  /// idempotent and must never crash a reconcile (see design doc
  /// §Discovery / Reconcile).
  @MainActor
  private static func reconcile(
    projectID: ProjectID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI
  ) async {
    guard let project = manager.catalog.projects.first(where: { $0.id == projectID })
    else { return }
    // Re-detect the git root every time gitRoot is nil. Folder Projects added
    // before the user ran `git init` (or `git clone`) inside the directory
    // would otherwise stay forever marked non-git: gitRoot is set once at
    // add-time and never refreshed. The reconciler runs on launch and on
    // every window-focus pulse, so this auto-promotes a folder Project to a
    // git Project the next time the app regains focus after `git init`.
    // `discoverGitRoot` shells out to `git rev-parse --show-toplevel`
    // (sub-10ms, swallows ENOENT) and is debounced upstream by
    // `ProjectReconciler`'s 2s window, so the per-focus cost is bounded.
    let gitRoot: String? = await {
      if let existing = project.gitRoot { return existing }
      let discovered = try? await gitCLI.discoverGitRoot(candidatePath: project.rootPath)
      if let discovered, !discovered.isEmpty {
        manager.setProjectGitRoot(projectID: projectID, gitRoot: discovered)
        return discovered
      }
      return nil
    }()
    guard let gitRoot else { return }
    do {
      let entries = try await gitWorktreeClient.lsWorktrees(
        URL(fileURLWithPath: gitRoot)
      )
      let mapped = entries.map { entry -> (path: String, branch: String?) in
        let branch = entry.branch.isEmpty ? nil : entry.branch
        return (path: HierarchyManager.canonicalPath(entry.path), branch: branch)
      }
      _ = manager.reconcileDiscoveredWorktrees(
        projectID: projectID,
        entries: mapped
      )
    } catch {
      // Log under com.touch-code.hierarchy/reconcile and swallow —
      // never throw, never crash a reconcile (see design doc
      // §Discovery / Reconcile). `projectID` is printed as .public
      // because it's a UUID opaque to users; the error description
      // is `.private(mask: .hash)` because `GitWorktreeError
      // .commandFailed` carries raw git stderr which can embed
      // local absolute paths. Issue #24 (d) + PR #31 review F2.
      reconcileLogger.error(
        "reconcileDiscoveredWorktrees failed: project=\(projectID.raw.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
      )
    }
  }

  /// Factored out of the `removeWorktreeWithGit` closure so the
  /// control flow stays readable. Tears down all surfaces first (the
  /// relocate-then-prune step about to run will move the worktree's
  /// working directory out from under any open terminals, so panes
  /// holding the cwd as a live file descriptor must be closed
  /// beforehand), then runs git, then drops the catalog row.
  /// Re-throws `GitWorktreeError` for the caller to surface.
  @MainActor
  private static func removeWorktreeWithGit(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient
  ) async throws {
    guard let project = manager.catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let gitRoot = project.gitRoot
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    manager.tearDownWorktreeSurfaces(worktreeID: worktreeID)
    let gitRootURL = URL(fileURLWithPath: gitRoot)
    try await gitWorktreeClient.removeWorktree(
      gitRootURL,
      URL(fileURLWithPath: worktree.path)
    )
    // Drop the branch the worktree was tracking. `git worktree remove`
    // intentionally leaves the ref behind, so re-creating a worktree
    // with the same name afterwards trips Touch Code's "branch already
    // exists" guard. Best-effort: git refuses if the branch is checked
    // out elsewhere (main / shared) — which is exactly when we DON'T
    // want to delete it — so swallowing the error is the safe default.
    if let branch = worktree.branch, !branch.isEmpty {
      await gitWorktreeClient.deleteBranchIfExists(gitRootURL, branch)
    }
    try manager.removeWorktree(worktreeID, from: projectID)
  }

  /// AsyncStream backed by Swift Observation — samples `manager.catalog`'s
  /// selection chain and yields a new `HierarchySelection` whenever any of
  /// the IDs changes. Closes the re-arm race window by sampling
  /// `currentSelection` BEFORE arming the next `withObservationTracking`
  /// block: any mutation that landed between the prior yield and the next
  /// arm is caught on the pre-arm compare; `withObservationTracking` then
  /// only waits for mutations that land after the new snapshot.
  @MainActor
  private static func makeSelectionStream(manager: HierarchyManager) -> AsyncStream<HierarchySelection> {
    AsyncStream { continuation in
      let task = Task { @MainActor in
        var last = currentSelection(for: manager)
        continuation.yield(last)
        while !Task.isCancelled {
          // Sample FIRST — catches any mutation that landed during the
          // gap between yield and re-arm.
          let preArm = currentSelection(for: manager)
          if preArm != last {
            continuation.yield(preArm)
            last = preArm
          }
          await withCheckedContinuation { (observationContinuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
              _ = currentSelection(for: manager)
            } onChange: {
              observationContinuation.resume()
            }
          }
          let current = currentSelection(for: manager)
          if current != last {
            continuation.yield(current)
            last = current
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Resolve `(projectID, worktreeID)` for the selection stream. Reads the
  /// authoritative `Catalog.selectedProjectID` first; if that is nil
  /// (initial-load before the user's first click), falls back to the first
  /// Project carrying a non-nil `selectedWorktreeID`. The fallback ensures
  /// app launch lands on a sensible default without a UI poke.
  @MainActor
  private static func currentSelection(for manager: HierarchyManager) -> HierarchySelection {
    let catalog = manager.catalog
    if let pid = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == pid })
    {
      return HierarchySelection(projectID: project.id, worktreeID: project.selectedWorktreeID)
    }
    for project in catalog.projects {
      if let worktreeID = project.selectedWorktreeID {
        return HierarchySelection(projectID: project.id, worktreeID: worktreeID)
      }
    }
    return .empty
  }
}

// MARK: - DependencyKey

extension HierarchyClient: DependencyKey {
  static let liveValue: HierarchyClient = HierarchyClient(
    createTag: { _, _ in
      fatalError("HierarchyClient.liveValue not configured; wire via .withDependencies at app startup")
    },
    renameTag: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    recolorTag: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeTag: { _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectTags: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setActiveTagFilter: { _ in fatalError("HierarchyClient.liveValue not configured") },
    addProject: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeProject: { _ in fatalError("HierarchyClient.liveValue not configured") },
    renameProject: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktree: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectProject: { _ in fatalError("HierarchyClient.liveValue not configured") },
    selectWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    renameTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setTabColor: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderTabs: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeOtherTabs: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTabsToRight: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeAllTabs: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectAdjacentTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    tabIsDirty: { _ in false },
    worktreeIsDirty: { _ in false },
    lastFocusedPane: { _ in nil },
    markPaneRunning: { _ in },
    markPaneIdle: { _ in },
    openPane: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    splitPane: { _, _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closePane: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusPane: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusSurfaceView: { _ in fatalError("HierarchyClient.liveValue not configured") },
    resizeSplit: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreeDiffInspectorVisible: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    snapshot: { fatalError("HierarchyClient.liveValue not configured") },
    selectionChanges: { AsyncStream { $0.finish() } },
    setWorktreeArchived: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreePinned: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectExpanded: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reconcileDiscoveredWorktrees: { _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktreeWithGit: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktreeWithGit: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runningPaneCount: { _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectLoadState: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderProjects: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectSortMode: { _ in fatalError("HierarchyClient.liveValue not configured") },
    applyManualProjectOrder: { _ in fatalError("HierarchyClient.liveValue not configured") },
    bumpProjectActivity: { _ in fatalError("HierarchyClient.liveValue not configured") },
    isPathRegistered: { _ in fatalError("HierarchyClient.liveValue not configured") },
    projectContaining: { _ in fatalError("HierarchyClient.liveValue not configured") },
    kind: { _ in fatalError("HierarchyClient.liveValue not configured") },
    addressOf: { _ in fatalError("HierarchyClient.liveValue not configured") },
    moveTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    equalizeTabSplits: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    resizePane: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    unzoomTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreeArchivedWithLifecycle: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    removeWorktreeWithLifecycle: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    promoteWorktree: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setPaneLabel: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    updatePaneWorkingDirectory: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    reorderWorktrees: { _, _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    }
  )

  static let testValue: HierarchyClient = HierarchyClient(
    createTag: unimplemented("HierarchyClient.createTag", placeholder: TagID()),
    renameTag: unimplemented("HierarchyClient.renameTag"),
    recolorTag: unimplemented("HierarchyClient.recolorTag"),
    removeTag: unimplemented("HierarchyClient.removeTag"),
    setProjectTags: unimplemented("HierarchyClient.setProjectTags"),
    setActiveTagFilter: unimplemented("HierarchyClient.setActiveTagFilter"),
    addProject: unimplemented("HierarchyClient.addProject", placeholder: ProjectID()),
    removeProject: unimplemented("HierarchyClient.removeProject"),
    renameProject: unimplemented("HierarchyClient.renameProject"),
    createWorktree: unimplemented("HierarchyClient.createWorktree", placeholder: WorktreeID()),
    removeWorktree: unimplemented("HierarchyClient.removeWorktree"),
    selectProject: unimplemented("HierarchyClient.selectProject"),
    selectWorktree: unimplemented("HierarchyClient.selectWorktree"),
    createTab: unimplemented("HierarchyClient.createTab", placeholder: TabID()),
    closeTab: unimplemented("HierarchyClient.closeTab"),
    selectTab: unimplemented("HierarchyClient.selectTab"),
    renameTab: unimplemented("HierarchyClient.renameTab"),
    setTabColor: unimplemented("HierarchyClient.setTabColor"),
    reorderTabs: unimplemented("HierarchyClient.reorderTabs"),
    closeOtherTabs: unimplemented("HierarchyClient.closeOtherTabs"),
    closeTabsToRight: unimplemented("HierarchyClient.closeTabsToRight"),
    closeAllTabs: unimplemented("HierarchyClient.closeAllTabs"),
    selectAdjacentTab: unimplemented("HierarchyClient.selectAdjacentTab", placeholder: nil),
    tabIsDirty: unimplemented("HierarchyClient.tabIsDirty", placeholder: false),
    worktreeIsDirty: unimplemented("HierarchyClient.worktreeIsDirty", placeholder: false),
    lastFocusedPane: unimplemented("HierarchyClient.lastFocusedPane", placeholder: nil),
    markPaneRunning: unimplemented("HierarchyClient.markPaneRunning"),
    markPaneIdle: unimplemented("HierarchyClient.markPaneIdle"),
    openPane: unimplemented("HierarchyClient.openPane", placeholder: PaneID()),
    splitPane: unimplemented("HierarchyClient.splitPane", placeholder: PaneID()),
    closePane: unimplemented("HierarchyClient.closePane"),
    focusPane: unimplemented("HierarchyClient.focusPane"),
    focusSurfaceView: unimplemented("HierarchyClient.focusSurfaceView"),
    resizeSplit: unimplemented("HierarchyClient.resizeSplit"),
    setWorktreeDiffInspectorVisible: unimplemented("HierarchyClient.setWorktreeDiffInspectorVisible"),
    snapshot: unimplemented(
      "HierarchyClient.snapshot",
      placeholder: Catalog()
    ),
    selectionChanges: unimplemented(
      "HierarchyClient.selectionChanges",
      placeholder: AsyncStream { $0.finish() }
    ),
    setWorktreeArchived: unimplemented("HierarchyClient.setWorktreeArchived"),
    setWorktreePinned: unimplemented("HierarchyClient.setWorktreePinned"),
    setProjectExpanded: unimplemented("HierarchyClient.setProjectExpanded"),
    reconcileDiscoveredWorktrees: unimplemented("HierarchyClient.reconcileDiscoveredWorktrees"),
    createWorktreeWithGit: unimplemented(
      "HierarchyClient.createWorktreeWithGit", placeholder: WorktreeID()
    ),
    removeWorktreeWithGit: unimplemented("HierarchyClient.removeWorktreeWithGit"),
    runningPaneCount: unimplemented("HierarchyClient.runningPaneCount", placeholder: 0),
    setProjectLoadState: unimplemented("HierarchyClient.setProjectLoadState"),
    reorderProjects: unimplemented("HierarchyClient.reorderProjects"),
    setProjectSortMode: unimplemented("HierarchyClient.setProjectSortMode"),
    applyManualProjectOrder: unimplemented("HierarchyClient.applyManualProjectOrder"),
    bumpProjectActivity: unimplemented("HierarchyClient.bumpProjectActivity"),
    isPathRegistered: unimplemented("HierarchyClient.isPathRegistered", placeholder: nil),
    projectContaining: unimplemented("HierarchyClient.projectContaining", placeholder: nil),
    kind: unimplemented("HierarchyClient.kind", placeholder: nil),
    addressOf: unimplemented("HierarchyClient.addressOf", placeholder: nil),
    moveTab: unimplemented("HierarchyClient.moveTab"),
    equalizeTabSplits: unimplemented("HierarchyClient.equalizeTabSplits"),
    resizePane: unimplemented("HierarchyClient.resizePane"),
    unzoomTab: unimplemented("HierarchyClient.unzoomTab"),
    runScript: unimplemented("HierarchyClient.runScript"),
    setWorktreeArchivedWithLifecycle: unimplemented(
      "HierarchyClient.setWorktreeArchivedWithLifecycle"
    ),
    removeWorktreeWithLifecycle: unimplemented(
      "HierarchyClient.removeWorktreeWithLifecycle"
    ),
    promoteWorktree: unimplemented("HierarchyClient.promoteWorktree"),
    setPaneLabel: unimplemented("HierarchyClient.setPaneLabel"),
    updatePaneWorkingDirectory: unimplemented("HierarchyClient.updatePaneWorkingDirectory"),
    reorderWorktrees: unimplemented("HierarchyClient.reorderWorktrees")
  )
}

extension DependencyValues {
  var hierarchyClient: HierarchyClient {
    get { self[HierarchyClient.self] }
    set { self[HierarchyClient.self] = newValue }
  }
}
