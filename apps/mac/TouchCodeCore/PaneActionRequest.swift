import Foundation

/// Tab / split intent decoded from a libghostty surface-scoped action.
/// The Runtime emits `TerminalEvent.paneActionRequested(paneID, request)`;
/// `PaneActionRouterFeature` resolves the request against `HierarchyClient`.
///
/// Intents are policy-free: the reducer decides whether a close is allowed,
/// how to handle a running process, etc. Runtime stays TCA-free by only
/// lifting the typed intent onto the event stream.
public nonisolated enum PaneActionRequest: Sendable, Equatable {
  case newTab
  case closeTab(mode: CloseTabMode)
  case moveTab(offset: Int)
  case gotoTab(target: GotoTabTarget)
  case newSplit(direction: NewSplitDirection)
  /// Tear down the source pane. The router applies policy: closing the
  /// last pane in a tab retires the now-empty tab instead, and a surviving
  /// sibling reclaims focus.
  case closePane
  case gotoSplit(direction: FocusDirection)
  case resizeSplit(direction: ResizeDirection, amount: Double)
  case equalizeSplits
  case toggleSplitZoom
  case presentTerminal
  case toggleCommandPalette
}

public nonisolated enum CloseTabMode: Sendable, Equatable {
  case this
  case other
  case right
}

public nonisolated enum GotoTabTarget: Sendable, Equatable {
  case previous
  case next
  case last
  case index(Int)
}

/// Four-way split insertion direction, matching libghostty's
/// `ghostty_action_split_direction_e`. The earlier two-axis collapse
/// (horizontal/vertical) has been dropped so a user binding
/// `new_split:left` actually splits to the left instead of always to the
/// right. Router maps each case onto `SplitTree.NewDirection`.
public nonisolated enum NewSplitDirection: Sendable, Equatable {
  case right
  case left
  case up
  case down
}

public nonisolated enum FocusDirection: Sendable, Equatable {
  case up
  case down
  case left
  case right
  case previous
  case next
}

public nonisolated enum ResizeDirection: Sendable, Equatable {
  case up
  case down
  case left
  case right
}
