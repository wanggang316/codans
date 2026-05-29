import Foundation

public nonisolated struct Worktree: Equatable, Sendable, Identifiable {
  public var id: WorktreeID
  public var name: String
  public var path: String
  public var branch: String?
  public var tabs: [Tab]
  public var selectedTabID: TabID?
  /// App-layer soft-hide. `true` removes the Worktree from the main sidebar
  /// list without touching disk or git refs (see the Worktree Management
  /// spec). Defaults to `false`; pre-archive catalogs decode to `false` via
  /// `decodeIfPresent`, and the encode path omits the key when `false` so
  /// existing catalogs round-trip identically.
  public var archived: Bool
  /// User-marked "pinned" state. Pinned Worktrees render in their own section
  /// at the top of the Project's row group (below the main checkout). Defaults
  /// to `false`; pre-pin catalogs decode to `false` via `decodeIfPresent`, and
  /// the encode path omits the key when `false` so existing catalogs round-trip
  /// identically.
  public var isPinned: Bool

  public init(
    id: WorktreeID = WorktreeID(),
    name: String,
    path: String,
    branch: String? = nil,
    tabs: [Tab] = [],
    selectedTabID: TabID? = nil,
    archived: Bool = false,
    isPinned: Bool = false
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.branch = branch
    self.tabs = tabs
    self.selectedTabID = selectedTabID
    self.archived = archived
    self.isPinned = isPinned
  }
}

extension Worktree: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, path, branch, tabs, selectedTabID, archived, isPinned
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(WorktreeID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.path = try container.decode(String.self, forKey: .path)
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
    self.selectedTabID = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encode(tabs, forKey: .tabs)
    try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
    // Omit `archived` when false so pre-archive catalogs round-trip
    // identically (decode path uses `decodeIfPresent ?? false`).
    if archived {
      try container.encode(true, forKey: .archived)
    }
    if isPinned {
      try container.encode(true, forKey: .isPinned)
    }
  }
}
