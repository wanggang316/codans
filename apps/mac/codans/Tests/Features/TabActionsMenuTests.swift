import Testing

@testable import Codans

/// The chip's actions menu: the Tab's own affairs first, then every action
/// the terminal surface offers, grouped as its right-click menu is.
@MainActor
struct TabActionsMenuTests {
  private static let model = TabActionsModel(agent: .claudeCode, handOffBlockedReason: nil, queuedCommandCount: 0)

  /// `nil` marks a separator; otherwise the title and whether it is enabled.
  private static func rows(_ items: [PullDownMenuItem]) -> [(String, Bool)?] {
    items.map { item in
      switch item.kind {
      case .separator: nil
      case .action(let title, _, let isEnabled, _): (title, isEnabled)
      }
    }
  }

  private static func titles(_ items: [PullDownMenuItem]) -> [String?] {
    rows(items).map { $0?.0 }
  }

  private static func items(
    model: TabActionsModel = model, hasSurface: Bool = true, hasSelection: Bool = false
  ) -> [PullDownMenuItem] {
    TabActionsMenu.items(
      model: model, hasSurface: hasSurface, hasSelection: hasSelection,
      perform: { _ in }, handOff: {}, commandQueue: {})
  }

  @Test
  func listsTheTabsOwnActionsThenTheSurfaceGroups() {
    #expect(
      Self.titles(Self.items()) == [
        "Hand Off…", "Command Queue…", nil,
        "Copy", "Paste", nil,
        "Split Right", "Split Down", "Split Left", "Split Up", nil,
        "Reset Terminal", "Copy Pane ID", nil,
        "Close Tab",
      ])
  }

  @Test
  func copyIsDisabledWithoutASelection() {
    let rows = Self.rows(Self.items(hasSelection: false)).compactMap { $0 }
    #expect(rows.first { $0.0 == "Copy" }?.1 == false)
    let selected = Self.rows(Self.items(hasSelection: true)).compactMap { $0 }
    #expect(selected.first { $0.0 == "Copy" }?.1 == true)
  }

  @Test
  func surfaceActionsAreDisabledWithoutASurface() {
    let rows = Self.rows(Self.items(hasSurface: false)).compactMap { $0 }
    #expect(rows.filter { $0.1 }.map(\.0) == ["Hand Off…", "Command Queue…"])
  }

  @Test
  func handOffFollowsTheModel() {
    let blocked = TabActionsModel(agent: nil, handOffBlockedReason: "No agent", queuedCommandCount: 0)
    let rows = Self.rows(Self.items(model: blocked)).compactMap { $0 }
    #expect(rows.first { $0.0 == "Hand Off…" }?.1 == false)
  }

  @Test
  func commandQueueCountsQueuedCommands() {
    let queued = TabActionsModel(agent: nil, handOffBlockedReason: nil, queuedCommandCount: 3)
    #expect(Self.titles(Self.items(model: queued))[1] == "Command Queue… (3)")
  }

  @Test
  func eachItemRunsItsAction() {
    var performed: [PaneSurfaceAction] = []
    var handedOff = 0
    var queued = 0
    let items = TabActionsMenu.items(
      model: Self.model, hasSurface: true, hasSelection: true,
      perform: { performed.append($0) }, handOff: { handedOff += 1 }, commandQueue: { queued += 1 })
    for item in items {
      if case .action(_, _, _, let perform) = item.kind { perform() }
    }
    #expect(handedOff == 1)
    #expect(queued == 1)
    #expect(performed == PaneSurfaceAction.groups.flatMap { $0 })
  }
}
