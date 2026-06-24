import CodansCore
import ComposableArchitecture
import Foundation

// MARK: - Transient sheet / dialog payloads

/// Stub-sheet payload for Project-header "+" (add Worktree). Retained
/// for the brief window between `.projectAddWorktreeTapped` firing and
/// the real `CreateWorktreeFeature.State` being seeded in the next
/// reducer step. Carries just the parent IDs needed to resolve the
/// Project from `HierarchyManager.catalog` when building the child state.
struct AddWorktreeSheet: Equatable {
  var projectID: ProjectID
}

/// Worktree-remove confirmation payload. Non-nil → `.confirmationDialog` visible.
/// `displayName` is captured at tap-time so the dialog title shows the correct
/// name even if the catalog mutates before the user confirms.
struct PendingWorktreeRemoval: Equatable {
  var worktreeID: WorktreeID
  var projectID: ProjectID
  var displayName: String
}

/// Project-remove confirmation payload. Symmetric to `PendingWorktreeRemoval`
/// — Remove Project transitively removes every child Worktree, killing their
/// terminal surfaces, so we gate it with the same confirm pattern.
struct PendingProjectRemoval: Equatable {
  var projectID: ProjectID
  var displayName: String
}

/// Sidebar reducer for the Project → Worktree hierarchy plus the Tag
/// chip footer's filter state. Owns local view state (expansion sets,
/// sheet payloads, confirmation dialogs) and the project-selection
/// choreography. Structural catalog data is NOT in state —
/// `HierarchySidebarView` reads `HierarchyManager.catalog` from the
/// SwiftUI environment directly.
///
/// Side effects for Reveal-in-Finder and Open-in-default-editor route
/// through `.delegate` actions so `RootFeature` composes them with the
/// `EditorFeature` open path and the `FinderClient` dependency. Keeps
/// this reducer free of AppKit and from duplicating editor-resolution
/// logic.
@Reducer
struct HierarchySidebarFeature {
  @ObservableState
  struct State: Equatable {
    // Project disclosure state lives on `Project.isExpanded` so the open /
    // closed choice survives restart — the view reads `project.isExpanded`
    // directly from the catalog, mirroring how `Worktree.isPinned` is
    // consumed.

    var addWorktreeSheet: AddWorktreeSheet?
    var createWorktreeSheet: CreateWorktreeFeature.State?
    /// "Clone Repository" sheet reached from the Add Project menu. Drives
    /// a `git clone` and, on success, routes the destination back through
    /// the same registration path as a picked local folder.
    var cloneRepoSheet: CloneRepoFeature.State?
    var archivedWorktreesSheet: ArchivedWorktreesFeature.State?
    var pendingWorktreeRemoval: PendingWorktreeRemoval?
    var pendingProjectRemoval: PendingProjectRemoval?
    /// Session-scoped "seen it" flag for the first-archive explainer.
    /// Lives on this reducer (sidebar is the sole archive entry point
    /// for the main list; Archived sheet handles its own flow).
    var hasShownArchiveExplainer: Bool = false
    /// Pending archive awaiting the first-archive explainer dialog.
    var pendingArchiveExplainer: PendingArchiveExplainer?
    /// Transient toast after Prune completes.
    var pruneToast: String?
    /// Transient toast surfacing an archive / delete lifecycle failure.
    /// The wrapper effects swallow the script's own pane output (it lives
    /// in the spawned tab); this toast covers the catalog / git step that
    /// fires after the script finishes — e.g. `removeWorktreeWithGit`
    /// failing on a dirty index. `nil` = hidden.
    var lifecycleErrorToast: String?
    /// Worktrees currently mid-archive / mid-delete. Lifecycle scripts
    /// run in a real pane and we wait for `paneExited` before mutating
    /// the catalog, which can take seconds (or longer) for cleanup
    /// scripts. The sidebar row swaps its icon for a spinner while the
    /// id is in this set so the user sees their click landed.
    var lifecycleInProgressWorktrees: Set<WorktreeID> = []
    /// In-memory placeholders for in-flight `wt sw` creations. Each row
    /// renders inside its Project's section between pinned and unpinned
    /// segments. Not persisted; an app restart clears the set, and the
    /// existing reconcile path picks up any worktree that did make it to
    /// disk before the crash.
    var pendingWorktrees: IdentifiedArrayOf<PendingWorktree> = []
    /// Transient "reorder projects inline" editing session. When `true`,
    /// the sidebar collapses every Project to a header-only row, prefixes
    /// each with a drag handle, and enables `ForEach.onMove` so Projects
    /// can be dragged directly in the list. Session-scoped — never
    /// persisted; the resulting order is saved live through
    /// `reorderProjects`. Entered from the footer sort menu's
    /// "Manual Order…" item, dismissed by the inline "Done" control.
    var isReorderingProjects: Bool = false
  }

