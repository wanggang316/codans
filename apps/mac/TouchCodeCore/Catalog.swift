import Foundation

public nonisolated struct Catalog: Equatable, Sendable {
  public static let currentVersion = 3

  public var version: Int
  public var projects: [Project]
  public var tags: [Tag]
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

  /// On-disk location: `<AppDirectories.configDirectory>/catalog.json`
  /// (`~/.config/touch-code/catalog.json` for Release, `…/touch-code-dev/…`
  /// for Debug — see `AppDirectories`).
  public static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    AppDirectories.configDirectory(home: home)
      .appendingPathComponent("catalog.json", isDirectory: false)
  }
}

extension Catalog: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case version, projects, tags, activeTagFilter, projectSortMode, selectedProjectID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Catalog.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = Catalog.currentVersion
    self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
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

  /// Resolve a `PaneID` to the Project that currently hosts it, if any.
  /// Walks `projects → worktrees → tabs → panes` and returns the first
  /// match. Linear in the total pane count.
  public func projectID(forPane paneID: PaneID) -> ProjectID? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return project.id
        }
      }
    }
    return nil
  }

  /// Resolve a `PaneID` to the Worktree that currently hosts it, if any.
  /// Walks `projects → worktrees → tabs → panes` and returns the first
  /// match. Linear in the total pane count.
  public func worktreeID(forPane paneID: PaneID) -> WorktreeID? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return worktree.id
        }
      }
    }
    return nil
  }

  /// All `PaneID`s currently living under the given Worktree, flat across
  /// every tab. Returns an empty set if the Worktree is not in the catalog.
  public func paneIDs(inWorktree worktreeID: WorktreeID) -> Set<PaneID> {
    for project in projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else {
        continue
      }
      var ids: Set<PaneID> = []
      for tab in worktree.tabs {
        for pane in tab.panes { ids.insert(pane.id) }
      }
      return ids
    }
    return []
  }
}
