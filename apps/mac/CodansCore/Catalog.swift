import Foundation

public nonisolated struct Catalog: Equatable, Sendable {
  public static let currentVersion = 4
  /// Oldest on-disk version `CatalogLoader` can still lift to
  /// `currentVersion`. Anything older is refused outright.
  public static let oldestMigratableVersion = 3

  public var version: Int
  public var projects: [Project]
  public var tags: [Tag]
  public var sidebarFilter: SidebarFilter = .all
  public var activeTagFilter: TagFilter
  /// Sidebar-wide project ordering policy. The `projects` array always
  /// stores the manual order; `.joinOrder` and `.activeFirst` are
  /// derived sorts applied at render time.
  public var projectSortMode: ProjectSortMode
  /// Authoritative top-level "the user's current Project". Single-window
  /// simplification means there is exactly one such selection per app.
  /// The selection-stream resolver in `HierarchyClient` reads this first;
  /// it falls back to the first Project carrying a non-nil
  /// `selectedWorktreeID` only when this field is nil (initial-load path).
  public var selectedProjectID: ProjectID?

  public init(
    version: Int = Catalog.currentVersion,
    projects: [Project] = [],
    tags: [Tag] = [],
    activeTagFilter: TagFilter = .all,
    projectSortMode: ProjectSortMode = .default,
    selectedProjectID: ProjectID? = nil
  ) {
    self.version = version
    self.projects = projects
    self.tags = tags
    self.activeTagFilter = activeTagFilter
    self.projectSortMode = projectSortMode
    self.selectedProjectID = selectedProjectID
  }

  public static let empty = Catalog()

  /// On-disk location: `<AppDirectories.stateDirectory>/catalog.json`
  /// (`~/.codans/state/catalog.json` for Release, `~/.codans-dev/state/…`
  /// for Debug — see `AppDirectories`).
  public static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    AppDirectories.stateDirectory(home: home)
      .appendingPathComponent("catalog.json", isDirectory: false)
  }
}

extension Catalog: Codable {
  /// Why `init(from:)` refused a document before reading any record.
  /// Only `currentVersion` decodes here; the other versions are told
  /// apart so a store can migrate, open read-only, or refuse.
  public enum DecodingIssue: Error, Equatable {
    /// Older than `oldestMigratableVersion`.
    case unsupportedVersion(Int)
    /// Migratable through `CatalogLoader` / `CatalogMigrationV3ToV4`.
    case needsMigration(Int)
    /// Written by a newer build. The file must stay untouched.
    case newerVersion(Int)

    static func classify(_ version: Int) -> DecodingIssue? {
      switch version {
      case Catalog.currentVersion: return nil
      case ..<Catalog.oldestMigratableVersion: return .unsupportedVersion(version)
      case ..<Catalog.currentVersion: return .needsMigration(version)
      default: return .newerVersion(version)
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case version, projects, tags, activeTagFilter, sidebarFilter, projectSortMode, selectedProjectID
  }

  /// Reads the `version` field alone. A store asks this before a full
  /// decode so a document from a newer build is recognised as such even
  /// when its records no longer have this build's shape.
  public static func peekVersion(in data: Data) throws -> Int {
    try JSONDecoder().decode(VersionProbe.self, from: data).version
  }

  private struct VersionProbe: Decodable {
    let version: Int
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    if let issue = DecodingIssue.classify(version) {
      throw issue
    }
    self.version = Catalog.currentVersion
    self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
    self.sidebarFilter = try container.decodeIfPresent(SidebarFilter.self, forKey: .sidebarFilter) ?? .all
    self.tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    self.activeTagFilter =
      try container.decodeIfPresent(TagFilter.self, forKey: .activeTagFilter) ?? .all
    self.projectSortMode =
      try container.decodeIfPresent(ProjectSortMode.self, forKey: .projectSortMode) ?? .default
    self.selectedProjectID =
      try container.decodeIfPresent(ProjectID.self, forKey: .selectedProjectID)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if sidebarFilter != .all {
      try container.encode(sidebarFilter, forKey: .sidebarFilter)
    }
    try container.encode(version, forKey: .version)
    try container.encode(projects, forKey: .projects)
    try container.encode(tags, forKey: .tags)
    // Omit `activeTagFilter` when it's the default `.all` — keeps the
    // common no-filter case from churning the on-disk JSON.
    if activeTagFilter != .all {
      try container.encode(activeTagFilter, forKey: .activeTagFilter)
    }
    // Same rationale: omit when default so existing catalogs stay
    // byte-identical on round-trip.
    if projectSortMode != .default {
      try container.encode(projectSortMode, forKey: .projectSortMode)
    }
    try container.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
  }
}

extension Catalog {
  /// Apply `projectSortMode` to a (possibly pre-filtered) Project list.
  /// Each mode sorts by its dedicated field — `addedAt` for
  /// `.joinOrder`, `lastActiveAt` for `.activeFirst`, `manualOrder`
  /// for `.manual` — with the incoming array order as the stable
  /// tiebreaker so the result is fully deterministic.
  public func sorted(_ projects: [Project]) -> [Project] {
    switch projectSortMode {
    case .manual:
      // Sort by the user-curated `manualOrder` field ASC. Legacy /
      // never-stamped projects all carry `0` and tie-break on incoming
      // array position, which equals the historical sidebar order.
      return projects.enumerated()
        .sorted { lhs, rhs in
          if lhs.element.manualOrder != rhs.element.manualOrder {
            return lhs.element.manualOrder < rhs.element.manualOrder
          }
          return lhs.offset < rhs.offset
        }
        .map { $0.element }
    case .joinOrder:
      // Stable sort by addedAt ASC; ties (including the `.distantPast`
      // legacy bucket) preserve incoming array order.
      return projects.enumerated()
        .sorted { lhs, rhs in
          if lhs.element.addedAt != rhs.element.addedAt {
            return lhs.element.addedAt < rhs.element.addedAt
          }
          return lhs.offset < rhs.offset
        }
        .map { $0.element }
    case .activeFirst:
      // Most-recently-active first. Projects with `nil` lastActiveAt
      // sink to the bottom and break ties by addedAt ASC (so the user
      // sees a sensible "everything else, oldest first" tail).
      return projects.enumerated()
        .sorted { lhs, rhs in
          switch (lhs.element.lastActiveAt, rhs.element.lastActiveAt) {
          case (let l?, let r?):
            if l != r { return l > r }
          case (.some, .none):
            return true
          case (.none, .some):
            return false
          case (.none, .none):
            break
          }
          if lhs.element.addedAt != rhs.element.addedAt {
            return lhs.element.addedAt < rhs.element.addedAt
          }
          return lhs.offset < rhs.offset
        }
        .map { $0.element }
    }
  }
}

// MARK: - Layout invariants

extension Catalog {
  public enum LayoutIssue: Error, Equatable {
    case inconsistentWorktree(WorktreeID, Worktree.InvariantError)
  }

  /// Every Worktree satisfies `Worktree.validateInvariants()`. Decoding
  /// repairs dangling selection and focus only; a loader or migrator
  /// calls this and rejects the whole document otherwise.
  public func validateLayouts() throws {
    for project in projects {
      for worktree in project.worktrees {
        do {
          try worktree.validateInvariants()
        } catch let issue as Worktree.InvariantError {
          throw LayoutIssue.inconsistentWorktree(worktree.id, issue)
        }
      }
    }
  }
}
