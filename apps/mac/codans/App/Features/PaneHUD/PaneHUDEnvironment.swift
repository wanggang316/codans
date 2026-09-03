import CodansCore
import SwiftUI

/// Actions the pane HUD fires that only the root store can service.
///
/// The HUD sits four levels below `ContentView` (`SplitViewportView` →
/// `SubtreeView` → `LeafView` → `LazyPaneHost`), and the two intermediate
/// views are private layout details. Threading a closure through them would
/// churn every initialiser; the environment carries it in one hop instead —
/// the same trade `ContentView` already makes with `onAddProject` and
/// `onFocusHierarchyPath`, one level up.
private struct PaneHUDActionsKey: EnvironmentKey {
  static let defaultValue = PaneHUDActions()
}

/// Defaults to no-ops so a preview or a test host renders the HUD without
/// wiring the root store.
struct PaneHUDActions {
  /// Opens the Hand Off panel for the given pane. Routed to
  /// `RootFeature.handoffRequested`, which re-checks the pane's agent and
  /// project kind before presenting.
  var handOff: (PaneID) -> Void = { _ in }
}

extension EnvironmentValues {
  var paneHUDActions: PaneHUDActions {
    get { self[PaneHUDActionsKey.self] }
    set { self[PaneHUDActionsKey.self] = newValue }
  }
}
