import CodansCore
import Foundation
import OSLog
import Observation

/// Breadcrumbs for the catalog-side half of the reconcile path. Shares the
/// `com.gumpw.codans.hierarchy` / `reconcile` address with `HierarchyClient`'s
/// logger so one predicate covers both halves — the client logs discovery
/// failures that threw, this logs the sweep decisions taken on the results
/// that did not.
private let reconcileLogger = Logger(
  subsystem: "com.gumpw.codans.hierarchy",
  category: "reconcile"
)

nonisolated enum HierarchyError: LocalizedError, Equatable, Sendable {
  case notFound(String)
  case invariantViolation(String)
  /// `zmx serve <paneID>` exited successfully but printed no socket
  /// path on stdout. Indicates a daemon-side packaging regression.
  case zmxServeNoSocketPath
  /// `zmx serve` failed to launch or exited with a non-zero status.
  /// `detail` is whatever stderr / spawn error the runner captured.
  case zmxServeFailed(detail: String)
  /// The shipped app bundle is missing the embedded `bin/zmx` resource.
  case zmxBinaryMissing
  /// A local Tab or Pane was asked to start in a folder that is gone.
  case directoryMissing(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let message), .invariantViolation(let message):
      return message
    case .zmxServeNoSocketPath:
      return "The zmx session daemon did not report a socket path."
    case .zmxServeFailed(let detail):
      return "The zmx session daemon failed to start: \(detail)"
    case .zmxBinaryMissing:
      return "This Codans build is missing its bundled zmx helper. Rebuild or reinstall the app."
    case .directoryMissing(let path):
      return "Folder no longer exists at \(path)"
    }
  }
}

/// Identifies a reorderable sidebar section under a Project. The full sidebar
/// taxonomy has four sections (main / pinned / pending / unpinned); only
/// `pinned` and `unpinned` admit user-initiated reordering, so this enum names
/// just those.
enum WorktreeSegment: Sendable, Equatable {
  case pinned
  case unpinned
}

/// Catalog-driven worktree repositioning mode for
/// `HierarchyClient.promoteWorktree`. Ships a single case today; the enum
/// exists so additional modes (e.g. `.toIndex(Int)` for an explicit reorder
/// UI) can land without reshaping the call surface.
enum WorktreePromotionMode: Sendable, Equatable {
  /// Move the worktree to index 0 of its Project's unpinned section. Pinned
  /// targets are a silent no-op (pinned ordering is the user's explicit
  /// preference and is not auto-mutated). Pinned + unpinned sections retain
  /// their independent ordering.
  case moveToFrontWithinUnpinned
}

@MainActor
@Observable
final class HierarchyManager {
  private(set) var catalog: Catalog {
    didSet { refreshWorkspaceMemberships() }
  }
  @ObservationIgnored private var workspaceMembershipIndex = WorkspaceMembershipIndex()
  private(set) var workspaceMemberships: [WorktreeID: WorkspaceMembership] = [:]

  private let store: CatalogStore
  var processRegistry = WorktreeProcessRegistry()
  private let runtime: HierarchyRuntime

  /// Live activity of a Content beyond what the catalog records: a running
  /// foreground command or a working agent. Injected by the app, which
  /// owns the content runtime and the agent store; `isBusy(_:)` ORs it
  /// with the catalog's own signal (a non-empty command queue).
  var contentActivity: (@MainActor (ContentID) -> Bool)?

  /// Fired after a Project is dropped from the catalog, with its id.
  ///
  /// Both removal entry points — the sidebar through `HierarchyClient` and
  /// `codans project rm` through `HierarchyHandlers` — land here, which the
  /// client-level closure this replaces did not: the RPC handler calls the
  /// manager directly and bypassed it entirely. A settable property rather
  /// than an init parameter because `AppState` builds the manager before the
  /// `SettingsStore` exists; a closure rather than a direct reference so the
  /// Runtime layer keeps its Settings independence.
  var onProjectRemoved: (@MainActor (ProjectID) -> Void)?

  init(catalog: Catalog, store: CatalogStore, runtime: HierarchyRuntime) {
    self.catalog = catalog
    self.store = store
    self.runtime = runtime
    Self.normalizeArchivedSelection(in: &self.catalog)
    let didStampLegacyTimestamps = Self.backfillLegacyAddedAt(in: &self.catalog)
    let didClearAgentBindings = Self.clearAgentBindings(in: &self.catalog)
    rebuildRunScriptContents()
    refreshWorkspaceMemberships()
    if didStampLegacyTimestamps || didClearAgentBindings {
      // Persist the migration so successive launches start from the
      // backfilled timestamps rather than re-deriving them on every
      // open (and so the user-visible order is deterministic the
      // moment another writer touches the catalog).
      store.scheduleSave(self.catalog)
    }
  }

  /// Agent bindings (`agentKind` + `agentSessionID` of a terminal Content)
  /// are session-scoped: the pty child that hosted the agent dies when
  /// codans quits, so on every cold start the catalog's stored kind
  /// describes a process that no longer exists. Keep these fields
  /// runtime-only by wiping them at launch — AgentBinder re-classifies
  /// once the user actually runs the agent again. Returns true if any
  /// Content was mutated.
  private static func clearAgentBindings(in catalog: inout Catalog) -> Bool {
    var mutated = false
    catalog.forEachTerminalContent { state in
      guard state.agentKind != nil || state.agentSessionID != nil else { return }
      state.agentKind = nil
      state.agentSessionID = nil
      mutated = true
    }
    return mutated
  }

  /// Defensive sweep run at load: if any project's `selectedWorktreeID`
  /// points to an archived worktree (a stale write from a now-fixed
  /// inbox-navigation bug, or a future regression), advance it to the
  /// first non-archived sibling. Keeps the active selection chain
  /// reachable from the sidebar so the detail pane never restores to
  /// a hidden, closed-surface row.
  /// One-time migration that pulls legacy projects (decoded with the
  /// sentinel `addedAt == .distantPast` because the field didn't exist
  /// when the catalog was written) onto a real timeline so each sort
  /// mode produces a distinct order. Without this every "active" /
  /// "join order" lookup would tie-break on the array position and
  /// visually match `.manual`, defeating the whole sort-mode UI.
  ///
  /// The stamped timestamps are derived from a fixed base far enough in
  /// the past that any future `Date.now` from `addProject` sorts after
  /// them, but spaced by 1 s per index so the relative order of legacy
  /// projects equals their `catalog.projects` array position — which is
  /// the historical sidebar order. Returns `true` if at least one
  /// project was mutated.
  private static func backfillLegacyAddedAt(in catalog: inout Catalog) -> Bool {
    let base = Date(timeIntervalSince1970: 0)
    var mutated = false
    for index in catalog.projects.indices where catalog.projects[index].addedAt == .distantPast {
      catalog.projects[index].addedAt = base.addingTimeInterval(TimeInterval(index))
      mutated = true
    }
    return mutated
  }

  private static func normalizeArchivedSelection(in catalog: inout Catalog) {
    for projectIndex in catalog.projects.indices {
      let project = catalog.projects[projectIndex]
      guard let selectedID = project.selectedWorktreeID,
        let selected = project.worktrees.first(where: { $0.id == selectedID }),
        selected.archived
      else { continue }
      catalog.projects[projectIndex].selectedWorktreeID =
        project.worktrees.first(where: { !$0.archived })?.id
    }
  }

  // MARK: - Tag mutations

