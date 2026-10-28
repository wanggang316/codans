import Foundation

/// A leaf of a Worktree's split tree: an ordered strip of Tabs with one
/// selected Tab. Never empty — closing the last Tab closes the Pane.
public nonisolated struct Pane: Equatable, Sendable, Identifiable {
  public var id: PaneID
  public var tabs: [Tab]
  public var selectedTabID: TabID?

  /// `selectedTabID` falls back to the first Tab, so a Pane built from a
  /// strip alone starts out consistent.
  public init(id: PaneID = PaneID(), tabs: [Tab], selectedTabID: TabID? = nil) {
    self.id = id
    self.tabs = tabs
    self.selectedTabID = selectedTabID ?? tabs.first?.id
  }

  public var selectedTab: Tab? {
    guard let selectedTabID else { return nil }
    return tabs.first { $0.id == selectedTabID }
  }

  public func tab(_ id: TabID) -> Tab? {
    tabs.first { $0.id == id }
  }

  public func tab(forContent contentID: ContentID) -> Tab? {
    tabs.first { $0.content.id == contentID }
  }

  public var tabIDs: [TabID] { tabs.map(\.id) }
  public var contentIDs: [ContentID] { tabs.map(\.content.id) }

  /// The selection names one of this Pane's Tabs.
  public var hasResolvedSelection: Bool {
    guard let selectedTabID else { return false }
    return tabs.contains { $0.id == selectedTabID }
  }
}

extension Pane: Codable {
  private enum CodingKeys: String, CodingKey { case id, tabs, selectedTabID }

  /// Tabs decode element-wise: an unreadable Tab is dropped and counted
  /// through `CatalogDecodeLoss`, the others survive. A dangling or
  /// missing selection is repaired to the first Tab.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(PaneID.self, forKey: .id)
    var tabs: [Tab] = []
    if container.contains(.tabs) {
      let loss = CatalogDecodeLoss.collector(in: decoder)
      var elements = try container.nestedUnkeyedContainer(forKey: .tabs)
      while !elements.isAtEnd {
        do {
          tabs.append(try elements.decode(Tab.self))
        } catch {
          _ = try elements.decode(DecodedSkip.self)
          loss?.recordDroppedTab()
        }
      }
    }
    self.tabs = tabs
    let stored = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    self.selectedTabID = stored.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(tabs, forKey: .tabs)
    try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
  }
}
