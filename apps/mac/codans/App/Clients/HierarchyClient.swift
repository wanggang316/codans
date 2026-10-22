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
  var setSidebarFilter: @MainActor @Sendable (SidebarFilter) -> Void
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
  /// Register a workspace root — a plain folder carrying
  /// `.codans/workspace.json`. Child rows are appended by the next reconcile
  /// from the manifest. Forwards to `HierarchyManager.addProject(isWorkspace:)`.
  var addWorkspaceProject:
    @MainActor @Sendable (
      _ name: String, _ rootPath: String
    ) -> ProjectID
  /// The workspace child row whose directory is `path`, if any. Answers from
  /// the catalog alone. Forwards to `HierarchyManager.workspaceMembership`.
  var workspaceMembership:
    @MainActor @Sendable (
      _ path: String
    ) -> WorkspaceMembership?
  /// Close every surface of the Worktree without touching the catalog —
  /// the step before a directory is moved out from under its terminals.
  /// Forwards to `HierarchyManager.tearDownWorktreeSurfaces`.
  var tearDownWorktreeSurfaces: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Void
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
  /// Re-icons the Project. `nil` clears the assignment so the UI falls back
  /// to the built-in folder pair. Replacing a custom icon deletes the file
  /// the previous one referenced. Silent no-op for unchanged values.
  var setProjectIcon:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ icon: ProjectIcon?
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

  // MARK: - Tab verbs

  /// Opens a new Tab holding `content`. A nil Pane targets the Worktree's
  /// focused Pane; a Worktree without Panes gets its first one. `select`
  /// makes the Tab the Pane's selected one and focuses the Pane. Catalog
  /// only — pair with `ensureSurface` to bring the session up.
  var newTab:
    @MainActor @Sendable (
      _ paneID: PaneID?, _ worktreeID: WorktreeID, _ projectID: ProjectID,
      _ content: ContentSnapshot, _ name: String?, _ initialTitle: String?, _ select: Bool
    ) throws -> TabAddress
  /// Closes the Tab and its Content; the last Tab of a Pane closes the
  /// Pane. Asks first when the Content still holds queued commands.
  var closeTab: @MainActor @Sendable (_ tabID: TabID) throws -> Void
  /// Selects the Tab in its Pane and focuses that Pane.
  var selectTab: @MainActor @Sendable (_ tabID: TabID) throws -> Void
  /// Selects the Tab at a zero-based position of the Pane's strip; out of
  /// range is a no-op returning nil.
  var selectTabAtIndex: @MainActor @Sendable (_ index: Int, _ paneID: PaneID) throws -> TabID?
  var selectAdjacentTab:
    @MainActor @Sendable (_ direction: TabAdjacency, _ paneID: PaneID) throws -> TabID?
  var renameTab: @MainActor @Sendable (_ tabID: TabID, _ name: String?) throws -> Void
  var setTabColor: @MainActor @Sendable (_ tabID: TabID, _ color: TabColor?) throws -> Void
  /// Updates the tab's icon under the `TabIconLock` rules
  /// (`.auto` ≤ `.script` ≤ `.user`). A write whose `lock` cannot
  /// override the tab's current lock is a silent no-op — UI consumers
  /// re-read the tab afterwards if they need to confirm the result.
  var setTabIcon:
    @MainActor @Sendable (_ tabID: TabID, _ icon: String?, _ lock: TabIconLock) throws -> Void
  var reorderTabs: @MainActor @Sendable (_ paneID: PaneID, _ orderedIDs: [TabID]) throws -> Void
  /// Moves a Tab by a relative offset within its Pane, wrapping.
  var moveTab: @MainActor @Sendable (_ tabID: TabID, _ offset: Int) throws -> Void
  var closeOtherTabs: @MainActor @Sendable (_ keeping: TabID) throws -> Void
  var closeTabsToRight: @MainActor @Sendable (_ of: TabID) throws -> Void
  /// Closes every Tab of the Pane — and so the Pane.
  var closeAllTabs: @MainActor @Sendable (_ paneID: PaneID) throws -> Void

  // MARK: - Pane verbs

  /// Creates a Pane beside `paneID` with one fresh Tab holding `content`
  /// and focuses it. Catalog only, like `newTab`.
  var splitPane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: SplitTree<PaneID>.NewDirection,
      _ content: ContentSnapshot, _ name: String?, _ initialTitle: String?
    ) throws -> TabAddress
  /// Closes every Tab of the Pane. Asks first when any holds queued commands.
  var closePane: @MainActor @Sendable (_ paneID: PaneID) throws -> Void
  /// Catalog focus only (persisted). Responder-chain focus is
  /// `focusSurfaceView`, since the surface may not exist yet.
  var focusPane: @MainActor @Sendable (_ paneID: PaneID) throws -> Void
  /// Moves focus to the Pane's neighbour in `direction` and hands its
  /// selected Content the keyboard; nil when there is none that way.
  var focusNeighbour:
    @MainActor @Sendable (_ paneID: PaneID, _ direction: FocusDirection) throws -> PaneID?
  /// Zooms the Pane to fill the layout area, or un-zooms it. Returns the
  /// new zoom state.
  var toggleZoom: @MainActor @Sendable (_ paneID: PaneID) throws -> Bool
  var resizeSplit:
    @MainActor @Sendable (
      _ path: SplitTree<PaneID>.Path, _ ratio: Double,
      _ worktreeID: WorktreeID, _ projectID: ProjectID
    ) throws -> Void
  /// Resizes a Pane along the given direction by `amount` (pixels, scaled
  /// to a ratio delta by the manager).
  var resizePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: ResizeDirection, _ amount: Double
    ) throws -> Void
  /// Sets every split ratio of the Worktree's tree to 0.5.
  var equalizeSplits:
    @MainActor @Sendable (_ worktreeID: WorktreeID, _ projectID: ProjectID) throws -> Void
  /// Re-positions an existing Pane next to `anchorID`, splitting the anchor
  /// along `direction`. Pure split-tree reshape — the moved Pane's Contents
  /// stay alive. Backs the pane drag-and-drop gesture.
  var movePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ anchorID: PaneID, _ direction: SplitTree<PaneID>.NewDirection
    ) throws -> Void

  // MARK: - Surfaces and runtime state

  /// Brings the Content's surface up (spawn or re-attach), with the
  /// Project's env vars resolved from Settings. Idempotent.
  var ensureSurface: @MainActor @Sendable (_ contentID: ContentID) async throws -> Void
  /// View-level first-responder focus. Does NOT mutate the catalog — it only
  /// asks the runtime to call `makeFirstResponder` on the Content's surface
  /// view. Used post-split (focus the new Pane) and post-close (transfer
  /// focus to the surviving neighbour).
  var focusSurfaceView: @MainActor @Sendable (_ contentID: ContentID) -> Void
  /// The focused Pane's selected Tab in the Worktree — where ⌘T, ⌘W and the
  /// `.focused` script target land. nil for a Worktree without Panes.
  var focusedContent: @MainActor @Sendable (_ worktreeID: WorktreeID) -> TabAddress?
  /// Resolves a Content to the Project / Worktree / Pane / Tab holding it.
  /// nil when the Content is not in the catalog — expected during teardown
  /// races on the action callback thread.
  var addressOf: @MainActor @Sendable (_ contentID: ContentID) -> TabAddress?
  /// Read path for the chip's dirty (running-command) spinner.
  var tabIsDirty: @MainActor @Sendable (_ tabID: TabID) -> Bool
  /// Worktree-scoped variant of `tabIsDirty`. Sidebar rows surface a busy
  /// glyph when any Content of the worktree is marked running.
  var worktreeIsDirty: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Bool
  /// OSC 9;4 progress writer for the Content's `TabChrome`.
  var setProgressBusy: @MainActor @Sendable (_ contentID: ContentID, _ busy: Bool) -> Void
  /// Foreground-command busy writer for the Content's `TabChrome`. The root
  /// reducer invokes it when the foreground-job poller reports a session's
  /// group started/stopped a non-agent command.
  var setCommandBusy: @MainActor @Sendable (_ contentID: ContentID, _ busy: Bool) -> Void
  /// Whether closing the Content would lose work (running command, working
  /// agent, queued commands). The close-confirmation gate reads it.
  var isContentBusy: @MainActor @Sendable (_ contentID: ContentID) -> Bool

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

  /// Forwards `HierarchyManager.runningContentCount`.
  var runningContentCount: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Int

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

  /// Runs a command that is not saved anywhere — a detected manifest entry
  /// run straight from the header dropdown. Goes through the same pipeline as
  /// `runScript` (tab spawn, env, run-pane reuse keyed by `script.id`, Run/Stop
  /// tracking), so callers pass a stable id to reuse the pane on a rerun.
  /// Throws `RunScriptError.missingWorktree` when the worktree is gone.
  var runCommand:
    @MainActor @Sendable (
      _ script: ScriptDefinition, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) async throws -> Void

  /// Launches an `AgentProfile` from `Settings.agents` in the given Worktree.
  /// Renders the profile through `AgentLaunchCommand` and dispatches it the
  /// same way a script is dispatched (new tab / split / focused pane), with
  /// one deliberate difference: agent launches are *not* tracked as run panes,
  /// so invoking the same profile twice opens a second session rather than
  /// re-typing into the first. `prompt` is the agent's first prompt; `nil`
  /// starts it without one. Throws `RunScriptError.unknownScript` when the
  /// profile id is gone (removed between click and dispatch);
  /// `.missingWorktree` when the worktree is.
  var launchAgentProfile:
    @MainActor @Sendable (
      _ profileID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID, _ prompt: String?
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

  /// Inserts or removes `label` from the Content's labels (Set semantics →
  /// idempotent on repeated calls with the same `present`). Silent no-op on
  /// an unknown id. In-memory state changes immediately so the next read
  /// sees the new label; only the disk write is debounced via the standard
  /// catalog save pipeline. Consumed by the content right-click "Mute
  /// notifications" menu (`notifications:muted` label).
  var setContentLabel:
    @MainActor @Sendable (
      _ contentID: ContentID,
      _ label: String,
      _ present: Bool
    ) -> Void

  /// Writes the Content's `agentKind` (classified CLI agent currently
  /// driving the session, e.g. `.claudeCode` / `.codex` / `.pi`). `nil`
  /// clears the field. Idempotent: a repeat call with the same value is a
  /// true no-op (no persistence churn). Silent no-op on an unknown id.
  /// Consumed by `AgentBinder`, which derives the kind from foreground job
  /// snapshots.
  var setAgentKind: @MainActor @Sendable (_ contentID: ContentID, _ kind: AgentKind?) -> Void

  /// Writes the Content's `agentSessionID` (agent-supplied session
  /// identifier; stable across resumes for the same agent process). `nil`
  /// clears the field. Idempotent. Silent no-op on an unknown id. Consumed
  /// alongside `setAgentKind` by `AgentBinder`.
  var setAgentSessionID: @MainActor @Sendable (_ contentID: ContentID, _ sessionID: String?) -> Void

  /// Writes the Content's live `workingDirectory` so restart restores it at
  /// the cwd the user last `cd`'d to instead of the creation-time cwd.
  /// Driven by libghostty `OSC 7` deltas routed through
  /// `RootFeature.engineEvents`. The manager-side mutator is idempotent on
  /// equal paths and silent on unknown ids, so a noisy shell that
  /// re-asserts the same pwd every prompt never touches the catalog file.
  var updateWorkingDirectory:
    @MainActor @Sendable (
      _ contentID: ContentID,
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

  /// Commands parked on the Content, `[]` for an unknown id. Read by the
  /// Command Queue panel so the reducer edits against live catalog state
  /// rather than a snapshot taken when the panel opened.
  var commandQueue: @MainActor @Sendable (_ contentID: ContentID) -> [QueuedCommand]

  /// Replaces the Content's command queue wholesale. Read-modify-write is
  /// the intended usage; the manager side is the single canonical writer
  /// and no-ops on an unknown id or an unchanged queue.
  var setCommandQueue: @MainActor @Sendable (_ contentID: ContentID, _ queue: [QueuedCommand]) -> Void
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

/// What an agent launch produced. The ids are nil when the command was
/// typed into the focused session rather than a fresh one.
nonisolated struct AgentLaunchOutcome: Sendable, Equatable {
  let profile: AgentProfile
  let command: String
  let tabID: TabID?
  let paneID: PaneID?
  let contentID: ContentID?
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
    terminalClient: TerminalClient? = nil,
    contents: ContentRuntime? = nil,
    closeTabConfirmation: (@MainActor () -> CloseTabConfirmation)? = nil,
    confirmClose:
      @escaping @MainActor (
        CloseConfirmationPrompt, _ completion: @escaping @MainActor (Bool) -> Void
      ) -> Void = { prompt, completion in
        CloseConfirmationDialog.present(prompt, completion: completion)
      }
  ) -> HierarchyClient {
    /// Closing a Tab or a Pane asks first per the "Confirm before closing a
    /// tab" setting. The gate sits here, on the UI's bridge, rather than in
    /// the manager: the CLI and the run-script auto-close policies reach the
    /// manager directly and must never block on a prompt. Busy is
    /// `HierarchyManager.isBusy` for every affected Content, live surface or
    /// not: a queued Tab that never came up still loses its queue. When it
    /// does ask, the close happens in the answer's completion, so the
    /// caller's `try` returns having closed nothing yet.
    func closeAfterConfirming(
      contents: [ContentSnapshot],
      subject: CloseConfirmationPrompt.Subject,
      _ close: @escaping @MainActor () throws -> Void
    ) throws {
      let setting =
        closeTabConfirmation?() ?? settings?.settings.general.closeTabConfirmation ?? .busy
      let queued = contents.reduce(0) { $0 + ($1.terminal?.commandQueue.count ?? 0) }
      let anyBusy = contents.contains { manager.isBusy($0.id) }
      guard !contents.isEmpty, setting.shouldPrompt(anyBusy: anyBusy) else {
        try close()
        return
      }
      let isRunning = contents.contains { manager.contentActivity?($0.id) ?? false }
      let prompt = CloseConfirmationPrompt(subject: subject, queuedCount: queued, isRunning: isRunning)
      confirmClose(prompt) { confirmed in
        guard confirmed else { return }
        try? close()
      }
    }
    func closeTabsAfterConfirming(
      _ doomed: [Tab],
      _ close: @escaping @MainActor () throws -> Void
    ) throws {
      try closeAfterConfirming(
        contents: doomed.map(\.content),
        subject: doomed.count == 1 ? .tab : .tabs(doomed.count),
        close
      )
    }
    func resolvedEnv(_ projectID: ProjectID) -> [String: String] {
      // Resolve project envVars from the SettingsStore so every spawn path
      // (strip "+", split, run scripts, IPC) inherits Project-defined env.
      // When the live wiring omits a SettingsStore (headless tests) the env
      // defaults to empty and the session spawns with the raw process env.
      settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) } ?? [:]
    }
    func requireContentDirectory(_ content: ContentSnapshot, in projectID: ProjectID) throws {
      // Stale catalog state: libghostty crashes when it spawns a shell in a
      // cwd that is gone (the folder was moved, or `git worktree remove` ran
      // outside the app before reconcile caught up). Reject here so callers'
      // `try?` swallows the error instead of bringing down the app.
      if let cwd = content.terminal?.workingDirectory {
        try manager.requireLocalDirectory(cwd, in: projectID)
      }
    }

    return HierarchyClient(
      createTag: { name, color in
        manager.createTag(name: name, color: color)
      },
      renameTag: { id, name in manager.renameTag(id, to: name) },
      recolorTag: { id, color in manager.recolorTag(id, to: color) },
      removeTag: { id in manager.removeTag(id) },
      setProjectTags: { projectID, tags in
        manager.setProjectTags(projectID, tags: tags)
      },
      setSidebarFilter: { manager.setSidebarFilter($0) },
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
      addWorkspaceProject: { name, rootPath in
        manager.addProject(name: name, rootPath: rootPath, gitRoot: nil, isWorkspace: true)
      },
      workspaceMembership: { path in manager.workspaceMembership(forPath: path) },
      tearDownWorktreeSurfaces: { worktreeID in
        manager.tearDownWorktreeSurfaces(worktreeID: worktreeID)
      },
      removeProject: { projectID in try manager.removeProject(projectID) },
      renameProject: { projectID, name in
        try manager.renameProject(projectID, name: name)
      },
      setProjectColor: { projectID, color in
        try manager.setProjectColor(projectID, color: color)
      },
      setProjectIcon: { projectID, icon in
        try manager.setProjectIcon(projectID, icon: icon)
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
      newTab: { paneID, worktreeID, projectID, content, name, initialTitle, select in
        try requireContentDirectory(content, in: projectID)
        return try manager.newTab(
          in: paneID, worktreeID: worktreeID, projectID: projectID,
          content: content, name: name, initialTitle: initialTitle, select: select
        )
      },
      closeTab: { tabID in
        let doomed = [manager.catalog.tab(tabID)].compactMap { $0 }
        try closeTabsAfterConfirming(doomed) {
          try manager.closeTab(tabID)
        }
      },
      selectTab: { tabID in try manager.selectTab(tabID) },
      selectTabAtIndex: { index, paneID in try manager.selectTab(at: index, in: paneID) },
      selectAdjacentTab: { direction, paneID in
        try manager.selectAdjacentTab(direction: direction, in: paneID)
      },
      renameTab: { tabID, name in try manager.renameTab(tabID, name: name) },
      setTabColor: { tabID, color in try manager.setTabColor(tabID, color: color) },
      setTabIcon: { tabID, icon, lock in try manager.setTabIcon(tabID, icon: icon, lock: lock) },
      reorderTabs: { paneID, orderedIDs in
        try manager.reorderTabs(in: paneID, orderedIDs: orderedIDs)
      },
      moveTab: { tabID, offset in try manager.moveTab(tabID, offset: offset) },
      closeOtherTabs: { keepID in
        let doomed = manager.catalog.address(forTab: keepID)
          .flatMap { manager.catalog.pane($0.paneID)?.tabs.filter { $0.id != keepID } } ?? []
        try closeTabsAfterConfirming(doomed) {
          try manager.closeOtherTabs(keeping: keepID)
        }
      },
      closeTabsToRight: { pivotID in
        let all = manager.catalog.address(forTab: pivotID).flatMap { manager.catalog.pane($0.paneID)?.tabs } ?? []
        let doomed =
          all.firstIndex(where: { $0.id == pivotID })
          .map { Array(all[($0 + 1)...]) } ?? []
        try closeTabsAfterConfirming(doomed) {
          try manager.closeTabsToRight(of: pivotID)
        }
      },
      closeAllTabs: { paneID in
        let doomed = manager.catalog.pane(paneID)?.tabs ?? []
        try closeTabsAfterConfirming(doomed) {
          try manager.closeAllTabs(in: paneID)
        }
      },
      splitPane: { paneID, direction, content, name, initialTitle in
        guard let projectID = manager.catalog.projectID(forPane: paneID) else {
          throw HierarchyError.notFound("Pane \(paneID)")
        }
        try requireContentDirectory(content, in: projectID)
        return try manager.splitPane(
          from: paneID, direction: direction, content: content, name: name, initialTitle: initialTitle
        )
      },
      closePane: { paneID in
        let doomed = manager.catalog.pane(paneID)?.tabs.map(\.content) ?? []
        try closeAfterConfirming(contents: doomed, subject: .pane) {
          try manager.closePane(paneID)
        }
      },
      focusPane: { paneID in try manager.focusPane(paneID) },
      focusNeighbour: { paneID, direction in
        try manager.focusNeighbour(of: paneID, direction: direction)
      },
      toggleZoom: { paneID in try manager.toggleZoom(paneID) },
      resizeSplit: { path, ratio, worktreeID, projectID in
        try manager.resizeSplit(at: path, ratio: ratio, in: worktreeID, in: projectID)
      },
      resizePane: { paneID, direction, amount in
        try manager.resizePane(paneID, direction: direction, amount: amount)
      },
      equalizeSplits: { worktreeID, projectID in
        try manager.equalizeSplits(in: worktreeID, in: projectID)
      },
      movePane: { paneID, anchorID, direction in
        try manager.movePane(paneID, relativeTo: anchorID, direction: direction)
      },
      ensureSurface: { contentID in
        guard let projectID = manager.catalog.projectID(forContent: contentID) else {
          throw HierarchyError.notFound("Content \(contentID)")
        }
        try await manager.ensureSurface(for: contentID, env: resolvedEnv(projectID))
      },
      focusSurfaceView: { contentID in manager.focusSurfaceView(for: contentID) },
      focusedContent: { worktreeID in manager.focusedContent(in: worktreeID) },
      addressOf: { contentID in manager.catalog.address(forContent: contentID) },
      tabIsDirty: { tabID in contents?.tabIsDirty(tabID) ?? false },
      worktreeIsDirty: { worktreeID in contents?.worktreeIsDirty(worktreeID) ?? false },
      setProgressBusy: { contentID, busy in contents?.setProgressBusy(contentID, busy) },
      setCommandBusy: { contentID, busy in contents?.setCommandBusy(contentID, busy) },
      isContentBusy: { contentID in manager.isBusy(contentID) },
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
      runningContentCount: { worktreeID in
        manager.runningContentCount(worktreeID: worktreeID)
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
      runCommand: { [weak settings] script, projectID, worktreeID in
        _ = try await runResolvedScript(
          script: script,
          projectID: projectID,
          worktreeID: worktreeID,
          manager: manager,
          snapshot: settings?.settings ?? .default,
          terminalClient: terminalClient
        )
      },
      launchAgentProfile: { [weak settings] profileID, projectID, worktreeID, prompt in
        let snapshot = settings?.settings ?? .default
        guard let profile = snapshot.agents.profile(id: profileID) else {
          throw RunScriptError.unknownScript(profileID)
        }
        _ = try await launchAgent(
          spec: AgentLaunchSpec(
            profile: profile, projectID: projectID, worktreeID: worktreeID, prompt: prompt),
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
        for scriptID in contents?.runningScriptIDs(in: worktreeID) ?? [] {
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
      setContentLabel: { contentID, label, present in
        manager.setContentLabel(contentID, label: label, present: present)
      },
      setAgentKind: { contentID, kind in
        manager.setAgentKind(contentID, kind: kind)
      },
      setAgentSessionID: { contentID, sessionID in
        manager.setAgentSessionID(contentID, sessionID: sessionID)
      },
      updateWorkingDirectory: { contentID, newPath in
        manager.updateWorkingDirectory(for: contentID, to: newPath)
      },
      reorderWorktrees: { projectID, segment, from, to in
        try manager.reorderWorktrees(
          in: projectID,
          segment: segment, from: from, to: to
        )
      },
      commandQueue: { contentID in manager.commandQueue(for: contentID) },
      setCommandQueue: { contentID, queue in manager.setCommandQueue(queue, for: contentID) }
    )
  }

  /// Resolves the script + worktree, then dispatches according to the
  /// script's `target`:
  ///   - `.newTab` : open a fresh Tab in the focused Pane and run as the
  ///                 new session's `initialCommand`.
  ///   - `.focused`: write the command (with trailing newline) to the
  ///                 focused Pane's selected Content via `TerminalClient`.
  ///                 No new Tab is created.
  ///   - `.split`  : split the focused Pane in `script.direction` and run
  ///                 as the new Pane's first session.
  ///
  /// `.focused` and `.split` fall back to `.newTab` when no anchor is
  /// available (empty worktree).
  ///
  /// When `target` spawned a session and `resolvedOnFinished` is non-`.none`,
  /// a detached observer waits for that session's child to exit and then
  /// applies the policy (`.closeTab`).
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
  /// dispatcher already knows how to open a Tab / split / focused session
  /// with a command and a tab icon, and an agent launch is exactly that plus
  /// a different way of composing the command string.
  ///
  /// `tracksRunContent: false` is the one behavioural difference: an agent
  /// is a session, not a job, so a second launch of the same profile opens a
  /// second session instead of re-typing into the first one's terminal
  /// (which is what the Run/Stop toggle wants for scripts).
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
    let spawned = try await runResolvedScript(
      script: script,
      projectID: spec.projectID,
      worktreeID: spec.worktreeID,
      manager: manager,
      snapshot: snapshot,
      terminalClient: terminalClient,
      tracksRunContent: false,
      anchorPaneID: spec.anchorPaneID
    )
    return AgentLaunchOutcome(
      profile: profile, command: command,
      tabID: spawned?.tabID, paneID: spawned?.paneID, contentID: spawned?.contentID)
  }

  /// Shared execution pipeline for a fully-resolved `ScriptDefinition`,
  /// regardless of whether it came from a Project's `scripts`, the global
  /// `general.globalScripts` list, or an agent profile. Resolves the worktree
  /// cwd + env, honours the run-session reuse / Run-Stop tracking / onFinished
  /// policy, and spawns the Tab / Pane. Run tracking keys on (worktreeID,
  /// scriptID); global and project scripts never collide because each carries
  /// a distinct UUID.
  ///
  /// `tracksRunContent: false` opts a caller out of both halves of that
  /// tracking — no reuse lookup on the way in, no `setRunScriptContent` on
  /// the way out — so every invocation spawns a fresh surface.
  ///
  /// `anchorPaneID` names the Pane a `.split` divides. Left nil, the split
  /// anchors on the worktree's focused Pane; a Pane that is not in this
  /// worktree is ignored the same way.
  ///
  /// Returns the address the command landed in when a fresh session was
  /// spawned; `nil` for a reused run session or a `.focused` dispatch.
  @MainActor
  @discardableResult
  private static func runResolvedScript(
    script: ScriptDefinition,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    snapshot: Settings,
    terminalClient: TerminalClient?,
    tracksRunContent: Bool = true,
    anchorPaneID: PaneID? = nil
  ) async throws -> TabAddress? {
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
    // run session is still alive — from an earlier run this session or
    // restored from the persisted catalog after a relaunch — never spawn a
    // second Tab for it.
    if tracksRunContent,
      script.target == .newTab || script.target == .split,
      let terminalClient,
      let existing = manager.runScriptContent(worktreeID: worktreeID, scriptID: scriptID)
    {
      let isRunning = terminalClient.surface(existing) != nil && manager.contentActivity?(existing) == true
      if isRunning {
        // Already executing — surface the run instead of typing a second
        // command into the busy pty. Honour `focus` so background scripts
        // stay background.
        if script.focus, let address = manager.catalog.address(forContent: existing) {
          try? manager.selectTab(address.tabID)
        }
        return nil
      }
      // Idle run session → re-run in place. Subscribe before the send for
      // the same no-replay reason as the spawn path below.
      let reuseStream: AsyncStream<TerminalEvent>? =
        onFinishedNeeded ? terminalClient.events() : nil
      // After a relaunch the restored session has no live surface yet (they
      // spawn lazily when a Tab is shown); bring it up first or the
      // sendInput below lands on nothing. No-op when already live.
      try? await manager.ensureSurface(for: existing, env: env)
      if script.focus, let address = manager.catalog.address(forContent: existing) {
        try? manager.selectTab(address.tabID)
      }
      // Same wrapping as the spawn path: a close-on-finish policy needs the
      // shell to exit after the command so `childExited` fires.
      let rerunCommand = wrapForOnFinished(
        command: script.command,
        policy: script.resolvedOnFinished
      )
      manager.recordProcessLaunch(contentID: existing, name: script.displayName, kind: .run)
      terminalClient.sendInput(existing, rerunCommand + "\n")
      if let reuseStream {
        scheduleOnFinishedAction(
          contentID: existing,
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

    let spawned = try await dispatchTrackedScript(
      script: script, worktreeID: worktreeID, projectID: projectID, cwd: cwd,
      env: env, manager: manager, terminalClient: terminalClient,
      tracksRunContent: tracksRunContent, anchorPaneID: anchorPaneID
    )

    // Record the dedicated session so the next run reuses it and the
    // toolbar Run/Stop toggle can find it. Only `.newTab` / `.split` create
    // one; `.focused` returns nil (it writes into the user's focused session).
    if tracksRunContent,
      let spawned,
      script.target == .newTab || script.target == .split
    {
      manager.setRunScriptContent(
        worktreeID: worktreeID, scriptID: scriptID, contentID: spawned.contentID)
    }

    if let spawned, let stream = preSubscribedStream {
      scheduleOnFinishedAction(
        contentID: spawned.contentID,
        policy: script.resolvedOnFinished,
        manager: manager,
        eventStream: stream
      )
    }

    // Honour the script's `focus` by dispatching `focusSurfaceView` async,
    // the same way the manual ⌘D / ⌘T paths do — the surface view needs
    // to attach to the hosting window before `makeFirstResponder` takes.
    if script.focus,
      script.target == .split || script.target == .newTab,
      let spawned
    {
      Task { @MainActor in
        manager.focusSurfaceView(for: spawned.contentID)
      }
    }
    return spawned
  }

  /// Launch attribution is separate from the dedicated run reuse index.
  /// Capture focused-session intent before dispatch so process birth can
  /// reject input sent to an already-running command.
  @MainActor
  private static func dispatchTrackedScript(
    script: ScriptDefinition,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    cwd: String,
    env: [String: String],
    manager: HierarchyManager,
    terminalClient: TerminalClient?,
    tracksRunContent: Bool,
    anchorPaneID: PaneID?
  ) async throws -> TabAddress? {
    let processLaunchRequestedAt = Date.now
    let focusedProcessContent =
      script.target == .focused && terminalClient != nil
      ? manager.focusedContent(in: worktreeID)?.contentID : nil
    if let focusedProcessContent {
      manager.recordProcessLaunch(
        contentID: focusedProcessContent, name: script.displayName, kind: tracksRunContent ? .run : .agent,
        now: processLaunchRequestedAt, requiresIdle: true
      )
    }
    let spawned: TabAddress?
    do {
      spawned = try await dispatchScript(
        script: script,
        worktreeID: worktreeID,
        projectID: projectID,
        cwd: cwd,
        env: env,
        manager: manager,
        terminalClient: terminalClient,
        anchorPaneID: anchorPaneID
      )
    } catch {
      if let focusedProcessContent,
        manager.processRegistry.launches[focusedProcessContent]?.requestedAt == processLaunchRequestedAt
      {
        manager.processRegistry.launches.removeValue(forKey: focusedProcessContent)
      }
      throw error
    }

    if let spawned {
      manager.recordProcessLaunch(
        contentID: spawned.contentID, name: script.displayName, kind: tracksRunContent ? .run : .agent
      )
    }

    return spawned
  }

  /// Stops the run for `(worktreeID, scriptID)`: interrupts the session's
  /// child (Ctrl-C → SIGINT) and then closes its Tab — which closes the
  /// Pane when it was the last Tab. Stop is a teardown, not a pause: the
  /// next run spawns a fresh Tab. Best-effort: silent no-op when no live run
  /// session is tracked or no `TerminalClient` is wired.
  @MainActor
  private static func stopScript(
    scriptID: UUID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    terminalClient: TerminalClient?
  ) {
    guard let terminalClient,
      let contentID = manager.runScriptContent(worktreeID: worktreeID, scriptID: scriptID)
    else {
      runScriptLogger.info(
        "stopScript: no live run session to interrupt for script \(scriptID, privacy: .public)"
      )
      return
    }
    // Goes through the key-event path (`ghostty_surface_key`), not `sendInput`'s
    // text path — the latter filters control bytes, so a literal 0x03 written
    // as text never reaches the PTY as an interrupt. The interrupt gives the
    // child a graceful SIGINT before the surface teardown below hangs up
    // the pty.
    terminalClient.interrupt(contentID)
    guard let address = manager.catalog.address(forContent: contentID) else { return }
    try? manager.closeTab(address.tabID)
  }

  /// Materializes a `ScriptDefinition` into a runtime action and returns the
  /// spawned address if a new session was created (`.newTab` / `.split`), or
  /// `nil` for `.focused` (which writes into an existing session). Falls
  /// back to `.newTab` for `.focused` / `.split` when there is no anchor.
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
  ) async throws -> TabAddress? {
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
    let content = ContentSnapshot.terminal(workingDirectory: cwd, initialCommand: spawnCommand)

    func bringUp(_ address: TabAddress) async throws -> TabAddress {
      // Carry the script's resolved SF Symbol onto the spawned Tab under
      // the .script lock. A later auto re-derivation cannot displace it;
      // a user pick still can. Failures are non-fatal — the Tab keeps
      // running with its default icon.
      try? manager.setTabIcon(address.tabID, icon: script.resolvedSystemImage, lock: .script)
      try await manager.ensureSurface(for: address.contentID, env: env)
      return address
    }

    func openInNewTab() async throws -> TabAddress {
      try manager.requireLocalDirectory(cwd, in: projectID)
      let address = try manager.newTab(
        in: nil, worktreeID: worktreeID, projectID: projectID,
        content: content, name: nil, initialTitle: script.displayName, select: script.focus
      )
      return try await bringUp(address)
    }

    switch script.target {
    case .newTab:
      return try await openInNewTab()

    case .focused:
      // sendInput needs the focused session and the terminal runtime; absent
      // either, fall back to a fresh Tab so the user always sees output.
      if let terminalClient,
        let anchor = manager.focusedContent(in: worktreeID)
      {
        terminalClient.sendInput(anchor.contentID, script.command + "\n")
        return nil
      }
      runScriptLogger.info(
        "target=.focused fell back to .newTab — \(terminalClient == nil ? "no TerminalClient" : "no focused Pane in worktree", privacy: .public)"
      )
      return try await openInNewTab()

    case .split:
      if let anchor = explicitAnchor(anchorPaneID, worktreeID: worktreeID, in: manager)
        ?? manager.focusedContent(in: worktreeID)?.paneID
      {
        try manager.requireLocalDirectory(cwd, in: projectID)
        let address = try manager.splitPane(
          from: anchor,
          direction: mapSplitDirection(script.direction),
          content: content,
          initialTitle: script.displayName
        )
        return try await bringUp(address)
      }
      runScriptLogger.info(
        "target=.split fell back to .newTab — no focused Pane in worktree"
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

  /// A caller-named split anchor, accepted only while it is still a Pane of
  /// this worktree; anything else falls through to the focused-Pane rule.
  @MainActor
  private static func explicitAnchor(
    _ paneID: PaneID?,
    worktreeID: WorktreeID,
    in manager: HierarchyManager
  ) -> PaneID? {
    guard let paneID, manager.catalog.worktreeID(forPane: paneID) == worktreeID else { return nil }
    return paneID
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

  /// Subscribes to terminal events and, when the spawned session's child
  /// exits / crashes, applies the `onFinished` policy on the main actor.
  /// Silent no-op when the Content is no longer in the catalog by the time
  /// the exit lands (already torn down by the user, etc.). The caller is
  /// responsible for subscribing to `events()` *before* the spawn so a
  /// one-shot script's `paneExited` is not missed.
  @MainActor
  private static func scheduleOnFinishedAction(
    contentID: ContentID,
    policy: ScriptOnFinished,
    manager: HierarchyManager,
    eventStream: AsyncStream<TerminalEvent>
  ) {
    Task.detached(priority: .userInitiated) {
      for await event in eventStream {
        switch event {
        case .paneInfoChanged(let id, .childExited) where id == contentID:
          // The child ended, but libghostty keeps the surface open (its
          // embedded API force-enables wait-after-command whenever a
          // spawn command is set), so `paneExited` would only fire after
          // a keypress in the dead session. The child's exit IS the
          // "finished" the policy is about — apply it now.
          await MainActor.run {
            applyOnFinished(policy: policy, contentID: contentID, manager: manager)
          }
          return
        case .paneExited(let id, _, _) where id == contentID,
          .paneCrashed(let id, _) where id == contentID:
          await MainActor.run {
            applyOnFinished(policy: policy, contentID: contentID, manager: manager)
          }
          return
        case .paneClosedByTab(let id, _) where id == contentID:
          // Already torn down — nothing left to close.
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
    contentID: ContentID,
    manager: HierarchyManager
  ) {
    guard let address = manager.catalog.address(forContent: contentID) else { return }
    switch policy {
    case .none:
      return
    case .closeTab:
      try? manager.closeTab(address.tabID)
    }
  }

  /// Opens a fresh Tab on the worktree, runs `command` as the new session's
  /// `initialCommand`, and suspends until that session's child process
  /// exits (or crashes). Returns immediately as a no-op when the worktree is
  /// gone, the Tab could not be created, or no `TerminalClient` is wired.
  /// Used by the archive / delete lifecycle flows — both must wait for the
  /// user's script to finish before mutating catalog state.
  ///
  /// `initialCommand` is delivered to the session via `sendInput`, i.e. it
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
  /// session sets one — `zmx attach`), so a surface whose child died stays
  /// open until a keypress, and `paneExited` — which fires on SURFACE
  /// close — would stall the lifecycle until the user pressed a key in
  /// the dead session. On a clean exit the transient script Tab is torn
  /// down here; a failing script keeps its Tab so the output stays
  /// readable. The surface-close family is still matched as a fallback
  /// for races (user closes the Tab mid-script, crash, teardown).
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
    // A missing folder cannot run the script: skip it, so the archive or
    // delete that awaits it goes on.
    guard let cwd = foundWorktreePath,
      (try? manager.requireLocalDirectory(cwd, in: projectID)) != nil
    else { return }
    guard let terminalClient else { return }
    let env = HierarchyManager.resolvedEnv(for: projectID, in: settings)

    // Subscribe before spawn: events() is broadcast and does not
    // replay. A one-shot script that exits between newTab and a later
    // events() call would otherwise be missed and the archive/delete await
    // would hang forever.
    let stream = terminalClient.events()

    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let wrapped = trimmed.isEmpty ? "exit" : "\(trimmed); exit"

    let address: TabAddress
    do {
      address = try manager.newTab(
        in: nil, worktreeID: worktreeID, projectID: projectID,
        content: .terminal(workingDirectory: cwd, initialCommand: wrapped),
        initialTitle: tabName
      )
      try await manager.ensureSurface(for: address.contentID, env: env)
    } catch {
      return
    }
    let contentID = address.contentID

    for await event in stream {
      switch event {
      case .paneInfoChanged(let id, .childExited(let code)) where id == contentID:
        // The script (and its `; exit` shell) is done — this is the
        // lifecycle's completion signal. `exit` propagates the last
        // command's status, so `code` is the script's own outcome.
        if code == 0 {
          try? manager.closeTab(address.tabID)
        }
        return
      case .paneExited(let id, _, _) where id == contentID,
        .paneCrashed(let id, _) where id == contentID,
        .paneClosedByTab(let id, _) where id == contentID:
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
    // A workspace root is a plain folder by construction and must never be
    // probed for a git root: if it happened to sit inside a repository, the
    // auto-promotion below would adopt that repository and the stale sweep
    // would archive every child row in one pass. Branch off before the probe.
    if project.isWorkspace {
      await reconcileWorkspace(project: project, manager: manager, gitCLI: gitCLI)
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
      let mapped = entries.map { entry -> (path: String, branch: String?, head: String?) in
        let branch = entry.branch.isEmpty ? nil : entry.branch
        return (
          path: HierarchyManager.canonicalPath(entry.path), branch: branch, head: entry.head
        )
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

  /// Workspace counterpart of `reconcile`. Membership comes from the manifest
  /// under the root; live facts (branch, owning repository) come from git in
  /// each child folder. Feeds `HierarchyManager.reconcileWorkspaceChildren`,
  /// which appends, refreshes in place, and soft-archives children whose
  /// folder is gone — and never touches the root row. Swallows and logs
  /// errors like its siblings; the manifest's own health is reported on the
  /// project row by `ProjectReconciler` before this runs.
  @MainActor
  private static func reconcileWorkspace(
    project: Project,
    manager: HierarchyManager,
    gitCLI: GitWorktreeCLI
  ) async {
    let projectID = project.id
    let rootPath = project.rootPath
    let manifest: WorkspaceManifest
    do {
      manifest = try WorkspaceManifestStore.load(rootPath: rootPath)
    } catch {
      reconcileLogger.error(
        "workspace reconcile skipped, manifest unreadable: project=\(projectID.raw.uuidString, privacy: .public) error=\(String(describing: error), privacy: .private(mask: .hash))"
      )
      return
    }
    manager.setProjectWorkspaceManifest(projectID: projectID, manifest: manifest)
    var observations: [HierarchyManager.WorkspaceChildObservation] = []
    for entry in manifest.repositories {
      let canonical = HierarchyManager.canonicalPath(entry.resolvedPath(rootPath: rootPath))
      var isDirectory = ObjCBool(false)
      let exists =
        FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
        && isDirectory.boolValue
      var branch: String?
      var sourceGitRoot: String?
      if exists {
        branch = try? await gitCLI.currentBranch(path: canonical)
        sourceGitRoot = (try? await gitCLI.repositoryRoot(forCheckoutAt: canonical))
          .map(HierarchyManager.canonicalPath)
        if let declared = entry.sourceGitRoot, let sourceGitRoot,
          HierarchyManager.canonicalPath(declared) != sourceGitRoot
        {
          reconcileLogger.notice(
            "workspace child belongs to a different repository than its manifest declares: project=\(projectID.raw.uuidString, privacy: .public) child=\(entry.name, privacy: .public)"
          )
        }
      }
      observations.append(
        HierarchyManager.WorkspaceChildObservation(
          name: entry.name,
          path: canonical,
          exists: exists,
          branch: branch,
          sourceGitRoot: sourceGitRoot
        )
      )
    }
    _ = manager.reconcileWorkspaceChildren(projectID: projectID, observations: observations)
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
      let mapped = entries.map { entry -> (path: String, branch: String?, head: String?) in
        let branch = (entry.branch?.isEmpty == false) ? entry.branch : nil
        return (
          path: HierarchyManager.normalizeRemotePath(entry.path), branch: branch, head: entry.head
        )
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
    let rows = manager.catalog.projects.first(where: { $0.id == projectID })?.worktrees ?? []
    for worktreeID in due {
      // A row that is also a workspace member's checkout belongs to that
      // workspace: removing it here would pull the folder out from under
      // the workspace's own row. Membership changes go through the
      // workspace flow, never the sweep.
      if let path = rows.first(where: { $0.id == worktreeID })?.path,
        manager.workspaceMembership(forPath: path) != nil
      {
        continue
      }
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
    guard let pid = catalog.displayedSelectedProjectID,
      let project = catalog.projects.first(where: { $0.id == pid })
    else { return .empty }
    return HierarchySelection(projectID: project.id, worktreeID: project.selectedWorktreeID)
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
    setSidebarFilter: { _ in fatalError("HierarchyClient.liveValue not configured") },
    setActiveTagFilter: { _ in fatalError("HierarchyClient.liveValue not configured") },
    addProject: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    addServerProject: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    updateServerProject: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    addWorkspaceProject: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    workspaceMembership: { _ in fatalError("HierarchyClient.liveValue not configured") },
    tearDownWorktreeSurfaces: { _ in fatalError("HierarchyClient.liveValue not configured") },
    removeProject: { _ in fatalError("HierarchyClient.liveValue not configured") },
    renameProject: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectColor: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectIcon: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktree: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectProject: { _ in fatalError("HierarchyClient.liveValue not configured") },
    selectWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    newTab: { _, _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTab: { _ in fatalError("HierarchyClient.liveValue not configured") },
    selectTab: { _ in fatalError("HierarchyClient.liveValue not configured") },
    selectTabAtIndex: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectAdjacentTab: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    renameTab: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setTabColor: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setTabIcon: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderTabs: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    moveTab: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeOtherTabs: { _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTabsToRight: { _ in fatalError("HierarchyClient.liveValue not configured") },
    closeAllTabs: { _ in fatalError("HierarchyClient.liveValue not configured") },
    splitPane: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closePane: { _ in fatalError("HierarchyClient.liveValue not configured") },
    focusPane: { _ in fatalError("HierarchyClient.liveValue not configured") },
    focusNeighbour: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    toggleZoom: { _ in fatalError("HierarchyClient.liveValue not configured") },
    resizeSplit: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    resizePane: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    equalizeSplits: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    movePane: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    ensureSurface: { _ in fatalError("HierarchyClient.liveValue not configured") },
    focusSurfaceView: { _ in fatalError("HierarchyClient.liveValue not configured") },
    focusedContent: { _ in fatalError("HierarchyClient.liveValue not configured") },
    addressOf: { _ in fatalError("HierarchyClient.liveValue not configured") },
    tabIsDirty: { _ in false },
    worktreeIsDirty: { _ in false },
    setProgressBusy: { _, _ in },
    setCommandBusy: { _, _ in },
    isContentBusy: { _ in false },
    snapshot: { fatalError("HierarchyClient.liveValue not configured") },
    selectionChanges: { AsyncStream { $0.finish() } },
    setWorktreeArchived: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreePinned: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreeIsNew: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectExpanded: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reconcileDiscoveredWorktrees: { _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktreeWithGit: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktreeWithGit: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runningContentCount: { _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectLoadState: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderProjects: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectSortMode: { _ in fatalError("HierarchyClient.liveValue not configured") },
    applyManualProjectOrder: { _ in fatalError("HierarchyClient.liveValue not configured") },
    bumpProjectActivity: { _ in fatalError("HierarchyClient.liveValue not configured") },
    isPathRegistered: { _ in fatalError("HierarchyClient.liveValue not configured") },
    projectContaining: { _ in fatalError("HierarchyClient.liveValue not configured") },
    kind: { _ in fatalError("HierarchyClient.liveValue not configured") },
    runScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runGlobalScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runCommand: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    launchAgentProfile: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    launchAgent: { _ in fatalError("HierarchyClient.liveValue not configured") },
    stopScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    stopAllScripts: { _ in fatalError("HierarchyClient.liveValue not configured") },
    runWorktreeLifecycleScript: { _, _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    promoteWorktree: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setContentLabel: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setAgentKind: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setAgentSessionID: { _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    updateWorkingDirectory: { _, _ in
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
    setSidebarFilter: unimplemented("HierarchyClient.setSidebarFilter"),
    setActiveTagFilter: unimplemented("HierarchyClient.setActiveTagFilter"),
    addProject: unimplemented("HierarchyClient.addProject", placeholder: ProjectID()),
    addServerProject: unimplemented("HierarchyClient.addServerProject", placeholder: ProjectID()),
    updateServerProject: unimplemented("HierarchyClient.updateServerProject"),
    addWorkspaceProject: unimplemented("HierarchyClient.addWorkspaceProject", placeholder: ProjectID()),
    workspaceMembership: unimplemented("HierarchyClient.workspaceMembership", placeholder: nil),
    tearDownWorktreeSurfaces: unimplemented("HierarchyClient.tearDownWorktreeSurfaces"),
    removeProject: unimplemented("HierarchyClient.removeProject"),
    renameProject: unimplemented("HierarchyClient.renameProject"),
    setProjectColor: unimplemented("HierarchyClient.setProjectColor"),
    setProjectIcon: unimplemented("HierarchyClient.setProjectIcon"),
    createWorktree: unimplemented("HierarchyClient.createWorktree", placeholder: WorktreeID()),
    removeWorktree: unimplemented("HierarchyClient.removeWorktree"),
    selectProject: unimplemented("HierarchyClient.selectProject"),
    selectWorktree: unimplemented("HierarchyClient.selectWorktree"),
    newTab: unimplemented(
      "HierarchyClient.newTab",
      placeholder: TabAddress(
        projectID: ProjectID(), worktreeID: WorktreeID(), paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    ),
    closeTab: unimplemented("HierarchyClient.closeTab"),
    selectTab: unimplemented("HierarchyClient.selectTab"),
    selectTabAtIndex: unimplemented("HierarchyClient.selectTabAtIndex", placeholder: nil),
    selectAdjacentTab: unimplemented("HierarchyClient.selectAdjacentTab", placeholder: nil),
    renameTab: unimplemented("HierarchyClient.renameTab"),
    setTabColor: unimplemented("HierarchyClient.setTabColor"),
    setTabIcon: unimplemented("HierarchyClient.setTabIcon"),
    reorderTabs: unimplemented("HierarchyClient.reorderTabs"),
    moveTab: unimplemented("HierarchyClient.moveTab"),
    closeOtherTabs: unimplemented("HierarchyClient.closeOtherTabs"),
    closeTabsToRight: unimplemented("HierarchyClient.closeTabsToRight"),
    closeAllTabs: unimplemented("HierarchyClient.closeAllTabs"),
    splitPane: unimplemented(
      "HierarchyClient.splitPane",
      placeholder: TabAddress(
        projectID: ProjectID(), worktreeID: WorktreeID(), paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    ),
    closePane: unimplemented("HierarchyClient.closePane"),
    focusPane: unimplemented("HierarchyClient.focusPane"),
    focusNeighbour: unimplemented("HierarchyClient.focusNeighbour", placeholder: nil),
    toggleZoom: unimplemented("HierarchyClient.toggleZoom", placeholder: false),
    resizeSplit: unimplemented("HierarchyClient.resizeSplit"),
    resizePane: unimplemented("HierarchyClient.resizePane"),
    equalizeSplits: unimplemented("HierarchyClient.equalizeSplits"),
    movePane: unimplemented("HierarchyClient.movePane"),
    ensureSurface: unimplemented("HierarchyClient.ensureSurface"),
    // Pure visual side-effect (focuses an NSView; no return value, no test
    // contract worth asserting). Every create/split path tail-calls this, so
    // an `unimplemented` here turns ~all routing tests into noisy stub farms.
    focusSurfaceView: { _ in },
    focusedContent: unimplemented("HierarchyClient.focusedContent", placeholder: nil),
    addressOf: unimplemented("HierarchyClient.addressOf", placeholder: nil),
    tabIsDirty: unimplemented("HierarchyClient.tabIsDirty", placeholder: false),
    worktreeIsDirty: unimplemented("HierarchyClient.worktreeIsDirty", placeholder: false),
    setProgressBusy: unimplemented("HierarchyClient.setProgressBusy"),
    setCommandBusy: unimplemented("HierarchyClient.setCommandBusy"),
    isContentBusy: unimplemented("HierarchyClient.isContentBusy", placeholder: false),
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
    runningContentCount: unimplemented("HierarchyClient.runningContentCount", placeholder: 0),
    setProjectLoadState: unimplemented("HierarchyClient.setProjectLoadState"),
    reorderProjects: unimplemented("HierarchyClient.reorderProjects"),
    setProjectSortMode: unimplemented("HierarchyClient.setProjectSortMode"),
    applyManualProjectOrder: unimplemented("HierarchyClient.applyManualProjectOrder"),
    bumpProjectActivity: unimplemented("HierarchyClient.bumpProjectActivity"),
    isPathRegistered: unimplemented("HierarchyClient.isPathRegistered", placeholder: nil),
    projectContaining: unimplemented("HierarchyClient.projectContaining", placeholder: nil),
    kind: unimplemented("HierarchyClient.kind", placeholder: nil),
    runScript: unimplemented("HierarchyClient.runScript"),
    runGlobalScript: unimplemented("HierarchyClient.runGlobalScript"),
    runCommand: unimplemented("HierarchyClient.runCommand"),
    launchAgentProfile: unimplemented("HierarchyClient.launchAgentProfile"),
    launchAgent: unimplemented(
      "HierarchyClient.launchAgent",
      placeholder: AgentLaunchOutcome(
        profile: AgentProfile(kind: .claudeCode), command: "", tabID: nil, paneID: nil, contentID: nil)
    ),
    stopScript: unimplemented("HierarchyClient.stopScript"),
    stopAllScripts: unimplemented("HierarchyClient.stopAllScripts"),
    runWorktreeLifecycleScript: unimplemented(
      "HierarchyClient.runWorktreeLifecycleScript"
    ),
    promoteWorktree: unimplemented("HierarchyClient.promoteWorktree"),
    setContentLabel: unimplemented("HierarchyClient.setContentLabel"),
    setAgentKind: unimplemented("HierarchyClient.setAgentKind"),
    setAgentSessionID: unimplemented("HierarchyClient.setAgentSessionID"),
    updateWorkingDirectory: unimplemented("HierarchyClient.updateWorkingDirectory"),
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
