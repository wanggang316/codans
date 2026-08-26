import CodansCore
import ComposableArchitecture
import Foundation
import OSLog
import Observation

/// Logger for the background reconcile path. Matches the project's
/// `com.gumpw.codans.<area>` subsystem convention (see SettingsStore,
/// CatalogStore, the IPC handlers, etc.). Category `reconcile` isolates
/// these events from the rest of the hierarchy subsystem so operators
/// can filter with `log stream --predicate 'category == "reconcile"'`.
private let reconcileLogger = Logger(
  subsystem: "com.gumpw.codans.hierarchy",
  category: "reconcile"
)

/// Diagnostics for the user-script dispatch path. Useful when a user
/// configures `.split` / `.focused` and gets a fresh tab instead — the
/// breadcrumb names which fallback fired and why.
private let runScriptLogger = Logger(
  subsystem: "com.gumpw.codans.hierarchy",
  category: "runScript"
)

/// Diagnostics for worktree removal — in particular, why a tracked
/// branch was kept (checked out elsewhere) instead of deleted. Filter
/// with `log stream --predicate 'category == "worktreeRemove"'`.
private let worktreeRemoveLogger = Logger(
  subsystem: "com.gumpw.codans.hierarchy",
  category: "worktreeRemove"
)

/// TCA dependency-injection bridge over `HierarchyManager`. Features depend
/// on this struct's closures, not on the manager directly; the `liveValue`
/// binds each closure to a concrete `HierarchyManager` instance at app
/// startup via `.withDependencies`.
///
/// Narrow by design: every command is a one-line forward into the manager,
/// and `snapshot` plus `selectionChanges` provide the read paths TCA
/// features need without exposing the `@Observable` manager surface.
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
  /// Add a Server (remote SSH) project. `rootPath` / `gitRoot` are remote
  /// path strings; `remoteHost` marks the project `.server`-kind. Forwards to
  /// `HierarchyManager.addServerProject`.
  var addServerProject:
    @MainActor @Sendable (
      _ name: String, _ remoteHost: RemoteHost, _ rootPath: String, _ gitRoot: String?
    ) -> ProjectID
  /// Apply an edited Server-project connection in place. A rootPath change
  /// reseeds the worktree rows (the old remote paths are stale). Forwards to
  /// `HierarchyManager.updateServerProject`.
  var updateServerProject:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ remoteHost: RemoteHost, _ rootPath: String, _ gitRoot: String?
    ) -> Void
  var removeProject: @MainActor @Sendable (_ projectID: ProjectID) throws -> Void
  var renameProject:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ name: String
    ) throws -> Void
  /// Recolors the Project. `nil` clears the assignment so the UI falls back
  /// to the system accent. Silent no-op for unknown ids / unchanged values.
  var setProjectColor:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ color: ProjectColor?
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

  // MARK: - Tab mutations

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
  /// Updates the tab's SF Symbol icon under the `TabIconLock` rules
  /// (`.auto` ≤ `.script` ≤ `.user`). A write whose `lock` cannot
  /// override the tab's current lock is a silent no-op — UI consumers
  /// re-read the tab afterwards if they need to confirm the result.
  var setTabIcon:
    @MainActor @Sendable (
      _ id: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ icon: String?,
      _ lock: TabIconLock
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

  // MARK: - Runtime state

  /// Read path for the chip's dirty (running-command) spinner. Bound by
  /// `TabChipLabel`; reflects `markPaneRunning` / `markPaneIdle`.
  var tabIsDirty: @MainActor @Sendable (_ tabID: TabID) -> Bool
  /// Worktree-scoped variant of `tabIsDirty`. Sidebar rows surface a busy
  /// glyph when any pane in any tab of the worktree is marked running.
  var worktreeIsDirty: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Bool
  /// Returns the Pane the user most recently focused in `tabID`, or nil.
  /// Mirrors `HierarchyManager.lastFocusedPane(in:)`.
  var lastFocusedPane: @MainActor @Sendable (_ tabID: TabID) -> PaneID?
  /// Forwards to `HierarchyManager.markPaneRunning`.
  var markPaneRunning: @MainActor @Sendable (_ paneID: PaneID) -> Void
  /// Forwards to `HierarchyManager.markPaneIdle`.
  var markPaneIdle: @MainActor @Sendable (_ paneID: PaneID) -> Void
  /// Writer for the foreground-command busy flag, calling
  /// `HierarchyManager.setPaneCommandBusy`. The root reducer invokes it when
  /// the foreground-job poller reports a pane's group started/stopped a
  /// non-agent command. Unions with OSC 9;4 in `tabIsDirty` / `worktreeIsDirty`.
  var setPaneCommandBusy: @MainActor @Sendable (_ paneID: PaneID, _ busy: Bool) -> Void

  var openPane:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ workingDirectory: String, _ initialCommand: String?
    ) async throws -> PaneID
  var splitPane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: SplitTree<PaneID>.NewDirection,
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ workingDirectory: String, _ initialCommand: String?
    ) async throws -> PaneID
  /// Synchronous catalog half of `openPane`: inserts the Pane row into the
  /// Tab (split tree + pane array) and persists, without the async zmx
  /// surface bringup. Callers seeding a pane from a synchronous reducer body
  /// use this so the Pane is observable before the next `.selectionChanged`
  /// fires — closing the `RootFeature.autoSeedTabAndPaneIfNeeded` double-seed
  /// race. Pair with `ensurePaneSurface` to bring the surface up afterwards.
  var createPaneRow:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ workingDirectory: String, _ initialCommand: String?
    ) throws -> PaneID
  /// Async surface-bringup half of `openPane`: spawns the zmx daemon and
  /// attaches the libghostty surface for an already-inserted Pane row.
  /// Idempotent — a no-op when the surface already exists.
  var ensurePaneSurface:
    @MainActor @Sendable (
      _ paneID: PaneID, _ tabID: TabID, _ inWorktree: WorktreeID,
      _ inProject: ProjectID
    ) async throws -> Void
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

  // HierarchyClient is read-only for per-Project preferences (see `snapshot` / `kind`):
  // per-Project editor / worktrees-directory values live on `Settings.projects[pid]` and
  // every consumer routes through `SettingsStore.mutateProject`
  // (`SettingsWriter.setProjectDefaultEditor` / `SettingsWriter.setProjectWorktreesDirectory`).

  var snapshot: @MainActor @Sendable () -> Catalog

  /// Emits whenever the selection chain `(projectID, worktreeID)` changes
  /// in the catalog. Deduped against the previous snapshot. Consumers
  /// subscribe without needing a reference to the `@Observable`
  /// `HierarchyManager`. The stream finishes only when the engine shuts down.
  var selectionChanges: @MainActor @Sendable () -> AsyncStream<HierarchySelection>

  // MARK: - Worktree Management additions

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

  /// Flips `Worktree.isNew` for the given Worktree. Silent for unknown ids / unchanged
  /// values. Persists via the standard debounced save pipeline.
  var setWorktreeIsNew:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ isNew: Bool
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
  /// by `ProjectReconciler`.
  var reconcileDiscoveredWorktrees:
    @MainActor @Sendable (
      _ projectID: ProjectID
    ) async -> Void

  /// Catalog-append step for Create Worktree. Idempotent on path: when a
  /// reconcile pulse already adopted the materialized worktree mid-stream,
  /// this returns the adopted row's id instead of throwing.
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
  ///
  /// Returns a non-fatal warning when removal succeeded but the
  /// worktree's branch was intentionally kept (it's checked out by the
  /// main checkout or another worktree); `nil` on a clean removal.
  var removeWorktreeWithGit:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID
    ) async throws -> String?

  /// Forwards `HierarchyManager.runningPaneCount`.
  var runningPaneCount: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Int

  // MARK: - Project Management

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
  /// Used by the `editor.open` IPC so `codans open` inside a subdirectory still
  /// resolves the parent Project's default editor. Caller canonicalizes.
  var projectContaining: @MainActor @Sendable (_ canonicalPath: String) -> ProjectID?

  /// Derived `ProjectKind` lookup — scans `catalog.projects` for the Project
  /// and returns its kind, or `nil` if the Project is not in the catalog.
  /// The Settings sidebar consults this to choose which sub-rows to render
  /// under a Project. Read-only; the app never writes kind — it flows from
  /// `gitRoot` set at project-discovery time.
  var kind: @MainActor @Sendable (_ projectID: ProjectID) -> ProjectKind?

  // MARK: - Pane Action Routing

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
  /// ghostty RESIZE_SPLIT action carries pixel amounts but codans's
  /// tree only stores ratios.
  var resizePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: ResizeDirection, _ amount: Double
    ) throws -> Void

  /// Re-positions an existing Pane next to `anchorID`, splitting the anchor
  /// along `direction`. Pure split-tree reshape — the moved pane's surface
  /// stays alive (no teardown / re-spawn). Backs the pane drag-and-drop
  /// gesture; self-moves and unknown ids resolve to a no-op / throw inside
  /// the manager.
  var movePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ anchorID: PaneID,
      _ direction: SplitTree<PaneID>.NewDirection,
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  /// Clears the Tab's zoomed-pane flag. Paired with `focusPane` (which
  /// sets the zoom) to service `PaneActionRequest.toggleSplitZoom`.
  var unzoomTab:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID
    ) throws -> Void

  // MARK: - Project Settings

  /// Runs a user-defined `ScriptDefinition` from `Settings.projects[pid].scripts`.
  /// Looks up the script + worktree, opens a fresh tab whose name is the
  /// script's `displayName`, and types the script's `command` into the new
  /// pane's PTY. Project envVars get injected through the spawn-path env
  /// hook. Throws `RunScriptError.unknownScript` when the id is not in the
  /// project's scripts (deleted between user click and effect dispatch);
  /// throws `RunScriptError.missingWorktree` when the worktree disappears.
  var runScript:
    @MainActor @Sendable (
      _ scriptID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) async throws -> Void

  /// Runs a user-defined `ScriptDefinition` from `Settings.general.globalScripts`
  /// (the project-agnostic global command list) in the given Worktree. Resolution
  /// reads the global list instead of a Project's scripts; everything downstream
  /// (tab/pane spawn, run-pane reuse, Run/Stop tracking, onFinished policy) is
  /// shared with `runScript`. `projectID` + `worktreeID` only name where to spawn —
  /// the selected Worktree's context. Throws `RunScriptError.unknownScript` when the
  /// id is absent from `globalScripts`; `.missingWorktree` when the worktree is gone.
  var runGlobalScript:
    @MainActor @Sendable (
      _ scriptID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) async throws -> Void

  /// Launches an `AgentProfile` from `Settings.agents` in the given Worktree.
  /// Renders the profile through `AgentLaunchCommand` and dispatches it the
  /// same way a script is dispatched (new tab / split / focused pane), with
  /// one deliberate difference: agent launches are *not* tracked as run panes,
  /// so invoking the same profile twice opens a second session rather than
  /// re-typing into the first. Throws `RunScriptError.unknownScript` when the
  /// profile id is gone (removed between click and dispatch);
  /// `.missingWorktree` when the worktree is.
  var launchAgentProfile:
    @MainActor @Sendable (
      _ profileID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) async throws -> Void

  /// Lower-level sibling of `launchAgentProfile` for callers that already
  /// hold a resolved profile and need to know where the agent landed: the
  /// `agent.launch` IPC handler and the handoff receiver launch. Same
  /// dispatch, same "never reuse a run pane" rule. Throws
  /// `RunScriptError.missingWorktree` when the worktree is gone.
  var launchAgent: @MainActor @Sendable (_ spec: AgentLaunchSpec) async throws -> AgentLaunchOutcome

  /// Interrupts a running script by sending Ctrl-C (`\u{3}`) to the pane the
  /// script last spawned in `worktreeID`. The pane is left open so the next
  /// run reuses it. Best-effort: a no-op when no run pane is tracked (or it
  /// has since closed) or no `TerminalClient` is wired.
  var stopScript:
    @MainActor @Sendable (
      _ scriptID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) -> Void

  /// Applies `stopScript`'s interrupt-then-close teardown to every script
  /// whose tracked run pane in `worktreeID` is currently executing. Callers
  /// are teardown paths that don't know which scripts are live: the sidebar
  /// ping dot's hover Stop, and the archive / remove lifecycles — those must
  /// not leave a script's child process running against a worktree that is
  /// about to be hidden or deleted. Best-effort, same as `stopScript`.
  var stopAllScripts: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Void

  // MARK: - Worktree lifecycle wrappers

  /// Runs a worktree lifecycle script (archive / delete) in a fresh tab on
  /// the worktree as that pane's `initialCommand`, suspending until the
  /// script finishes (its shell child exits). Returns as a best-effort
  /// no-op when the worktree is gone or the tab/pane could not spawn.
  /// The catalog mutation that follows the script — the archive flag flip
  /// or the relocate-then-prune removal — is the CALLER's job: the sidebar
  /// reducer sequences script → mutation itself so each phase is visible
  /// to the row's in-progress presentation.
  var runWorktreeLifecycleScript:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID,
      _ command: String, _ tabName: String
    ) async -> Void

  // MARK: - Worktree sidebar ordering

  /// Moves a single worktree according to `mode`. Silent no-op on unknown ids and on pinned
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
  /// menu (`notifications:muted` label).
  var setPaneLabel:
    @MainActor @Sendable (
      _ paneID: PaneID,
      _ label: String,
      _ present: Bool
    ) -> Void

  /// Writes `Pane.agentKind` (classified CLI agent currently driving the
  /// pane, e.g. `.claudeCode` / `.codex` / `.pi`). `nil` clears the field.
  /// Idempotent: a repeat call with the same value is a true no-op
  /// (no persistence churn). Silent no-op on unknown `paneID`. Consumed
  /// by `AgentBinder`, which derives the kind from foreground job snapshots.
  var setPaneAgentKind: @MainActor @Sendable (_ paneID: PaneID, _ kind: AgentKind?) -> Void

  /// Writes `Pane.agentSessionID` (agent-supplied session identifier;
  /// stable across resumes for the same agent process). `nil` clears the
  /// field. Idempotent: a repeat call with the same value is a true
  /// no-op. Silent no-op on unknown `paneID`. Consumed alongside
  /// `setPaneAgentKind` by `AgentBinder`.
  var setPaneAgentSessionID: @MainActor @Sendable (_ paneID: PaneID, _ sessionID: String?) -> Void

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

  /// Commands parked on `paneID`, `[]` for an unknown pane. Read by the
  /// Command Queue panel so the reducer edits against live catalog state
  /// rather than a snapshot taken when the panel opened.
  var commandQueue: @MainActor @Sendable (_ paneID: PaneID) -> [QueuedCommand]

  /// Replaces `paneID`'s command queue wholesale. Read-modify-write is the
  /// intended usage; the manager side is the single canonical writer and
  /// no-ops on an unknown pane or an unchanged queue.
  var setCommandQueue: @MainActor @Sendable (_ paneID: PaneID, _ queue: [QueuedCommand]) -> Void
}

