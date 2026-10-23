import Foundation

/// Lifts a version 3 catalog (Worktree → Tab → split tree of session
/// Panes) to version 4 (Worktree → split tree of Panes → Tab → Content).
///
/// Per Worktree:
/// 1. The selected former Tab's split tree becomes the Worktree's split
///    tree, one single-Tab Pane per leaf; ratios and directions are kept,
///    the leaf ids are fresh `PaneID`s.
/// 2. The sessions of the other former Tabs are appended, in former-Tab
///    order, to the focused Pane's strip; a multi-leaf former Tab is
///    fanned out in leaf order. The focused Pane holds the former Tab's
///    zoomed leaf (the focus marker of the old layout), else its first
///    leaf.
/// 3. A session's UUID becomes its `ContentID` unchanged; `TabID`s and
///    `PaneID`s are fresh.
/// 4. A former Tab's name / cachedDisplayTitle / color / icon / iconLock
///    go to the Tab of its first session.
/// 5. Zoom state and former Tabs without sessions are dropped; a nil or
///    dangling `selectedTabID` falls back to the first former Tab with
///    sessions; a Worktree without sessions has no Panes and no focus.
/// 6. Any unreadable record fails the whole migration: nothing partial is
///    returned.
///
/// Every other field passes through unchanged. The result satisfies
/// `Catalog.validateLayouts()`.
public nonisolated enum CatalogMigrationV3ToV4 {
  public static let sourceVersion = 3

  public enum Failure: Error, Equatable {
    /// The document's `version` is not 3.
    case notVersion3(Int)
  }

  /// Pure: reads `data`, returns the v4 catalog or throws. A record that
  /// does not decode surfaces as the `DecodingError` it raised; a result
  /// that would break a Worktree invariant as `Catalog.LayoutIssue`.
  public static func migrate(v3 data: Data) throws -> Catalog {
    let legacy = try JSONDecoder().decode(LegacyCatalogV3.self, from: data)
    let catalog = migrate(legacy)
    try catalog.validateLayouts()
    return catalog
  }

  private static func migrate(_ legacy: LegacyCatalogV3) -> Catalog {
    Catalog(
      version: Catalog.currentVersion,
      projects: legacy.projects.map { project in
        var migrated = project.base
        migrated.worktrees = project.worktrees.map(migrate)
        return migrated
      },
      tags: legacy.tags,
      activeTagFilter: legacy.activeTagFilter,
      projectSortMode: legacy.projectSortMode,
      selectedProjectID: legacy.selectedProjectID,
    )
  }

  private static func migrate(_ legacy: LegacyWorktreeV3) -> Worktree {
    var worktree = legacy.base
    let formerTabs = legacy.tabs.filter { !$0.sessions.isEmpty }
    guard
      let layoutIndex = formerTabs.firstIndex(where: { $0.id == legacy.selectedTabID })
        ?? formerTabs.indices.first
    else {
      return worktree
    }
    let layout = formerTabs[layoutIndex].layout()
    var panes = layout.panes
    let focusedIndex = panes.firstIndex { $0.id == layout.focusedPaneID } ?? 0
    for (index, formerTab) in formerTabs.enumerated() where index != layoutIndex {
      panes[focusedIndex].tabs.append(contentsOf: formerTab.tabs())
    }
    worktree.splitTree = layout.splitTree
    worktree.panes = panes
    worktree.focusedPaneID = panes[focusedIndex].id
    return worktree
  }
}

// MARK: - Legacy v3 shape

/// The v3 document differs from v4 only below the Worktree: a Worktree
/// carries `tabs` + `selectedTabID` instead of `splitTree` + `panes` +
/// `focusedPaneID`, and a former Tab carries a split tree of session
/// records. Each mirror decodes the fields the v4 type still has through
/// the v4 decoder, so pass-through is by construction, and reads only the
/// retired keys itself.
private struct LegacyCatalogV3: Decodable {
  let projects: [LegacyProjectV3]
  let tags: [Tag]
  let activeTagFilter: TagFilter
  let projectSortMode: ProjectSortMode
  let selectedProjectID: ProjectID?

  private enum CodingKeys: String, CodingKey {
    case version, projects, tags, activeTagFilter, projectSortMode, selectedProjectID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == CatalogMigrationV3ToV4.sourceVersion else {
      throw CatalogMigrationV3ToV4.Failure.notVersion3(version)
    }
    self.projects = try container.decodeIfPresent([LegacyProjectV3].self, forKey: .projects) ?? []
    self.tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    self.activeTagFilter = try container.decodeIfPresent(TagFilter.self, forKey: .activeTagFilter) ?? .all
    self.projectSortMode =
      try container.decodeIfPresent(ProjectSortMode.self, forKey: .projectSortMode) ?? .default
    self.selectedProjectID = try container.decodeIfPresent(ProjectID.self, forKey: .selectedProjectID)
  }
}

