import Foundation

public nonisolated struct Worktree: Equatable, Sendable, Identifiable {
  public var id: WorktreeID
  public var name: String
  public var path: String
  public var branch: String?
  /// HEAD commit of the worktree's checkout, as reported by
  /// `git worktree list --porcelain` (full 40-char SHA). The only way to
  /// identify a detached worktree (`branch == nil`): the sidebar renders it
  /// as "Detached HEAD @<short>". `nil` when unknown — synthetic non-git
  /// worktrees, and pre-existing catalogs until the next reconcile. Updated
  /// in place by `reconcileDiscoveredWorktrees` on every launch / focus
  /// pulse, so a detached worktree whose HEAD moved (e.g. a Codex sandbox
  /// committing onto its base) re-renders with the new SHA.
  /// Encode omits the key when `nil` so existing catalogs round-trip
  /// identically.
  public var headSHA: String?

  /// Layout of the content area: a split tree whose leaves are the ids of
  /// `panes`. See `validateInvariants()` for the relationship between the
  /// three layout fields.
  public var splitTree: SplitTree<PaneID>
  public var panes: [Pane]
  /// The Pane that receives keyboard input and Tab-level shortcuts. Set
  /// iff `panes` is non-empty.
  public var focusedPaneID: PaneID?
  /// App-layer soft-hide. `true` removes the Worktree from the main sidebar
  /// list without touching disk or git refs (see the Worktree Management
  /// spec). Defaults to `false`; pre-archive catalogs decode to `false` via
  /// `decodeIfPresent`, and the encode path omits the key when `false` so
  /// existing catalogs round-trip identically.
  public var archived: Bool
  /// When the Worktree was archived (the moment `archived` last flipped to
  /// `true`). Drives the Settings → Worktrees → Cleanup "auto-delete after N
  /// days" sweep. `nil` when the Worktree is not archived; cleared back to
  /// `nil` on unarchive. Pre-existing archived catalogs decode to `nil` (no
  /// known timestamp) and are lazily back-filled with the current time the
  /// first time the sweep observes them, so they are never deleted retroactively.
  /// The encode path omits the key when `nil` so existing catalogs round-trip
  /// identically.
  public var archivedAt: Date?
  /// User-marked "pinned" state. Pinned Worktrees render in their own section
  /// at the top of the Project's row group (below the main checkout). Defaults
  /// to `false`; pre-pin catalogs decode to `false` via `decodeIfPresent`, and
  /// the encode path omits the key when `false` so existing catalogs round-trip
  /// identically.
  public var isPinned: Bool
  /// A fresh, never-opened Worktree created with auto-switch OFF. Cleared the
  /// first time the user selects the Worktree. Defaults to `false`; pre-existing
  /// catalogs decode to `false` via `decodeIfPresent`, and the encode path omits
  /// the key when `false` so existing catalogs round-trip identically.
  public var isNew: Bool
  /// Absolute root of the repository this row's checkout belongs to, when it
  /// is not the owning Project's `gitRoot` — set on workspace child rows,
  /// whose checkouts come from other repositories. Read through
  /// `Project.repoRoot(for:)`, never directly. Refreshed from git on every
  /// reconcile so a stripped or stale value self-heals. `nil` for ordinary
  /// worktrees; the encode path omits the key so existing catalogs
  /// round-trip identically.
  public var sourceGitRoot: String?

  public init(
    id: WorktreeID = WorktreeID(),
    name: String,
    path: String,
    branch: String? = nil,
    headSHA: String? = nil,
    splitTree: SplitTree<PaneID> = SplitTree(),
    panes: [Pane] = [],
    focusedPaneID: PaneID? = nil,
    archived: Bool = false,
    archivedAt: Date? = nil,
    isPinned: Bool = false,
    isNew: Bool = false,
    sourceGitRoot: String? = nil
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.branch = branch
    self.headSHA = headSHA
    self.splitTree = splitTree
    self.panes = panes
    self.focusedPaneID = focusedPaneID
    self.archived = archived
    self.archivedAt = archivedAt
    self.isPinned = isPinned
    self.isNew = isNew
    self.sourceGitRoot = sourceGitRoot
  }
}

// MARK: - Layout lookups

extension Worktree {
  public var focusedPane: Pane? {
    guard let focusedPaneID else { return nil }
    return pane(focusedPaneID)
  }

  public func pane(_ id: PaneID) -> Pane? {
    panes.first { $0.id == id }
  }

  public func pane(forTab tabID: TabID) -> Pane? {
    panes.first { pane in pane.tabs.contains { $0.id == tabID } }
  }

  public func pane(forContent contentID: ContentID) -> Pane? {
    panes.first { pane in pane.tabs.contains { $0.content.id == contentID } }
  }

  public func tab(_ id: TabID) -> Tab? {
    for pane in panes {
      if let tab = pane.tab(id) { return tab }
    }
    return nil
  }

  public func tab(forContent contentID: ContentID) -> Tab? {
    for pane in panes {
      if let tab = pane.tab(forContent: contentID) { return tab }
    }
    return nil
  }

  /// Every Tab of the Worktree, Pane by Pane in `panes` order.
  public var allTabs: [Tab] { panes.flatMap(\.tabs) }
  public var tabIDs: [TabID] { allTabs.map(\.id) }
  public var contentIDs: [ContentID] { allTabs.map(\.content.id) }
}

