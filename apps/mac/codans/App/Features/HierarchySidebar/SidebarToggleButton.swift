import CodansCore
import SwiftUI

/// App-owned replacement for the native `NavigationSplitView` sidebar toggle. The native
/// button's tooltip cannot show a chord, so the main and Diff windows remove it
/// (`.toolbar(removing: .sidebarToggle)`) and place this one in the same slot. It keeps the
/// native glyph and toolbar button style, and it reads the live Toggle Sidebar binding, so a
/// rebind in Settings shows up on the next hover.
struct SidebarToggleButton: View {
  let isSidebarVisible: Bool
  let toggle: () -> Void
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  var body: some View {
    Button(action: toggle) {
      Label(Self.title(isSidebarVisible: isSidebarVisible), systemImage: "sidebar.left")
    }
    .labelStyle(.iconOnly)
    .help(Self.tooltip(isSidebarVisible: isSidebarVisible, shortcuts: resolvedShortcuts))
    .accessibilityIdentifier("sidebar.toggle")
  }

  static func title(isSidebarVisible: Bool) -> String {
    isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
  }

  static func tooltip(isSidebarVisible: Bool, shortcuts: ResolvedShortcutMap) -> String {
    ShortcutDisplay.tooltip(title(isSidebarVisible: isSidebarVisible), for: .toggleSidebar, in: shortcuts)
  }
}
