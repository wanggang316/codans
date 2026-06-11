import SwiftUI
import CodansCore

/// SwiftUI environment plumbing for the resolved shortcut map. The app injects the live
/// store's `resolved` value at the top of the view tree; call sites read it via
/// `@Environment(\.resolvedShortcuts)` and apply it to buttons/menu items through
/// `View.appKeyboardShortcut(_:)`.
private struct ResolvedShortcutsKey: EnvironmentKey {
  static let defaultValue: ResolvedShortcutMap = [:]
}

extension EnvironmentValues {
  /// Map from `CommandID` to the resolved binding (default ⊕ override). Empty when no store
  /// is injected, in which case `appKeyboardShortcut` is a no-op.
  public var resolvedShortcuts: ResolvedShortcutMap {
    get { self[ResolvedShortcutsKey.self] }
    set { self[ResolvedShortcutsKey.self] = newValue }
  }
}