// MARK: - Invariants

extension Worktree {
  public enum InvariantError: Error, Equatable {
    case duplicatePaneIDs
    case leavesDoNotMatchPanes(leaves: Set<PaneID>, panes: Set<PaneID>)
    case emptyPane(PaneID)
    /// `selectedTabID` is nil or names no Tab of that Pane.
    case unresolvedSelection(PaneID)
    /// Panes exist but nothing is focused.
    case missingFocus
    /// `focusedPaneID` names no Pane.
    case danglingFocus(PaneID)
    case duplicateTabIDs
    case duplicateContentIDs
  }

  public var isConsistent: Bool {
    (try? validateInvariants()) != nil
  }

  /// Split-tree leaves equal the Pane id set with no duplicates; no Pane is
  /// empty; every selection resolves inside its Pane; the focus exists iff
  /// Panes exist and resolves; Tab ids and Content ids are unique.
  public func validateInvariants() throws {
    let paneIDs = Set(panes.map(\.id))
    guard paneIDs.count == panes.count else { throw InvariantError.duplicatePaneIDs }
    let leaves = Set(splitTree.leaves())
    if leaves != paneIDs { throw InvariantError.leavesDoNotMatchPanes(leaves: leaves, panes: paneIDs) }
    for pane in panes {
      if pane.tabs.isEmpty { throw InvariantError.emptyPane(pane.id) }
      if !pane.hasResolvedSelection { throw InvariantError.unresolvedSelection(pane.id) }
    }
    switch focusedPaneID {
    case nil where !panes.isEmpty:
      throw InvariantError.missingFocus
    case let focused? where !paneIDs.contains(focused):
      throw InvariantError.danglingFocus(focused)
    default:
      break
    }
    let tabs = allTabs
    guard Set(tabs.map(\.id)).count == tabs.count else { throw InvariantError.duplicateTabIDs }
    guard Set(tabs.map(\.content.id)).count == tabs.count else { throw InvariantError.duplicateContentIDs }
  }
}

// MARK: - Codable

extension Worktree: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, path, branch, headSHA, splitTree, panes, focusedPaneID, archived, archivedAt, isPinned,
      isNew, sourceGitRoot
  }

  /// Repairs dangling references only: a Pane whose Tabs all dropped
  /// leaves with its split-tree leaf (counted through `CatalogDecodeLoss`),
  /// and a missing or dangling focus falls back to the first Pane. The
  /// tree and the Pane list are otherwise taken as written; the loader
  /// gates on `isConsistent`.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(WorktreeID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.path = try container.decode(String.self, forKey: .path)
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA)
    var splitTree = try container.decodeIfPresent(SplitTree<PaneID>.self, forKey: .splitTree) ?? SplitTree()
    var panes: [Pane] = []
    let loss = CatalogDecodeLoss.collector(in: decoder)
    for pane in try container.decodeIfPresent([Pane].self, forKey: .panes) ?? [] {
      if pane.tabs.isEmpty {
        splitTree = splitTree.removing(pane.id)
        loss?.recordDroppedPane()
      } else {
        panes.append(pane)
      }
    }
    self.splitTree = splitTree
    self.panes = panes
    let storedFocus = try container.decodeIfPresent(PaneID.self, forKey: .focusedPaneID)
    self.focusedPaneID =
      storedFocus.flatMap { id in panes.contains { $0.id == id } ? id : nil } ?? panes.first?.id
    self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    self.archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    self.isNew = try container.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
    self.sourceGitRoot = try container.decodeIfPresent(String.self, forKey: .sourceGitRoot)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encodeIfPresent(headSHA, forKey: .headSHA)
    // Omit the layout keys for a Worktree without Panes.
    if !splitTree.isEmpty {
      try container.encode(splitTree, forKey: .splitTree)
    }
    if !panes.isEmpty {
      try container.encode(panes, forKey: .panes)
    }
    try container.encodeIfPresent(focusedPaneID, forKey: .focusedPaneID)
    // Omit `archived` when false so pre-archive catalogs round-trip
    // identically (decode path uses `decodeIfPresent ?? false`).
    if archived {
      try container.encode(true, forKey: .archived)
    }
    // Omit `archivedAt` when nil (not archived / unknown) so non-archived
    // and pre-existing catalogs round-trip identically.
    try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
    if isPinned {
      try container.encode(true, forKey: .isPinned)
    }
    if isNew {
      try container.encode(true, forKey: .isNew)
    }
    // Omit when nil so ordinary worktrees round-trip identically.
    try container.encodeIfPresent(sourceGitRoot, forKey: .sourceGitRoot)
  }
}

extension Worktree {
  /// Secondary-line title for a detached checkout: "Detached HEAD @<7-char
  /// SHA>". `nil` unless `branch == nil` **and** the HEAD commit is known —
  /// synthetic non-git worktrees (`branch == nil`, no SHA) stay single-line.
  /// Shared by the sidebar row and the WorktreeHeader so both surfaces name
  /// a detached checkout identically.
  public var detachedHeadTitle: String? {
    guard branch == nil, let headSHA, !headSHA.isEmpty else { return nil }
    return "Detached HEAD @\(String(headSHA.prefix(7)))"
  }
}