enum RunScriptError: Error, Equatable, Sendable {
  case unknownScript(UUID)
  case missingWorktree(WorktreeID)
  case missingProject(ProjectID)
}

/// Everything a single agent launch needs. Carries the resolved
/// `AgentProfile` value (not an id) so callers that build a transient
/// preset — a handoff receiver for an agent with no enabled profile — go
/// through the same pipeline as a saved one.
nonisolated struct AgentLaunchSpec: Sendable, Equatable {
  var profile: AgentProfile
  var projectID: ProjectID
  var worktreeID: WorktreeID
  /// Kickoff prompt appended in the agent's own spelling; ignored by agents
  /// without a prompt style.
  var prompt: String?
  /// Placement overrides. `nil` keeps the profile's saved target / direction.
  var target: ScriptTarget?
  var direction: ScriptSplitDirection?
  /// Pane a `.split` divides. `nil` splits the worktree's focused pane, the
  /// interactive default; a hand-off names its source pane so the receiver
  /// lands beside the agent it takes over from.
  var anchorPaneID: PaneID?
  /// `false` spawns without selecting the tab or stealing focus.
  var focus: Bool
  /// Tab title override; `nil` uses the profile's display name.
  var tabName: String?

  init(
    profile: AgentProfile,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    prompt: String? = nil,
    target: ScriptTarget? = nil,
    direction: ScriptSplitDirection? = nil,
    anchorPaneID: PaneID? = nil,
    focus: Bool = true,
    tabName: String? = nil
  ) {
    self.profile = profile
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.prompt = prompt
    self.target = target
    self.direction = direction
    self.anchorPaneID = anchorPaneID
    self.focus = focus
    self.tabName = tabName
  }
}