  /// Payload for the first-archive explainer dialog. Carries the
  /// originating `(projectID, name)` so the post-confirm path
  /// can run the archive-script wrapper without re-walking the catalog.
  struct PendingArchiveExplainer: Equatable {
    var worktreeID: WorktreeID
    var projectID: ProjectID
    var name: String
  }

  enum Action: Equatable {
    // Row taps
    case projectRowTapped(ProjectID)
    case worktreeRowTapped(WorktreeID, inProject: ProjectID)

    // Expansion
    case toggleProjectExpansion(ProjectID)

    // Toolbar — Add Project flow. The toolbar button drives the folder
    // picker directly (no intermediate sheet); the picked folder is then
    // classified for git-backing and either registered with its
    // last-path-component name or routed to the existing row when the
    // path is already a Project.
    case toolbarAddProjectTapped
    case addProjectFolderPicked(URL?)
    case addProjectGitRootResolved(canonicalPath: String, gitRoot: String?)
    /// Add Project menu → "Clone Repository…". Opens the clone sheet.
    case cloneRepoTapped

    // Reorder Projects (ForEach.onMove forwarder).
    case reorderProjects(from: IndexSet, to: Int)

    // Reorder Worktrees within a single sidebar segment under a Project
    // (ForEach.onMove forwarder for the pinned / unpinned segments).
    case reorderWorktrees(
      projectID: ProjectID,
      segment: WorktreeSegment, from: IndexSet, to: Int
    )

    /// Fired from `FailedProjectRow.Retry` (or the context menu). Delegates
    /// to `RootFeature` which calls `ProjectReconciler.reconcile` — same path
    /// used after Add Project.
    case retryProjectTapped(projectID: ProjectID)

    /// Sidebar bottom-bar refresh button. Delegates up so `RootFeature`
    /// can call `ProjectReconciler.reconcileAll(force: true)` — the
    /// manual override bypasses the focus-driven debounce so the user's
    /// "refresh now" tap doesn't sit on the queue.
    case refreshAllProjectsTapped

    // Project section hover chrome
    case projectAddWorktreeTapped(projectID: ProjectID)
    /// `⋯` menu → "Project Settings…". Opens the Settings window and lands
    /// the selection on this Project's General pane via
    /// `SettingsWindowPresenter.openAt(.projectGeneral(_))`.
    case projectSettingsTapped(projectID: ProjectID)
    case projectRemoveTapped(projectID: ProjectID, name: String)
    case projectRemoveConfirmed
    case projectRemoveCancelled

    // Worktree row context menu
    case worktreeRemoveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      name: String
    )
    case worktreeRemoveConfirmed
    case worktreeRemoveCancelled

