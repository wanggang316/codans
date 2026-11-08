import Foundation

public nonisolated struct Tab: Equatable, Sendable, Identifiable {
  public var id: TabID
  public var name: String?
  /// Snapshot of the most recently resolved live title (OSC tabTitle /
  /// title / pwd basename). Persisted to the catalog so a tab whose
  /// surface has not yet been re-spawned after app launch still shows
  /// the previous session's title instead of falling back to "Tab N".
  /// Cleared / overwritten as soon as a live title is observed again.
  public var cachedDisplayTitle: String?
  /// The pane whose title `cachedDisplayTitle` holds. The tab chip mirrors
  /// its selected pane, so it uses the cache only for that pane. Nil in
  /// catalogs written before ADR 0009.
  public var cachedDisplayTitlePaneID: PaneID?
  public var splitTree: SplitTree<PaneID>
  public var panes: [Pane]

  public init(
    id: TabID = TabID(),
    name: String? = nil,
    cachedDisplayTitle: String? = nil,
    cachedDisplayTitlePaneID: PaneID? = nil,
    splitTree: SplitTree<PaneID> = SplitTree(),
    panes: [Pane] = []
  ) {
    self.id = id
    self.name = name
    self.cachedDisplayTitle = cachedDisplayTitle
    self.cachedDisplayTitlePaneID = cachedDisplayTitlePaneID
    self.splitTree = splitTree
    self.panes = panes
  }

  /// The set of PaneIDs that appear as leaves in the split tree.
  public var splitTreeLeafIDs: Set<PaneID> { Set(splitTree.leaves()) }

  /// The set of PaneIDs stored in the flat panes array.
  public var flatPaneIDs: Set<PaneID> { Set(panes.map(\.id)) }

  /// Invariant: leaves of `splitTree` equal IDs of `panes`. Debug-only callers.
  public enum InvariantError: Error, Equatable {
    case leavesDoNotMatchPanes(leaves: Set<PaneID>, panes: Set<PaneID>)
    case duplicatePaneIDs
  }

  public func validateInvariants() throws {
    guard flatPaneIDs.count == panes.count else { throw InvariantError.duplicatePaneIDs }
    let leaves = splitTreeLeafIDs
    let flat = flatPaneIDs
    if leaves != flat { throw InvariantError.leavesDoNotMatchPanes(leaves: leaves, panes: flat) }
  }
}

extension Tab: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, cachedDisplayTitle, cachedDisplayTitlePaneID, splitTree, panes
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(TabID.self, forKey: .id)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.cachedDisplayTitle = try c.decodeIfPresent(String.self, forKey: .cachedDisplayTitle)
    self.cachedDisplayTitlePaneID = try c.decodeIfPresent(
      PaneID.self, forKey: .cachedDisplayTitlePaneID)
    self.splitTree = try c.decode(SplitTree<PaneID>.self, forKey: .splitTree)
    self.panes = try c.decode([Pane].self, forKey: .panes)
  }

  /// Optional fields are omitted when unset. Keys that older builds wrote
  /// (`color`, `icon`, `iconLock`) are ignored on decode and dropped on the
  /// next save.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(name, forKey: .name)
    try c.encodeIfPresent(cachedDisplayTitle, forKey: .cachedDisplayTitle)
    try c.encodeIfPresent(cachedDisplayTitlePaneID, forKey: .cachedDisplayTitlePaneID)
    try c.encode(splitTree, forKey: .splitTree)
    try c.encode(panes, forKey: .panes)
  }
}
