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
  /// Per-tab accent color for the active underline stripe. `nil` = system accent.
  public var color: TabColor?
  /// Icon the user picked for the tab chip: an SF Symbol name, or an
  /// `agent:<kind>` reference to a bundled brand mark (see `TabIconRef`).
  /// Rendered only under `.user`; otherwise the chip shows the selected
  /// pane's glyph (see `resolvedIcon(selectedPane:)`).
  public var icon: String?
  /// Authority of the most recent icon write. See `applyingIcon(_:lock:)`.
  public var iconLock: TabIconLock
  public var splitTree: SplitTree<PaneID>
  public var panes: [Pane]

  public init(
    id: TabID = TabID(),
    name: String? = nil,
    cachedDisplayTitle: String? = nil,
    color: TabColor? = nil,
    icon: String? = nil,
    iconLock: TabIconLock = .auto,
    splitTree: SplitTree<PaneID> = SplitTree(),
    panes: [Pane] = []
  ) {
    self.id = id
    self.name = name
    self.cachedDisplayTitle = cachedDisplayTitle
    self.color = color
    self.icon = icon
    self.iconLock = iconLock
    self.splitTree = splitTree
    self.panes = panes
  }

  /// The set of PaneIDs that appear as leaves in the split tree.
  public var splitTreeLeafIDs: Set<PaneID> { Set(splitTree.leaves()) }

  /// The set of PaneIDs stored in the flat panes array.
  public var flatPaneIDs: Set<PaneID> { Set(panes.map(\.id)) }

  /// Glyph for the tab chip. A user pick wins; otherwise the chip shows the
  /// same glyph as the selected pane's header, so the chip always describes
  /// the pane its title comes from.
  public func resolvedIcon(selectedPane: Pane?) -> String {
    if iconLock == .user, let icon, !icon.isEmpty { return icon }
    return TabIconRef.icon(for: selectedPane)
  }

  /// Returns a copy of this tab with the icon updated, or `nil` when the
  /// incoming `lock` cannot override the current `iconLock`. `.auto` <
  /// `.user` (see `TabIconLock`). A `.user` write with a
  /// nil icon is treated as an explicit reset back to `.auto`.
  public func applyingIcon(_ icon: String?, lock: TabIconLock) -> Tab? {
    guard lock >= iconLock else { return nil }
    var copy = self
    if lock == .user, icon == nil {
      copy.icon = nil
      copy.iconLock = .auto
    } else {
      copy.icon = icon
      copy.iconLock = lock
    }
    return copy
  }

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
    case id, name, cachedDisplayTitle, color, icon, iconLock, splitTree, panes
  }

  /// Lock value older catalogs wrote for a tab spawned by a run script or an
  /// agent profile.
  private static let legacyScriptLock = "script"

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(TabID.self, forKey: .id)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.cachedDisplayTitle = try c.decodeIfPresent(String.self, forKey: .cachedDisplayTitle)
    self.color = try c.decodeIfPresent(TabColor.self, forKey: .color)
    let icon = try c.decodeIfPresent(String.self, forKey: .icon)
    switch try c.decodeIfPresent(String.self, forKey: .iconLock) {
    case TabIconLock.user.rawValue?:
      self.icon = icon
      self.iconLock = .user
    case nil, TabIconLock.auto.rawValue?, Self.legacyScriptLock?:
      // Only a user pick is ever rendered, so any other stored icon is
      // dropped and the next save removes it from the catalog.
      self.icon = nil
      self.iconLock = .auto
    case let raw?:
      throw DecodingError.dataCorruptedError(
        forKey: .iconLock, in: c, debugDescription: "Unknown tab icon lock \(raw)")
    }
    self.splitTree = try c.decode(SplitTree<PaneID>.self, forKey: .splitTree)
    self.panes = try c.decode([Pane].self, forKey: .panes)
  }

  /// Omit-when-default encoding so an unset tab does not litter
  /// `catalog.json` with `iconLock=auto` and absent `icon` keys. Older
  /// builds that decode this file still see a clean object.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(name, forKey: .name)
    try c.encodeIfPresent(cachedDisplayTitle, forKey: .cachedDisplayTitle)
    try c.encodeIfPresent(color, forKey: .color)
    try c.encodeIfPresent(icon, forKey: .icon)
    if iconLock != .auto {
      try c.encode(iconLock, forKey: .iconLock)
    }
    try c.encode(splitTree, forKey: .splitTree)
    try c.encode(panes, forKey: .panes)
  }
}
