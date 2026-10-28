import Foundation

/// The pane-scoped actions a live terminal surface offers.
///
/// Both places the user reaches them from render this one list: the
/// surface's own right-click menu (`GhosttySurfaceView.menu(for:)`) and the
/// actions menu on each tab chip. Adding a case here puts the action in
/// both, which is the point — the chip menu exists so these are
/// discoverable without knowing that right-click does anything, and a menu
/// that silently offers less than the other is worse than no menu.
///
/// The list is deliberately terminal-scoped. Actions that belong to the
/// Tab rather than its surface — hand off, the command queue — are the chip
/// menu's own and live in `TabActionsMenu`.
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
    // Named for its object: a bare "Close" leaves the user guessing whether
    // the Tab or its whole Pane goes away.
    case .close: "Close Tab"
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
  /// drops such an item; the chip menu shows it disabled, because a menu the
  /// user opens to find out what a Tab can do should say that copying is
  /// possible at all.
  var needsSelection: Bool {
    self == .copy
  }
}
