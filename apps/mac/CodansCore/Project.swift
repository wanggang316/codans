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
  /// User-set display override. `nil` means the project shows under its
  /// canonical name — the last path component of `rootPath`. Renaming via
  /// Settings → General → Name writes here; clearing the field writes `nil`.
  /// Persistence-only; `name` is still the right thing to read at call sites.
  public var displayName: String?
  /// For a local project, the canonical local root path. For a Server project
  /// (`remoteHost != nil`), the **remote** absolute path on the host — the same
  /// string plumbing carries it, but it is never a valid local filesystem path,
  /// so local-FS operations must be gated on `isRemote`.
  public var rootPath: String
  /// Resolved git repository root. For a Server project this is a **remote** path
  /// string (discovered over SSH), `nil` when the remote root is a plain folder.
  public var gitRoot: String?
  /// SSH destination this project lives on. `nil` = local. When set, `rootPath` /
  /// `gitRoot` / each `Worktree.path` are remote path strings and terminals/git
  /// run over SSH. See `RemoteHost`.
  public var remoteHost: RemoteHost?
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
    remoteHost: RemoteHost? = nil,
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
    self.rootPath = rootPath
    // Compress the legacy `name:` argument into the canonical/override split.
    // A value equal to the canonical (or empty) means "no override" — keeps
    // every existing caller (tests, addProject) source-compatible while the
    // semantics of `Project.name` move under the hood.
    let canonical = (rootPath as NSString).lastPathComponent
    self.displayName = (name.isEmpty || name == canonical) ? nil : name
    self.gitRoot = gitRoot
    self.remoteHost = remoteHost
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
  /// and the "Add Worktree" affordance is suppressed. Holds for remote git repos too — a
  /// Server project with a resolved (remote) git root supports worktree operations over SSH.
  public var supportsWorktrees: Bool { gitRoot != nil }

  /// True for a Server project — its `rootPath` / `gitRoot` / worktree paths are
  /// remote, and terminals / git run over SSH. Local-filesystem operations
  /// (`FileManager`, `URL(fileURLWithPath:)`, symlink resolution, reveal-in-Finder)
  /// must be gated on this being `false`.
  public var isRemote: Bool { remoteHost != nil }

  /// Path-derived fallback name. Identical to `name` when the user hasn't
  /// set a custom `displayName`. Worktree base-directory resolution uses
  /// this so renaming a project never relocates its worktrees on disk.
  public var canonicalName: String {
    (rootPath as NSString).lastPathComponent
  }

  /// Effective name shown in sidebars, the Settings header, and any other
  /// label surface. Reads through the override → canonical chain so a
  /// `nil` `displayName` transparently renders as the canonical name.
  public var name: String { displayName ?? canonicalName }
}

extension Project: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, displayName, rootPath, gitRoot, remoteHost, worktrees, selectedWorktreeID,
      isExpanded, tagIDs, addedAt, lastActiveAt, manualOrder, color
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(ProjectID.self, forKey: .id)
    self.rootPath = try container.decode(String.self, forKey: .rootPath)
    // Migration: prefer the explicit `displayName` key when present. Fall back
    // to the legacy `name` field — keeping it as the override only when it
    // differs from the canonical path-derived name (else it's redundant and
    // gets normalized away).
    let canonicalForDecode = (self.rootPath as NSString).lastPathComponent
    if let explicit = try container.decodeIfPresent(String.self, forKey: .displayName) {
      self.displayName = explicit.isEmpty ? nil : explicit
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .name) {
      self.displayName = (legacy.isEmpty || legacy == canonicalForDecode) ? nil : legacy
    } else {
      self.displayName = nil
    }
    self.gitRoot = try container.decodeIfPresent(String.self, forKey: .gitRoot)
    self.remoteHost = try container.decodeIfPresent(RemoteHost.self, forKey: .remoteHost)
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
    // `name` is written verbatim as the effective (computed) name so older
    // builds that don't know about `displayName` still render the project
    // under the right label. `displayName` is the source of truth on read.
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encodeIfPresent(gitRoot, forKey: .gitRoot)
    // Only emit `remoteHost` for Server projects — keeps existing local catalogs
    // byte-identical on round-trip.
    try container.encodeIfPresent(remoteHost, forKey: .remoteHost)
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
