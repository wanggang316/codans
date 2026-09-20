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

  public var tabs: [Tab]
  public var selectedTabID: TabID?
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

  public init(
    id: WorktreeID = WorktreeID(),
    name: String,
    path: String,
    branch: String? = nil,
    headSHA: String? = nil,
    tabs: [Tab] = [],
    selectedTabID: TabID? = nil,
    archived: Bool = false,
    archivedAt: Date? = nil,
    isPinned: Bool = false,
    isNew: Bool = false
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.branch = branch
    self.headSHA = headSHA
    self.tabs = tabs
    self.selectedTabID = selectedTabID
    self.archived = archived
    self.archivedAt = archivedAt
    self.isPinned = isPinned
    self.isNew = isNew
  }
}

extension Worktree: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, path, branch, headSHA, tabs, selectedTabID, archived, archivedAt, isPinned, isNew
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(WorktreeID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.path = try container.decode(String.self, forKey: .path)
    self.headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA)
    self.tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
    self.selectedTabID = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    self.archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    self.isNew = try container.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(headSHA, forKey: .headSHA)
    try container.encode(tabs, forKey: .tabs)
    try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
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
