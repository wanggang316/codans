import CodansCore
import SwiftUI

/// Actions a tab chip's actions menu fires that only the root store can
/// service.
///
/// The chip sits many levels below `ContentView` (`SplitViewportView` →
/// `SubtreeView` → `PaneView` → `TabBarView` → `TabBarRowView`), and the
/// intermediate views are private layout details. Threading a closure
/// through them would churn every initialiser; the environment carries it
/// in one hop instead — the same trade `ContentView` already makes with
/// `onAddProject` and `onFocusHierarchyPath`, one level up.
private struct TabActionsKey: EnvironmentKey {
  static let defaultValue = TabActions()
}

/// Defaults to no-ops so a preview or a test host renders the chip without
/// wiring the root store.
struct TabActions {
  /// Opens the Hand Off panel for the given Content. Routed to
  /// `RootFeature.handoffRequested`, which re-checks the Content's agent and
  /// project kind before presenting.
  var handOff: (ContentID) -> Void = { _ in }
  /// Opens the Command Queue sheet for the given Content — the same one ⌘⌥L
  /// summons. Routed to `RootFeature.commandQueueToggle`.
  var commandQueue: (ContentID) -> Void = { _ in }
}

extension EnvironmentValues {
  var tabActions: TabActions {
    get { self[TabActionsKey.self] }
    set { self[TabActionsKey.self] = newValue }
  }
}
