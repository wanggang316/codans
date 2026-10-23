import AppKit

/// The items of a tab chip's actions menu. First the Tab's own affairs —
/// handing its agent's task off and opening its command queue — then every
/// action its terminal surface offers, in the groups of the surface's
/// right-click menu (`PaneSurfaceAction.groups`), so the two menus cannot
/// drift apart.
@MainActor
enum TabActionsMenu {
  static func items(
    model: TabActionsModel,
    hasSurface: Bool,
    hasSelection: Bool,
    perform: @escaping (PaneSurfaceAction) -> Void,
    handOff: @escaping () -> Void,
    commandQueue: @escaping () -> Void
  ) -> [PullDownMenuItem] {
    let queueTitle =
      model.queuedCommandCount > 0 ? "Command Queue… (\(model.queuedCommandCount))" : "Command Queue…"
    var items: [PullDownMenuItem] = [
      .action("Hand Off…", image: symbol("arrow.left.arrow.right"), isEnabled: model.canHandOff, perform: handOff),
      .action(queueTitle, image: symbol(CommandQueueStyle.symbol), perform: commandQueue),
    ]
    for group in PaneSurfaceAction.groups {
      items.append(.separator)
      for action in group {
        // Shown disabled rather than dropped, so the menu still answers
        // "can this Tab copy?" for someone who opened it to find out.
        let isEnabled = hasSurface && (!action.needsSelection || hasSelection)
        items.append(
          .action(action.title, image: symbol(action.symbol), isEnabled: isEnabled) { perform(action) })
      }
    }
    return items
  }

  private static func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }
}