    // Archive actions on the main worktree row.
    case worktreeArchiveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      name: String
    )
    case worktreeArchiveConfirmed
    case worktreeArchiveCancelled
    case worktreeUnarchiveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID
    )
    /// Right-click menu toggle. Flips the Worktree's `isPinned` flag via `HierarchyClient`.
    /// The `current` parameter lets the reducer emit the opposite value without reading
    /// catalog state.
    case worktreePinToggleTapped(worktreeID: WorktreeID, current: Bool)

    // Project ⋯ menu: Archived + Prune.
    case projectShowArchivedTapped(projectID: ProjectID)
    case archivedWorktreesSheet(ArchivedWorktreesFeature.Action)
    case archivedWorktreesSheetDismissed
    case projectPruneTapped(projectID: ProjectID)
    case projectPruneCompleted(pruned: Int, error: String?)
    case pruneToastDismissed
    /// Surfaces a lifecycle wrapper failure (archive flag flip rejected,
    /// delete-time `removeWorktreeWithGit` failed, etc.). Sent from the
    /// wrapper effect's catch arm; renders via `lifecycleErrorToast`.
    case lifecycleFailed(message: String)
    case lifecycleErrorToastDismissed
    /// Wrapper-effect bookends — the row spinner is driven by the set
    /// of worktree ids between `started` and `ended`. Always paired:
    /// the wrapper sends `ended` whether the underlying call succeeded
    /// or threw, so a stuck row should not be possible.
    case lifecycleStarted(worktreeID: WorktreeID)
    case lifecycleEnded(worktreeID: WorktreeID)
    case worktreeRevealInFinderTapped(path: String)
    case worktreeOpenInDefaultEditorTapped(
      worktreeID: WorktreeID,
      projectID: ProjectID,
      path: String
    )
    /// Right-click menu's "Open in" submenu — picks an explicit editor
    /// out of the installed list, bypassing the project-override /
    /// global-default cascade. Routed through the `openInEditor`
    /// delegate so RootFeature owns the `EditorFeature.openRequested`
    /// dispatch.
    case worktreeOpenInEditorTapped(
      worktreeID: WorktreeID,
      projectID: ProjectID,
      path: String,
      editorID: EditorID
    )

    // Pending-worktree lifecycle.
    case beginPendingWorktreeCreation(PendingWorktree)
    case pendingWorktreeProgress(PendingWorktreeID, String)
    case pendingWorktreeFinished(PendingWorktreeID, URL)
    case pendingWorktreeFailed(PendingWorktreeID, GitWorktreeError)
    case pendingWorktreeRetryTapped(PendingWorktreeID)
    case pendingWorktreeDiscardTapped(PendingWorktreeID)
    case pendingWorktreeCancelTapped(PendingWorktreeID)

    // Sidebar bottom-bar sort mode.
    /// User picked a non-manual sort from the sort popover. Persists and
    /// keeps `catalog.projects` (the manual order) untouched.
    case projectSortModeChanged(ProjectSortMode)
    /// User picked "Manual Order…" — enter the inline reorder session.
    /// Seeds `manualOrder` from the currently displayed order (so the
    /// list doesn't reshuffle), flips `projectSortMode` to `.manual`,
    /// and sets `isReorderingProjects`.
    case beginProjectReorder
    /// User tapped the inline "Done" control — leaves the reorder
    /// session. The order is already persisted, so this only clears the
    /// transient UI flag.
    case endProjectReorder

    // Tag chip footer at the sidebar's safe-area bottom.
    /// Toggle membership of `id` in `Catalog.activeTagFilter`. If filter is
    /// `.all` or `.untagged` it becomes `.tags([id])`. Within `.tags(set)`,
    /// `id` toggles in/out; an empty result resets to `.all`.
    case tagChipTapped(TagID)
    /// Resets the filter to `.all`.
    case allChipTapped
    /// Sets filter to `.untagged`. Mutually exclusive with `.tags(...)`.
    case untaggedChipTapped
    /// Bound to ⌘F via `MainWindowCommands`. Routed up so the chip footer
    /// view can take focus.
    case tagFilterFocusRequested
    /// Toggle membership of `tagID` in the Project's `tagIDs`. Resolves the
    /// current set from the catalog snapshot so the View binding can be a
    /// plain Toggle without holding state.
    case toggleTagOnProject(ProjectID, TagID)

    // Sheet stubs
    case addWorktreeSheetDismissed
    /// Child-feature actions for the Create Worktree sheet. Parent
    /// dismisses on either delegate case (dismiss or submitted).
    case createWorktreeSheet(CreateWorktreeFeature.Action)
    /// Child-feature actions for the Clone Repository sheet.
    case cloneRepoSheet(CloneRepoFeature.Action)

    // Delegate up to RootFeature for effects that cross feature boundaries.
    case delegate(Delegate)
    @CasePathable
    enum Delegate: Equatable {
      case openInDefaultEditor(worktreePath: String, projectID: ProjectID?)
      /// Sidebar's "Open in <Editor>" submenu — RootFeature dispatches
      /// `.editor(.openRequested)` directly with the explicit editor ID
      /// instead of letting the priority cascade pick one.
      case openInEditor(worktreePath: String, projectID: ProjectID?, editorID: EditorID)
      case revealInFinder(path: String)
      /// Emitted after a Project is added (or via Retry on a `.failed` row).
      /// `RootFeature` forwards to `ProjectReconciler.reconcile`.
      case reconcileProjectRequested(ProjectID)
      /// Emitted when the Add Project picker hits a folder that's already
      /// registered. `RootFeature` selects the Project so the user lands
      /// on the existing row.
      case revealExistingProject(ProjectID)
      /// Opens the Tag CRUD sheet at root level.
      /// Emitted from the project header's "Tags" submenu ("Edit Tags…")
      /// and from the chip footer's trailing "+" button.
      case openTagManager
      /// Sidebar bottom-bar refresh button. RootFeature routes this to
      /// `ProjectReconciler.reconcileAll(force: true)`.
      case refreshAllProjectsRequested
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(GitWorktreeClient.self) private var gitWorktreeClient
  @Dependency(FolderPickerClient.self) private var folderPickerClient
  @Dependency(GitWorktreeCLI.self) private var gitCLI
  @Dependency(SettingsWindowPresenter.self) private var settingsWindowPresenter

  /// Cancellation token namespace for sidebar-owned effects. The single
  /// `.pending` case ties each in-flight `wt sw` stream to its
  /// `PendingWorktreeID` so Cancel / Retry can target it precisely.
  /// `nonisolated` because TCA's `.cancellable(id:)` requires a Sendable
  /// id; the reducer's default MainActor isolation would otherwise gate
  /// the conformance.
  private nonisolated enum CancelID: Hashable, Sendable {
    case pending(PendingWorktreeID)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      // Parent-side handling for Create-Worktree delegate events.
      // The child reducer (attached via `.ifLet` below) runs first via
      // TCA's reducer composition order; these cases fire after the
      // child's own logic has already dispatched, so clearing
      // `createWorktreeSheet` here is the correct "dismiss the sheet"
      // effect.
      switch action {
      case .createWorktreeSheet(.delegate(.dismissed)):
        state.createWorktreeSheet = nil
        return .none
      case .createWorktreeSheet(.delegate(.beginCreate(let pending))):
        // Sheet validated the form; parent dismisses and starts the
        // pending lifecycle in the same reducer frame so the user never
        // sees a "sheet closed but row not yet present" gap.
        state.createWorktreeSheet = nil
        return .send(.beginPendingWorktreeCreation(pending))
      case .createWorktreeSheet:
        // Other child actions are handled by the ifLet-scoped
        // reducer; no-op at the parent level.
        return .none
      case .cloneRepoSheet(.delegate(.dismissed)):
        state.cloneRepoSheet = nil
        return .none
      case .cloneRepoSheet(.delegate(.cloned(let localPath))):
        // Clone landed on disk; dismiss the sheet and reuse the picked-folder
        // path so registration (dedup guard → gitRoot discovery → catalog
        // add → reconcile) stays in one place.
        state.cloneRepoSheet = nil
        return .send(.addProjectFolderPicked(URL(fileURLWithPath: localPath)))
      case .cloneRepoSheet:
        return .none
      case .archivedWorktreesSheet(.delegate(.dismissed)):
        state.archivedWorktreesSheet = nil
        return .none
      case .archivedWorktreesSheet:
        return .none
      default:
        return coreReduce(into: &state, action: action)
      }
    }
    .ifLet(\.createWorktreeSheet, action: \.createWorktreeSheet) {
      CreateWorktreeFeature()
    }
    .ifLet(\.cloneRepoSheet, action: \.cloneRepoSheet) {
      CloneRepoFeature()
    }
    .ifLet(\.archivedWorktreesSheet, action: \.archivedWorktreesSheet) {
      ArchivedWorktreesFeature()
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func coreReduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    // MARK: Row taps

    case .projectRowTapped(let projectID):
      hierarchyClient.selectProject(projectID)
      return .none

    case .worktreeRowTapped(let worktreeID, let projectID):
      // Switching worktrees across Projects must also flip the active
      // Project — otherwise selection keeps reading the previous Project's
      // `selectedWorktreeID` and the detail column never refreshes.
      hierarchyClient.selectProject(projectID)
      try? hierarchyClient.selectWorktree(worktreeID, projectID)
      return .none

    // MARK: Expansion

    case .toggleProjectExpansion(let projectID):
      // Single source of truth lives on the catalog (`Project.isExpanded`),
      // so flip via the client and let the SwiftUI catalog observation
      // re-render the row. Unknown ids are a silent no-op inside the
      // manager.
      let snapshot = hierarchyClient.snapshot()
      let current =
        snapshot.projects
        .first(where: { $0.id == projectID })?
        .isExpanded ?? true
      hierarchyClient.setProjectExpanded(projectID, !current)
      return .none

    // MARK: Toolbar

    case .toolbarAddProjectTapped:
      return .run { [picker = folderPickerClient] send in
        let url = await picker.pick("Add Project")
        await send(.addProjectFolderPicked(url))
      }

    case .addProjectFolderPicked(let url):
      guard let url else { return .none }
      let canonical = HierarchyManager.canonicalPath(url.path)
      if let existing = hierarchyClient.isPathRegistered(canonical) {
        return .send(.delegate(.revealExistingProject(existing)))
      }
      return .run { [cli = gitCLI] send in
        let gitRoot = try? await cli.discoverGitRoot(candidatePath: canonical)
        await send(.addProjectGitRootResolved(canonicalPath: canonical, gitRoot: gitRoot))
      }

    case .addProjectGitRootResolved(let canonical, let gitRoot):
      let name = (canonical as NSString).lastPathComponent
      guard !name.isEmpty else { return .none }
      // addProject is non-throwing and returns a non-optional ProjectID.
      let projectID = hierarchyClient.addProject(name, canonical, gitRoot)
      return .send(.delegate(.reconcileProjectRequested(projectID)))

    case .cloneRepoTapped:
      state.cloneRepoSheet = CloneRepoFeature.State()
      return .none

    // MARK: Tag filter chip footer

    case .tagChipTapped(let tagID):
      let current = hierarchyClient.snapshot().activeTagFilter
      let next: TagFilter
      switch current {
      case .all, .untagged:
        next = .tags([tagID])
      case .tags(let set):
        if set.contains(tagID) {
          var updated = set
          updated.remove(tagID)
          next = updated.isEmpty ? .all : .tags(updated)
        } else {
          var updated = set
          updated.insert(tagID)
          next = .tags(updated)
        }
      }
      hierarchyClient.setActiveTagFilter(next)
      return .none

    case .allChipTapped:
      hierarchyClient.setActiveTagFilter(.all)
      return .none

    case .untaggedChipTapped:
      hierarchyClient.setActiveTagFilter(.untagged)
      return .none

    case .tagFilterFocusRequested:
      // The view subscribes to this via `@FocusState`; the reducer is a
      // pure pass-through so the feature stays state-light.
      return .none

    case .toggleTagOnProject(let projectID, let tagID):
      let snapshot = hierarchyClient.snapshot()
      guard let project = snapshot.projects.first(where: { $0.id == projectID })
      else { return .none }
      var updated = project.tagIDs
      if updated.contains(tagID) {
        updated.remove(tagID)
      } else {
        updated.insert(tagID)
      }
      hierarchyClient.setProjectTags(projectID, updated)
      return .none

    // MARK: Project hover chrome

    case .reorderProjects(let source, let destination):
      hierarchyClient.reorderProjects(source, destination)
      return .none

    case .reorderWorktrees(let projectID, let segment, let source, let destination):
      try? hierarchyClient.reorderWorktrees(projectID, segment, source, destination)
      return .none

    case .retryProjectTapped(let projectID):
      return .send(.delegate(.reconcileProjectRequested(projectID)))

    case .refreshAllProjectsTapped:
      return .send(.delegate(.refreshAllProjectsRequested))

    // MARK: Project sort mode

    case .projectSortModeChanged(let mode):
      hierarchyClient.setProjectSortMode(mode)
      // Switching to a computed order leaves no manual session to edit.
      if mode != .manual { state.isReorderingProjects = false }
      return .none

    case .beginProjectReorder:
      // Seed `manualOrder` from the order the user currently sees (the
      // full, unfiltered list under the active mode) and flip to
      // `.manual` in one step, so entering the session doesn't reshuffle
      // rows. The inline `.onMove` then maps 1:1 onto `catalog.projects`.
      let catalog = hierarchyClient.snapshot()
      hierarchyClient.applyManualProjectOrder(catalog.sorted(catalog.projects).map(\.id))
      state.isReorderingProjects = true
      return .none

    case .endProjectReorder:
      state.isReorderingProjects = false
      return .none

    case .projectAddWorktreeTapped(let projectID):
      // Resolve the Project from the catalog to feed repoRoot + worktreesDirectory
      // into CreateWorktreeFeature. v3 moved worktreesDirectory off catalog into
      // settings.json.projects[pid]. If the Project has no gitRoot the sheet wouldn't
      // be useful — silently no-op (the Add-Worktree "+" row is hidden for non-git).
      let snapshot = hierarchyClient.snapshot()
      guard let project = snapshot.projects.first(where: { $0.id == projectID }),
        let gitRoot = project.gitRoot
      else { return .none }
      let settingsSnapshot = settingsWriter.readSnapshotSync()
      let projectSettings = settingsSnapshot.projects[projectID]
      let globalWorktree = settingsSnapshot.worktree
      let defaultWtDir = globalWorktree.resolveBaseDirectory(
        // Use the path-derived canonical name so renaming a project in
        // Settings → General never relocates the suggested worktree folder.
        forProjectName: project.canonicalName,
        projectOverride: projectSettings?.worktreesDirectory
      )
      let pendingCount = state.pendingWorktrees.filter { $0.projectID == projectID }.count
      // Seed the sheet toggles from the effective settings so the
      // checkboxes match what the user pinned in Project Settings → Worktree
      // (with the global Worktree pane as the fallback). Each per-project
      // override is `nil` = inherit; if both are unset the value falls back
      // to the global default.
      let projectGit = projectSettings?.git
      let copyIgnoredDefault =
        projectGit?.copyIgnoredOnWorktreeCreate ?? globalWorktree.copyIgnoredOnCreate
      let copyUntrackedDefault =
        projectGit?.copyUntrackedOnWorktreeCreate ?? globalWorktree.copyUntrackedOnCreate
      let fetchOriginDefault =
        projectGit?.fetchRemoteOnWorktreeCreate ?? globalWorktree.fetchRemoteOnCreate
      state.createWorktreeSheet = CreateWorktreeFeature.State(
        projectID: projectID,
        repoRoot: URL(fileURLWithPath: gitRoot),
        worktreesDirectory: defaultWtDir,
        currentPendingCountForProject: pendingCount,
        baseRefOverride: projectGit?.worktreeBaseRef,
        fetchOrigin: fetchOriginDefault,
        copyIgnored: copyIgnoredDefault,
        copyUntracked: copyUntrackedDefault
      )
      return .none

    case .projectSettingsTapped(let projectID):
      let presenter = settingsWindowPresenter
      return .run { _ in
        await MainActor.run {
          presenter.openAt(.projectGeneral(projectID))
        }
      }

    case .projectRemoveTapped(let projectID, let name):
      state.pendingProjectRemoval = PendingProjectRemoval(
        projectID: projectID,
        displayName: name
      )
      return .none

    case .projectRemoveConfirmed:
      guard let pending = state.pendingProjectRemoval else { return .none }
      try? hierarchyClient.removeProject(pending.projectID)
      state.pendingProjectRemoval = nil
      return .none

    case .projectRemoveCancelled:
      state.pendingProjectRemoval = nil
      return .none

    // MARK: Worktree context menu

    case .worktreeRemoveTapped(let worktreeID, let projectID, let name):
      // Defensive guard: the main checkout cannot be removed — its directory IS
      // the project's `rootPath`, and `removeWorktree`'s relocate-then-prune
      // strategy would silently move the project root into trash. The sidebar
      // context menu hides "Remove Worktree" for this case, but the destructive
      // chord (⌘⇧⌫) and any future caller would otherwise bypass that
      // protection. Guard at the lifecycle entry point so every dispatch path
      // is covered by a single check.
      if isMainCheckout(worktreeID: worktreeID, projectID: projectID) {
        return .none
      }
      state.pendingWorktreeRemoval = PendingWorktreeRemoval(
        worktreeID: worktreeID,
        projectID: projectID,
        displayName: name
      )
      return .none

    case .worktreeRemoveConfirmed:
      guard let pending = state.pendingWorktreeRemoval else { return .none }
      state.pendingWorktreeRemoval = nil
      let client = hierarchyClient
      let wid = pending.worktreeID
      let pid = pending.projectID
      return runRemoveWithDeleteScript(client: client, wid: wid, pid: pid)

    case .worktreeRemoveCancelled:
      state.pendingWorktreeRemoval = nil
      return .none

    case .worktreeArchiveTapped(let wid, let pid, let name):
      // Same main-checkout guard as `worktreeRemoveTapped`. Archive runs the
      // configured archive script in a new pane against the worktree's path
      // and then flips `Worktree.archived = true` — for the main checkout
      // this would hide the project's root from the sidebar with no way back
      // short of editing the catalog file by hand.
      if isMainCheckout(worktreeID: wid, projectID: pid) {
        return .none
      }
      if state.hasShownArchiveExplainer {
        return runArchiveWithLifecycle(wid: wid, pid: pid)
      }
      state.pendingArchiveExplainer = PendingArchiveExplainer(
        worktreeID: wid, projectID: pid, name: name
      )
      return .none

    case .worktreeArchiveConfirmed:
      guard let pending = state.pendingArchiveExplainer else { return .none }
      state.hasShownArchiveExplainer = true
      state.pendingArchiveExplainer = nil
      return runArchiveWithLifecycle(
        wid: pending.worktreeID, pid: pending.projectID
      )

    case .worktreeArchiveCancelled:
      state.pendingArchiveExplainer = nil
      return .none

    case .worktreeUnarchiveTapped(let wid, _):
      try? hierarchyClient.setWorktreeArchived(wid, false)
      return .none

    case .worktreePinToggleTapped(let wid, let current):
      hierarchyClient.setWorktreePinned(wid, !current)
      return .none

    case .projectShowArchivedTapped(let projectID):
      state.archivedWorktreesSheet = ArchivedWorktreesFeature.State(
        projectID: projectID
      )
      return .none

    case .archivedWorktreesSheetDismissed:
      state.archivedWorktreesSheet = nil
      return .none

    case .projectPruneTapped(let projectID):
      let snapshot = hierarchyClient.snapshot()
      guard let project = snapshot.projects.first(where: { $0.id == projectID }),
        let gitRoot = project.gitRoot
      else { return .none }
      let gitRootURL = URL(fileURLWithPath: gitRoot)
      @Dependency(GitWorktreeClient.self) var gitClient
      let client = gitClient
      return .run { send in
        do {
          let pruned = try await client.pruneWorktrees(gitRootURL)
          await send(.projectPruneCompleted(pruned: pruned, error: nil))
        } catch let error as GitWorktreeError {
          let msg: String
          if case .commandFailed(_, let stderr) = error {
            msg = stderr
          } else {
            msg = "\(error)"
          }
          await send(.projectPruneCompleted(pruned: 0, error: msg))
        } catch {
          await send(.projectPruneCompleted(pruned: 0, error: error.localizedDescription))
        }
      }

    case .projectPruneCompleted(let pruned, let error):
      if let error {
        state.pruneToast = "Prune failed: \(error)"
      } else {
        state.pruneToast =
          pruned == 1
          ? "Pruned 1 stale worktree"
          : "Pruned \(pruned) stale worktrees"
      }
      return .none

    case .pruneToastDismissed:
      state.pruneToast = nil
      return .none

    case .lifecycleFailed(let message):
      state.lifecycleErrorToast = message
      return .none

    case .lifecycleErrorToastDismissed:
      state.lifecycleErrorToast = nil
      return .none

    case .lifecycleStarted(let wid):
      state.lifecycleInProgressWorktrees.insert(wid)
      return .none

    case .lifecycleEnded(let wid):
      state.lifecycleInProgressWorktrees.remove(wid)
      return .none

    case .archivedWorktreesSheet:
      // Routed through the top-level Reducer; unreachable here.
      return .none

    case .worktreeRevealInFinderTapped(let path):
      return .send(.delegate(.revealInFinder(path: path)))

    case .worktreeOpenInDefaultEditorTapped(_, let projectID, let path):
      return .send(.delegate(.openInDefaultEditor(worktreePath: path, projectID: projectID)))

    case .worktreeOpenInEditorTapped(_, let projectID, let path, let editorID):
      return .send(
        .delegate(.openInEditor(worktreePath: path, projectID: projectID, editorID: editorID))
      )

    // MARK: Sheet stubs

    case .addWorktreeSheetDismissed:
      state.addWorktreeSheet = nil
      return .none

    // MARK: Pending worktree lifecycle

    case .beginPendingWorktreeCreation(let pending):
      // Hard cap: silently reject when this project already has 8 pending
      // creations. The sheet UI also enforces this via banner + disabled
      // Create; reducer guard covers non-sheet entry points (IPC, command
      // palette, tests).
      let count = state.pendingWorktrees.filter { $0.projectID == pending.projectID }.count
      guard count < 8 else { return .none }
      state.pendingWorktrees.append(pending)
      return runPendingStream(pending)

    case .pendingWorktreeProgress(let id, let line):
      // Race guard: cancel may have removed the row before this progress
      // line drained from the stream.
      guard state.pendingWorktrees[id: id] != nil else { return .none }
      state.pendingWorktrees[id: id]?.lastProgressLine = line
      // Streaming tail for the WorktreeLoadingView. Cap on append so the
      // array stays bounded even on long clones; the detail view shows
      // the last `progressLineWindow` lines.
      state.pendingWorktrees[id: id]?.progressLines.append(line)
      let window = PendingWorktree.progressLineWindow
      if let count = state.pendingWorktrees[id: id]?.progressLines.count, count > window {
        state.pendingWorktrees[id: id]?.progressLines.removeFirst(count - window)
      }
      return .none

    case .pendingWorktreeFinished(let id, let path):
      guard let pending = state.pendingWorktrees[id: id] else { return .none }
      let pid = pending.projectID
      let displayName = pending.displayName
      let branch = pending.spec.name
      let pathString = path.standardizedFileURL.path(percentEncoded: false)

      // Critical boundary: catalog write. Failure here keeps the row
      // visible as .failed for Retry/Discard. Anything below is cosmetic.
      // displayName preserves the user's original input ("feat/web-ui") for UI;
      // branch is the sanitized git branch ("feat-web-ui") that matches HEAD.
      let worktreeID: WorktreeID
      do {
        worktreeID = try hierarchyClient.createWorktreeWithGit(
          pid, displayName, branch, pathString)
      } catch let err as GitWorktreeError {
        state.pendingWorktrees[id: id]?.status = .failed(err)
        return .none
      } catch {
        state.pendingWorktrees[id: id]?.status = .failed(
          .commandFailed(command: "catalog", stderr: error.localizedDescription))
        return .none
      }

      // Catalog now has the real worktree row. Remove pending IMMEDIATELY
      // so the sidebar doesn't double-render (real row + .failed pending
      // row for the same logical creation). The post-catalog steps below
      // are cosmetic side-effects and must not roll back this removal.
      state.pendingWorktrees.remove(id: id)
      hierarchyClient.selectProject(pid)
      try? hierarchyClient.selectWorktree(worktreeID, pid)
      // Create script materializes as the auto-opened pane's
      // initialCommand — user sees realtime output in that pane. Empty
      // / unset script = a plain interactive shell.
      let createCommand =
        settingsWriter
        .readSnapshotSync()
        .projects[pid]?.git?.createScript?.command
      // Seed the first pane in two phases. The catalog row (`createPaneRow`)
      // is inserted SYNCHRONOUSLY here so it is observable before the
      // `.selectionChanged` that `selectWorktree` above just triggered is
      // processed. Otherwise `RootFeature.autoSeedTabAndPaneIfNeeded` reads
      // the still-empty tab and races in a second, redundant pane — and the
      // two concurrent `zmx serve` spawns collide, the loser surfacing
      // `zmxServeFailed`. The async zmx-daemon + surface bringup follows in
      // the effect. The create script rides along as the pane's initialCommand.
      if let tabID = try? hierarchyClient.createTab(worktreeID, pid, nil),
        let paneID = try? hierarchyClient.createPaneRow(
          tabID, worktreeID, pid, pathString, createCommand
        )
      {
        return .run { [client = hierarchyClient] _ in
          try? await client.ensurePaneSurface(paneID, tabID, worktreeID, pid)
        }
      }
      return .none

    case .pendingWorktreeFailed(let id, let err):
      // Race guard symmetric with progress / finished arms: a Cancel
      // that lands before the stream's failure event drains drops the
      // late .failed without spuriously logging or mutating state.
      guard state.pendingWorktrees[id: id] != nil else { return .none }
      state.pendingWorktrees[id: id]?.status = .failed(err)
      return .none

    case .pendingWorktreeRetryTapped(let id):
      guard let pending = state.pendingWorktrees[id: id] else { return .none }
      guard case .failed = pending.status else { return .none }
      state.pendingWorktrees[id: id]?.status = .running
      state.pendingWorktrees[id: id]?.lastProgressLine = nil
      // Streaming tail is rebuilt from the new attempt's stdout/stderr;
      // keeping the previous run's lines around would mislead the
      // detail-pane WorktreeLoadingView (the user is looking at the
      // *current* attempt, not the failed one).
      state.pendingWorktrees[id: id]?.progressLines = []
      // Re-read the (now-updated) row so the effect sees `status == .running`.
      guard let restarted = state.pendingWorktrees[id: id] else { return .none }
      return runPendingStream(restarted)

    case .pendingWorktreeDiscardTapped(let id):
      state.pendingWorktrees.remove(id: id)
      return .none

    case .pendingWorktreeCancelTapped(let id):
      state.pendingWorktrees.remove(id: id)
      return .cancel(id: CancelID.pending(id))

    // MARK: Delegate

    case .delegate:
      // Handled by the parent reducer.
      return .none

    case .createWorktreeSheet:
      // Routed through the top-level Reducer; unreachable here.
      return .none

    case .cloneRepoSheet:
      // Routed through the top-level Reducer; unreachable here.
      return .none
    }
  }

  /// Cancellable streaming effect that consumes `createWorktreeStream`
  /// for a single pending creation. Cancel-in-flight protects Retry from
  /// overlapping a zombie effect (edge case — by the time Retry fires
  /// the prior effect should already have thrown).
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
        await send(
          .pendingWorktreeFailed(
            id, .commandFailed(command: "wt sw", stderr: "stream ended without finishing")))
      } catch let err as GitWorktreeError {
        await send(.pendingWorktreeFailed(id, err))
      } catch is CancellationError {
        return
      } catch {
        await send(
          .pendingWorktreeFailed(
            id, .commandFailed(command: "wt sw", stderr: error.localizedDescription)))
      }
    }
    .cancellable(id: CancelID.pending(id), cancelInFlight: true)
  }

  /// `true` when the given Worktree is the project's main checkout (its
  /// `path` equals the project's `rootPath`). The main checkout cannot be
  /// archived or removed — see the call sites for the rationale.
  private func isMainCheckout(worktreeID: WorktreeID, projectID: ProjectID) -> Bool {
    let snapshot = hierarchyClient.snapshot()
    guard
      let project = snapshot.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return false }
    return worktree.path == project.rootPath
  }

  /// Archive button → archive-script flow. The lifecycle wrapper opens a
  /// new tab in the worktree, runs the script as that pane's
  /// `initialCommand`, and waits for the pane's child to exit before
  /// flipping `Worktree.archived = true`. The script's own output lives
  /// in the spawned pane; only failures of the catalog flag flip
  /// surface here, via `lifecycleErrorToast`.
  private func runArchiveWithLifecycle(
    wid: WorktreeID, pid: ProjectID
  ) -> Effect<Action> {
    let client = hierarchyClient
    return .run { send in
      await send(.lifecycleStarted(worktreeID: wid))
      do {
        try await client.setWorktreeArchivedWithLifecycle(wid, pid, true)
      } catch {
        let detail = (error as? GitWorktreeError).map(humanReadable) ?? error.localizedDescription
        await send(.lifecycleFailed(message: "Archive failed: \(detail)"))
      }
      await send(.lifecycleEnded(worktreeID: wid))
    }
  }

  /// Remove button → delete-script flow. The lifecycle wrapper opens a
  /// new tab in the worktree, runs the configured `deleteScript` as the
  /// pane's `initialCommand`, waits for the pane's child to exit, then
  /// drives the relocate-then-prune `removeWorktreeWithGit`. Removal of
  /// an *already-archived* worktree goes through `removeWorktreeWithGit`
  /// directly (skipping the script) — that path is owned by
  /// `ArchivedWorktreesFeature`. The script's own output lives in the
  /// spawned pane; only `removeWorktreeWithGit` failures surface here,
  /// via `lifecycleErrorToast`.
  private func runRemoveWithDeleteScript(
    client: HierarchyClient,
    wid: WorktreeID, pid: ProjectID
  ) -> Effect<Action> {
    .run { send in
      await send(.lifecycleStarted(worktreeID: wid))
      do {
        // A non-nil return means removal succeeded but the branch was
        // intentionally kept (checked out elsewhere) — surface it as a
        // non-fatal note via the same toast channel.
        if let warning = try await client.removeWorktreeWithLifecycle(wid, pid) {
          await send(.lifecycleFailed(message: warning))
        }
      } catch {
        await send(.lifecycleFailed(message: "Delete failed: \(error.localizedDescription)"))
      }
      await send(.lifecycleEnded(worktreeID: wid))
    }
  }
}