  /// Creates a new Tag with the given display name and color, appends it to
  /// `catalog.tags`, and persists. Names are trimmed and rejected if empty
  /// (returns a fresh TagID without appending — symmetric with the way
  /// `addProject` would silently no-op on an empty name). Names are not
  /// enforced unique (mirrors Finder).
  @discardableResult
  func createTag(name: String, color: TagColor) -> TagID {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return TagID() }
    let tag = Tag(name: trimmed, color: color)
    catalog.tags.append(tag)
    store.scheduleSave(catalog)
    return tag.id
  }

  /// Renames the Tag in place. Trims the input, rejects empty names, and
  /// silently no-ops on unknown ids or unchanged values.
  func renameTag(_ id: TagID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let index = catalog.tags.firstIndex(where: { $0.id == id }) else { return }
    guard catalog.tags[index].name != trimmed else { return }
    catalog.tags[index].name = trimmed
    store.scheduleSave(catalog)
  }

  /// Recolors the Tag. Silent no-op for unknown ids and unchanged values.
  func recolorTag(_ id: TagID, to color: TagColor) {
    guard let index = catalog.tags.firstIndex(where: { $0.id == id }) else { return }
    guard catalog.tags[index].color != color else { return }
    catalog.tags[index].color = color
    store.scheduleSave(catalog)
  }

  /// Removes the Tag and cascades the removal: strips `id` from every
  /// `Project.tagIDs`, and normalizes `catalog.activeTagFilter` so the
  /// deleted id can never linger in the persisted filter
  /// (`.tags(set)` with the id dropped; if the set becomes empty the
  /// filter resets to `.all`). Non-destructive — Project data is not
  /// affected. Silent no-op for unknown ids; idempotent.
  func removeTag(_ id: TagID) {
    guard let index = catalog.tags.firstIndex(where: { $0.id == id }) else { return }
    catalog.tags.remove(at: index)
    for projectIndex in catalog.projects.indices {
      catalog.projects[projectIndex].tagIDs.remove(id)
    }
    if case .tags(var set) = catalog.activeTagFilter {
      set.remove(id)
      catalog.activeTagFilter = set.isEmpty ? .all : .tags(set)
    }
    store.scheduleSave(catalog)
  }

  /// Replaces the Project's tag membership with the given set. Silent no-op
  /// for unknown ids and unchanged values (no save scheduled).
  func setProjectTags(_ projectID: ProjectID, tags: Set<TagID>) {
    guard let index = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return }
    guard catalog.projects[index].tagIDs != tags else { return }
    catalog.projects[index].tagIDs = tags
    store.scheduleSave(catalog)
  }

  /// Replaces the catalog-wide active tag filter. Empty `.tags(set)` is
  /// normalized to `.all` so callers don't have to. Unchanged value is a
  /// silent no-op (no save scheduled).
  func setActiveTagFilter(_ filter: TagFilter) {
    let normalized: TagFilter
    if case .tags(let set) = filter, set.isEmpty {
      normalized = .all
    } else {
      normalized = filter
    }
    guard catalog.activeTagFilter != normalized else { return }
    catalog.activeTagFilter = normalized
    store.scheduleSave(catalog)
  }

  func setSidebarFilter(_ filter: SidebarFilter) {
    guard catalog.sidebarFilter != filter else { return }
    catalog.sidebarFilter = filter
    store.scheduleSave(catalog)
  }

  // MARK: - Project mutations

  /// Registers a local project. `isWorkspace` marks a workspace root: a plain
  /// folder of child checkouts — it never carries a `gitRoot`, and the
  /// synthetic row seeded below doubles as the workspace's main row (the
  /// folder agents run in). Child rows are appended by the workspace
  /// reconcile from the manifest, not here.
  func addProject(
    name: String, rootPath: String, gitRoot: String? = nil, isWorkspace: Bool = false
  ) -> ProjectID {
    let projectID = ProjectID()
    var worktrees: [Worktree] = []
    var selectedWorktreeID: WorktreeID?
    let gitRoot = isWorkspace ? nil : gitRoot

    if gitRoot == nil {
      let synthetic = Worktree(
        id: WorktreeID(),
        name: (rootPath as NSString).lastPathComponent,
        path: rootPath,
        branch: nil
      )
      worktrees = [synthetic]
      selectedWorktreeID = synthetic.id
    }

    // Manual-order auto-increment: new projects land at the end of the
    // manual list. `max + 1` works on a sparse field too — legacy zeros
    // simply get bumped past as users add new entries.
    let nextManualOrder = (catalog.projects.map(\.manualOrder).max() ?? -1) + 1
    let project = Project(
      id: projectID,
      name: name,
      rootPath: rootPath,
      gitRoot: gitRoot,
      worktrees: worktrees,
      selectedWorktreeID: selectedWorktreeID,
      addedAt: Date(),
      manualOrder: nextManualOrder,
      isWorkspace: isWorkspace
    )
    catalog.projects.append(project)
    store.scheduleSave(catalog)
    return projectID
  }

  /// Add a Server (remote SSH) project. Mirrors `addProject` but stamps
  /// `remoteHost` so the project is `.server`-kind, and `rootPath` / `gitRoot`
  /// hold **remote** path strings. When `gitRoot` is nil a synthetic worktree
  /// seeds the row (same as a local folder project) so the sidebar has
  /// something to show before the first SSH reconcile discovers the real
  /// worktrees. `rootPath` is stored verbatim — remote paths must never pass
  /// through the local symlink canonicalizer.
  func addServerProject(
    name: String,
    remoteHost: RemoteHost,
    rootPath: String,
    gitRoot: String? = nil
  ) -> ProjectID {
    let projectID = ProjectID()
    var worktrees: [Worktree] = []
    var selectedWorktreeID: WorktreeID?
    if gitRoot == nil {
      let synthetic = Worktree(
        id: WorktreeID(),
        name: (rootPath as NSString).lastPathComponent,
        path: rootPath,
        branch: nil
      )
      worktrees = [synthetic]
      selectedWorktreeID = synthetic.id
    }
    let nextManualOrder = (catalog.projects.map(\.manualOrder).max() ?? -1) + 1
    let project = Project(
      id: projectID,
      name: name,
      rootPath: rootPath,
      gitRoot: gitRoot,
      remoteHost: remoteHost,
      worktrees: worktrees,
      selectedWorktreeID: selectedWorktreeID,
      addedAt: Date(),
      manualOrder: nextManualOrder
    )
    catalog.projects.append(project)
    store.scheduleSave(catalog)
    return projectID
  }

  /// Apply an edited Server-project connection in place. Host-only changes
  /// (alias / user / port to the same machine) keep the worktree rows — their
  /// remote paths are still valid. A `rootPath` change re-points the project
  /// at a different remote directory, so every existing row's path is stale:
  /// tear down their surfaces and reseed (synthetic row for a folder, empty
  /// for a git root — the next reconcile discovers the real worktrees).
  func updateServerProject(
    projectID: ProjectID,
    remoteHost: RemoteHost,
    rootPath: String,
    gitRoot: String?
  ) {
    guard let index = catalog.projects.firstIndex(where: { $0.id == projectID }),
      catalog.projects[index].remoteHost != nil
    else { return }
    let pathChanged =
      Self.normalizeRemotePath(catalog.projects[index].rootPath)
      != Self.normalizeRemotePath(rootPath)
    catalog.projects[index].remoteHost = remoteHost
    catalog.projects[index].rootPath = rootPath
    catalog.projects[index].gitRoot = gitRoot
    if pathChanged {
      for worktree in catalog.projects[index].worktrees {
        tearDownWorktreeSurfaces(worktreeID: worktree.id)
      }
      if gitRoot == nil {
        let synthetic = Worktree(
          id: WorktreeID(),
          name: (rootPath as NSString).lastPathComponent,
          path: rootPath,
          branch: nil
        )
        catalog.projects[index].worktrees = [synthetic]
        catalog.projects[index].selectedWorktreeID = synthetic.id
      } else {
        catalog.projects[index].worktrees = []
        catalog.projects[index].selectedWorktreeID = nil
      }
    }
    store.scheduleSave(catalog)
  }

  // MARK: - Project sort mode (sidebar bottom bar)

  /// Replaces the catalog-wide `projectSortMode`. Unchanged values are
  /// silent no-ops. Switching modes never reorders `catalog.projects` —
  /// the array stays the manual order; non-manual modes derive their
  /// display order at render time.
  func setProjectSortMode(_ mode: ProjectSortMode) {
    guard catalog.projectSortMode != mode else { return }
    catalog.projectSortMode = mode
    store.scheduleSave(catalog)
  }

  /// Commit the result of the manual-sort sheet. Stamps each
  /// project's `manualOrder` to match its position in `orderedIDs`,
  /// rewrites `catalog.projects` in the same order so the on-disk
  /// array stays aligned with the field (cheap consistency for code
  /// that iterates `catalog.projects` directly), and flips
  /// `projectSortMode` to `.manual`. Unknown ids in the input are
  /// dropped; projects missing from the input keep their existing
  /// `manualOrder` and are appended at the end of the array so a
  /// partial / stale list can't lose data.
  func applyManualProjectOrder(_ orderedIDs: [ProjectID]) {
    guard !catalog.projects.isEmpty else {
      if catalog.projectSortMode != .manual {
        catalog.projectSortMode = .manual
        store.scheduleSave(catalog)
      }
      return
    }
    let byID = Dictionary(uniqueKeysWithValues: catalog.projects.map { ($0.id, $0) })
    var seen: Set<ProjectID> = []
    var rebuilt: [Project] = []
    rebuilt.reserveCapacity(catalog.projects.count)
    for id in orderedIDs {
      guard var project = byID[id], !seen.contains(id) else { continue }
      project.manualOrder = rebuilt.count
      rebuilt.append(project)
      seen.insert(id)
    }
    for project in catalog.projects where !seen.contains(project.id) {
      var copy = project
      copy.manualOrder = rebuilt.count
      rebuilt.append(copy)
    }
    catalog.projects = rebuilt
    catalog.projectSortMode = .manual
    store.scheduleSave(catalog)
  }

  /// Record an activity tick on a Project. Called by the notification
  /// pipeline (new inbox entry whose source resolves to this Project)
  /// and by the input pipeline (`TerminalInputSink.sendInput` resolves
  /// the pane → project). Monotonic — a stale `now` smaller than the
  /// stored timestamp is dropped so out-of-order callers can't rewind
  /// the sort order. Silent no-op for unknown ids.
  func bumpProjectActivity(_ projectID: ProjectID, now: Date = Date()) {
    guard let index = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return }
    if let existing = catalog.projects[index].lastActiveAt, existing >= now { return }
    catalog.projects[index].lastActiveAt = now
    store.scheduleSave(catalog)
  }

  /// Sets the Project's user-facing display name. Persists onto
  /// `Project.displayName`; the canonical name (derived from `rootPath`) is
  /// untouched and remains the worktree-path anchor. Empty / whitespace input
  /// or a value equal to the canonical name clears the override so the
  /// catalog never carries a redundant string that just mirrors the path.
  /// Missing project is `.notFound`; an unchanged value is a silent no-op
  /// (no catalog churn, no save).
  func renameProject(_ id: ProjectID, name: String) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonical = catalog.projects[projectIndex].canonicalName
    let newOverride: String? = (trimmed.isEmpty || trimmed == canonical) ? nil : trimmed
    guard catalog.projects[projectIndex].displayName != newOverride else { return }
    catalog.projects[projectIndex].displayName = newOverride
    store.scheduleSave(catalog)
  }

  /// Recolors the Project. `nil` clears the assignment so the UI falls back
  /// to the system accent. Unchanged value is a silent no-op so repeated
  /// taps on the same swatch don't churn the catalog or debounced save.
  func setProjectColor(_ id: ProjectID, color: ProjectColor?) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    guard catalog.projects[projectIndex].color != color else { return }
    catalog.projects[projectIndex].color = color
    store.scheduleSave(catalog)
  }

  /// Re-icons the Project. `nil` clears the assignment so the UI falls back
  /// to the built-in folder pair. Unchanged value is a silent no-op, matching
  /// `setProjectColor`.
  ///
  /// Replacing a custom icon deletes the file the old icon referenced —
  /// nothing else can reference it (import stamps a fresh UUID name per pick),
  /// so leaving it behind would accumulate dead artwork in the config
  /// directory for the lifetime of the install.
  func setProjectIcon(_ id: ProjectID, icon: ProjectIcon?) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    let previous = catalog.projects[projectIndex].icon
    guard previous != icon else { return }
    catalog.projects[projectIndex].icon = icon
    if let orphaned = previous?.customFileName {
      ProjectIconStore.removeIcon(named: orphaned)
    }
    store.scheduleSave(catalog)
  }

  /// Drops the runtime-only bookkeeping the manager keeps per Content (the
  /// process row). `closeTab` / `closePane` clear it inline, but they only
  /// run for teardown that emits `.paneExited`. The archive and
  /// project-removal paths use `suspendSurface`, which deliberately emits
  /// none, so without this the rows survive their Content.
  private func purgeRuntimeState(forContents contentIDs: [ContentID]) {
    for contentID in contentIDs {
      processRegistry.remove(contentID)
    }
  }

  /// Drops the Project from the catalog. The on-disk repository is never
  /// touched — this only unregisters it.
  ///
  /// Every Pane under the Project is torn down through
  /// `runtime.suspendSurface(for:)` first, for the same two reasons archive
  /// uses it (see `setWorktreeArchived`): surfaces are lazy, so a
  /// backgrounded Pane usually has no registered surface while its zmx
  /// daemon is still running, and `.paneExited` would route through
  /// `paneLifecycleExited → closePane` for Panes this call has already
  /// deleted wholesale. Archived Worktrees are included: their daemons were
  /// killed at archive time and a missing control socket is a silent no-op.
  ///
  /// Suspend emits no per-Pane lifecycle event, so the removal ends with
  /// `announceHierarchyMutated()` — that is what makes the AgentState
  /// reconcile run against the now-smaller catalog and retire the Project's
  /// agent rows, which would otherwise linger as em-dash ghosts (and be
  /// re-seeded from the quit snapshot on the next launch).
  func removeProject(_ id: ProjectID) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    let contentIDs = catalog.projects[projectIndex].worktrees.flatMap(\.contentIDs)
    for contentID in contentIDs {
      runtime.suspendSurface(for: contentID)
    }
    purgeRuntimeState(forContents: contentIDs)
    // The Project is the only referent of its custom icon file, so drop the
    // artwork with it rather than leaving it orphaned in the config directory.
    if let iconFileName = catalog.projects[projectIndex].icon?.customFileName {
      ProjectIconStore.removeIcon(named: iconFileName)
    }
    catalog.projects.remove(at: projectIndex)
    if catalog.selectedProjectID == id {
      catalog.selectedProjectID = nil
    }
    store.scheduleSave(catalog)
    runtime.announceHierarchyMutated()
    // After the catalog mutation, so a throwing removal cannot strip a live
    // Project's settings.
    onProjectRemoved?(id)
  }

  /// Set the user's currently-selected Project at the top level. Single-
  /// window simplification means there is exactly one such selection per
  /// app. `nil` clears the selection. Equal-value writes are dropped so
  /// repeated taps on the same Project don't churn the catalog or the
  /// debounced save pipeline. Unknown IDs are silently ignored — the
  /// selection-stream resolver clamps to a valid Project ID anyway.
  func selectProject(_ id: ProjectID?) {
    guard catalog.selectedProjectID != id else { return }
    if let id, !catalog.projects.contains(where: { $0.id == id }) {
      return
    }
    catalog.selectedProjectID = id
    store.scheduleSave(catalog)
  }

  /// Transient Project-level health state owned by `ProjectReconciler`. Never
  /// persisted (`Project.loadState` is a transient field); equal-value writes
  /// are dropped so repeated reconciliations don't churn the catalog graph.
  /// Throws `.directoryMissing` when `path` is not a local directory, so no
  /// Tab or Pane is created that cannot start. A missing project root also
  /// flags the Project failed: reconcile runs on focus changes only, so a
  /// root folder moved from inside a pane would otherwise stay "ready".
  /// Server projects always pass: their paths are remote.
  func requireLocalDirectory(_ path: String, in projectID: ProjectID) throws {
    let project = catalog.projects.first(where: { $0.id == projectID })
    guard project?.isRemote != true else { return }
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
      return
    }
    if let project, !FileManager.default.fileExists(atPath: project.rootPath) {
      setProjectLoadState(
        ProjectReconciler.missingFolderState(rootPath: project.rootPath), projectID: projectID)
    }
    throw HierarchyError.directoryMissing(path)
  }

  func setProjectLoadState(
    _ state: ProjectLoadState,
    projectID: ProjectID
  ) {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return }
    guard catalog.projects[projectIndex].loadState != state else { return }
    catalog.projects[projectIndex].loadState = state
    // No scheduleSave — transient.
  }

  /// Reorder Projects at the catalog top level. Mirrors SwiftUI
  /// `ForEach.onMove`'s `(IndexSet, Int)` signature so the sidebar can
  /// forward directly. Array's `move(fromOffsets:toOffset:)` already handles
  /// out-of-range destinations by trapping — callers must pass a valid
  /// index. Persists.
  func reorderProjects(
    from source: IndexSet,
    to destination: Int
  ) {
    guard !source.isEmpty else { return }
    catalog.projects.move(fromOffsets: source, toOffset: destination)
    // Inline drag is also a manual-ordering gesture; stamp
    // `manualOrder` to match the new array layout so the user-curated
    // sequence survives a switch to a non-manual mode and back.
    for index in catalog.projects.indices {
      catalog.projects[index].manualOrder = index
    }
    store.scheduleSave(catalog)
  }

  /// Resolves a canonical path to its registered `ProjectID` if any
  /// Project's `rootPath` canonicalizes to the same form. Caller canonicalizes
  /// its input via `HierarchyManager.canonicalPath(_:)` before querying.
  /// Linear in total Project count — acceptable at the low cardinality we
  /// support (Projects per user, not per repo).
  func isPathRegistered(canonical path: String) -> ProjectID? {
    for project in catalog.projects where Self.canonicalPath(project.rootPath) == path {
      return project.id
    }
    return nil
  }

  /// Resolves a canonical path to the `ProjectID` whose `rootPath`
  /// **contains** `path` — i.e. the path is the root itself or a descendant.
  /// Used by the `editor.open` IPC so `codans open` inside a subdirectory of a
  /// registered Project still honors the Project's `defaultEditor` override;
  /// `isPathRegistered` only matches the exact root.
  ///
  /// Matching is on path-segment boundaries: `/repo` matches `/repo` and
  /// `/repo/src/` but not `/repository`. When Projects nest (rare but legal —
  /// a monorepo Project with a sub-repo Project under it), the deepest match
  /// wins so the closest override is applied.
  ///
  /// Caller canonicalizes via `HierarchyManager.canonicalPath(_:)` before
  /// querying. Linear in total Project count like `isPathRegistered`.
  func project(containing path: String) -> ProjectID? {
    var best: (ProjectID, Int)?  // (project, root length)
    for project in catalog.projects {
      let root = Self.canonicalPath(project.rootPath)
      guard path == root || path.hasPrefix(root + "/") else { continue }
      if best == nil || root.count > best!.1 {
        best = (project.id, root.count)
      }
    }
    return best.map { $0.0 }
  }

  // MARK: - Worktree mutations

  func createWorktree(
    in projectID: ProjectID,
    name: String,
    path: String,
    branch: String?,
    reuseExisting: Bool = false
  ) throws -> WorktreeID {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }

    // Canonicalize at the single write boundary so every downstream
    // comparison (main-checkout guard, reconcile dedupe, selection
    // lookups) sees the same symlink-resolved form that
    // `Project.rootPath` already stores. Caller-side canonicalization
    // is easy to forget; doing it here means the API is self-correcting.
    let canonicalizedPath = Self.canonicalPath(path)

    // Uniqueness guard: without this, dispatcher retries on
    // tab/pane failure register a fresh row pointing at the same
    // (canonical path, name) every time, polluting `codans tree` with
    // orphan UUIDs. Compare canonical-form so symlinked paths
    // (/var/...  vs /private/var/...) collide as expected.
    let existingWorktrees = catalog.projects[projectIndex].worktrees
    let pathConflict = existingWorktrees.first { Self.canonicalPath($0.path) == canonicalizedPath }
    if let pathConflict {
      if reuseExisting {
        // Idempotent mode — caller is replaying create after a partial
        // failure downstream, or lost the race against a reconcile pulse
        // that adopted the freshly materialized worktree, and just wants
        // the existing id. Name / branch are NOT re-applied to avoid
        // silently rewriting fields the user may have customized through
        // the UI — except when the row's name still tracks its branch
        // (the reconcile-adoption signature): there the caller's name is
        // the user's original input and wins, provided no other row
        // already holds it.
        if pathConflict.name == pathConflict.branch, pathConflict.name != name,
          !existingWorktrees.contains(where: { $0.name == name }),
          let conflictIndex = catalog.projects[projectIndex].worktrees
            .firstIndex(where: { $0.id == pathConflict.id })
        {
          catalog.projects[projectIndex].worktrees[conflictIndex].name = name
          store.scheduleSave(catalog)
        }
        return pathConflict.id
      }
      throw HierarchyError.invariantViolation(
        "worktree with path \(canonicalizedPath) already exists (id=\(pathConflict.id))"
      )
    }
    if let nameConflict = existingWorktrees.first(where: { $0.name == name }) {
      throw HierarchyError.invariantViolation(
        "worktree named '\(name)' already exists in this project (id=\(nameConflict.id))"
      )
    }

    let worktreeID = WorktreeID()
    let worktree = Worktree(
      id: worktreeID,
      name: name,
      path: canonicalizedPath,
      branch: branch
    )
    // Insert at the top of the unpinned segment (after the last main/pinned row,
    // before the first unpinned row) so newly created worktrees are visible
    // without scrolling. Empty / main-only / all-pinned cases naturally fall to
    // the array tail because `unpinnedBoundary` returns `worktrees.count`.
    let boundary = Self.unpinnedBoundary(
      in: catalog.projects[projectIndex].worktrees,
      rootPath: catalog.projects[projectIndex].rootPath
    )
    catalog.projects[projectIndex].worktrees.insert(worktree, at: boundary)
    catalog.projects[projectIndex].selectedWorktreeID = worktreeID
    store.scheduleSave(catalog)
    return worktreeID
  }

  func removeWorktree(
    _ id: WorktreeID,
    from projectID: ProjectID
  ) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    guard
      let worktreeIndex = catalog.projects[projectIndex].worktrees.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Worktree \(id)")
    }

    let worktree = catalog.projects[projectIndex].worktrees[worktreeIndex]
    // The main checkout is the Project root itself: dropping its row would
    // leave a dir-kind or workspace Project with nothing to open, and the
    // git-backed caller's relocate-then-prune would move the project root
    // into the trash. The sidebar trims the menu item; this guard covers the
    // IPC / CLI path, which has no menu to trim.
    if worktree.path == catalog.projects[projectIndex].rootPath {
      throw HierarchyError.invariantViolation("Cannot remove main checkout")
    }
    for contentID in worktree.contentIDs {
      runtime.closeSurface(for: contentID)
    }
    purgeRuntimeState(forContents: worktree.contentIDs)

    catalog.projects[projectIndex].worktrees.remove(at: worktreeIndex)
    if catalog.projects[projectIndex].selectedWorktreeID == id {
      // Advance to the next visible (non-archived) worktree so the detail
      // pane doesn't get pinned to a row the user can't see. `first` was
      // already a fallback; the extra `!archived` filter matters when the
      // removed row sat above an archived sibling that would otherwise
      // become the new selection.
      catalog.projects[projectIndex].selectedWorktreeID =
        catalog.projects[projectIndex].worktrees.first { !$0.archived }?.id
    }
    store.scheduleSave(catalog)
    // `closeSurface` emits `.paneExited` only for Panes that had a live
    // surface, so a Worktree of never-opened Panes leaves the membership
    // reconcilers with no signal at all. Announce unconditionally.
    runtime.announceHierarchyMutated()
  }

  func selectWorktree(_ id: WorktreeID?, in projectID: ProjectID) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    catalog.projects[projectIndex].selectedWorktreeID = id
    store.scheduleSave(catalog)
  }

  /// Sets the archived flag on a Worktree (spec W-Q1, soft-hide). The
  /// main checkout (path == project.rootPath) cannot be archived and
  /// throws `.invariantViolation`. Archiving `true` iterates the
  /// Worktree's Panes and calls `runtime.suspendSurface(for:)` each so the
  /// pane daemons are killed (even backgrounded ones with no live surface)
  /// and surfaces torn down — without deleting the Panes, which soft-hide
  /// keeps in the catalog for restore; the on-disk directory and git refs
  /// are NOT touched. It then fires `announceHierarchyMutated()` so the
  /// AgentState reconcile retires the hidden worktree's agent rows.
  /// Idempotent: unchanged value is a silent no-op (no save scheduled).
  /// Silent no-op when the id is unknown.
  func setWorktreeArchived(worktreeID: WorktreeID, archived: Bool) throws {
    for projectIndex in catalog.projects.indices {
      let project = catalog.projects[projectIndex]
      guard let worktreeIndex = project.worktrees.firstIndex(where: { $0.id == worktreeID })
      else { continue }
      let worktree = project.worktrees[worktreeIndex]
      if worktree.path == project.rootPath {
        throw HierarchyError.invariantViolation("Cannot archive main checkout")
      }
      guard worktree.archived != archived else { return }
      if archived {
        for contentID in worktree.contentIDs {
          // `suspendSurface`, not `closeSurface`: kill each session's daemon
          // even when it has no live surface (lazy surfaces left a
          // backgrounded archived session's daemon running for days), and
          // emit no `.paneExited` so soft-hide keeps the Tab in the catalog.
          runtime.suspendSurface(for: contentID)
        }
        purgeRuntimeState(forContents: worktree.contentIDs)
      }
      catalog.projects[projectIndex].worktrees[worktreeIndex].archived = archived
      // Stamp the archive time so the Cleanup auto-delete sweep can age the
      // Worktree out; clear it on unarchive so a re-archive restarts the clock.
      catalog.projects[projectIndex].worktrees[worktreeIndex].archivedAt = archived ? Date() : nil
      // After flipping archived → true, the row vanishes from the sidebar but
      // the detail view is still bound to its WorktreeID. Advance the
      // project's selection to the next visible sibling so the detail pane
      // jumps to a real surface (or empties cleanly when no sibling remains).
      // Skip on unarchive — flipping archived → false should never disturb
      // the active selection.
      if archived,
        catalog.projects[projectIndex].selectedWorktreeID == worktreeID
      {
        catalog.projects[projectIndex].selectedWorktreeID =
          catalog.projects[projectIndex].worktrees.first {
            $0.id != worktreeID && !$0.archived
          }?.id
      }
      store.scheduleSave(catalog)
      // Archive emits no per-pane `.paneExited` (see `suspendSurface`), so
      // nudge a structural-mutation event to re-run the AgentState reconcile
      // against `visiblePaneIDs()` — that is what retires the now-hidden
      // worktree's agent rows. Unarchive announces too: nothing else tells
      // the GitHub poll its branch set grew, so the restored row would keep
      // painting the PR snapshot captured at archive time.
      runtime.announceHierarchyMutated()
      return
    }
  }

  /// Returns the IDs of archived Worktrees in `projectID` whose archive
  /// timestamp is older than `ttl` seconds — i.e. those due for the Cleanup
  /// auto-delete sweep. As a side effect, archived rows with no recorded
  /// timestamp (catalogs from before `archivedAt` existed) are back-filled
  /// with `now` and saved, so they age from first observation instead of
  /// being deleted retroactively. Pinned rows are skipped. The returned IDs
  /// are handed to `HierarchyClient` to perform the actual git removal.
  func archivedWorktreesDue(in projectID: ProjectID, now: Date, ttl: TimeInterval) -> [WorktreeID] {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return [] }
    var due: [WorktreeID] = []
    var didBackfill = false
    let snapshot = catalog.projects[projectIndex].worktrees
    for (index, worktree) in snapshot.enumerated() where worktree.archived && !worktree.isPinned {
      guard let archivedAt = worktree.archivedAt else {
        catalog.projects[projectIndex].worktrees[index].archivedAt = now
        didBackfill = true
        continue
      }
      if now.timeIntervalSince(archivedAt) >= ttl {
        due.append(worktree.id)
      }
    }
    if didBackfill { store.scheduleSave(catalog) }
    return due
  }

  /// Flips the Project's sidebar disclosure flag. Persists so the user's
  /// open / closed choice survives restart. Silent no-op for unchanged values
  /// and for unknown ids. Goes through the standard debounced save pipeline.
  func setProjectExpanded(projectID: ProjectID, isExpanded: Bool) {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return }
    guard catalog.projects[projectIndex].isExpanded != isExpanded else { return }
    catalog.projects[projectIndex].isExpanded = isExpanded
    store.scheduleSave(catalog)
  }

  /// Updates the Project's resolved git root. Called by the reconciler when a
  /// folder Project becomes a git repo (`git init` / `git clone` from the
  /// terminal) — flipping `gitRoot` from nil → discovered path lights up the
  /// "+ Add Worktree" affordance and unlocks the worktree reconcile path
  /// without an app relaunch. Silent no-op on unchanged values and unknown
  /// ids. Persists via the standard debounced save pipeline.
  func setProjectGitRoot(projectID: ProjectID, gitRoot: String?) {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return }
    guard catalog.projects[projectIndex].gitRoot != gitRoot else { return }
    catalog.projects[projectIndex].gitRoot = gitRoot
    store.scheduleSave(catalog)
  }

  /// Flips the Worktree's pinned flag and repositions the row in the catalog
  /// array so segment-internal order matches the sidebar. Pin moves the row to
  /// the end of the pinned segment (last visible pinned); Unpin moves it to
  /// the top of the unpinned segment (first visible unpinned). Silent no-op
  /// for unchanged values (no flag flip, no move, no save) and for unknown
  /// ids. Persists via the standard debounced save pipeline.
  func setWorktreePinned(worktreeID: WorktreeID, isPinned: Bool) {
    for projectIndex in catalog.projects.indices {
      let project = catalog.projects[projectIndex]
      guard let worktreeIndex = project.worktrees.firstIndex(where: { $0.id == worktreeID })
      else { continue }
      guard project.worktrees[worktreeIndex].isPinned != isPinned else { return }
      catalog.projects[projectIndex].worktrees[worktreeIndex].isPinned = isPinned
      // Recompute the boundary on the post-flip array so the destination
      // offset reflects the new flag. Pin → boundary lands the row right
      // after the last existing pinned row (it becomes the new last
      // pinned). Unpin → the just-flipped row itself is the first match
      // (or some earlier unpinned row is), and `move(toOffset:)` is a
      // no-op when the row already sits at the boundary, otherwise it
      // pulls the row up to the unpinned-segment top.
      let boundary = Self.unpinnedBoundary(
        in: catalog.projects[projectIndex].worktrees,
        rootPath: catalog.projects[projectIndex].rootPath
      )
      catalog.projects[projectIndex].worktrees
        .move(fromOffsets: IndexSet(integer: worktreeIndex), toOffset: boundary)
      store.scheduleSave(catalog)
      return
    }
  }

  /// Flips `Worktree.isNew` for the given Worktree. Silent no-op for unknown
  /// ids and unchanged values. Persists via the standard debounced save pipeline.
  func setWorktreeIsNew(worktreeID: WorktreeID, isNew: Bool) {
    for projectIndex in catalog.projects.indices {
      let project = catalog.projects[projectIndex]
      guard let worktreeIndex = project.worktrees.firstIndex(where: { $0.id == worktreeID })
      else { continue }
      guard project.worktrees[worktreeIndex].isNew != isNew else { return }
      catalog.projects[projectIndex].worktrees[worktreeIndex].isNew = isNew
      store.scheduleSave(catalog)
      return
    }
  }

  /// Reorder rows within a single sidebar segment under one Project. SwiftUI
  /// `.onMove` reports segment-relative `IndexSet` and target offset; this
  /// method translates those into a catalog-array mutation that preserves the
  /// catalog positions of rows in other segments (and of archived rows).
  ///
  /// Validation is all-or-nothing: if any `from` offset or `to` falls outside
  /// the current segment range, or `from` is empty, the call is a silent
  /// no-op (no save). A snapshot taken before a worktree was removed
  /// produces out-of-range offsets, and dropping the whole reorder is
  /// preferable to a partial application.
  /// Missing project throws `.notFound`.
  func reorderWorktrees(
    in projectID: ProjectID,
    segment: WorktreeSegment,
    from source: IndexSet,
    to destination: Int
  ) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    let project = catalog.projects[projectIndex]
    let rootPath = project.rootPath
    let inSegment: (Worktree) -> Bool = { w in
      guard !w.archived, w.path != rootPath else { return false }
      switch segment {
      case .pinned: return w.isPinned
      case .unpinned: return !w.isPinned
      }
    }
    let segmentCatalogIndices = project.worktrees.indices.filter { inSegment(project.worktrees[$0]) }
    let segmentCount = segmentCatalogIndices.count
    guard !source.isEmpty,
      source.allSatisfy({ $0 >= 0 && $0 < segmentCount }),
      destination >= 0, destination <= segmentCount
    else { return }
    var segmentRows = segmentCatalogIndices.map { project.worktrees[$0] }
    segmentRows.move(fromOffsets: source, toOffset: destination)
    for (k, catalogIdx) in segmentCatalogIndices.enumerated() {
      catalog.projects[projectIndex].worktrees[catalogIdx] = segmentRows[k]
    }
    store.scheduleSave(catalog)
  }

  /// Moves a worktree within its Project according to `mode`. The only mode
  /// for v1.1 is `.moveToFrontWithinUnpinned`, the catalog primitive behind
  /// the notifications-v1-1 worktree-promote behaviour: when a 0→N unread
  /// edge fires on an unpinned worktree, the coordinator drives it to
  /// position 0 of the unpinned section so the sidebar surfaces the freshly
  /// active row. Pinned worktrees are deliberately untouched — pinning is a
  /// stronger user signal than activity. Silent no-ops on unknown ids and on
  /// pinned targets. Persists via the standard debounced save pipeline.
  ///
  /// Implementation: split the project's `worktrees` into `pinned + unpinned`
  /// preserving each segment's relative order, then move the target to index
  /// 0 of `unpinned` and rejoin. This leaves the pinned segment's array
  /// positions untouched and keeps the catalog mutation linear.
  func promoteWorktree(
    in projectID: ProjectID,
    worktreeID: WorktreeID,
    mode: WorktreePromotionMode
  ) {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else {
      return
    }
    let project = catalog.projects[projectIndex]
    guard let target = project.worktrees.first(where: { $0.id == worktreeID }) else {
      return
    }
    // Pinned ordering is the user's explicit preference; never auto-mutate.
    guard !target.isPinned else { return }

    switch mode {
    case .moveToFrontWithinUnpinned:
      let pinned = project.worktrees.filter { $0.isPinned }
      var unpinned = project.worktrees.filter { !$0.isPinned }
      guard let unpinnedIndex = unpinned.firstIndex(where: { $0.id == worktreeID }) else {
        return
      }
      // Already at front of unpinned — nothing to do, no save scheduled.
      if unpinnedIndex == 0 { return }
      let row = unpinned.remove(at: unpinnedIndex)
      unpinned.insert(row, at: 0)
      catalog.projects[projectIndex].worktrees = pinned + unpinned
      store.scheduleSave(catalog)
    }
  }

  // MARK: - Content (session) fields

  /// Applies `body` to the terminal state of `contentID` and persists when
  /// `body` reports a change. Every session-field writer goes through here
  /// so the catalog walk and the unchanged-value guard (no save, no
  /// debounce churn for a repeated write) are spelled once. Returns
  /// `false` when the Content is unknown.
  @discardableResult
  private func mutateTerminalContent(
    _ contentID: ContentID,
    _ body: (inout TerminalContentState) -> Bool
  ) -> Bool {
    guard let changed = catalog.withTerminalContent(contentID, body) else { return false }
    if changed {
      store.scheduleSave(catalog)
    }
    return true
  }

  /// Writes `newPath` as the Content's working directory so a restart
  /// restores the session at the cwd the user last `cd`'d to rather than
  /// its creation-time cwd. Driven reactively by `PaneInfoDelta.pwd`
  /// (libghostty OSC 7) routed through `RootFeature.engineEvents`.
  /// Idempotent: equal-path writes and unknown ids skip `scheduleSave`, so
  /// idle cwd traffic never touches the catalog file.
  func updateWorkingDirectory(for contentID: ContentID, to newPath: String) {
    guard !newPath.isEmpty else { return }
    mutateTerminalContent(contentID) { state in
      guard state.workingDirectory != newPath else { return false }
      state.workingDirectory = newPath
      return true
    }
  }

  /// Toggles membership of `label` in the Content's labels. `present: true`
  /// inserts; `present: false` removes. Set semantics make repeated calls
  /// idempotent, and an unchanged set skips the save. Behind the content
  /// right-click "Mute notifications" toggle (`notifications:muted`): the
  /// notification detector consults the labels to drop muted candidates.
  func setContentLabel(_ contentID: ContentID, label: String, present: Bool) {
    mutateTerminalContent(contentID) { state in
      if present {
        return state.labels.insert(label).inserted
      }
      return state.labels.remove(label) != nil
    }
  }

  // MARK: - Content agent identity

  /// Writes the Content's `agentKind` (the classified CLI agent currently
  /// driving the session). `nil` clears the field. Silent no-op on an
  /// unknown id. Idempotent — a repeat call with the same value is a true
  /// no-op (no `scheduleSave`, no debounce churn). The single canonical
  /// writer for `agentKind`; the `AgentBinder` routes its classification
  /// output through here so all persistence flows through the standard
  /// `store.scheduleSave(catalog)` pipeline.
  func setAgentKind(_ contentID: ContentID, kind: AgentKind?) {
    mutateTerminalContent(contentID) { state in
      guard state.agentKind != kind else { return false }
      state.agentKind = kind
      return true
    }
  }

  /// Writes the Content's `agentSessionID` (agent-supplied session
  /// identifier). `nil` clears the field. Silent no-op on an unknown id.
  /// Idempotent — repeat calls with the same value skip the save. Single
  /// canonical writer; consumed by `AgentBinder` alongside `setAgentKind`.
  func setAgentSessionID(_ contentID: ContentID, sessionID: String?) {
    mutateTerminalContent(contentID) { state in
      guard state.agentSessionID != sessionID else { return false }
      state.agentSessionID = sessionID
      return true
    }
  }
  /// Merges worktrees discovered on disk (typically from
  /// `wt ls --json`) into the catalog. Path-canonicalized dedupe
  /// against existing rows — both sides go through
  /// `URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`
  /// so `/var/...` vs. `/private/var/...` don't cause duplicate rows
  /// against the `Project.rootPath`, which is stored in the
  /// symlink-resolved form. Never removes or mutates existing rows —
  /// stale rows are surfaced in the view layer and only deleted by the
  /// user-initiated Prune action. Idempotent across repeated calls
  /// with the same entries. Returns the count of appended rows so the
  /// caller can surface a toast.
  ///
  /// - Parameters:
  ///   - projectID: target Project.
  ///   - entries: on-disk worktree metadata (path, branch, HEAD SHA) from
  ///     `GitWorktreeClient.lsWorktrees`. `head` carries the full commit SHA
  /// so detached entries (`branch == nil`) render as
  /// "Detached HEAD @<short>" instead of collapsing onto the directory
  /// basename (five Codex sandboxes under `~/.codex/worktrees/*/codans`
  /// would otherwise be indistinguishable).
  ///   - normalizePath: canonicalization applied to every path before dedupe.
  ///     Defaults to the local symlink-resolving `canonicalPath`; Server
  ///     (remote) projects pass `normalizeRemotePath` so a remote path is never
  ///     resolved against the *local* filesystem (which would mangle e.g. a
  ///     remote `/tmp/...` into `/private/tmp/...`).
  @discardableResult
  func reconcileDiscoveredWorktrees(
    projectID: ProjectID,
    entries: [(path: String, branch: String?, head: String?)],
    normalizePath: (String) -> String = { HierarchyManager.canonicalPath($0) }
  ) -> Int {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID })
    else { return 0 }
    let project = catalog.projects[projectIndex]
    let discoveredPaths = Set(entries.map { normalizePath($0.path) })
    let rootCanonical = normalizePath(project.rootPath)
    var appended = 0
    var upgraded = 0
    for entry in entries {
      let canonical = normalizePath(entry.path)
      let entryBranch = (entry.branch?.isEmpty == false) ? entry.branch : nil
      let entryHead = (entry.head?.isEmpty == false) ? entry.head : nil
      if let existingIdx = catalog.projects[projectIndex].worktrees
        .firstIndex(where: { normalizePath($0.path) == canonical })
      {
        // Path already in the catalog. Three cases land here:
        //
        // 1. Synthetic placeholder upgrade — `addProject(gitRoot: nil)`
        //    seeded a row with `branch == nil` and `name == lastPathComponent`;
        //    once the directory becomes a git repo, adopt the real branch
        //    so the sidebar reads "main" instead of the folder name.
        // 2. In-place branch change — user ran `git checkout` /
        //    `git switch` inside the worktree pane. The row's `branch`
        //    must follow HEAD so the sidebar subtitle, WorktreeHeader
        //    label, and GitHubFeature's PR fetch all see the new value.
        // 3. Unchanged — no-op.
        //
        // Tabs, panes, pin/archive flags, and the row id are preserved
        // in every case because we mutate in place. `name` is only
        // re-synced when it was tracking the previous branch — user-
        // customized display names (e.g. "feat/web-ui" alongside the
        // sanitized git branch "feat-web-ui", set via `createWorktreeWithGit`)
        // are kept intact.
        let existing = catalog.projects[projectIndex].worktrees[existingIdx]
        if existing.branch != entryBranch || existing.headSHA != entryHead {
          catalog.projects[projectIndex].worktrees[existingIdx].branch = entryBranch
          if let newBranch = entryBranch, existing.name == existing.branch || existing.branch == nil {
            catalog.projects[projectIndex].worktrees[existingIdx].name = newBranch
          }
          // HEAD SHA syncs independently of the branch: a detached worktree
          // whose HEAD moved between reconciles (Codex sandbox committing
          // onto its base) must re-render with the new SHA even though
          // `branch` stayed nil on both sides.
          catalog.projects[projectIndex].worktrees[existingIdx].headSHA = entryHead
          upgraded += 1
        }
        continue
      }
      let name = entryBranch ?? (canonical as NSString).lastPathComponent
      let worktree = Worktree(
        id: WorktreeID(),
        name: name,
        path: canonical,
        branch: entryBranch,
        headSHA: entryHead
      )
      catalog.projects[projectIndex].worktrees.append(worktree)
      appended += 1
    }
    // An EMPTY discovery set never means "every worktree was deleted".
    // `git worktree list` on a healthy repo always reports at least the main
    // checkout, so zero entries can only mean discovery itself failed — and
    // that failure is not always visible as a thrown error. The bundled
    // `wt ls --json` reads `git worktree list --porcelain` through a process
    // substitution, whose exit status is invisible to `set -euo pipefail`, so
    // a git that dies under disk pressure yields `[]` on stdout and exit 0.
    // The caller sees a successful, well-formed, empty response.
    //
    // On 2026-08-25 that combination soft-archived every non-pinned worktree
    // across four projects while the directories were all still on disk. `wt`
    // is a third-party submodule, so the invariant has to be enforced here:
    // treat an empty set as append-only and leave the sweep for a pass whose
    // discovery we can believe.
    guard !entries.isEmpty else {
      reconcileLogger.error(
        "empty discovery set — skipping stale sweep: project=\(projectID.raw.uuidString, privacy: .public) catalogRows=\(project.worktrees.count, privacy: .public)"
      )
      return appended
    }
    // Bidirectional sync: rows whose canonical path is no longer in the
    // discovered set are stale (the worktree was deleted via `git worktree
    // remove` or `git worktree prune` outside the app). Soft-archive them
    // so they vanish from the sidebar but the user can still inspect or
    // restore via the Archived menu. Skip the main checkout (cannot be
    // archived per setWorktreeArchived's invariant) and pinned rows
    // (preserve user intent — `openPane` still guards the click path).
    var archivedCount = 0
    let snapshot = catalog.projects[projectIndex].worktrees
    for worktree in snapshot {
      let canonical = normalizePath(worktree.path)
      guard
        !discoveredPaths.contains(canonical),
        canonical != rootCanonical,
        !worktree.isPinned,
        !worktree.archived
      else { continue }
      // Archive semantics, so `suspendSurface` — the same call
      // `setWorktreeArchived` makes, for the same two reasons. `closeSurface`
      // was wrong here twice over: it left a never-opened Pane's daemon
      // running, and for a Pane that DID have a surface its `.paneExited`
      // routed through `paneLifecycleExited` into `closeTab` / `closePane`,
      // deleting the very rows soft-hide keeps in the catalog for restore.
      for contentID in worktree.contentIDs {
        runtime.suspendSurface(for: contentID)
      }
      purgeRuntimeState(forContents: worktree.contentIDs)
      if let idx = catalog.projects[projectIndex].worktrees.firstIndex(where: { $0.id == worktree.id }) {
        catalog.projects[projectIndex].worktrees[idx].archived = true
        // Stamp the archive time for the Cleanup auto-delete sweep (the loop
        // guard above only reaches not-yet-archived rows, so this never
        // overwrites an earlier timestamp).
        catalog.projects[projectIndex].worktrees[idx].archivedAt = Date()
        archivedCount += 1
      }
    }
    if archivedCount > 0 {
      // Auto-archive is the one reconcile outcome the user did not ask for,
      // and it is silent in the UI (rows just vanish). Leave a breadcrumb so
      // a future "where did my worktrees go?" is answerable from the log
      // instead of archaeology on `archivedAt` timestamps in catalog.json.
      reconcileLogger.notice(
        "auto-archived \(archivedCount, privacy: .public) stale worktree(s): project=\(projectID.raw.uuidString, privacy: .public) discovered=\(entries.count, privacy: .public)"
      )
    }
    if appended > 0 || upgraded > 0 || archivedCount > 0 {
      store.scheduleSave(catalog)
    }
    // Soft-hide emits no per-Pane lifecycle event, so without this the
    // membership reconcilers never learn the rows went away — same reason
    // `setWorktreeArchived` announces. This path archives without the user
    // asking, which makes a lingering ghost row especially confusing.
    if archivedCount > 0 {
      runtime.announceHierarchyMutated()
    }
    return appended
  }

  // MARK: - Workspace

  /// What the workspace reconcile observed for one manifest entry.
  struct WorkspaceChildObservation: Equatable, Sendable {
    /// Manifest entry name — the row's display name.
    let name: String
    /// Canonical absolute path of the child folder.
    let path: String
    /// Whether the folder exists on disk.
    let exists: Bool
    /// Live branch from git; nil when detached, missing, or not a repo.
    let branch: String?
    /// Root of the repository the checkout belongs to, from git.
    let sourceGitRoot: String?
  }

  /// Transient decoded manifest for display. Never persisted, equal-value
  /// writes dropped — same contract as `setProjectLoadState`.
  func setProjectWorkspaceManifest(projectID: ProjectID, manifest: WorkspaceManifest?) {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else { return }
    guard catalog.projects[projectIndex].workspace != manifest else { return }
    catalog.projects[projectIndex].workspace = manifest
  }

  /// Workspace counterpart of `reconcileDiscoveredWorktrees`. The manifest,
  /// not `git worktree list`, is the membership source: every observation is
  /// one manifest entry, resolved and probed on disk by the caller.
  ///
  /// - An observed folder with no row: append a child row (name = entry
  ///   name, branch / sourceGitRoot from git).
  /// - An observed folder with a row: refresh `branch` and `sourceGitRoot`
  ///   in place. The name is never re-synced — it tracks the folder, not the
  ///   branch — so tabs, panes, and flags survive as they do for worktrees.
  /// - A missing folder with a live row: soft-archive it, exactly as the
  ///   stale sweep does for a worktree removed outside the app. The
  ///   manifest entry is left alone; only an explicit removal edits it.
  /// - A row no observation names (an entry the user deleted from the
  ///   manifest by hand): left untouched and logged. Reconcile never deletes.
  ///
  /// The root row is never touched, and an empty observation set — a
  /// manifest that names nothing — never archives anything, mirroring the
  /// empty-discovery guard on the git path.
  @discardableResult
  func reconcileWorkspaceChildren(
    projectID: ProjectID,
    observations: [WorkspaceChildObservation]
  ) -> (appended: Int, updated: Int, archived: Int) {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }),
      catalog.projects[projectIndex].isWorkspace
    else { return (0, 0, 0) }
    let rootCanonical = Self.canonicalPath(catalog.projects[projectIndex].rootPath)
    var appended = 0
    var updated = 0
    var archived = 0
    var observedPaths = Set<String>()
    for observation in observations {
      let canonical = Self.canonicalPath(observation.path)
      guard canonical != rootCanonical else { continue }
      observedPaths.insert(canonical)
      let existingIndex = catalog.projects[projectIndex].worktrees
        .firstIndex { Self.canonicalPath($0.path) == canonical }
      if let existingIndex {
        let existing = catalog.projects[projectIndex].worktrees[existingIndex]
        if observation.exists {
          if existing.branch != observation.branch {
            catalog.projects[projectIndex].worktrees[existingIndex].branch = observation.branch
            updated += 1
          }
          if let sourceGitRoot = observation.sourceGitRoot,
            existing.sourceGitRoot != sourceGitRoot
          {
            catalog.projects[projectIndex].worktrees[existingIndex].sourceGitRoot = sourceGitRoot
            updated += 1
          }
        } else if !existing.archived, !existing.isPinned {
          for contentID in existing.contentIDs {
            runtime.suspendSurface(for: contentID)
          }
          purgeRuntimeState(forContents: existing.contentIDs)
          catalog.projects[projectIndex].worktrees[existingIndex].archived = true
          catalog.projects[projectIndex].worktrees[existingIndex].archivedAt = Date()
          archived += 1
        }
        continue
      }
      guard observation.exists else { continue }
      catalog.projects[projectIndex].worktrees.append(
        Worktree(
          id: WorktreeID(),
          name: observation.name,
          path: canonical,
          branch: observation.branch,
                    sourceGitRoot: observation.sourceGitRoot
        )
      )
      appended += 1
    }
    let unmanaged = catalog.projects[projectIndex].worktrees.filter {
      let canonical = Self.canonicalPath($0.path)
      return canonical != rootCanonical && !observedPaths.contains(canonical)
    }
    if !unmanaged.isEmpty {
      reconcileLogger.notice(
        "workspace has \(unmanaged.count, privacy: .public) row(s) the manifest no longer names; left as-is: project=\(projectID.raw.uuidString, privacy: .public)"
      )
    }
    if archived > 0 {
      reconcileLogger.notice(
        "auto-archived \(archived, privacy: .public) workspace child(ren) whose folder is gone: project=\(projectID.raw.uuidString, privacy: .public)"
      )
    }
    if appended > 0 || updated > 0 || archived > 0 {
      store.scheduleSave(catalog)
    }
    if archived > 0 {
      runtime.announceHierarchyMutated()
    }
    return (appended, updated, archived)
  }

  private func refreshWorkspaceMemberships() {
    workspaceMembershipIndex.update(catalog: catalog, canonicalize: Self.canonicalPath)
    let memberships = workspaceMembershipIndex.memberships
    if workspaceMemberships != memberships { workspaceMemberships = memberships }
  }

  /// The workspace child row at `path`, if any Project's child checkout lives
  /// there. Resolves live filesystem aliases for command guards. Views use
  /// `workspaceMemberships`, refreshed when catalog identity or paths change.
  func workspaceMembership(forPath path: String) -> WorkspaceMembership? {
    catalog.workspaceMembership(
      forCanonicalPath: Self.canonicalPath(path),
      canonicalize: Self.canonicalPath
    )
  }

  /// **Single** canonical form used across the hierarchy layer:
  /// - reconcile dedupe (`reconcileDiscoveredWorktrees`),
  /// - duplicate-path join (`isPathRegistered`),
  /// - catalog storage for `Project.rootPath` and `Worktree.path`.
  ///
  /// Resolves symlinks first, then standardizes (strips trailing
  /// slashes and `.` / `..` components). On macOS, symlink resolution
  /// maps `/var/...` to `/private/var/...` (and similar for `/tmp`,
  /// `/etc`); without this step a `wt ls --json` entry reported as
  /// `/var/folders/...` would fail to match a `Project.rootPath`
  /// stored as `/private/var/folders/...` and the main checkout would
  /// duplicate on every reconcile.
  ///
  /// **Regression guard**: do NOT add a second equivalent helper on
  /// this type. Two static methods (`canonical` + `canonicalPath`) once
  /// coexisted with identical bodies;
  /// any drift (e.g. one side adding trimming) would silently break
  /// the symmetry the PR body guarantees. Route all call-sites
  /// through this function.
  nonisolated static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
  }

  /// String-only canonicalization for **remote** (Server-project) paths. Unlike
  /// `canonicalPath`, it never touches the local filesystem — `git rev-parse
  /// --show-toplevel` and `git worktree list --porcelain` already emit absolute
  /// canonical paths on the host, so the only normalization needed is trimming
  /// a trailing slash (except for the root `/`) so the same worktree reported
  /// with and without one dedupes to a single catalog row. Routing a remote
  /// path through `canonicalPath` would resolve it against *this* machine's
  /// symlink table (`/tmp` → `/private/tmp`, etc.), corrupting the identity.
  nonisolated static func normalizeRemotePath(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    return trimmed
  }

  /// The SSH host owning `path`, or `nil` for a local path. Backs the
  /// `GitService` transport seam: a path that matches a Server project's
  /// rootPath / gitRoot / any worktree path (exact match after string-only
  /// normalization — remote paths never go through the local symlink
  /// resolver) routes that git invocation over SSH. Every `GitService`
  /// consumer — the sidebar diff chip, the PR badge's remote-URL probe, the
  /// branch switcher, the diff inspector — receives worktree-level paths, so
  /// exact matching is sufficient; subpaths inside a worktree are not
  /// resolved (none of those callers pass one today).
  func remoteHost(forPath path: String) -> RemoteHost? {
    let normalized = Self.normalizeRemotePath(path)
    for project in catalog.projects {
      guard let host = project.remoteHost else { continue }
      if Self.normalizeRemotePath(project.rootPath) == normalized { return host }
      if let gitRoot = project.gitRoot, Self.normalizeRemotePath(gitRoot) == normalized {
        return host
      }
      if project.worktrees.contains(where: { Self.normalizeRemotePath($0.path) == normalized }) {
        return host
      }
    }
    return nil
  }

  /// Relabels a worktree in the sidebar. The name is display-only (the
  /// path and branch stay), so this is a plain catalog write. Unchanged
  /// value is a silent no-op.
  func renameWorktree(_ id: WorktreeID, in projectID: ProjectID, name: String) throws {
    guard let (projectIndex, worktreeIndex) = findWorktreeIndices(worktreeID: id, projectID: projectID) else {
      throw HierarchyError.notFound("Worktree \(id)")
    }
    guard catalog.projects[projectIndex].worktrees[worktreeIndex].name != name else { return }
    catalog.projects[projectIndex].worktrees[worktreeIndex].name = name
    store.scheduleSave(catalog)
  }

  /// Tears down every terminal surface attached to the Worktree without
  /// mutating the catalog. Used by force-remove so any held file handles
  /// are released before `git worktree remove --force` runs; the catalog
  /// row is dropped afterwards via `removeWorktree`. Silent no-op when
  /// the id is unknown. Idempotent.
  func tearDownWorktreeSurfaces(worktreeID: WorktreeID) {
    for project in catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { continue }
      for contentID in worktree.contentIDs {
        runtime.closeSurface(for: contentID)
        processRegistry.remove(contentID)
      }
      return
    }
  }

  /// Counts the Contents in this Worktree whose terminal surface is live.
  /// Used by force-remove to size the confirmation copy ("This will
  /// terminate N running processes"). 0 when the id is unknown.
  func runningContentCount(worktreeID: WorktreeID) -> Int {
    for project in catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { continue }
      return worktree.contentIDs.filter { runtime.hasSurface(for: $0) }.count
    }
    return 0
  }

  // MARK: - Layout addressing

  /// `(projectIndex, worktreeIndex)` of the Worktree hosting `paneID`.
  private func worktreeIndices(forPane paneID: PaneID) -> (Int, Int)? {
    guard let address = catalog.address(forPane: paneID) else { return nil }
    return findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
  }

  private func worktreeIndices(forTab tabID: TabID) -> (Int, Int)? {
    guard let address = catalog.address(forTab: tabID) else { return nil }
    return findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
  }

  /// Runs `body` on a copy of the Worktree, checks the layout invariants
  /// on the result, and only then writes it back and persists. A body that
  /// would leave the Worktree inconsistent never reaches the catalog.
  private func mutateLayout(
    at indices: (Int, Int),
    _ body: (inout Worktree) throws -> Void
  ) throws {
    var worktree = catalog.projects[indices.0].worktrees[indices.1]
    try body(&worktree)
    do {
      try worktree.validateInvariants()
    } catch {
      throw HierarchyError.invariantViolation("layout invariant broken: \(error)")
    }
    catalog.projects[indices.0].worktrees[indices.1] = worktree
    store.scheduleSave(catalog)
  }

  /// Applies `body` to the Tab and persists when it reports a change.
  @discardableResult
  private func mutateTab(_ tabID: TabID, _ body: (inout Tab) -> Bool) throws -> Bool {
    guard let address = catalog.address(forTab: tabID),
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: address.worktreeID, projectID: address.projectID),
      let paneIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].panes.firstIndex(where: {
        $0.id == address.paneID
      }),
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs.firstIndex(
        where: { $0.id == tabID })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    let changed = body(&catalog.projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs[tabIndex])
    if changed {
      store.scheduleSave(catalog)
    }
    return changed
  }

  /// The Content currently shown and focused in the Worktree: the focused
  /// Pane's selected Tab. `nil` for a Worktree without Panes.
  func focusedContent(in worktreeID: WorktreeID) -> TabAddress? {
    guard case (let project, let worktree)? = catalog.worktree(worktreeID),
      let pane = worktree.focusedPane, let tab = pane.selectedTab
    else { return nil }
    return TabAddress(
      projectID: project.id, worktreeID: worktree.id, paneID: pane.id, tabID: tab.id, contentID: tab.content.id)
  }

  // MARK: - Tab verbs

  /// Opens a new Tab holding `content`. `paneID == nil` targets the
  /// focused Pane; a Worktree with no Panes gets its first Pane (which
  /// becomes focused). `select` makes the Tab the Pane's selected one and
  /// focuses the Pane; `false` appends it quietly, so a background script
  /// runs in the strip while the user stays put — except for the first
  /// Tab of a fresh Pane, which is always selected.
  ///
  /// Catalog-only: the surface comes up through `ensureSurface(for:env:)`
  /// so a caller mutating the catalog from a synchronous reducer body can
  /// observe the Tab before any bring-up is in flight.
  @discardableResult
  func newTab(
    in paneID: PaneID?,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    content: ContentSnapshot,
    name: String? = nil,
    initialTitle: String? = nil,
    select: Bool = true
  ) throws -> TabAddress {
    guard let indices = findWorktreeIndices(worktreeID: worktreeID, projectID: projectID) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    // `initialTitle` seeds the cached title, not `name`: `name` is the
    // sticky manual rename, and a command-spawned Tab must keep following
    // the live title its session reports.
    let tab = Tab(name: name, cachedDisplayTitle: initialTitle, content: content)
    var hostPaneID = paneID
    try mutateLayout(at: indices) { worktree in
      if let paneID {
        guard worktree.pane(paneID) != nil else { throw HierarchyError.notFound("Pane \(paneID)") }
      } else {
        hostPaneID = worktree.focusedPaneID ?? worktree.panes.first?.id
      }
      guard let targetID = hostPaneID,
        let paneIndex = worktree.panes.firstIndex(where: { $0.id == targetID })
      else {
        let pane = Pane(tabs: [tab])
        worktree.splitTree = SplitTree(leaf: pane.id)
        worktree.panes = [pane]
        worktree.focusedPaneID = pane.id
        hostPaneID = pane.id
        return
      }
      worktree.panes[paneIndex].tabs.append(tab)
      if select {
        worktree.panes[paneIndex].selectedTabID = tab.id
        worktree.focusedPaneID = targetID
      }
    }
    guard let hostPaneID else { throw HierarchyError.invariantViolation("new Tab has no Pane") }
    return TabAddress(
      projectID: projectID, worktreeID: worktreeID, paneID: hostPaneID, tabID: tab.id, contentID: content.id)
  }

  /// Closes the Tab and its Content. The last Tab of a Pane closes the
  /// Pane with its split-tree leaf; focus then moves to the neighbour
  /// `SplitTree.focusTargetAfterClosing` names. Closing the selected Tab
  /// of a surviving Pane selects the right neighbour, else the new last
  /// Tab (the platform convention).
  func closeTab(_ tabID: TabID) throws {
    guard let address = catalog.address(forTab: tabID),
      let indices = findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    runtime.closeSurface(for: address.contentID)
    processRegistry.remove(address.contentID)
    var focusTarget: ContentID?
    try mutateLayout(at: indices) { worktree in
      guard let paneIndex = worktree.panes.firstIndex(where: { $0.id == address.paneID }),
        let tabIndex = worktree.panes[paneIndex].tabs.firstIndex(where: { $0.id == tabID })
      else { throw HierarchyError.notFound("Tab \(tabID)") }
      worktree.panes[paneIndex].tabs.remove(at: tabIndex)
      if worktree.panes[paneIndex].tabs.isEmpty {
        focusTarget = Self.removePane(address.paneID, from: &worktree)
      } else if worktree.panes[paneIndex].selectedTabID == tabID {
        let remaining = worktree.panes[paneIndex].tabs
        let next = tabIndex < remaining.count ? remaining[tabIndex] : remaining[remaining.count - 1]
        worktree.panes[paneIndex].selectedTabID = next.id
        if worktree.focusedPaneID == address.paneID {
          focusTarget = next.content.id
        }
      }
    }
    // Transfer AppKit first-responder focus to the surface that took the
    // closed one's place. Without this the closed surface's responder slot
    // stays empty and the next ⌘W bypasses Ghostty's `performKeyEquivalent`,
    // falling through to the menu where the system Close Window shadows
    // our binding and shuts the window.
    if let focusTarget {
      runtime.focusSurfaceView(for: focusTarget)
    }
  }

  /// Drops the Pane and its leaf. Moves the focus to the neighbour when
  /// the Pane was focused, clears a zoom on it. Returns the Content to
  /// hand keyboard focus to, when the focus moved.
  private static func removePane(_ paneID: PaneID, from worktree: inout Worktree) -> ContentID? {
    let neighbour = worktree.splitTree.focusTargetAfterClosing(paneID)
    worktree.splitTree = worktree.splitTree.removing(paneID)
    worktree.panes.removeAll { $0.id == paneID }
    if worktree.panes.isEmpty {
      worktree.splitTree = SplitTree()
      worktree.focusedPaneID = nil
      return nil
    }
    let focusMoves = worktree.focusedPaneID == paneID || worktree.focusedPane == nil
    guard focusMoves else { return nil }
    let target = neighbour.flatMap { worktree.pane($0) } ?? worktree.panes[0]
    worktree.focusedPaneID = target.id
    return target.selectedTab?.content.id
  }

  /// Selects the Tab in its Pane and focuses that Pane — a click on a
  /// chip means "show this and type here". Idempotent on the catalog;
  /// the surface is asked for first-responder either way so a click on
  /// the already-selected chip still brings input back to it.
  func selectTab(_ tabID: TabID) throws {
    guard let address = catalog.address(forTab: tabID),
      let indices = findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID),
      let paneIndex = catalog.projects[indices.0].worktrees[indices.1].panes.firstIndex(where: {
        $0.id == address.paneID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    let worktree = catalog.projects[indices.0].worktrees[indices.1]
    if worktree.panes[paneIndex].selectedTabID != tabID || worktree.focusedPaneID != address.paneID {
      catalog.projects[indices.0].worktrees[indices.1].panes[paneIndex].selectedTabID = tabID
      catalog.projects[indices.0].worktrees[indices.1].focusedPaneID = address.paneID
      store.scheduleSave(catalog)
    }
    runtime.focusSurfaceView(for: address.contentID)
  }

  /// Selects the Tab at `index` (zero-based) in the Pane's strip. Out of
  /// range is a silent no-op returning `nil`, matching the ⌘1…⌘9 chords.
  @discardableResult
  func selectTab(at index: Int, in paneID: PaneID) throws -> TabID? {
    guard let pane = catalog.pane(paneID) else { throw HierarchyError.notFound("Pane \(paneID)") }
    guard pane.tabs.indices.contains(index) else { return nil }
    let tabID = pane.tabs[index].id
    try selectTab(tabID)
    return tabID
  }

  /// Selects the Tab before / after the Pane's selection, wrapping at the
  /// ends. Returns the newly selected id.
  @discardableResult
  func selectAdjacentTab(direction: TabAdjacency, in paneID: PaneID) throws -> TabID? {
    guard let pane = catalog.pane(paneID) else { throw HierarchyError.notFound("Pane \(paneID)") }
    guard !pane.tabs.isEmpty else { return nil }
    let currentIndex = pane.selectedTabID.flatMap { id in pane.tabs.firstIndex { $0.id == id } } ?? 0
    let count = pane.tabs.count
    let newIndex: Int
    switch direction {
    case .previous:
      newIndex = (currentIndex - 1 + count) % count
    case .next:
      newIndex = (currentIndex + 1) % count
    }
    let newID = pane.tabs[newIndex].id
    try selectTab(newID)
    return newID
  }

  /// Renames a Tab in place. `nil` clears the custom name so the UI falls
  /// back to the live title. Unchanged value is a silent no-op.
  func renameTab(_ tabID: TabID, name: String?) throws {
    try mutateTab(tabID) { tab in
      guard tab.name != name else { return false }
      tab.name = name
      return true
    }
  }

  func setTabColor(_ tabID: TabID, color: TabColor?) throws {
    try mutateTab(tabID) { tab in
      guard tab.color != color else { return false }
      tab.color = color
      return true
    }
  }

  /// Update the Tab's icon, subject to the lock precedence in
  /// `TabIconLock` (`.auto` ≤ `.script` ≤ `.user`). A lower-priority write
  /// against a higher lock is a silent no-op; a `.user` write with `nil`
  /// drops the lock back to `.auto` so the runtime fallback takes over.
  func setTabIcon(_ tabID: TabID, icon: String?, lock: TabIconLock) throws {
    try mutateTab(tabID) { tab in
      guard let updated = tab.applyingIcon(icon, lock: lock), updated != tab else { return false }
      tab = updated
      return true
    }
  }

  /// Persists the most recently resolved live title so the chip can fall
  /// back to it on the next launch (before the surface respawns and the
  /// shell re-pushes OSC titles). No-op when unchanged so a hot OSC stream
  /// does not churn the catalog. Failures to locate the Tab are silent —
  /// the cache is best-effort, never load-bearing.
  func setCachedTabTitle(_ title: String?, for tabID: TabID) {
    _ = try? mutateTab(tabID) { tab in
      guard tab.cachedDisplayTitle != title else { return false }
      tab.cachedDisplayTitle = title
      return true
    }
  }

  /// Replaces the Pane's Tab ordering in a single write. The incoming id
  /// set must match the current set exactly — a mismatch throws
  /// `.invariantViolation` so upstream drag bugs surface immediately
  /// instead of silently discarding Tabs. Same-order input is a no-op.
  func reorderTabs(in paneID: PaneID, orderedIDs: [TabID]) throws {
    guard let indices = worktreeIndices(forPane: paneID) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    var changed = false
    try mutateLayout(at: indices) { worktree in
      guard let paneIndex = worktree.panes.firstIndex(where: { $0.id == paneID }) else {
        throw HierarchyError.notFound("Pane \(paneID)")
      }
      let existing = worktree.panes[paneIndex].tabs
      let currentIDs = existing.map(\.id)
      guard Set(currentIDs) == Set(orderedIDs), currentIDs.count == orderedIDs.count else {
        throw HierarchyError.invariantViolation("tab reorder set mismatch")
      }
      guard currentIDs != orderedIDs else { return }
      let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
      worktree.panes[paneIndex].tabs = orderedIDs.compactMap { byID[$0] }
      changed = true
    }
    _ = changed
  }

  /// Moves a Tab inside its Pane by `offset` positions, wrapping cyclically
  /// like Ghostty's `move_tab`: moving the last Tab forward places it first.
  /// Zero or identity offsets are a silent no-op.
  func moveTab(_ tabID: TabID, offset: Int) throws {
    guard let address = catalog.address(forTab: tabID),
      let indices = findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    try mutateLayout(at: indices) { worktree in
      guard let paneIndex = worktree.panes.firstIndex(where: { $0.id == address.paneID }),
        let tabIndex = worktree.panes[paneIndex].tabs.firstIndex(where: { $0.id == tabID })
      else { throw HierarchyError.notFound("Tab \(tabID)") }
      let count = worktree.panes[paneIndex].tabs.count
      // Swift's `%` on negative dividends returns a negative remainder, so
      // pre-add a multiple of `count` to land in [0, count).
      let target = ((tabIndex + offset) % count + count) % count
      guard target != tabIndex else { return }
      let tab = worktree.panes[paneIndex].tabs.remove(at: tabIndex)
      worktree.panes[paneIndex].tabs.insert(tab, at: target)
    }
  }

  /// Moves a Tab into another Pane of the same Worktree at `index`
  /// (clamped to the strip), selects it there and focuses that Pane. The
  /// Content is kept alive; responder focus is the caller's call, after the
  /// moved surface is back in a window. A source Pane left without Tabs closes, like
  /// closing its last Tab.
  func moveTab(_ tabID: TabID, toPane targetID: PaneID, at index: Int) throws {
    guard let address = catalog.address(forTab: tabID),
      let indices = findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    try mutateLayout(at: indices) { worktree in
      guard worktree.pane(targetID) != nil else {
        throw HierarchyError.notFound("Pane \(targetID) in Worktree \(address.worktreeID)")
      }
      if targetID == address.paneID, worktree.pane(targetID)?.tabs.count == 1 { return }
      let tab = try Self.detachTab(tabID, from: address.paneID, in: &worktree)
      guard let targetIndex = worktree.panes.firstIndex(where: { $0.id == targetID }) else {
        throw HierarchyError.notFound("Pane \(targetID)")
      }
      let slot = min(max(index, 0), worktree.panes[targetIndex].tabs.count)
      worktree.panes[targetIndex].tabs.insert(tab, at: slot)
      worktree.panes[targetIndex].selectedTabID = tabID
      worktree.focusedPaneID = targetID
    }
  }

  /// Moves a Tab into a new Pane beside `anchorID`, split along
  /// `direction`, and focuses it. The Content is kept alive. When the Tab
  /// is the only one of its Pane, that Pane itself moves instead (and a
  /// move beside itself is a no-op). Returns the Pane that holds the Tab.
  @discardableResult
  func splitTab(
    _ tabID: TabID,
    beside anchorID: PaneID,
    direction: SplitTree<PaneID>.NewDirection
  ) throws -> PaneID {
    guard let address = catalog.address(forTab: tabID),
      let indices = findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    var hostID = address.paneID
    try mutateLayout(at: indices) { worktree in
      guard worktree.pane(anchorID) != nil else {
        throw HierarchyError.notFound("Pane \(anchorID) in Worktree \(address.worktreeID)")
      }
      if worktree.pane(address.paneID)?.tabs.count == 1 {
        guard anchorID != address.paneID else { return }
        worktree.splitTree = try worktree.splitTree
          .moving(address.paneID, relativeTo: anchorID, direction: direction)
          .settingZoomed(nil)
      } else {
        let tab = try Self.detachTab(tabID, from: address.paneID, in: &worktree)
        let pane = Pane(tabs: [tab])
        worktree.splitTree = try worktree.splitTree
          .inserting(pane.id, at: anchorID, direction: direction)
          .settingZoomed(nil)
        worktree.panes.append(pane)
        hostID = pane.id
      }
      worktree.focusedPaneID = hostID
    }
    return hostID
  }

  /// Takes the Tab out of its Pane without touching its Content. A Pane
  /// left empty is removed; a selected Tab hands the selection to its
  /// right neighbour, else to the new last Tab (as `closeTab` does).
  private static func detachTab(
    _ tabID: TabID, from paneID: PaneID, in worktree: inout Worktree
  ) throws -> Tab {
    guard let paneIndex = worktree.panes.firstIndex(where: { $0.id == paneID }),
      let tabIndex = worktree.panes[paneIndex].tabs.firstIndex(where: { $0.id == tabID })
    else { throw HierarchyError.notFound("Tab \(tabID)") }
    let tab = worktree.panes[paneIndex].tabs.remove(at: tabIndex)
    let remaining = worktree.panes[paneIndex].tabs
    if remaining.isEmpty {
      _ = removePane(paneID, from: &worktree)
    } else if worktree.panes[paneIndex].selectedTabID == tabID {
      worktree.panes[paneIndex].selectedTabID = remaining[min(tabIndex, remaining.count - 1)].id
    }
    return tab
  }

  /// Closes every Tab in the Pane except `tabID`. Reuses `closeTab` per
  /// sibling so surfaces are torn down the same way as a single close.
  func closeOtherTabs(keeping tabID: TabID) throws {
    guard let address = catalog.address(forTab: tabID), let pane = catalog.pane(address.paneID) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    for sibling in pane.tabIDs where sibling != tabID {
      try? closeTab(sibling)
    }
    try selectTab(tabID)
  }

  /// Closes every Tab whose position in the Pane is strictly after
  /// `tabID`'s. No-op when it is the last Tab.
  func closeTabsToRight(of tabID: TabID) throws {
    guard let address = catalog.address(forTab: tabID), let pane = catalog.pane(address.paneID),
      let pivot = pane.tabs.firstIndex(where: { $0.id == tabID })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    for doomed in pane.tabs.suffix(from: pivot + 1).map(\.id) {
      try? closeTab(doomed)
    }
    // A close inside the doomed suffix may have advanced the selection;
    // reseat it so the pivot stays the user's anchor.
    try selectTab(tabID)
  }

  /// Closes every Tab in the Pane — which closes the Pane.
  func closeAllTabs(in paneID: PaneID) throws {
    try closePane(paneID)
  }

  // MARK: - Pane verbs

  /// Creates a Pane beside `paneID` with one fresh Tab holding `content`,
  /// and focuses it. A zoom on the Worktree is cleared: the new Pane must
  /// be visible. Catalog-only, like `newTab`.
  @discardableResult
  func splitPane(
    from paneID: PaneID,
    direction: SplitTree<PaneID>.NewDirection,
    content: ContentSnapshot,
    name: String? = nil,
    initialTitle: String? = nil
  ) throws -> TabAddress {
    guard let address = catalog.address(forPane: paneID),
      let indices = findWorktreeIndices(worktreeID: address.worktreeID, projectID: address.projectID)
    else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    let tab = Tab(name: name, cachedDisplayTitle: initialTitle, content: content)
    let pane = Pane(tabs: [tab])
    try mutateLayout(at: indices) { worktree in
      worktree.splitTree = try worktree.splitTree
        .inserting(pane.id, at: paneID, direction: direction)
        .settingZoomed(nil)
      worktree.panes.append(pane)
      worktree.focusedPaneID = pane.id
    }
    return TabAddress(
      projectID: address.projectID, worktreeID: address.worktreeID, paneID: pane.id, tabID: tab.id,
      contentID: content.id)
  }

  /// Closes every Tab of the Pane and the Pane itself; focus moves to the
  /// neighbour when the Pane was focused.
  func closePane(_ paneID: PaneID) throws {
    guard let indices = worktreeIndices(forPane: paneID), let pane = catalog.pane(paneID) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    for contentID in pane.contentIDs {
      runtime.closeSurface(for: contentID)
      processRegistry.remove(contentID)
    }
    var focusTarget: ContentID?
    try mutateLayout(at: indices) { worktree in
      focusTarget = Self.removePane(paneID, from: &worktree)
    }
    if let focusTarget {
      runtime.focusSurfaceView(for: focusTarget)
    }
  }

  /// Makes `paneID` the Worktree's focused Pane. Persists; unchanged is a
  /// no-op. Responder-chain focus is the caller's call
  /// (`focusSurfaceView(for:)`), since the surface may not exist yet.
  func focusPane(_ paneID: PaneID) throws {
    guard let indices = worktreeIndices(forPane: paneID) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    guard catalog.projects[indices.0].worktrees[indices.1].focusedPaneID != paneID else { return }
    catalog.projects[indices.0].worktrees[indices.1].focusedPaneID = paneID
    store.scheduleSave(catalog)
  }

  /// Moves focus from `paneID` to its neighbour in `direction` and hands
  /// the neighbour's selected Content the keyboard. Returns the neighbour,
  /// or `nil` when there is none in that direction (an edge is a no-op).
  @discardableResult
  func focusNeighbour(of paneID: PaneID, direction: FocusDirection) throws -> PaneID? {
    guard let indices = worktreeIndices(forPane: paneID) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    let worktree = catalog.projects[indices.0].worktrees[indices.1]
    let target: PaneID?
    switch direction {
    case .previous: target = worktree.splitTree.focusTarget(for: .previous, from: paneID)
    case .next: target = worktree.splitTree.focusTarget(for: .next, from: paneID)
    case .left: target = worktree.splitTree.focusTarget(spatial: .left, from: paneID)
    case .right: target = worktree.splitTree.focusTarget(spatial: .right, from: paneID)
    case .up: target = worktree.splitTree.focusTarget(spatial: .up, from: paneID)
    case .down: target = worktree.splitTree.focusTarget(spatial: .down, from: paneID)
    }
    guard let target, let pane = worktree.pane(target) else { return nil }
    try focusPane(target)
    if let contentID = pane.selectedTab?.content.id {
      runtime.focusSurfaceView(for: contentID)
    }
    return target
  }

  /// Zooms the Pane to fill the layout area, or un-zooms it when it is the
  /// zoomed one. Focuses the Pane either way. Returns the new zoom state.
  @discardableResult
  func toggleZoom(_ paneID: PaneID) throws -> Bool {
    guard let indices = worktreeIndices(forPane: paneID) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    var zoomed = false
    try mutateLayout(at: indices) { worktree in
      zoomed = worktree.splitTree.zoomed != paneID
      worktree.splitTree = worktree.splitTree.settingZoomed(zoomed ? paneID : nil)
      worktree.focusedPaneID = paneID
    }
    return zoomed
  }

  func resizeSplit(
    at path: SplitTree<PaneID>.Path,
    ratio: Double,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard let indices = findWorktreeIndices(worktreeID: worktreeID, projectID: projectID) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    try mutateLayout(at: indices) { worktree in
      worktree.splitTree = try worktree.splitTree.resizing(at: path, ratio: ratio)
    }
  }

  /// Sets every split node's `ratio` in the Worktree's tree to 0.5 so
  /// sibling Panes render at equal sizes. Leaf-only trees are a no-op.
  func equalizeSplits(in worktreeID: WorktreeID, in projectID: ProjectID) throws {
    guard let indices = findWorktreeIndices(worktreeID: worktreeID, projectID: projectID) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard let root = catalog.projects[indices.0].worktrees[indices.1].splitTree.root else { return }
    try mutateLayout(at: indices) { worktree in
      worktree.splitTree = SplitTree(root: Self.balancingRatios(in: root), zoomed: worktree.splitTree.zoomed)
    }
  }

  private static func balancingRatios(
    in node: SplitTree<PaneID>.Node
  ) -> SplitTree<PaneID>.Node {
    switch node {
    case .leaf:
      return node
    case .split(let split):
      return .split(
        SplitTree<PaneID>.Split(
          direction: split.direction,
          ratio: 0.5,
          left: balancingRatios(in: split.left),
          right: balancingRatios(in: split.right)
        )
      )
    }
  }

  /// Adjusts the ratio of the closest ancestor split whose orientation
  /// matches `direction`. The ghostty RESIZE_SPLIT action carries a pixel
  /// amount (default keybinds are e.g. 10–20 px), but the split tree only
  /// stores ratios in `[0.1, 0.9]`. Adding the raw pixel value to a ratio
  /// collapses the split on the first keypress, so the delta is scaled by
  /// `pixelsPerRatioStep` — an empirical divisor that maps a default 10 px
  /// keybind to a ~2.5% ratio nudge on a typical 400 px split.
  ///
  /// Direction semantics (matches ghostty's FocusDirection analog):
  /// - `.left`: grow the left child  → decrease ratio of nearest horizontal split
  /// - `.right`: grow the right child → increase ratio of nearest horizontal split
  /// - `.up`: grow the top child     → decrease ratio of nearest vertical split
  /// - `.down`: grow the bottom child → increase ratio of nearest vertical split
  ///
  /// Silent no-op when the Pane is unknown or no ancestor split matches the
  /// direction (e.g. resize-left on a purely vertical column).
  func resizePane(_ paneID: PaneID, direction: ResizeDirection, amount: Double) throws {
    let pixelsPerRatioStep: Double = 400
    let ratioDelta = amount / pixelsPerRatioStep
    guard let indices = worktreeIndices(forPane: paneID) else { return }
    try mutateLayout(at: indices) { worktree in
      guard let leafPath = worktree.splitTree.path(to: paneID) else { return }
      let orientation: SplitTree<PaneID>.Direction =
        (direction == .left || direction == .right) ? .horizontal : .vertical
      guard
        let (ancestorPath, currentRatio, grewRight) = Self.findAncestorSplit(
          root: worktree.splitTree.root, leafPath: leafPath, orientation: orientation)
      else { return }
      let grow = (direction == .right || direction == .down)
      let signedDelta = (grewRight == grow) ? ratioDelta : -ratioDelta
      worktree.splitTree = try worktree.splitTree.resizing(at: ancestorPath, ratio: currentRatio + signedDelta)
    }
  }

  /// Walks up from `leafPath` toward the root and returns the nearest split
  /// whose orientation matches. `grewRight` is `true` when the leaf lives
  /// under the split's right child (so growing its side is `ratio += delta`).
  private static func findAncestorSplit(
    root: SplitTree<PaneID>.Node?,
    leafPath: SplitTree<PaneID>.Path,
    orientation: SplitTree<PaneID>.Direction
  ) -> (SplitTree<PaneID>.Path, Double, Bool)? {
    guard let root else { return nil }
    var components = leafPath.components
    while !components.isEmpty {
      let childBranch = components.removeLast()
      let ancestorPath = SplitTree<PaneID>.Path(components)
      guard case .split(let split) = root.node(at: ancestorPath),
        split.direction == orientation
      else { continue }
      return (ancestorPath, split.ratio, childBranch == .right)
    }
    return nil
  }

  // MARK: - Surfaces

  /// Brings the Content's surface up (or re-attaches it). Idempotent: a
  /// live surface returns at once. The worktree built-ins
  /// (`CODANS_WORKTREE_PATH` …) are injected here, after the caller's env.
  func ensureSurface(for contentID: ContentID, env: [String: String] = [:]) async throws {
    guard !runtime.hasSurface(for: contentID) else { return }
    guard let address = catalog.address(forContent: contentID),
      case (let project, let worktree)? = catalog.worktree(address.worktreeID),
      let content = worktree.tab(address.tabID)?.content
    else {
      throw HierarchyError.notFound("Content \(contentID)")
    }
    let workspaceRoot = project.isWorkspace ? project.rootPath : nil
    try await runtime.ensureSurface(
      for: content, at: address, in: worktree,
      env: Self.injectingBuiltins(
        env, worktreePath: worktree.path, rootPath: project.rootPath, workspaceRoot: workspaceRoot)
    )
  }

  /// Make the Content's surface view the first responder of its window.
  /// Distinct from `focusPane` (the catalog focus) — this only touches the
  /// AppKit responder chain so keyboard input routes correctly. Silent
  /// no-op when the surface or window isn't available.
  func focusSurfaceView(for contentID: ContentID) {
    runtime.focusSurfaceView(for: contentID)
  }

  func currentWorkingDirectory(for contentID: ContentID) -> String? {
    runtime.currentWorkingDirectory(for: contentID)
  }

  // MARK: - Run-script Contents

  /// Identity of a dedicated run-script Content: the worktree it lives in
  /// plus the `ScriptDefinition.id` that spawned it. Keying on both lets
  /// each script keep its own reusable Content while surviving worktree
  /// switches.
  private struct ScriptContentKey: Hashable {
    let worktree: WorktreeID
    let script: UUID
  }

  /// Maps a (worktree, script) pair to the Content a `.newTab` / `.split`
  /// run script last spawned. Lets repeated runs reuse the same Content
  /// instead of piling up Tabs, and lets the Run/Stop toggle find the
  /// Content to interrupt. The persistent identity lives on
  /// `TerminalContentState.runScriptID`; this map is the in-memory index
  /// over it, rebuilt from the catalog at init so a relaunch still routes
  /// the next run into the restored Content.
  private var scriptRunContents: [ScriptContentKey: ContentID] = [:]

  private func rebuildRunScriptContents() {
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.allTabs {
          guard let scriptID = tab.content.terminal?.runScriptID else { continue }
          scriptRunContents[ScriptContentKey(worktree: worktree.id, script: scriptID)] = tab.content.id
        }
      }
    }
  }

  /// The live run Content for `(worktreeID, scriptID)`, or `nil` when none
  /// was recorded or the recorded Content has since closed. Lazily prunes
  /// stale entries so callers never act on a dead Content.
  func runScriptContent(worktreeID: WorktreeID, scriptID: UUID) -> ContentID? {
    let key = ScriptContentKey(worktree: worktreeID, script: scriptID)
    guard let contentID = scriptRunContents[key] else { return nil }
    if catalog.content(contentID) == nil {
      scriptRunContents.removeValue(forKey: key)
      return nil
    }
    return contentID
  }

  /// Records the Content a run script spawned so the next run can reuse
  /// it. Stamps `runScriptID` in the catalog as well — the persisted half
  /// of the association that `rebuildRunScriptContents` reads back.
  func setRunScriptContent(worktreeID: WorktreeID, scriptID: UUID, contentID: ContentID) {
    scriptRunContents[ScriptContentKey(worktree: worktreeID, script: scriptID)] = contentID
    mutateTerminalContent(contentID) { state in
      guard state.runScriptID != scriptID else { return false }
      state.runScriptID = scriptID
      return true
    }
  }

  /// Every recorded (script, Content) pair of the worktree whose Content
  /// still exists. Pure read — no pruning, so it is safe from SwiftUI
  /// `body`.
  func runScriptContents(in worktreeID: WorktreeID) -> [(scriptID: UUID, contentID: ContentID)] {
    scriptRunContents.compactMap { key, contentID in
      guard key.worktree == worktreeID, catalog.content(contentID) != nil else { return nil }
      return (scriptID: key.script, contentID: contentID)
    }
  }

  // MARK: - Worktree / Tab activation

  func activateWorktree(_ id: WorktreeID) throws {
    for (pi, project) in catalog.projects.enumerated()
    where project.worktrees.contains(where: { $0.id == id }) {
      catalog.projects[pi].selectedWorktreeID = id
      store.scheduleSave(catalog)
      return
    }
    throw HierarchyError.notFound("Worktree \(id)")
  }

  func activateTab(_ id: TabID) throws {
    try selectTab(id)
  }

  // MARK: - Content labels

  /// Update a Content's `labels` set. **Single canonical writer** — every
  /// user-facing write path (the CLI's label verb, the hook action DSL,
  /// any future UI) routes through this method, so label mutations stay
  /// auditable and persist through `CatalogStore.scheduleSave`.
  ///
  /// - Parameters:
  ///   - replace: when `true`, replaces the set entirely; when `false`,
  ///     union-merges with the existing set.
  /// - Throws: `HierarchyError.notFound` if the Content id is unknown.
  func setContentLabels(
    _ contentID: ContentID,
    labels: Set<String>,
    replace: Bool = false
  ) throws {
    let found = mutateTerminalContent(contentID) { state in
      let next = replace ? labels : state.labels.union(labels)
      guard next != state.labels else { return false }
      state.labels = next
      return true
    }
    guard found else { throw HierarchyError.notFound("Content \(contentID)") }
  }

  // MARK: - Command queue

  /// The commands parked on the Content, or `[]` when it is unknown.
  func commandQueue(for contentID: ContentID) -> [QueuedCommand] {
    catalog.content(contentID)?.terminal?.commandQueue ?? []
  }

  /// **Single canonical writer** for a Content's `commandQueue` — the
  /// editor panel, the badge's per-row delete, and the runner's post-fire
  /// re-arm all land here, so every queue mutation persists through the
  /// same `CatalogStore.scheduleSave` as the rest of the hierarchy.
  ///
  /// Silently no-ops for an unknown Content rather than throwing: every
  /// caller is a best-effort UI action or a background drain pass racing
  /// a close, and neither has anything useful to do with the error.
  func setCommandQueue(_ queue: [QueuedCommand], for contentID: ContentID) {
    mutateTerminalContent(contentID) { state in
      guard state.commandQueue != queue else { return false }
      state.commandQueue = queue
      return true
    }
  }

  /// Every Content that currently owes the user something, paired with
  /// its queue. One catalog walk per drain pass. Archived worktrees are
  /// skipped: their daemons are down.
  func contentsWithQueuedCommands() -> [(contentID: ContentID, queue: [QueuedCommand])] {
    var result: [(contentID: ContentID, queue: [QueuedCommand])] = []
    for project in catalog.projects {
      for worktree in project.worktrees where !worktree.archived {
        for tab in worktree.allTabs {
          guard let queue = tab.content.terminal?.commandQueue, !queue.isEmpty else { continue }
          result.append((contentID: tab.content.id, queue: queue))
        }
      }
    }
    return result
  }

  // MARK: - Busy predicate

  /// Whether closing the Content would lose work: a running foreground
  /// command, a working agent (both through `contentActivity`), or a
  /// non-empty command queue. The close-confirmation gate reads it for
  /// every Tab a close affects.
  func isBusy(_ contentID: ContentID) -> Bool {
    if !commandQueue(for: contentID).isEmpty { return true }
    return contentActivity?(contentID) ?? false
  }
  // MARK: - Env resolution

  /// Resolves the merged environment for a Project's spawned subprocesses.
  /// Combines `ProcessInfo.processInfo.environment` with
  /// `Settings.projects[pid].envVars`; project-defined keys win on collision.
  /// Pure / nonisolated so callers (PaneSurface env injection, lifecycle
  /// script execution) can reach it from off the main actor when convenient.
  nonisolated static func resolvedEnv(
    for projectID: ProjectID,
    in settings: Settings
  ) -> [String: String] {
    TabEnvironment.processBase(
      overrides: settings.projects[projectID]?.envVars ?? [:],
      socketPath: SocketPaths.resolve()
    )
  }

  /// Merges the per-worktree built-in variables codans provides for
  /// every pane (`CODANS_WORKTREE_PATH`, `CODANS_ROOT_PATH`) into
  /// `env`. Injected here at spawn time — not in `resolvedEnv`, which is
  /// project-scoped and has no worktree — and written *after* the caller's
  /// env so a user-defined `envVars` entry of the same name can't shadow
  /// the real path. Mirrors the read-only rows the Environment editor pins
  /// and the always-wins ordering `resolvedEnv` uses for the socket path.
  nonisolated static func injectingBuiltins(
    _ env: [String: String],
    worktreePath: String,
    rootPath: String,
    workspaceRoot: String? = nil
  ) -> [String: String] {
    var merged = env
    merged[BuiltinEnvVar.worktreePath.key] = worktreePath
    merged[BuiltinEnvVar.rootPath.key] = rootPath
    // Present only inside a workspace, so its absence is itself a signal.
    // A user-defined entry of the same name is dropped either way: the
    // editor refuses the key, and a stale value from a project's envVars
    // must not leak into a non-workspace pane.
    if let workspaceRoot {
      merged[BuiltinEnvVar.workspaceRoot.key] = workspaceRoot
    } else {
      merged.removeValue(forKey: BuiltinEnvVar.workspaceRoot.key)
    }
    return merged
  }

  // MARK: - Helpers

  /// Index in `worktrees` where the unpinned segment begins — the first row
  /// that would render in the unpinned section of the sidebar (non-archived,
  /// not the main checkout, not pinned). Archived and pinned rows that happen
  /// to sit later in the array do not pull the boundary back. Returns
  /// `worktrees.count` when no unpinned row exists, so callers can use the
  /// value directly as an `insert(at:)` or `move(toOffset:)` target.
  private static func unpinnedBoundary(
    in worktrees: [Worktree],
    rootPath: String
  ) -> Int {
    for (i, w) in worktrees.enumerated() {
      if !w.archived && !w.isPinned && w.path != rootPath { return i }
    }
    return worktrees.count
  }

  private func findWorktreeIndices(
    worktreeID: WorktreeID,
    projectID: ProjectID
  ) -> (Int, Int)? {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID }) else {
      return nil
    }
    guard
      let worktreeIndex = catalog.projects[projectIndex].worktrees.firstIndex(where: {
        $0.id == worktreeID
      })
    else { return nil }
    return (projectIndex, worktreeIndex)
  }
}
