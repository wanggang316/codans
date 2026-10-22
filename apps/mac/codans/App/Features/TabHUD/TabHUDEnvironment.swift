import CodansCore
import SwiftUI

/// Actions the Tab HUD fires that only the root store can service.
///
/// The HUD sits four levels below `ContentView` (`SplitViewportView` →
/// `SubtreeView` → `LeafView` → `LazyPaneHost`), and the two intermediate
/// views are private layout details. Threading a closure through them would
/// churn every initialiser; the environment carries it in one hop instead —
/// the same trade `ContentView` already makes with `onAddProject` and
/// `onFocusHierarchyPath`, one level up.
private struct TabHUDActionsKey: EnvironmentKey {
  static let defaultValue = TabHUDActions()
}

/// Defaults to no-ops so a preview or a test host renders the HUD without
/// wiring the root store.
struct TabHUDActions {
  /// Opens the Hand Off panel for the given Content. Routed to
  /// `RootFeature.handoffRequested`, which re-checks the Content's agent and
  /// project kind before presenting.
  var handOff: (ContentID) -> Void = { _ in }
  /// Opens the Command Queue sheet for the given Content — the same one ⌘⌥L
  /// summons. Routed to `RootFeature.commandQueueToggle`.
  var commandQueue: (ContentID) -> Void = { _ in }
}

extension EnvironmentValues {
  var tabHUDActions: TabHUDActions {
    get { self[TabHUDActionsKey.self] }
    set { self[TabHUDActionsKey.self] = newValue }
  }
}
