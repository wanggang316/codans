import Foundation

/// One slot in a Pane's strip: the chip attributes (title, color, icon)
/// and exactly one Content.
public nonisolated struct Tab: Equatable, Sendable, Identifiable {
  public var id: TabID
  /// User-set title; `nil` follows the live title.
  public var name: String?
  /// Snapshot of the most recently resolved live title (OSC tabTitle /
  /// title / pwd basename). Persisted so a Tab whose surface has not yet
  /// been re-spawned after app launch still shows the previous session's
  /// title instead of falling back to "Tab N". Overwritten as soon as a
  /// live title is observed again.
  public var cachedDisplayTitle: String?
  /// Per-tab accent color for the active underline stripe. `nil` = system accent.
  public var color: TabColor?
  /// Glyph shown in the tab chip: an SF Symbol name, or an
  /// `agent:<kind>` reference to a bundled brand mark (see `TabIconRef`).
  /// `nil` means "let the auto fallback decide" — the runtime computes a
  /// default from the foreground job. See `iconLock` for who last wrote
  /// the icon.
  public var icon: String?
  /// Authority of the most recent icon write. `.user` and `.script`
  /// stick across auto re-derivation; `.auto` writes are best-effort
  /// suggestions from the runtime. See `applyingIcon(_:lock:)`.
  public var iconLock: TabIconLock
  public var content: ContentSnapshot

  public init(
    id: TabID = TabID(),
    name: String? = nil,
    cachedDisplayTitle: String? = nil,
    color: TabColor? = nil,
    icon: String? = nil,
    iconLock: TabIconLock = .auto,
    content: ContentSnapshot
  ) {
    self.id = id
    self.name = name
    self.cachedDisplayTitle = cachedDisplayTitle
    self.color = color
    self.icon = icon
    self.iconLock = iconLock
    self.content = content
  }

  public var contentID: ContentID { content.id }

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
}

extension Tab: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, cachedDisplayTitle, color, icon, iconLock, content
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(TabID.self, forKey: .id)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.cachedDisplayTitle = try c.decodeIfPresent(String.self, forKey: .cachedDisplayTitle)
    self.color = try c.decodeIfPresent(TabColor.self, forKey: .color)
    self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
    self.iconLock = try c.decodeIfPresent(TabIconLock.self, forKey: .iconLock) ?? .auto
    self.content = try c.decode(ContentSnapshot.self, forKey: .content)
  }

  /// Omit-when-default encoding so an unset tab does not litter
  /// `catalog.json` with `iconLock=auto` and absent `icon` keys.
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
    try c.encode(content, forKey: .content)
  }
}
