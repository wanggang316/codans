import Foundation
import Observation
import TouchCodeCore

enum HierarchyError: Error, Equatable, Sendable {
  case notFound(String)
  case invariantViolation(String)
}

/// Identifies a reorderable sidebar section under a Project. The full sidebar
/// taxonomy has four sections (main / pinned / pending / unpinned, see
/// `docs/design-docs/worktree-sidebar-ordering.md`); only `pinned` and
/// `unpinned` admit user-initiated reordering, so this enum names just those.
enum WorktreeSegment: Sendable, Equatable {
  case pinned
  case unpinned
}

/// Catalog-driven worktree repositioning mode for
/// `HierarchyClient.promoteWorktree`. The notifications-v1-1 worktree-promote
/// behaviour ships the only case in v1.1; the enum exists so additional
/// modes (e.g. `.toIndex(Int)` for an explicit reorder UI) can land without
/// reshaping the call surface. See
/// `docs/design-docs/notifications-v1-1.md` §"Worktree promote".
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
  private(set) var catalog: Catalog
  private let store: CatalogStore
  private let runtime: HierarchyRuntime

  /// Runtime-only map of the pane the user most recently focused inside a
  /// given tab. Read by `selectTab` to restore focus on tab switches;
  /// cleared when the pane or the tab is closed. Never persisted — wall-
  /// clock-live state that must be rebuilt each launch.
  private var lastFocusedPaneByTab: [TabID: PaneID] = [:]

  /// Runtime-only set of panes that are currently executing a tracked
  /// command. Driven by C3 hooks in a future milestone; today the only
  /// writers are the `markPaneRunning` / `markPaneIdle` methods, which no
  /// caller invokes in production. Reads via `tabIsDirty(_:)` still work
  /// — they return `false` uniformly until a writer wakes up. Stored as a
  /// `Set` rather than `[PaneID: Bool]` so absence is the natural "idle"
  /// signal and `contains` is the only read shape.
  private var runningPanes: Set<PaneID> = []

  init(catalog: Catalog, store: CatalogStore, runtime: HierarchyRuntime) {
    self.catalog = catalog
    self.store = store
    self.runtime = runtime
    Self.normalizeArchivedSelection(in: &self.catalog)
    let didStampLegacyTimestamps = Self.backfillLegacyAddedAt(in: &self.catalog)
    if didStampLegacyTimestamps {
      // Persist the migration so successive launches start from the
      // backfilled timestamps rather than re-deriving them on every
      // open (and so the user-visible order is deterministic the
      // moment another writer touches the catalog).
      store.scheduleSave(self.catalog)
    }
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
  /// enforced unique — see `docs/design-docs/project-tags.md` §3.2 for
  /// rationale (mirrors Finder).
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

  // MARK: - Project mutations

  func addProject(name: String, rootPath: String, gitRoot: String? = nil) -> ProjectID {
    let projectID = ProjectID()
    var worktrees: [Worktree] = []
    var selectedWorktreeID: WorktreeID?

    if gitRoot == nil {
      let synthetic = Worktree(
        id: WorktreeID(),
        name: (rootPath as NSString).lastPathComponent,
        path: rootPath,
        branch: nil,
        tabs: [],
        selectedTabID: nil
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
      manualOrder: nextManualOrder
    )
    catalog.projects.append(project)
    store.scheduleSave(catalog)
    return projectID
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

  /// Renames the Project in place. Missing project is `.notFound`; an unchanged
  /// name is a silent no-op (no catalog churn, no save). The caller is
  /// responsible for trimming / empty-string validation.
  func renameProject(_ id: ProjectID, name: String) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    guard catalog.projects[projectIndex].name != name else { return }
    catalog.projects[projectIndex].name = name
    store.scheduleSave(catalog)
  }

  func removeProject(_ id: ProjectID) throws {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    catalog.projects.remove(at: projectIndex)
    if catalog.selectedProjectID == id {
      catalog.selectedProjectID = nil
    }
    store.scheduleSave(catalog)
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
  /// Used by the `editor.open` IPC so `tc open` inside a subdirectory of a
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

    // Uniqueness guard (HAN-82): without this, dispatcher retries on
    // tab/pane failure register a fresh row pointing at the same
    // (canonical path, name) every time, polluting `tc tree` with
    // orphan UUIDs. Compare canonical-form so symlinked paths
    // (/var/...  vs /private/var/...) collide as expected.
    let existingWorktrees = catalog.projects[projectIndex].worktrees
    let pathConflict = existingWorktrees.first { Self.canonicalPath($0.path) == canonicalizedPath }
    if let pathConflict {
      if reuseExisting {
        // Idempotent mode — caller is replaying create after a partial
        // failure downstream and just wants the existing id. Name /
        // branch are NOT re-applied to avoid silently rewriting fields
        // the user may have customized through the UI.
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
      branch: branch,
      tabs: [],
      selectedTabID: nil
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
    for pane in worktree.tabs.flatMap({ $0.panes }) {
      runtime.closeSurface(for: pane.id)
    }

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
  /// Worktree's Panes and calls `runtime.closeSurface(for:)` each so
  /// terminal surfaces are torn down; the on-disk directory and git
  /// refs are NOT touched. Idempotent: unchanged value is a silent
  /// no-op (no save scheduled). Silent no-op when the id is unknown.
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
        for pane in worktree.tabs.flatMap({ $0.panes }) {
          runtime.closeSurface(for: pane.id)
        }
      }
      catalog.projects[projectIndex].worktrees[worktreeIndex].archived = archived
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
      return
    }
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
  /// ids. Persists via the standard debounced save pipeline. See
  /// `docs/design-docs/worktree-sidebar-ordering.md` §pinned 段 / §unpinned 段.
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

  /// Reorder rows within a single sidebar segment under one Project. SwiftUI
  /// `.onMove` reports segment-relative `IndexSet` and target offset; this
  /// method translates those into a catalog-array mutation that preserves the
  /// catalog positions of rows in other segments (and of archived rows).
  ///
  /// Validation is all-or-nothing: if any `from` offset or `to` falls outside
  /// the current segment range, or `from` is empty, the call is a silent
  /// no-op (no save). This matches the staleness guard described in
  /// `docs/design-docs/worktree-sidebar-ordering.md` §Risks — a snapshot
  /// taken before a worktree was removed produces out-of-range offsets, and
  /// dropping the whole reorder is preferable to a partial application.
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

  /// Toggles membership of `label` in `Pane.labels`. `present: true` inserts;
  /// `present: false` removes. Set semantics make repeated calls idempotent
  /// (the in-memory state matches what a single call with the same `present`
  /// would produce). Silent no-op on unknown `paneID`. Persists via the
  /// standard debounced save pipeline so rapid toggles coalesce into one
  /// disk write per 500 ms window; in-memory state changes immediately so a
  /// subsequent read inside the debounce window sees the latest value.
  ///
  /// Behind notifications-v1-1's pane right-click "Mute notifications" toggle
  /// (`notifications:muted` label). The notification detector consults
  /// `Pane.labels` to drop muted-pane candidates.
  func setPaneLabel(paneID: PaneID, label: String, present: Bool) {
    for projectIndex in catalog.projects.indices {
      for worktreeIndex in catalog.projects[projectIndex].worktrees.indices {
        for tabIndex in catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.indices {
          let tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
          guard let paneIndex = tab.panes.firstIndex(where: { $0.id == paneID }) else {
            continue
          }
          if present {
            let (inserted, _) = catalog.projects[projectIndex]
              .worktrees[worktreeIndex]
              .tabs[tabIndex]
              .panes[paneIndex].labels.insert(label)
            // Idempotent: already-present insert is a true no-op for both
            // in-memory state and the disk file. Skip the save to avoid
            // touching the catalog file when nothing changed.
            guard inserted else { return }
          } else {
            guard
              catalog.projects[projectIndex]
                .worktrees[worktreeIndex]
                .tabs[tabIndex]
                .panes[paneIndex].labels.remove(label) != nil
            else { return }
          }
          store.scheduleSave(catalog)
          return
        }
      }
    }
  }

  /// Merges worktrees discovered on disk (typically from
  /// `wt ls --json`) into the catalog. Path-canonicalized dedupe
  /// against existing rows — both sides go through
  /// `URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`
  /// so `/var/...` vs. `/private/var/...` don't cause duplicate rows
  /// against T-PROJECT's `Project.rootPath` which is stored in the
  /// symlink-resolved form. Never removes or mutates existing rows —
  /// stale rows are surfaced in the view layer and only deleted by the
  /// user-initiated Prune action. Idempotent across repeated calls
  /// with the same entries. Returns the count of appended rows so the
  /// caller can surface a toast.
  ///
  /// - Parameters:
  ///   - projectID: target Project.
  ///   - entries: on-disk worktree metadata (path, branch) from
  ///     `GitWorktreeClient.lsWorktrees`.
  @discardableResult
  func reconcileDiscoveredWorktrees(
    projectID: ProjectID,
    entries: [(path: String, branch: String?)]
  ) -> Int {
    guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == projectID })
    else { return 0 }
    let project = catalog.projects[projectIndex]
    let discoveredPaths = Set(entries.map { Self.canonicalPath($0.path) })
    let rootCanonical = Self.canonicalPath(project.rootPath)
    var appended = 0
    var upgraded = 0
    for entry in entries {
      let canonical = Self.canonicalPath(entry.path)
      let entryBranch = (entry.branch?.isEmpty == false) ? entry.branch! : nil
      if let existingIdx = catalog.projects[projectIndex].worktrees
        .firstIndex(where: { Self.canonicalPath($0.path) == canonical })
      {
        // Path already in the catalog. Three cases land here:
        //
        // 1. Synthetic placeholder upgrade — `addProject(gitRoot: nil)`
        //    seeded a row with `branch == nil` and `name == lastPathComponent`;
        //    once the directory becomes a git repo, adopt the real branch
        //    so the sidebar reads "main" instead of the folder name.
        // 2. In-place branch change (HAN-62) — user ran `git checkout` /
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
        if existing.branch != entryBranch {
          catalog.projects[projectIndex].worktrees[existingIdx].branch = entryBranch
          if let newBranch = entryBranch, existing.name == existing.branch || existing.branch == nil {
            catalog.projects[projectIndex].worktrees[existingIdx].name = newBranch
          }
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
        tabs: [],
        selectedTabID: nil
      )
      catalog.projects[projectIndex].worktrees.append(worktree)
      appended += 1
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
      let canonical = Self.canonicalPath(worktree.path)
      guard
        !discoveredPaths.contains(canonical),
        canonical != rootCanonical,
        !worktree.isPinned,
        !worktree.archived
      else { continue }
      for pane in worktree.tabs.flatMap({ $0.panes }) {
        runtime.closeSurface(for: pane.id)
        runningPanes.remove(pane.id)
      }
      if let idx = catalog.projects[projectIndex].worktrees.firstIndex(where: { $0.id == worktree.id }) {
        catalog.projects[projectIndex].worktrees[idx].archived = true
        archivedCount += 1
      }
    }
    if appended > 0 || upgraded > 0 || archivedCount > 0 {
      store.scheduleSave(catalog)
    }
    return appended
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
  /// this type. Prior to PR #31 review, two static methods
  /// (`canonical` + `canonicalPath`) coexisted with identical bodies;
  /// any drift (e.g. one side adding trimming) would silently break
  /// the symmetry the PR body guarantees. Route all call-sites
  /// through this function.
  static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
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
      for pane in worktree.tabs.flatMap({ $0.panes }) {
        runtime.closeSurface(for: pane.id)
        runningPanes.remove(pane.id)
      }
      for tab in worktree.tabs {
        lastFocusedPaneByTab.removeValue(forKey: tab.id)
      }
      return
    }
  }

  /// Counts the number of Panes in this Worktree whose terminal surface
  /// is live. Used by force-remove to size the confirmation copy
  /// ("This will terminate N running processes"). 0 when the id is unknown.
  func runningPaneCount(worktreeID: WorktreeID) -> Int {
    for project in catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { continue }
      return worktree.tabs
        .flatMap { $0.panes }
        .filter { runtime.hasSurface(for: $0.id) }
        .count
    }
    return 0
  }

  /// Records whether the right-side Git Viewer overlay is visible for this
  /// Worktree. Visibility persists across app restarts — each Worktree
  /// remembers its own. Missing `worktreeID` is a silent no-op; unchanged
  /// value is a silent no-op (no save scheduled). Persists via the
  /// standard debounced `store.scheduleSave(catalog)` pipeline. The
  /// `projectID` argument is not required — the method scans all
  /// Worktrees in the catalog so the caller does not have to thread
  /// parent IDs through the UI-toggle path.
  func setWorktreeDiffInspectorVisible(worktreeID: WorktreeID, visible: Bool) {
    for projectIndex in catalog.projects.indices {
      guard
        let worktreeIndex = catalog.projects[projectIndex]
          .worktrees.firstIndex(where: { $0.id == worktreeID })
      else { continue }
      guard
        catalog.projects[projectIndex].worktrees[worktreeIndex].diffInspectorVisible != visible
      else { return }
      catalog.projects[projectIndex].worktrees[worktreeIndex].diffInspectorVisible = visible
      store.scheduleSave(catalog)
      return
    }
  }

  // MARK: - Tab mutations

  func createTab(
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    name: String?,
    select: Bool = true
  ) throws -> TabID {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    let tabID = TabID()
    let tab = Tab(id: tabID, name: name, splitTree: SplitTree(), panes: [])
    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.append(tab)
    // Background-script support: when `select == false` the new tab is
    // appended without stealing the worktree's selectedTabID, so a script
    // with `focus: false` runs in the strip while the user stays put.
    // The first tab of an otherwise-empty worktree always wins selection
    // — there is nothing to "stay focused on" and an unselected sole tab
    // would render an empty worktree with no live pane.
    let existingTabs = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs
    let existingSelection = catalog.projects[projectIndex].worktrees[worktreeIndex].selectedTabID
    if select || existingTabs.count == 1 || existingSelection == nil {
      catalog.projects[projectIndex].worktrees[worktreeIndex].selectedTabID = tabID
    }
    store.scheduleSave(catalog)
    return tabID
  }

  func closeTab(
    _ id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == id
      })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }

    let tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    for pane in tab.panes {
      runtime.closeSurface(for: pane.id)
      runningPanes.remove(pane.id)
    }
    lastFocusedPaneByTab.removeValue(forKey: id)

    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.remove(at: tabIndex)
    if catalog.projects[projectIndex].worktrees[worktreeIndex].selectedTabID == id {
      // Match the platform convention (Safari/Chrome/VSCode/iTerm): pick the
      // right neighbor; if the closed tab was the last one, fall back to the
      // new last tab. After `remove(at:)`, the original right neighbor sits at
      // `tabIndex`; an out-of-range index means we removed the trailing tab.
      let remaining = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs
      let nextTab = tabIndex < remaining.count ? remaining[tabIndex] : remaining.last
      catalog.projects[projectIndex].worktrees[worktreeIndex].selectedTabID = nextTab?.id
      // Transfer AppKit first-responder focus to the new tab's surface.
      // Without this the closed surface's responder slot stays empty and
      // the next ⌘W bypasses Ghostty's `performKeyEquivalent`, falling
      // through to the menu where the system Close Window shadows our
      // binding and shuts the window. Mirrors `selectTab`'s focus logic.
      if let nextTab {
        let flatPaneIDs = Set(nextTab.panes.map(\.id))
        let remembered = lastFocusedPaneByTab[nextTab.id]
          .flatMap { flatPaneIDs.contains($0) ? $0 : nil }
        if let focusID = remembered ?? nextTab.splitTree.leaves().first {
          runtime.focusSurfaceView(for: focusID)
        }
      }
    }
    store.scheduleSave(catalog)
  }

  func selectTab(
    _ id: TabID?,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    catalog.projects[projectIndex].worktrees[worktreeIndex].selectedTabID = id
    store.scheduleSave(catalog)

    // Focus the last-used pane in the target tab; fall back to the
    // leftmost leaf of the split tree when no memory exists or the
    // remembered pane has since been closed. Silent no-op when there is
    // no active tab or the tab has no panes.
    guard
      let tabID = id,
      let tab = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.first(where: { $0.id == tabID })
    else { return }
    let flatPaneIDs = Set(tab.panes.map(\.id))
    let remembered = lastFocusedPaneByTab[tabID].flatMap { flatPaneIDs.contains($0) ? $0 : nil }
    if let focusID = remembered ?? tab.splitTree.leaves().first {
      runtime.focusSurfaceView(for: focusID)
    }
  }

  // MARK: - Tab mutations (tab-bar uplift)

  /// Renames a Tab in place. `nil` clears the custom name so the UI falls
  /// back to the default "Tab" label. Unchanged value is a silent no-op
  /// (no save scheduled) so repeated calls are free.
  func renameTab(
    _ id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    name: String?
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }
    guard
      catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs[tabIndex].name != name
    else { return }
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex].name = name
    store.scheduleSave(catalog)
  }

  func setTabColor(
    _ id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    color: TabColor?
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }
    guard
      catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs[tabIndex].color != color
    else { return }
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex].color = color
    store.scheduleSave(catalog)
  }

  /// Persists the most recently resolved live tab title so the chip can
  /// fall back to it on the next launch (before the surface respawns and
  /// the shell re-pushes OSC titles). No-op when the cache is unchanged
  /// so a hot OSC stream does not churn the catalog (saves are debounced
  /// further downstream by `CatalogStore`). Failures to locate the tab
  /// are silent — the cache is best-effort, never load-bearing.
  func setCachedTabTitle(
    _ title: String?,
    for tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID, projectID: projectID
      )
    else { return }
    guard
      let tabIndex = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    guard
      catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs[tabIndex].cachedDisplayTitle != title
    else { return }
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex].cachedDisplayTitle = title
    store.scheduleSave(catalog)
  }

  /// Replaces the Worktree's tab ordering in a single atomic write. The
  /// incoming id set must match the current set exactly — mismatched input
  /// throws `.invariantViolation` so upstream drag bugs surface immediately
  /// instead of silently discarding tabs. Same-order input is a silent
  /// no-op.
  func reorderTabs(
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    orderedIDs: [TabID]
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let existing = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs
    let currentIDs = existing.map(\.id)
    guard Set(currentIDs) == Set(orderedIDs) else {
      throw HierarchyError.invariantViolation("tab reorder set mismatch")
    }
    guard currentIDs != orderedIDs else { return }
    let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    let reordered = orderedIDs.compactMap { byID[$0] }
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs = reordered
    store.scheduleSave(catalog)
  }

  /// Closes every Tab in the Worktree except `id`. Reuses `closeTab` per
  /// sibling so runtime surfaces are torn down the same way they are for
  /// the single-close path. The pivot is re-selected at the end in case the
  /// per-close auto-advance moved selection elsewhere during teardown.
  func closeOtherTabs(
    keeping id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let siblingIDs = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs
      .map(\.id)
      .filter { $0 != id }
    for siblingID in siblingIDs {
      try? closeTab(siblingID, in: worktreeID, in: projectID)
    }
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].selectedTabID = id
    store.scheduleSave(catalog)
  }

  /// Closes every Tab whose position is strictly after `id`'s. Reuses
  /// `closeTab` per sibling for the same runtime-teardown reasoning as
  /// `closeOtherTabs`. No-op when `id` is the last tab.
  func closeTabsToRight(
    of id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let pivotIndex = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }
    let doomedIDs = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs
      .suffix(from: pivotIndex + 1)
      .map(\.id)
    for doomedID in doomedIDs {
      try? closeTab(doomedID, in: worktreeID, in: projectID)
    }
    // Mirror `closeOtherTabs`: if the user's active tab was inside the
    // doomed suffix, `closeTab`'s auto-advance lands on `tabs.first`, not
    // the pivot. Reseat selection so the pivot stays the user's anchor.
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].selectedTabID = id
    store.scheduleSave(catalog)
  }

  /// Closes every Tab in the Worktree.
  func closeAllTabs(
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let allIDs = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs.map(\.id)
    for tabID in allIDs {
      try? closeTab(tabID, in: worktreeID, in: projectID)
    }
  }

  /// Selects the tab before / after the current selection, wrapping at the
  /// ends. Returns the newly selected id, or `nil` when the Worktree has no
  /// tabs. If no tab is currently selected the jump is relative to the
  /// first tab (so `.previous` lands on the last, `.next` on the second).
  @discardableResult
  func selectAdjacentTab(
    direction: TabAdjacency,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws -> TabID? {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let tabs = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs
    guard !tabs.isEmpty else { return nil }
    let currentID = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].selectedTabID
    let currentIndex =
      currentID.flatMap { id in
        tabs.firstIndex(where: { $0.id == id })
      } ?? 0
    let count = tabs.count
    let newIndex: Int
    switch direction {
    case .previous:
      newIndex = (currentIndex - 1 + count) % count
    case .next:
      newIndex = (currentIndex + 1) % count
    }
    let newID = tabs[newIndex].id
    // Route through `selectTab` rather than writing `selectedTabID`
    // directly so the M3 focus-restoration block fires for the keyboard
    // shortcut path. Otherwise `⌘⇧[` / `⌘⇧]` would persist the new
    // selection without ever asking AppKit to focus the remembered pane.
    try selectTab(newID, in: worktreeID, in: projectID)
    return newID
  }

  // MARK: - Runtime state (tab-bar uplift)

  /// Records `paneID` as the tab's last-focused pane so a future
  /// `selectTab` call can restore it. `nil` clears the entry. No catalog
  /// mutation — the map is runtime-only.
  func setLastFocusedPane(_ paneID: PaneID?, in tabID: TabID) {
    if let paneID {
      lastFocusedPaneByTab[tabID] = paneID
    } else {
      lastFocusedPaneByTab.removeValue(forKey: tabID)
    }
  }

  /// Returns the last-focused pane for `tabID`, or `nil` if none was
  /// recorded or the remembered pane has since been closed.
  func lastFocusedPane(in tabID: TabID) -> PaneID? {
    lastFocusedPaneByTab[tabID]
  }

  func currentWorkingDirectory(for paneID: PaneID) -> String? {
    runtime.currentWorkingDirectory(for: paneID)
  }

  /// Marks `paneID` as running a tracked command. No caller wired today
  /// — lands with C3 hooks. Idempotent.
  func markPaneRunning(_ paneID: PaneID) {
    runningPanes.insert(paneID)
  }

  /// Clears `paneID`'s running flag. Idempotent.
  func markPaneIdle(_ paneID: PaneID) {
    runningPanes.remove(paneID)
  }

  /// True when any pane inside `tabID` is currently marked running.
  /// Reads a runtime set, never touches the catalog.
  func tabIsDirty(_ tabID: TabID) -> Bool {
    // Fast-path: no pane is running anywhere in the app, so the catalog
    // walk is pointless. Until the C3 hooks plan starts populating
    // `runningPanes`, this short-circuit means the chip's per-render
    // call is a single set-emptiness check rather than a hierarchy walk.
    guard !runningPanes.isEmpty else { return false }
    // Walk the catalog once to locate the tab; absent tabs read as idle.
    for project in catalog.projects {
      for worktree in project.worktrees {
        guard let tab = worktree.tabs.first(where: { $0.id == tabID })
        else { continue }
        return tab.panes.contains { runningPanes.contains($0.id) }
      }
    }
    return false
  }

  /// True when any pane inside `worktreeID` (any tab, any leaf) is
  /// currently marked running. Sidebar uses this to surface a busy
  /// glyph on the worktree row even when its tab is unfocused.
  func worktreeIsDirty(_ worktreeID: WorktreeID) -> Bool {
    guard !runningPanes.isEmpty else { return false }
    for project in catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { continue }
      return worktree.tabs.contains { tab in
        tab.panes.contains { runningPanes.contains($0.id) }
      }
    }
    return false
  }

  // MARK: - Pane mutations

  func openPane(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    workingDirectory: String,
    initialCommand: String?,
    env: [String: String] = [:]
  ) throws -> PaneID {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    let paneID = PaneID()
    let pane = Pane(id: paneID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    if tab.splitTree.isEmpty {
      tab.splitTree = SplitTree(leaf: paneID)
    } else {
      let leaves = tab.splitTree.leaves()
      guard let anchor = leaves.first else {
        throw HierarchyError.invariantViolation("Tab has split tree but no leaves")
      }
      tab.splitTree = try tab.splitTree.inserting(paneID, at: anchor, direction: .right)
    }

    tab.panes.append(pane)
    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: pane, in: worktree, env: env)

    store.scheduleSave(catalog)
    return paneID
  }

  func splitPane(
    _ paneID: PaneID,
    direction: SplitTree<PaneID>.NewDirection,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    workingDirectory: String,
    initialCommand: String?,
    env: [String: String] = [:]
  ) throws -> PaneID {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    let newPaneID = PaneID()
    let newPane = Pane(id: newPaneID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    tab.splitTree = try tab.splitTree.inserting(newPaneID, at: paneID, direction: direction)
    tab.panes.append(newPane)
    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: newPane, in: worktree, env: env)

    store.scheduleSave(catalog)
    return newPaneID
  }

  func closePane(
    _ paneID: PaneID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    guard let paneIndex = tab.panes.firstIndex(where: { $0.id == paneID }) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }

    runtime.closeSurface(for: paneID)
    runningPanes.remove(paneID)
    if lastFocusedPaneByTab[tabID] == paneID {
      lastFocusedPaneByTab.removeValue(forKey: tabID)
    }

    tab.panes.remove(at: paneIndex)
    tab.splitTree = tab.splitTree.removing(paneID)

    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    store.scheduleSave(catalog)
  }

  /// Make the surface view for `paneID` the first responder of its
  /// window. Distinct from `focusPane` (which flips the Tab's zoom
  /// flag) — this only touches AppKit responder-chain focus so keyboard
  /// input routes correctly. Silent no-op when the surface or window
  /// isn't available.
  func focusSurfaceView(for paneID: PaneID) {
    runtime.focusSurfaceView(for: paneID)
  }

  func focusPane(
    _ paneID: PaneID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    guard tab.panes.contains(where: { $0.id == paneID }) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }

    tab.splitTree = tab.splitTree.settingZoomed(paneID)
    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab
    // Remember this pane as the tab's last-focused so the next `selectTab`
    // call restores it instead of snapping to the leftmost leaf.
    lastFocusedPaneByTab[tabID] = paneID

    store.scheduleSave(catalog)
  }

  func ensurePaneSurface(
    _ paneID: PaneID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    env: [String: String] = [:]
  ) throws {
    guard !runtime.hasSurface(for: paneID) else { return }
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.first(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    guard let pane = tab.panes.first(where: { $0.id == paneID }) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }
    let worktree = catalog.projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: pane, in: worktree, env: env)
  }

  func unfocusPane(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    tab.splitTree = tab.splitTree.settingZoomed(nil)
    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  func resizeSplit(
    at path: SplitTree<PaneID>.Path,
    ratio: Double,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    tab.splitTree = try tab.splitTree.resizing(at: path, ratio: ratio)
    catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  // MARK: - Pane address resolution (0008 M5)

  /// Resolves a `PaneID` to the full hierarchy address that owns it. Used by
  /// `PaneActionRouterFeature` to service pane-scoped intents (closeTab,
  /// moveTab, activateTab, equalizeTabSplits). Linear in total pane count —
  /// acceptable at the cardinalities we support; no secondary index needed
  /// yet. `nil` when the pane is unknown (closed mid-flight, stale callback).
  func addressOf(paneID: PaneID) -> (ProjectID, WorktreeID, TabID)? {
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return (project.id, worktree.id, tab.id)
        }
      }
    }
    return nil
  }

  // MARK: - Tab reordering (0008 M5)

  /// Moves a Tab inside its Worktree by `offset` positions. Positive shifts
  /// right, negative shifts left; the final index is clamped to the Worktree's
  /// tab-array bounds so the caller does not need to know the array length.
  /// Zero offset or clamped-to-identity is a silent no-op (no save scheduled).
  /// Persists via the standard debounced `store.scheduleSave` pipeline.
  func moveTab(
    _ tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    offset: Int
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    let count = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs.count
    // Ghostty's move_tab wraps cyclically: moving the last tab forward
    // places it first, moving the first backward places it last. Swift's
    // `%` on negative dividends returns a negative remainder, so pre-add
    // a multiple of `count` to land in [0, count).
    guard count > 0 else { return }
    let normalized = ((tabIndex + offset) % count + count) % count
    let target = normalized
    guard target != tabIndex else { return }
    let tab = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs.remove(at: tabIndex)
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs.insert(tab, at: target)
    store.scheduleSave(catalog)
  }

  // MARK: - Split equalization (0008 M5)

  /// Sets every split node's `ratio` inside the Tab's `SplitTree` to 0.5 so
  /// sibling panes render at equal sizes. Leaf-only trees are a silent
  /// no-op. Persists. The concept of a "weight=1 layout" in the design doc
  /// maps onto this ratio — touch-code's tree only carries per-split ratios,
  /// not per-leaf weights, so every balanced split is ratio == 0.5.
  func equalizeTabSplits(
    _ tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID
  ) throws {
    guard
      let (projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    var tab = catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex]
    guard let root = tab.splitTree.root else { return }
    let balanced = Self.balancingRatios(in: root)
    tab.splitTree = SplitTree(root: balanced, zoomed: tab.splitTree.zoomed)
    catalog.projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex] = tab
    store.scheduleSave(catalog)
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

  // MARK: - Pane resize (0008 M5)

  /// Adjusts the ratio of the closest ancestor split whose orientation
  /// matches `direction`. The ghostty RESIZE_SPLIT action carries a pixel
  /// amount (default keybinds are e.g. 10–20 px), but touch-code's split
  /// tree only stores ratios in `[0.1, 0.9]`. Adding the raw pixel value
  /// to a ratio collapses the split on the first keypress, so we scale
  /// the delta by `pixelsPerRatioStep` — an empirical divisor that maps
  /// a default 10 px keybind to a ~2.5% ratio nudge on a typical 400 px
  /// split. The viewport layer will later expose the real split frame
  /// via `ResizePaneOptions` so the divisor can become per-split.
  ///
  /// Direction semantics (matches ghostty's FocusDirection analog):
  /// - `.left`: grow the left child  → decrease ratio of nearest horizontal split
  /// - `.right`: grow the right child → increase ratio of nearest horizontal split
  /// - `.up`: grow the top child     → decrease ratio of nearest vertical split
  /// - `.down`: grow the bottom child → increase ratio of nearest vertical split
  ///
  /// Silent no-op when the pane is unknown or no ancestor split matches the
  /// direction (e.g. resize-left on a purely vertical column).
  func resizePane(_ paneID: PaneID, direction: ResizeDirection, amount: Double) throws {
    // Empirical px → ratio scale. See doc above.
    let pixelsPerRatioStep: Double = 400
    let ratioDelta = amount / pixelsPerRatioStep
    for projectIndex in catalog.projects.indices {
      for worktreeIndex in catalog.projects[projectIndex].worktrees.indices {
        let worktree = catalog.projects[projectIndex].worktrees[worktreeIndex]
        for tabIndex in worktree.tabs.indices
        where worktree.tabs[tabIndex].splitTree.contains(paneID) {
          var tab = worktree.tabs[tabIndex]
          guard let leafPath = tab.splitTree.path(to: paneID) else { return }
          let orientation: SplitTree<PaneID>.Direction =
            (direction == .left || direction == .right)
            ? .horizontal : .vertical
          guard
            let (ancestorPath, currentRatio, grewRight) = Self.findAncestorSplit(
              root: tab.splitTree.root,
              leafPath: leafPath,
              orientation: orientation
            )
          else { return }
          let grow: Bool = (direction == .right || direction == .down)
          let signedDelta = (grewRight == grow) ? ratioDelta : -ratioDelta
          let newRatio = currentRatio + signedDelta
          tab.splitTree = try tab.splitTree.resizing(at: ancestorPath, ratio: newRatio)
          catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab
          store.scheduleSave(catalog)
          return
        }
      }
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

  // MARK: - Worktree / Tab activation (M6)

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
    for (pi, project) in catalog.projects.enumerated() {
      for (wi, worktree) in project.worktrees.enumerated()
      where worktree.tabs.contains(where: { $0.id == id }) {
        catalog.projects[pi].worktrees[wi].selectedTabID = id
        store.scheduleSave(catalog)
        return
      }
    }
    throw HierarchyError.notFound("Tab \(id)")
  }

  // MARK: - Pane labels (canonical writer for C3 / C4)

  /// Update a Pane's `labels` set. **Single canonical writer** — every
  /// user-facing write path (the CLI's `tc pane label`, the hook action
  /// DSL's `HookAction.setPaneLabels`, any future UI) routes through this
  /// method. Keeps label mutations auditable and persists through the same
  /// `CatalogStore.scheduleSave` every other mutation uses.
  ///
  /// - Parameters:
  ///   - paneID: target Pane.
  ///   - labels: labels to apply.
  ///   - replace: when `true`, replaces the set entirely; when `false`,
  ///     union-merges with the existing set.
  /// - Throws: `HierarchyError.notFound` if the Pane id is unknown.
  func setPaneLabels(
    _ paneID: PaneID,
    labels: Set<String>,
    replace: Bool = false
  ) throws {
    for projectIndex in catalog.projects.indices {
      for worktreeIndex in catalog.projects[projectIndex].worktrees.indices {
        for tabIndex in catalog.projects[projectIndex].worktrees[worktreeIndex].tabs.indices {
          let panes = catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex].panes
          if let paneIndex = panes.firstIndex(where: { $0.id == paneID }) {
            var pane = panes[paneIndex]
            pane.labels = replace ? labels : pane.labels.union(labels)
            catalog.projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex].panes[paneIndex] = pane
            store.scheduleSave(catalog)
            return
          }
        }
      }
    }
    throw HierarchyError.notFound("Pane \(paneID)")
  }

  // MARK: - Phase 2: env resolution

  /// Resolves the merged environment for a Project's spawned subprocesses.
  /// Combines `ProcessInfo.processInfo.environment` with
  /// `Settings.projects[pid].envVars`; project-defined keys win on collision.
  /// Pure / nonisolated so M8 (PaneSurface env injection) and M9 (lifecycle
  /// script execution) can call it from off the main actor when convenient.
  nonisolated static func resolvedEnv(
    for projectID: ProjectID,
    in settings: Settings
  ) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    // Strip terminal-describing variables inherited from the parent process so
    // libghostty's own PTY-spawn TERM injection (`xterm-ghostty`) is what the
    // child shell sees. When touch-code.app is launched from a non-interactive
    // context (e.g. `make` → `open`, an IDE compile shell) parent `TERM=dumb`
    // would otherwise flow through `ghostty_surface_config.env_vars` and
    // override ghostty's value, breaking starship and other TUIs.
    for key in Self.inheritedTerminalEnvVarsToStrip {
      env.removeValue(forKey: key)
    }
    if let overrides = settings.projects[projectID]?.envVars {
      for (key, value) in overrides {
        env[key] = value
      }
    }
    env["TOUCH_CODE_SOCKET_PATH"] = SocketPaths.resolve()
    return env
  }

  nonisolated private static let inheritedTerminalEnvVarsToStrip: [String] = [
    "TERM", "TERMCAP", "TERMINFO", "COLORTERM",
  ]

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
