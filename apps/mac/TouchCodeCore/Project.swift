import Foundation

/// Per-Project health signal driven at runtime by `ProjectReconciler`.
/// Intentionally **transient** — not encoded into `catalog.json`. Every decode
/// produces `.loading`; the reconciler transitions the value on its first pass
/// after launch (and on window focus / Retry). Keeping this out of `Codable`
/// avoids a catalog-schema bump and keeps pre-existing catalogs round-trip
/// identical.
public nonisolated enum ProjectLoadState: Equatable, Sendable {
  case loading
  case ready
  case failed(reason: String)
}

public nonisolated struct Project: Equatable, Sendable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var rootPath: String
  public var gitRoot: String?
  public var worktrees: [Worktree]
  public var selectedWorktreeID: WorktreeID?
  /// Sidebar disclosure state for this Project's worktree group. Defaults to
  /// `true` so newly added Projects reveal their worktrees immediately.
  /// Persisted via the standard catalog save pipeline so the open/closed
  /// choice survives app restarts.
  public var isExpanded: Bool
  /// User-assigned tag membership. Set semantics in memory; encoded as a
  /// sorted `[TagID]` so `git diff catalog.json` is order-stable. Default
  /// empty — projects start untagged.
  public var tagIDs: Set<TagID>
  /// Wall-clock timestamp at which this Project was added to the catalog.
  /// Used by `ProjectSortMode.joinOrder` to render an ordering stable
  /// across manual reordering — i.e. so the user can switch back from
  /// `.manual` to `.joinOrder` and get the original insertion order.
  /// Legacy catalogs that predate this field decode to `.distantPast`;
  /// they tie and fall back to array-position order, which equals
  /// insertion order at the time the file was first written.
  public var addedAt: Date
  /// Most-recent activity timestamp. Bumped on (a) inbox-notification
  /// arrival for any worktree of this Project, and (b) any input the
  /// app dispatches into a pane of this Project. `nil` = never active;
  /// `ProjectSortMode.activeFirst` puts these at the bottom.
  public var lastActiveAt: Date?
  /// User-curated ordering key consumed by `ProjectSortMode.manual`.
  /// Auto-incremented at `addProject` time so new projects land at the
  /// end of the manual list; rewritten en bloc when the user confirms
  /// the manual-sort sheet. Legacy projects decode to `0` and tie-break
  /// on their `catalog.projects` array position, which equals their
  /// historical sidebar order — i.e. a no-op upgrade.
  public var manualOrder: Int
  /// User-assigned Project accent. `nil` = no color (system accent).
  /// Edited via Settings → Projects → General. Encoded only when set so
  /// catalogs without a color stay byte-identical on round-trip.
  public var color: ProjectColor?
  /// Transient. See `ProjectLoadState` doc-comment.
  public var loadState: ProjectLoadState

  public init(
    id: ProjectID = ProjectID(),
    name: String,
    rootPath: String,
    gitRoot: String? = nil,
    worktrees: [Worktree] = [],
    selectedWorktreeID: WorktreeID? = nil,
    isExpanded: Bool = true,
    tagIDs: Set<TagID> = [],
    addedAt: Date = Date(),
    lastActiveAt: Date? = nil,
    manualOrder: Int = 0,
    color: ProjectColor? = nil,
    loadState: ProjectLoadState = .loading
  ) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.gitRoot = gitRoot
    self.worktrees = worktrees
    self.selectedWorktreeID = selectedWorktreeID
    self.isExpanded = isExpanded
    self.tagIDs = tagIDs
    self.addedAt = addedAt
    self.lastActiveAt = lastActiveAt
    self.manualOrder = manualOrder
    self.color = color
    self.loadState = loadState
  }

  /// A Project supports Git-backed Worktree operations only when it has a resolved git root.
  /// For non-git Projects, the UI presents a single synthetic Worktree (`Project.rootPath`)
  /// and the "Add Worktree" affordance is suppressed.
  public var supportsWorktrees: Bool { gitRoot != nil }
}

extension Project: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, rootPath, gitRoot, worktrees, selectedWorktreeID, isExpanded, tagIDs,
      addedAt, lastActiveAt, manualOrder, color
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(ProjectID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.rootPath = try container.decode(String.self, forKey: .rootPath)
    self.gitRoot = try container.decodeIfPresent(String.self, forKey: .gitRoot)
    self.worktrees = try container.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
    self.selectedWorktreeID = try container.decodeIfPresent(WorktreeID.self, forKey: .selectedWorktreeID)
    self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    let tagIDArray = try container.decodeIfPresent([TagID].self, forKey: .tagIDs) ?? []
    self.tagIDs = Set(tagIDArray)
    // Legacy catalogs ship without `addedAt`; fall back to `.distantPast`
    // so joinOrder sorts produce a stable result (ties broken by array
    // position, which equals the original insertion order).
    self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
    self.lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    self.manualOrder = try container.decodeIfPresent(Int.self, forKey: .manualOrder) ?? 0
    self.color = try container.decodeIfPresent(ProjectColor.self, forKey: .color)
    self.loadState = .loading
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encodeIfPresent(gitRoot, forKey: .gitRoot)
    try container.encode(worktrees, forKey: .worktrees)
    try container.encodeIfPresent(selectedWorktreeID, forKey: .selectedWorktreeID)
    // Only emit `isExpanded` when collapsed — keeps the common case
    // (expanded) byte-identical on round-trip.
    if !isExpanded {
      try container.encode(false, forKey: .isExpanded)
    }
    // Stable on-disk ordering for set-typed memory: sort by raw UUID string.
    // Omit the key entirely when the project carries no tags.
    if !tagIDs.isEmpty {
      let sorted = tagIDs.sorted { $0.raw.uuidString < $1.raw.uuidString }
      try container.encode(sorted, forKey: .tagIDs)
    }
    // Sentinel addedAt (from legacy decode) is omitted so legacy
    // catalogs stay byte-identical until something actually populates
    // the timestamp.
    if addedAt != .distantPast {
      try container.encode(addedAt, forKey: .addedAt)
    }
    try container.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
    // Sentinel manualOrder (legacy decode or never-stamped) is omitted
    // so unmigrated catalogs stay byte-identical until something writes
    // a real value.
    if manualOrder != 0 {
      try container.encode(manualOrder, forKey: .manualOrder)
    }
    try container.encodeIfPresent(color, forKey: .color)
    // `loadState` intentionally not encoded (transient).
  }
}