private struct LegacyProjectV3: Decodable {
  /// The Project with its v3 Worktrees decoded as layout-less v4 ones;
  /// `worktrees` replaces them.
  let base: Project
  let worktrees: [LegacyWorktreeV3]

  private enum CodingKeys: String, CodingKey { case worktrees }

  init(from decoder: Decoder) throws {
    self.base = try Project(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.worktrees = try container.decodeIfPresent([LegacyWorktreeV3].self, forKey: .worktrees) ?? []
  }
}

private struct LegacyWorktreeV3: Decodable {
  /// The Worktree without a layout; the migration fills the layout in.
  let base: Worktree
  let tabs: [LegacyTabV3]
  let selectedTabID: TabID?

  private enum CodingKeys: String, CodingKey { case tabs, selectedTabID }

  init(from decoder: Decoder) throws {
    self.base = try Worktree(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.tabs = try container.decodeIfPresent([LegacyTabV3].self, forKey: .tabs) ?? []
    self.selectedTabID = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
  }
}

private struct LegacyTabV3: Decodable {
  let id: TabID
  let name: String?
  let cachedDisplayTitle: String?
  let color: TabColor?
  let icon: String?
  let iconLock: TabIconLock
  let splitTree: SplitTree<PaneID>
  let panes: [LegacySessionV3]

  private enum CodingKeys: String, CodingKey {
    case id, name, cachedDisplayTitle, color, icon, iconLock, splitTree, panes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(TabID.self, forKey: .id)
    self.name = try container.decodeIfPresent(String.self, forKey: .name)
    self.cachedDisplayTitle = try container.decodeIfPresent(String.self, forKey: .cachedDisplayTitle)
    self.color = try container.decodeIfPresent(TabColor.self, forKey: .color)
    self.icon = try container.decodeIfPresent(String.self, forKey: .icon)
    self.iconLock = try container.decodeIfPresent(TabIconLock.self, forKey: .iconLock) ?? .auto
    self.splitTree = try container.decode(SplitTree<PaneID>.self, forKey: .splitTree)
    self.panes = try container.decode([LegacySessionV3].self, forKey: .panes)
  }

  /// Sessions in leaf order; a session record the tree does not reference
  /// follows in record order, so no session is lost to a drifted tree.
  var sessions: [LegacySessionV3] {
    let inTree = splitTree.leaves().compactMap { leaf in panes.first { $0.id == leaf } }
    let referenced = Set(inTree.map(\.id))
    return inTree + panes.filter { !referenced.contains($0.id) }
  }

  /// One Tab per session, the chip attributes on the first.
  func tabs() -> [Tab] {
    var tabs = sessions.map { Tab(content: $0.content) }
    if !tabs.isEmpty {
      tabs[0] = Tab(
        name: name, cachedDisplayTitle: cachedDisplayTitle, color: color, icon: icon,
        iconLock: iconLock, content: tabs[0].content)
    }
    return tabs
  }

  /// The former Tab as a Pane layout: its tree with fresh leaves, one
  /// single-Tab Pane per leaf that has a session record, the zoom cleared.
  /// Sessions outside the tree go to the focused Pane's strip; a former
  /// Tab whose tree references none of its records becomes one Pane.
  func layout() -> (splitTree: SplitTree<PaneID>, panes: [Pane], focusedPaneID: PaneID) {
    let tabs = tabs()
    let leaves = splitTree.leaves()
    let leavesWithRecord = leaves.filter { leaf in panes.contains { $0.id == leaf } }
    var tree = splitTree.settingZoomed(nil)
    var migratedPanes: [Pane] = []
    for (index, leaf) in leavesWithRecord.enumerated() {
      let pane = Pane(tabs: [tabs[index]])
      // The leaf cannot be missing: it came from this very tree.
      tree = (try? tree.replacing(leaf, with: pane.id)) ?? tree
      migratedPanes.append(pane)
    }
    for leaf in leaves where !leavesWithRecord.contains(leaf) {
      tree = tree.removing(leaf)
    }
    if migratedPanes.isEmpty {
      let pane = Pane(tabs: [])
      tree = SplitTree(leaf: pane.id)
      migratedPanes = [pane]
    }
    let focusedIndex = splitTree.zoomed.flatMap { leavesWithRecord.firstIndex(of: $0) } ?? 0
    migratedPanes[focusedIndex].tabs.append(contentsOf: tabs[leavesWithRecord.count...])
    return (tree, migratedPanes, migratedPanes[focusedIndex].id)
  }
}

/// A v3 session record: the v4 terminal state plus the session id, which
/// becomes the `ContentID`.
private struct LegacySessionV3: Decodable {
  let id: PaneID
  let state: TerminalContentState

  private enum CodingKeys: String, CodingKey { case id }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(PaneID.self, forKey: .id)
    self.state = try TerminalContentState(from: decoder)
  }

  var content: ContentSnapshot {
    ContentSnapshot(id: ContentID(raw: id.raw), state: .terminal(state))
  }
}
