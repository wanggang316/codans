import Foundation

/// The pane-scoped actions a live terminal surface offers.
///
/// Both places the user reaches them from render this one list: the
/// surface's own right-click menu (`GhosttySurfaceView.menu(for:)`) and the
/// pane HUD card in the pane's top-right corner. Adding a case here puts the
/// action in both, which is the point — the corner menu exists so these are
/// discoverable without knowing that right-click does anything, and a menu
/// that silently offers less than the other is worse than no menu.
///
/// The list is deliberately terminal-scoped. Actions that belong to the
/// pane's *row* rather than its surface — hand off, the command queue, the
/// notification mute — are the HUD's own and live in `PaneHUDView`.
nonisolated enum PaneSurfaceAction: CaseIterable, Hashable, Sendable {
  case copy
  case paste
  case splitRight
  case splitDown
  case splitLeft
  case splitUp
  case resetTerminal
  case copyPaneID
  case close

  /// Menu order, one inner array per separator-delimited group. Renderers
  /// walk this rather than `allCases` so both menus group identically.
  static let groups: [[PaneSurfaceAction]] = [
    [.copy, .paste],
    [.splitRight, .splitDown, .splitLeft, .splitUp],
    [.resetTerminal, .copyPaneID],
    [.close],
  ]

  var title: String {
    switch self {
    case .copy: "Copy"
    case .paste: "Paste"
    case .splitRight: "Split Right"
    case .splitDown: "Split Down"
    case .splitLeft: "Split Left"
    case .splitUp: "Split Up"
    case .resetTerminal: "Reset Terminal"
    case .copyPaneID: "Copy Pane ID"
    // Named for its object: the menu it sits in also closes splits and
    // reaches a tab's worth of panes, so a bare "Close" leaves the user
    // guessing what goes away.
    case .close: "Close Pane"
    }
  }

  /// The split symbols are the same ones the tab bar and the Command
  /// Palette use for those actions, so a split reads the same wherever it
  /// is offered.
  var symbol: String {
    switch self {
    case .copy: "doc.on.doc"
    case .paste: "doc.on.clipboard"
    case .splitRight: "rectangle.righthalf.inset.filled"
    case .splitDown: "rectangle.bottomhalf.inset.filled"
    case .splitLeft: "rectangle.leadinghalf.inset.filled"
    case .splitUp: "rectangle.tophalf.inset.filled"
    case .resetTerminal: "arrow.trianglehead.2.clockwise"
    case .copyPaneID: "number"
    case .close: "xmark"
    }
  }

  /// Actions that need something selected on screen. The right-click menu
  /// drops such an item; the HUD card shows it disabled, because a card the
  /// user opens to find out what a pane can do should say that copying is
  /// possible at all.
  var needsSelection: Bool {
    self == .copy
  }

  /// Suffix for the HUD row's accessibility identifier (`pane_hud.<id>`),
  /// which is also how the AX-driven UI harness addresses the row.
  var accessibilityID: String {
    switch self {
    case .copy: "copy"
    case .paste: "paste"
    case .splitRight: "split_right"
    case .splitDown: "split_down"
    case .splitLeft: "split_left"
    case .splitUp: "split_up"
    case .resetTerminal: "reset_terminal"
    case .copyPaneID: "copy_pane_id"
    case .close: "close"
    }
  }
}
