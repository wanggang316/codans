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
  /// SF Symbol name shown in the tab chip. `nil` means "let the auto
  /// fallback decide" — the runtime computes a default from the
  /// foreground job. See `iconLock` for who last wrote the icon.
  public var icon: String?
  /// Authority of the most recent icon write. `.user` and `.script`
  /// stick across auto re-derivation; `.auto` writes are best-effort
  /// suggestions from the runtime. See `applyingIcon(_:lock:)`.
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

  /// Resolves the SF Symbol to render for this tab. A locked write
  /// (`.user` / `.script`) wins outright; `.auto` defers to the caller's
  /// derived fallback so the runtime stays the source of truth for
  /// unlocked tabs.
  public func resolvedIcon(autoFallback: String?) -> String? {
    if iconLock != .auto, let icon, !icon.isEmpty { return icon }
    return autoFallback
  }

  /// Returns a copy of this tab with the icon updated, or `nil` when the
  /// incoming `lock` cannot override the current `iconLock`. `.auto` ≤
  /// `.script` ≤ `.user` (see `TabIconLock`). A `.user` write with a
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

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(TabID.self, forKey: .id)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.cachedDisplayTitle = try c.decodeIfPresent(String.self, forKey: .cachedDisplayTitle)
    self.color = try c.decodeIfPresent(TabColor.self, forKey: .color)
    self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
    self.iconLock = try c.decodeIfPresent(TabIconLock.self, forKey: .iconLock) ?? .auto
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