/// What an agent launch produced. `tabID` / `paneID` are nil when the
/// command was typed into the focused pane rather than a fresh surface.
nonisolated struct AgentLaunchOutcome: Sendable, Equatable {
  let profile: AgentProfile
  let command: String
  let tabID: TabID?
  let paneID: PaneID?
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
/// `projectID` resolves from `Catalog.selectedProjectID` (the top-level
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
      addServerProject: { name, remoteHost, rootPath, gitRoot in
        manager.addServerProject(
          name: name, remoteHost: remoteHost, rootPath: rootPath, gitRoot: gitRoot
        )
      },
      updateServerProject: { projectID, remoteHost, rootPath, gitRoot in
        manager.updateServerProject(
          projectID: projectID, remoteHost: remoteHost, rootPath: rootPath, gitRoot: gitRoot
        )
      },
      removeProject: { projectID in try manager.removeProject(projectID) },
      renameProject: { projectID, name in
        try manager.renameProject(projectID, name: name)
      },
      setProjectColor: { projectID, color in
        try manager.setProjectColor(projectID, color: color)
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
      setTabIcon: { tabID, worktreeID, projectID, icon, lock in
        try manager.setTabIcon(
          tabID, in: worktreeID, in: projectID, icon: icon, lock: lock
        )
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
      setPaneCommandBusy: { paneID, busy in manager.setPaneCommandBusy(paneID, busy) },
      openPane: { [weak settings] tabID, worktreeID, projectID, cwd, initial in
        // Defensive guard against stale catalog state: when a worktree
        // is deleted outside the app (`git worktree remove`) before
        // reconcile catches up, libghostty crashes if it tries to spawn
        // a shell in a non-existent cwd. Reject here so callers'
        // `try?` swallows the error instead of bringing down the app.
        // Skipped for Server projects: `cwd` is a remote path that never
        // exists locally, and libghostty is handed a real local cwd — the
        // remote `cd` (inside the SSH command) owns the directory instead.
        let isRemote =
          manager.catalog.projects.first(where: { $0.id == projectID })?.isRemote ?? false
        if !isRemote {
          var isDir: ObjCBool = false
          guard
            FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
            isDir.boolValue
          else {
            throw HierarchyError.notFound("Worktree path missing: \(cwd)")
          }
        }
        // Resolve project envVars from the SettingsStore so every
        // user-flow openPane (TabBar new-tab, SplitViewport new-tab,
        // CreateWorktree, IPC openPane) inherits Project-defined env. When
        // the live wiring omits a SettingsStore (legacy callers, headless
        // tests) the env defaults to empty and the pane spawns with the
        // raw process env.
        let env: [String: String] =
          settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) }
          ?? [:]
        return try await manager.openPane(
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
        return try await manager.splitPane(
          paneID, direction: direction,
          in: tabID, in: worktreeID, in: projectID,
          workingDirectory: cwd, initialCommand: initial, env: env
        )
      },
      createPaneRow: { tabID, worktreeID, projectID, cwd, initial in
        try manager.createPaneRow(
          in: tabID, in: worktreeID, in: projectID,
          workingDirectory: cwd, initialCommand: initial
        )
      },
      ensurePaneSurface: { [weak settings] paneID, tabID, worktreeID, projectID in
        // Mirror openPane's env resolution — this is the surface-bringup
        // half, so Project-defined envVars must still reach the spawned shell.
        let env: [String: String] =
          settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) }
          ?? [:]
        try await manager.ensurePaneSurface(
          paneID, in: tabID, in: worktreeID, in: projectID, env: env
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
      snapshot: { manager.catalog },
      selectionChanges: { makeSelectionStream(manager: manager) },
      setWorktreeArchived: { worktreeID, archived in
        try manager.setWorktreeArchived(worktreeID: worktreeID, archived: archived)
      },
      setWorktreePinned: { worktreeID, isPinned in
        manager.setWorktreePinned(worktreeID: worktreeID, isPinned: isPinned)
      },
      setWorktreeIsNew: { worktreeID, isNew in
        manager.setWorktreeIsNew(worktreeID: worktreeID, isNew: isNew)
      },
      setProjectExpanded: { projectID, isExpanded in
        manager.setProjectExpanded(projectID: projectID, isExpanded: isExpanded)
      },
      reconcileDiscoveredWorktrees: { [weak settings] projectID in
        await reconcile(
          projectID: projectID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient,
          gitCLI: gitCLI,
          settings: settings
        )
      },
      createWorktreeWithGit: { projectID, name, branch, path in
        // reuseExisting heals the create-vs-reconcile race: a window-focus
        // reconcile pulse can adopt the freshly materialized worktree into
        // the catalog while the creation stream is still running its setup
        // phase. Without it the finish path throws invariantViolation
        // ("worktree with path … already exists") against its own worktree.
        try manager.createWorktree(
          in: projectID,
          name: name, path: path, branch: branch,
          reuseExisting: true
        )
      },
      removeWorktreeWithGit: { [weak settings] worktreeID, projectID in
        let deleteRemote = (settings?.settings ?? .default).worktree.deleteRemoteBranchWithWorktree
        return try await removeWorktreeWithGit(
          worktreeID: worktreeID,
          projectID: projectID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient,
          deleteRemoteBranch: deleteRemote
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
      movePane: { paneID, anchorID, direction, tabID, worktreeID, projectID in
        try manager.movePane(
          paneID, relativeTo: anchorID, direction: direction,
          in: tabID, in: worktreeID, in: projectID
        )
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
      runGlobalScript: { [weak settings] scriptID, projectID, worktreeID in
        try await runGlobalScript(
          scriptID: scriptID,
          projectID: projectID,
          worktreeID: worktreeID,
          manager: manager,
          settings: settings,
          terminalClient: terminalClient
        )
      },
      launchAgentProfile: { [weak settings] profileID, projectID, worktreeID in
        let snapshot = settings?.settings ?? .default
        guard let profile = snapshot.agents.profile(id: profileID) else {
          throw RunScriptError.unknownScript(profileID)
        }
        _ = try await launchAgent(
          spec: AgentLaunchSpec(profile: profile, projectID: projectID, worktreeID: worktreeID),
          manager: manager,
          snapshot: snapshot,
          terminalClient: terminalClient
        )
      },
      launchAgent: { [weak settings] spec in
        try await launchAgent(
          spec: spec,
          manager: manager,
          snapshot: settings?.settings ?? .default,
          terminalClient: terminalClient
        )
      },
      stopScript: { scriptID, _, worktreeID in
        stopScript(
          scriptID: scriptID,
          worktreeID: worktreeID,
          manager: manager,
          terminalClient: terminalClient
        )
      },
      stopAllScripts: { worktreeID in
        for scriptID in manager.runningScriptIDs(in: worktreeID) {
          stopScript(
            scriptID: scriptID,
            worktreeID: worktreeID,
            manager: manager,
            terminalClient: terminalClient
          )
        }
      },
      runWorktreeLifecycleScript: { [weak settings] worktreeID, projectID, command, tabName in
        await openNewTabAndAwaitExit(
          worktreeID: worktreeID, projectID: projectID,
          command: command, tabName: tabName,
          manager: manager, terminalClient: terminalClient,
          settings: settings?.settings ?? .default
        )
      },
      promoteWorktree: { projectID, worktreeID, mode in
        manager.promoteWorktree(in: projectID, worktreeID: worktreeID, mode: mode)
      },
      setPaneLabel: { paneID, label, present in
        manager.setPaneLabel(paneID: paneID, label: label, present: present)
      },
      setPaneAgentKind: { paneID, kind in
        manager.setPaneAgentKind(paneID, kind: kind)
      },
      setPaneAgentSessionID: { paneID, sessionID in
        manager.setPaneAgentSessionID(paneID, sessionID: sessionID)
      },
      updatePaneWorkingDirectory: { paneID, newPath in
        manager.updatePaneWorkingDirectory(paneID, to: newPath)
      },
      reorderWorktrees: { projectID, segment, from, to in
        try manager.reorderWorktrees(
          in: projectID,
          segment: segment, from: from, to: to
        )
      },
      commandQueue: { paneID in manager.commandQueue(for: paneID) },
      setCommandQueue: { paneID, queue in manager.setCommandQueue(queue, for: paneID) }
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
    try await runResolvedScript(
      script: script,
      projectID: projectID,
      worktreeID: worktreeID,
      manager: manager,
      snapshot: snapshot,
      terminalClient: terminalClient
    )
  }

  /// Global-command sibling of `runScript`: resolves the `ScriptDefinition`
  /// from `Settings.general.globalScripts` rather than a Project's scripts,
  /// then hands off to the shared `runResolvedScript` pipeline. `projectID` /
  /// `worktreeID` name the spawn target (the selected Worktree).
  @MainActor
  private static func runGlobalScript(
    scriptID: UUID,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    settings: SettingsStore?,
    terminalClient: TerminalClient?
  ) async throws {
    let snapshot = settings?.settings ?? .default
    guard let script = snapshot.general.globalScripts.first(where: { $0.id == scriptID })
    else {
      throw RunScriptError.unknownScript(scriptID)
    }
    try await runResolvedScript(
      script: script,
      projectID: projectID,
      worktreeID: worktreeID,
      manager: manager,
      snapshot: snapshot,
      terminalClient: terminalClient
    )
  }

  /// Launches a resolved `AgentProfile` through the shared script pipeline.
  /// The profile renders into a synthetic `ScriptDefinition` — the
  /// dispatcher already knows how to open a tab / split / focused pane with a
  /// command and a tab icon, and an agent launch is exactly that plus a
  /// different way of composing the command string.
  ///
  /// `tracksRunPane: false` is the one behavioural difference: an agent is a
  /// session, not a job, so a second launch of the same profile opens a
  /// second session instead of re-typing into the first one's pane (which is
  /// what the Run/Stop toggle wants for scripts).
  @MainActor
  private static func launchAgent(
    spec: AgentLaunchSpec,
    manager: HierarchyManager,
    snapshot: Settings,
    terminalClient: TerminalClient?
  ) async throws -> AgentLaunchOutcome {
    let profile = spec.profile
    if profile.usesDedicatedHome {
      // The agent CLI will write config / credentials under this HOME on
      // first run; most refuse to create a missing home themselves.
      try? FileManager.default.createDirectory(
        at: AgentLaunchCommand.dedicatedHomeURL(for: profile),
        withIntermediateDirectories: true
      )
    }
    let command = AgentLaunchCommand.render(profile: profile, prompt: spec.prompt)
    let script = ScriptDefinition(
      id: profile.id,
      kind: .custom,
      name: spec.tabName ?? profile.displayName,
      command: command,
      // Brand mark rather than a generic glyph: the tab chip resolves the
      // `agent:` reference to the same asset the Agents pane and the
      // toolbar menu show, so one agent reads the same across surfaces.
      systemImage: profile.tabIcon,
      target: spec.target ?? profile.target,
      direction: spec.direction ?? profile.direction,
      onFinished: .none,
      focus: spec.focus
    )
    let paneID = try await runResolvedScript(
      script: script,
      projectID: spec.projectID,
      worktreeID: spec.worktreeID,
      manager: manager,
      snapshot: snapshot,
      terminalClient: terminalClient,
      tracksRunPane: false,
      anchorPaneID: spec.anchorPaneID
    )
    let tabID = paneID.flatMap { manager.addressOf(paneID: $0)?.2 }
    return AgentLaunchOutcome(profile: profile, command: command, tabID: tabID, paneID: paneID)
  }

  /// Shared execution pipeline for a fully-resolved `ScriptDefinition`,
  /// regardless of whether it came from a Project's `scripts`, the global
  /// `general.globalScripts` list, or an agent profile. Resolves the worktree
  /// cwd + env, honours the run-pane reuse / Run-Stop tracking / onFinished
  /// policy, and spawns the tab/pane. Run-pane tracking keys on (worktreeID,
  /// scriptID); global and project scripts never collide because each carries
  /// a distinct UUID.
  ///
  /// `tracksRunPane: false` opts a caller out of both halves of that tracking
  /// — no reuse lookup on the way in, no `setRunScriptPane` on the way out —
  /// so every invocation spawns a fresh surface.
  ///
  /// `anchorPaneID` names the pane a `.split` divides. Left nil, the split
  /// anchors on the worktree's focused pane; a pane that is not in this
  /// worktree is ignored the same way.
  ///
  /// Returns the pane the command landed in when a fresh surface was spawned;
  /// `nil` for a reused run pane or a `.focused` dispatch.
  @MainActor
  @discardableResult
  private static func runResolvedScript(
    script: ScriptDefinition,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    snapshot: Settings,
    terminalClient: TerminalClient?,
    tracksRunPane: Bool = true,
    anchorPaneID: PaneID? = nil
  ) async throws -> PaneID? {
    let scriptID = script.id
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

    let onFinishedNeeded = script.resolvedOnFinished != .none

    // Reuse path: a run is unique per (worktree, script). If the dedicated
    // run pane is still alive — from an earlier run this session or restored
    // from the persisted catalog after a relaunch — never spawn a second
    // tab/pane for it.
    if tracksRunPane,
      script.target == .newTab || script.target == .split,
      let terminalClient,
      let existing = manager.runScriptPane(worktreeID: worktreeID, scriptID: scriptID)
    {
      if manager.isScriptRunning(worktreeID: worktreeID, scriptID: scriptID) {
        // Already executing — surface the run instead of typing a second
        // command into the busy pty. Honour `focus` so background scripts
        // stay background.
        if script.focus, let (proj, wt, tab) = manager.addressOf(paneID: existing) {
          try? manager.selectTab(tab, in: wt, in: proj)
          manager.focusSurfaceView(for: existing)
        }
        return nil
      }
      // Idle run pane → re-run in place. Subscribe before the send for the
      // same no-replay reason as the spawn path below.
      let reuseStream: AsyncStream<TerminalEvent>? =
        onFinishedNeeded ? terminalClient.events() : nil
      if let (proj, wt, tab) = manager.addressOf(paneID: existing) {
        // After a relaunch the restored pane has no live surface yet (they
        // spawn lazily when a tab is shown); bring it up first or the
        // sendInput below lands on nothing. No-op when already live.
        try? await manager.ensurePaneSurface(existing, in: tab, in: wt, in: proj, env: env)
        if script.focus {
          try? manager.selectTab(tab, in: wt, in: proj)
          manager.focusSurfaceView(for: existing)
        }
      }
      // Same wrapping as the spawn path: a close-on-finish policy needs the
      // shell to exit after the command so `childExited` fires.
      let rerunCommand = wrapForOnFinished(
        command: script.command,
        policy: script.resolvedOnFinished
      )
      terminalClient.sendInput(existing, rerunCommand + "\n")
      if let reuseStream {
        scheduleOnFinishedAction(
          paneID: existing,
          policy: script.resolvedOnFinished,
          manager: manager,
          eventStream: reuseStream
        )
      }
      return nil
    }

    // Subscribe before spawn: events() is broadcast and does not
    // replay. A one-shot script that exits before scheduleOnFinishedAction
    // calls events() would otherwise miss the paneExited and the
    // onFinished policy would never fire.
    let preSubscribedStream: AsyncStream<TerminalEvent>? =
      onFinishedNeeded ? terminalClient?.events() : nil

    let spawnedPaneID = try await dispatchScript(
      script: script,
      worktreeID: worktreeID,
      projectID: projectID,
      cwd: cwd,
      env: env,
      manager: manager,
      terminalClient: terminalClient,
      anchorPaneID: anchorPaneID
    )

    // Record the dedicated pane so the next run reuses it and the toolbar
    // Run/Stop toggle can find it. Only `.newTab` / `.split` create one;
    // `.focused` returns nil (it writes into the user's focused pane).
    if tracksRunPane,
      let spawnedPaneID,
      script.target == .newTab || script.target == .split
    {
      manager.setRunScriptPane(
        worktreeID: worktreeID, scriptID: scriptID, paneID: spawnedPaneID)
    }

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
    return spawnedPaneID
  }

  /// Stops the run for `(worktreeID, scriptID)`: interrupts the pane's
  /// child (Ctrl-C → SIGINT) and then closes the run surface — the whole
  /// tab when the run pane is its only pane, just the pane otherwise (a
  /// `.split` run, or a run tab the user split into). Stop is a teardown,
  /// not a pause: the next run spawns a fresh tab/pane. Best-effort: silent
  /// no-op when no live run pane is tracked or no `TerminalClient` is wired.
  @MainActor
  private static func stopScript(
    scriptID: UUID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    terminalClient: TerminalClient?
  ) {
    guard let terminalClient,
      let paneID = manager.runScriptPane(worktreeID: worktreeID, scriptID: scriptID)
    else {
      runScriptLogger.info(
        "stopScript: no live run pane to interrupt for script \(scriptID, privacy: .public)"
      )
      return
    }
    // Goes through the key-event path (`ghostty_surface_key`), not `sendInput`'s
    // text path — the latter filters control bytes, so a literal 0x03 written
    // as text never reaches the PTY as an interrupt. The interrupt gives the
    // child a graceful SIGINT before the surface teardown below hangs up
    // the pty.
    terminalClient.interrupt(paneID)
    guard let (projectID, resolvedWorktreeID, tabID) = manager.addressOf(paneID: paneID) else {
      return
    }
    let tab =
      manager.catalog.projects
      .first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == resolvedWorktreeID })?
      .tabs.first(where: { $0.id == tabID })
    if tab?.panes.count == 1 {
      try? manager.closeTab(tabID, in: resolvedWorktreeID, in: projectID)
      return
    }
    // Resolve the survivor BEFORE the tree mutation invalidates the leaf, then
    // hand it focus. `closePane` drops the tab's last-focused entry (the run
    // pane usually owns it — scripts spawn with `focus: true`), and unlike the
    // ⌘W / pane-action close paths nothing else re-homes input, so the Tab was
    // left with no focused pane until the user clicked one.
    //
    // Called synchronously rather than hopping a turn like the reducer-side
    // close paths: the survivor's surface view is still attached here (SwiftUI
    // rebuilds the viewport after this turn), so `makeFirstResponder` takes
    // immediately, and `GhosttySurfaceView` reclaims first responder on its own
    // once the rebuild re-attaches it.
    let focusTarget = tab?.splitTree.focusTargetAfterClosing(paneID)
    try? manager.closePane(paneID, in: tabID, in: resolvedWorktreeID, in: projectID)
    if let focusTarget {
      manager.focusSurfaceView(for: focusTarget)
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
    terminalClient: TerminalClient?,
    anchorPaneID: PaneID? = nil
  ) async throws -> PaneID? {
    // initialCommand is replayed by TerminalEngine via `sendInput(command + "\n")`
    // into an interactive shell, so the shell stays at a prompt after the user's
    // command finishes and `paneExited` never fires. When the script has an
    // onFinished policy (closeTab / closePane), append `; exit` so the shell
    // exits as soon as the script's last statement completes — same trick the
    // archive/delete lifecycle uses in `openNewTabAndAwaitExit`. Without it,
    // "Close tab when finished" silently never triggers.
    let spawnCommand = wrapForOnFinished(
      command: script.command,
      policy: script.resolvedOnFinished
    )

    func openInNewTab() async throws -> PaneID {
      let tabID = try manager.createTab(
        in: worktreeID, in: projectID,
        name: script.displayName,
        select: script.focus
      )
      // Carry the script's resolved SF Symbol onto the spawned tab under
      // the .script lock. A later auto re-derivation cannot displace it;
      // a user pick still can. Failures are non-fatal — the tab keeps
      // running with its default icon.
      try? manager.setTabIcon(
        tabID, in: worktreeID, in: projectID,
        icon: script.resolvedSystemImage,
        lock: .script
      )
      return try await manager.openPane(
        in: tabID, in: worktreeID, in: projectID,
        workingDirectory: cwd,
        initialCommand: spawnCommand,
        env: env
      )
    }

    switch script.target {
    case .newTab:
      return try await openInNewTab()

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
      return try await openInNewTab()

    case .split:
      if let anchor = explicitAnchor(anchorPaneID, worktreeID: worktreeID, in: manager)
        ?? focusedAnchor(worktreeID: worktreeID, in: manager)
      {
        return try await manager.splitPane(
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
      return try await openInNewTab()
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

  /// A caller-named split anchor, accepted only while it is still a pane of
  /// this worktree; anything else falls through to the focused-pane rule.
  @MainActor
  private static func explicitAnchor(
    _ paneID: PaneID?,
    worktreeID: WorktreeID,
    in manager: HierarchyManager
  ) -> (tabID: TabID, paneID: PaneID)? {
    guard let paneID, let address = manager.addressOf(paneID: paneID), address.1 == worktreeID
    else { return nil }
    return (address.2, paneID)
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
        case .paneInfoChanged(let pid, .childExited) where pid == paneID:
          // The child ended, but libghostty keeps the surface open (its
          // embedded API force-enables wait-after-command whenever a
          // spawn command is set), so `paneExited` would only fire after
          // a keypress in the dead pane. The child's exit IS the
          // "finished" the policy is about — apply it now.
          await MainActor.run {
            applyOnFinished(policy: policy, paneID: paneID, manager: manager)
          }
          return
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
  /// wired. Used by the archive / delete lifecycle flows — both must wait
  /// for the user's script to finish before mutating catalog state.
  ///
  /// `initialCommand` is delivered to the pane via `sendInput`, i.e. it
  /// is typed into an interactive shell rather than passed through
  /// `sh -c`. A bare `npm install\n` would therefore leave the shell at
  /// an interactive prompt and the await would block until the user
  /// manually `exit`s — the archive flag would never flip. To make
  /// lifecycle scripts terminate deterministically, the command is
  /// wrapped as `<trimmed>; exit\n` so the shell exits after running
  /// the user's script regardless of its outcome.
  ///
  /// Completion keys on the CHILD's exit (`paneInfoChanged(.childExited)`),
  /// not on `paneExited`: libghostty's embedded API force-enables
  /// `wait-after-command` whenever a spawn command is set (every codans
  /// pane sets one — `zmx attach`), so a surface whose child died stays
  /// open until a keypress, and `paneExited` — which fires on SURFACE
  /// close — would stall the lifecycle until the user pressed a key in
  /// the dead pane. On a clean exit the transient script tab is torn
  /// down here; a failing script keeps its tab so the output stays
  /// readable. The surface-close family is still matched as a fallback
  /// for races (user closes the tab mid-script, crash, teardown).
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
    let tabID: TabID
    do {
      tabID = try manager.createTab(
        in: worktreeID, in: projectID, name: tabName
      )
      paneID = try await manager.openPane(
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
      case .paneInfoChanged(let pid, .childExited(let code)) where pid == paneID:
        // The script (and its `; exit` shell) is done — this is the
        // lifecycle's completion signal. `exit` propagates the last
        // command's status, so `code` is the script's own outcome.
        if code == 0 {
          try? manager.closeTab(tabID, in: worktreeID, in: projectID)
        }
        return
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
  /// stored for `Project.rootPath` — without this normalization the main
  /// checkout would duplicate on every reconcile under `/tmp` and `/var`.
  /// Swallows and logs `GitWorktreeError` — this path is idempotent and
  /// must never crash a reconcile.
  @MainActor
  private static func reconcile(
    projectID: ProjectID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI,
    settings: SettingsStore? = nil
  ) async {
    guard let project = manager.catalog.projects.first(where: { $0.id == projectID })
    else { return }
    // Server projects discover + reconcile entirely over SSH (no bundled `wt`,
    // no local `wt ls`, no local symlink canonicalization). Branch off before
    // any local-filesystem git path runs.
    if project.isRemote {
      await reconcileRemote(project: project, manager: manager)
      return
    }
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
      // Cleanup: auto-delete archived worktrees past their retention period.
      // Runs on the same launch / window-focus pulse as discovery, so no
      // separate timer is needed (see Settings → Worktrees → Cleanup).
      await sweepExpiredArchivedWorktrees(
        projectID: projectID,
        manager: manager,
        gitWorktreeClient: gitWorktreeClient,
        settings: settings
      )
    } catch {
      // Log under com.gumpw.codans.hierarchy/reconcile and swallow —
      // never throw, never crash a reconcile. `projectID` is printed as
      // .public because it's a UUID opaque to users; the error description
      // is `.private(mask: .hash)` because `GitWorktreeError.commandFailed`
      // carries raw git stderr which can embed local absolute paths.
      reconcileLogger.error(
        "reconcileDiscoveredWorktrees failed: project=\(projectID.raw.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
      )
    }
  }

  /// Server-project counterpart of `reconcile`: discovers the remote git root
  /// and worktree list over SSH via `RemoteGitService`, normalizes each path
  /// string-only (`normalizeRemotePath` — never the local symlink resolver),
  /// and hands the result to the shared append-only merge. Mirrors the local
  /// path's "re-detect gitRoot when nil" auto-promotion so a plain remote
  /// folder becomes a git Server project once the user runs `git init` on the
  /// host. Swallows and logs errors — reconcile is idempotent and must never
  /// crash, and a transient SSH failure must not archive live worktree rows
  /// (the merge only appends / upgrades; the stale-sweep runs against the
  /// discovered set, so an *empty* discovery from a failed probe never reaches
  /// it because we return early on `catch`).
  @MainActor
  private static func reconcileRemote(
    project: Project,
    manager: HierarchyManager
  ) async {
    guard let host = project.remoteHost else { return }
    let projectID = project.id
    let service = RemoteGitService(host: host)
    let gitRoot: String? = await {
      if let existing = project.gitRoot { return existing }
      if let discovered = await service.discoverGitRoot(candidatePath: project.rootPath),
        !discovered.isEmpty
      {
        manager.setProjectGitRoot(projectID: projectID, gitRoot: discovered)
        return discovered
      }
      return nil
    }()
    guard let gitRoot else { return }
    do {
      let entries = try await service.listWorktrees(gitRoot: gitRoot)
      let mapped = entries.map { entry -> (path: String, branch: String?) in
        let branch = (entry.branch?.isEmpty == false) ? entry.branch : nil
        return (path: HierarchyManager.normalizeRemotePath(entry.path), branch: branch)
      }
      _ = manager.reconcileDiscoveredWorktrees(
        projectID: projectID,
        entries: mapped,
        normalizePath: HierarchyManager.normalizeRemotePath
      )
    } catch {
      reconcileLogger.error(
        "remote reconcile failed: project=\(projectID.raw.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
      )
    }
  }

  /// Auto-delete sweep for Settings → Worktrees → Cleanup. No-op unless
  /// `autoDeleteArchived` is on. Asks the manager for the archived worktrees
  /// whose retention period has elapsed (the manager also back-fills any
  /// pre-existing archived rows that lack a timestamp, so they age from first
  /// observation rather than being deleted retroactively), then removes each
  /// via the shared git path — honoring `deleteRemoteBranchWithWorktree` so
  /// the auto-delete behaves like a manual delete. Best-effort per worktree:
  /// a single failure is logged and the sweep moves on.
  @MainActor
  private static func sweepExpiredArchivedWorktrees(
    projectID: ProjectID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient,
    settings: SettingsStore?
  ) async {
    let worktreeSettings = (settings?.settings ?? .default).worktree
    guard worktreeSettings.autoDeleteArchived else { return }
    let ttl = TimeInterval(worktreeSettings.autoDeletePeriod.rawValue) * 86_400
    let deleteRemoteBranch = worktreeSettings.deleteRemoteBranchWithWorktree
    let due = manager.archivedWorktreesDue(in: projectID, now: Date(), ttl: ttl)
    for worktreeID in due {
      do {
        try await removeWorktreeWithGit(
          worktreeID: worktreeID,
          projectID: projectID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient,
          deleteRemoteBranch: deleteRemoteBranch
        )
      } catch {
        reconcileLogger.error(
          "auto-delete archived worktree failed: project=\(projectID.raw.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
        )
      }
    }
  }

  /// Factored out of the `removeWorktreeWithGit` closure so the
  /// control flow stays readable. Tears down all surfaces first (the
  /// relocate-then-prune step about to run will move the worktree's
  /// working directory out from under any open terminals, so panes
  /// holding the cwd as a live file descriptor must be closed
  /// beforehand), then runs git, then drops the catalog row.
  /// Re-throws `GitWorktreeError` for the caller to surface.
  @discardableResult
  @MainActor
  private static func removeWorktreeWithGit(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient,
    deleteRemoteBranch: Bool
  ) async throws -> String? {
    guard let project = manager.catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let gitRoot = project.gitRoot
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    manager.tearDownWorktreeSurfaces(worktreeID: worktreeID)
    let gitRootURL = URL(fileURLWithPath: gitRoot)
    // Resolve the branch authoritatively from git BEFORE removal —
    // `worktree.branch` can be empty/stale (reconciled rows, legacy
    // catalog entries), and a missed branch deletion is exactly what
    // leaves a dangling ref that blocks same-name re-creation. Match by
    // canonical path; fall back to the catalog value. Remote paths use the
    // string-only normalizer — the local symlink resolver would corrupt them.
    let isRemote = project.isRemote
    func normalize(_ path: String) -> String {
      isRemote
        ? HierarchyManager.normalizeRemotePath(path)
        : HierarchyManager.canonicalPath(path)
    }
    let liveBranch = (try? await gitWorktreeClient.lsWorktrees(gitRootURL))?
      .first { normalize($0.path) == normalize(worktree.path) }?
      .branch
    let branchToDelete = [liveBranch, worktree.branch]
      .compactMap { $0 }
      .first { !$0.isEmpty }

    try await gitWorktreeClient.removeWorktree(
      gitRootURL,
      URL(fileURLWithPath: worktree.path)
    )
    // Drop the branch the worktree was tracking. `git worktree remove`
    // intentionally leaves the ref behind, so re-creating a worktree
    // with the same name afterwards trips Codans's "branch already
    // exists" guard. git refuses if the branch is checked out elsewhere
    // (main / shared) — which is exactly when we DON'T want to delete it.
    var keptWarning: String?
    if let branch = branchToDelete {
      // Delete the remote tracking branch first, while the local branch
      // (and its upstream config) still exists so the remote can be
      // resolved. Gated on the user's "Delete remote branch with worktree"
      // setting; also best-effort.
      if deleteRemoteBranch {
        await gitWorktreeClient.deleteRemoteBranchIfExists(gitRootURL, branch)
      }
      switch await gitWorktreeClient.deleteBranchIfExists(gitRootURL, branch) {
      case .deleted, .absent:
        break
      case .kept(let reason):
        worktreeRemoveLogger.notice(
          "kept branch after worktree remove: branch=\(branch, privacy: .public) reason=\(reason, privacy: .public)"
        )
        keptWarning =
          "Worktree removed. Branch \"\(branch)\" was kept because it's checked out elsewhere; "
          + "re-creating a worktree with the same name will reuse it."
      }
    }
    try manager.removeWorktree(worktreeID, from: projectID)
    return keptWarning
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
    addServerProject: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    updateServerProject: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeProject: { _ in fatalError("HierarchyClient.liveValue not configured") },
    renameProject: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectColor: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktree: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectProject: { _ in fatalError("HierarchyClient.liveValue not configured") },
    selectWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    renameTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setTabColor: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setTabIcon: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
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
    setPaneCommandBusy: { _, _ in },
    openPane: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    splitPane: { _, _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createPaneRow: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    ensurePaneSurface: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closePane: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusPane: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusSurfaceView: { _ in fatalError("HierarchyClient.liveValue not configured") },
    resizeSplit: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    snapshot: { fatalError("HierarchyClient.liveValue not configured") },
    selectionChanges: { AsyncStream { $0.finish() } },
    setWorktreeArchived: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreePinned: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreeIsNew: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
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
    movePane: { _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    unzoomTab: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runGlobalScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    launchAgentProfile: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    launchAgent: { _ in fatalError("HierarchyClient.liveValue not configured") },
    stopScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    stopAllScripts: { _ in fatalError("HierarchyClient.liveValue not configured") },
    runWorktreeLifecycleScript: { _, _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    promoteWorktree: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setPaneLabel: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setPaneAgentKind: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setPaneAgentSessionID: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    updatePaneWorkingDirectory: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    reorderWorktrees: { _, _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    commandQueue: { _ in [] },
    setCommandQueue: { _, _ in
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
    addServerProject: unimplemented("HierarchyClient.addServerProject", placeholder: ProjectID()),
    updateServerProject: unimplemented("HierarchyClient.updateServerProject"),
    removeProject: unimplemented("HierarchyClient.removeProject"),
    renameProject: unimplemented("HierarchyClient.renameProject"),
    setProjectColor: unimplemented("HierarchyClient.setProjectColor"),
    createWorktree: unimplemented("HierarchyClient.createWorktree", placeholder: WorktreeID()),
    removeWorktree: unimplemented("HierarchyClient.removeWorktree"),
    selectProject: unimplemented("HierarchyClient.selectProject"),
    selectWorktree: unimplemented("HierarchyClient.selectWorktree"),
    createTab: unimplemented("HierarchyClient.createTab", placeholder: TabID()),
    closeTab: unimplemented("HierarchyClient.closeTab"),
    selectTab: unimplemented("HierarchyClient.selectTab"),
    renameTab: unimplemented("HierarchyClient.renameTab"),
    setTabColor: unimplemented("HierarchyClient.setTabColor"),
    setTabIcon: unimplemented("HierarchyClient.setTabIcon"),
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
    setPaneCommandBusy: unimplemented("HierarchyClient.setPaneCommandBusy"),
    openPane: unimplemented("HierarchyClient.openPane", placeholder: PaneID()),
    splitPane: unimplemented("HierarchyClient.splitPane", placeholder: PaneID()),
    createPaneRow: unimplemented("HierarchyClient.createPaneRow", placeholder: PaneID()),
    ensurePaneSurface: unimplemented("HierarchyClient.ensurePaneSurface"),
    closePane: unimplemented("HierarchyClient.closePane"),
    focusPane: unimplemented("HierarchyClient.focusPane"),
    // Pure visual side-effect (focuses an NSView; no return value, no test
    // contract worth asserting). Every create/split path tail-calls this, so
    // an `unimplemented` here turns ~all routing tests into noisy stub farms.
    focusSurfaceView: { _ in },
    resizeSplit: unimplemented("HierarchyClient.resizeSplit"),
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
    setWorktreeIsNew: unimplemented("HierarchyClient.setWorktreeIsNew"),
    setProjectExpanded: unimplemented("HierarchyClient.setProjectExpanded"),
    reconcileDiscoveredWorktrees: unimplemented("HierarchyClient.reconcileDiscoveredWorktrees"),
    createWorktreeWithGit: unimplemented(
      "HierarchyClient.createWorktreeWithGit", placeholder: WorktreeID()
    ),
    removeWorktreeWithGit: unimplemented(
      "HierarchyClient.removeWorktreeWithGit", placeholder: nil
    ),
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
    movePane: unimplemented("HierarchyClient.movePane"),
    unzoomTab: unimplemented("HierarchyClient.unzoomTab"),
    runScript: unimplemented("HierarchyClient.runScript"),
    runGlobalScript: unimplemented("HierarchyClient.runGlobalScript"),
    launchAgentProfile: unimplemented("HierarchyClient.launchAgentProfile"),
    launchAgent: unimplemented(
      "HierarchyClient.launchAgent",
      placeholder: AgentLaunchOutcome(
        profile: AgentProfile(kind: .claudeCode), command: "", tabID: nil, paneID: nil)
    ),
    stopScript: unimplemented("HierarchyClient.stopScript"),
    stopAllScripts: unimplemented("HierarchyClient.stopAllScripts"),
    runWorktreeLifecycleScript: unimplemented(
      "HierarchyClient.runWorktreeLifecycleScript"
    ),
    promoteWorktree: unimplemented("HierarchyClient.promoteWorktree"),
    setPaneLabel: unimplemented("HierarchyClient.setPaneLabel"),
    setPaneAgentKind: unimplemented("HierarchyClient.setPaneAgentKind"),
    setPaneAgentSessionID: unimplemented("HierarchyClient.setPaneAgentSessionID"),
    updatePaneWorkingDirectory: unimplemented("HierarchyClient.updatePaneWorkingDirectory"),
    reorderWorktrees: unimplemented("HierarchyClient.reorderWorktrees"),
    // Quiet `[]` mirrors the liveValue fallback: SwiftUI bodies read the
    // queue on every render of a pane badge, and a detached render pass in
    // the test host must not record an issue against `unimplemented(...)`.
    commandQueue: { _ in [] },
    setCommandQueue: unimplemented("HierarchyClient.setCommandQueue")
  )
}

extension DependencyValues {
  var hierarchyClient: HierarchyClient {
    get { self[HierarchyClient.self] }
    set { self[HierarchyClient.self] = newValue }
  }
}
