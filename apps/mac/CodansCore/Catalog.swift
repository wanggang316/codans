import Foundation

public nonisolated struct Catalog: Equatable, Sendable {
  public static let currentVersion = 5
  /// Oldest version this build still reads; it is migrated on load.
  public static let oldestReadableVersion = 3

  /// Version of the decoded file. Lower than `currentVersion` until the
  /// catalog migrations have run; always `currentVersion` when built in
  /// memory.
  public var version: Int
  /// The Project order: the sidebar shows Projects in this array order
  /// (ADR 0001).
  public var projects: [Project]
  /// The Host list: every Host that Server projects can refer to, in the
  /// order of addition. `HierarchyManager` is its only writer; change it
  /// through the `Catalog+Hosts` operations so `Project.remoteHost` stays
  /// resolved. See ADR 0003.
  public var hosts: [HostRecord]
  public var tags: [Tag]
  /// Sidebar Host rows the user closed (ADR 0003, decision 7). A Host that
  /// is not in the set is open, so a new Host shows its Projects.
  public var collapsedSidebarHosts: Set<SidebarHost> = []
  public var sidebarFilter: SidebarFilter = .all
  public var activeTagFilter: TagFilter
  /// Authoritative top-level "the user's current Project". Single-window
  /// simplification means there is exactly one such selection per app.
  /// The selection-stream resolver in `HierarchyClient` reads this first;
  /// it falls back to the first Project carrying a non-nil
  /// `selectedWorktreeID` only when this field is nil (initial-load path).
  public var selectedProjectID: ProjectID?

  public init(
    version: Int = Catalog.currentVersion,
    projects: [Project] = [],
    hosts: [HostRecord] = [],
    tags: [Tag] = [],
    activeTagFilter: TagFilter = .all,
    selectedProjectID: ProjectID? = nil
  ) {
    self.version = version
    self.projects = projects
    self.hosts = hosts
    self.tags = tags
    self.activeTagFilter = activeTagFilter
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
  public enum DecodingIssue: Error, Equatable {
    /// Retired version this build no longer reads.
    case unsupportedVersion(Int)
    /// Written by a newer build. The file must stay as it is.
    case newerVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case version, projects, hosts, collapsedSidebarHosts, tags, activeTagFilter, sidebarFilter
    case selectedProjectID
    /// Retired (ADR 0001). Read only to materialize the order one time.
    case projectSortMode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version <= Catalog.currentVersion else {
      throw DecodingIssue.newerVersion(version)
    }
    guard version >= Catalog.oldestReadableVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    // Versions 3 and 4 have the same shape minus later fields (Workspace
    // groups, the Host list), which decode to their defaults; the store then
    // runs the migrations.
    self.version = version
    let projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
    // A catalog written before ADR 0001 can still name a sort mode. Sort
    // one time so the user sees the same order; the next save drops it.
    let legacySortMode = try? container.decodeIfPresent(String.self, forKey: .projectSortMode)
    let manualOrders =
      legacySortMode == LegacyProjectOrder.manual
      ? (try? container.decodeIfPresent([LegacyProjectOrder.Fields].self, forKey: .projects))?
        .map(\.manualOrder)
      : nil
    self.projects = LegacyProjectOrder.materialize(
      projects, sortMode: legacySortMode, manualOrders: manualOrders ?? [])
    self.hosts = try container.decodeIfPresent([HostRecord].self, forKey: .hosts) ?? []
    self.collapsedSidebarHosts = Set(
      try container.decodeIfPresent([SidebarHost].self, forKey: .collapsedSidebarHosts) ?? [])
    self.sidebarFilter = try container.decodeIfPresent(SidebarFilter.self, forKey: .sidebarFilter) ?? .all
    self.tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    self.activeTagFilter =
      try container.decodeIfPresent(TagFilter.self, forKey: .activeTagFilter) ?? .all
    self.selectedProjectID =
      try container.decodeIfPresent(ProjectID.self, forKey: .selectedProjectID)
    resolveHostReferences()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if sidebarFilter != .all {
      try container.encode(sidebarFilter, forKey: .sidebarFilter)
    }
    try container.encode(version, forKey: .version)
    try container.encode(projects, forKey: .projects)
    try container.encode(hosts, forKey: .hosts)
    // Omitted while every Host is open; sorted so the file is order-stable.
    if !collapsedSidebarHosts.isEmpty {
      try container.encode(collapsedSidebarHosts.sorted { $0.key < $1.key }, forKey: .collapsedSidebarHosts)
    }
    try container.encode(tags, forKey: .tags)
    // Omit `activeTagFilter` when it's the default `.all` — keeps the
    // common no-filter case from churning the on-disk JSON.
    if activeTagFilter != .all {
      try container.encode(activeTagFilter, forKey: .activeTagFilter)
    }
    try container.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
  }
}

extension Catalog {
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

  /// Resolve a `PaneID` to the Tab that currently hosts it, if any.
  /// Walks `projects → worktrees → tabs → panes` and returns the first
  /// match. Linear in the total pane count.
  public func tabID(forPane paneID: PaneID) -> TabID? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return tab.id
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

  /// Every `PaneID` currently in the catalog, flat across all projects,
  /// worktrees, and tabs. Linear in the total pane count. Used by the
  /// AgentState registry's membership reconcile to detect bound entries
  /// whose pane has left the hierarchy (see
  /// `AgentStateStore.reconcileMembership`).
  public func allPaneIDs() -> Set<PaneID> {
    var ids: Set<PaneID> = []
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          for pane in tab.panes { ids.insert(pane.id) }
        }
      }
    }
    return ids
  }

  /// Every `PaneID` in a non-archived (visible) worktree, flat across all
  /// projects. Differs from `allPaneIDs()` only by skipping archived
  /// worktrees. The AgentState registry's membership reconcile uses this so
  /// a soft-hidden worktree's panes count as "gone": archive kills their
  /// daemons, so their agent rows must retire — even though the Pane stays
  /// in the catalog for restore (see `AgentStateStore.reconcileMembership`).
  public func visiblePaneIDs() -> Set<PaneID> {
    var ids: Set<PaneID> = []
    for project in projects {
      for worktree in project.worktrees where !worktree.archived {
        for tab in worktree.tabs {
          for pane in tab.panes { ids.insert(pane.id) }
        }
      }
    }
    return ids
  }
}
