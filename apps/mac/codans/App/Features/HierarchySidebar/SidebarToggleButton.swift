import CodansCore
import SwiftUI

/// App-owned replacement for the native `NavigationSplitView` sidebar toggle. The native
/// button's tooltip cannot show a chord, so the main and Diff windows remove it
/// (`.toolbar(removing: .sidebarToggle)`) and place `SidebarToggleToolbarItem` in the same
/// slot. It keeps the native glyph, and it reads the live Toggle Sidebar binding, so a rebind
/// in Settings shows up on the next hover.
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

/// The toggle as the last item of a sidebar column's toolbar, in both sidebar states. One item
/// that never moves between toolbar sections slides with the sidebar the way the native toggle
/// does; swapping items between sections on each toggle makes the toolbar re-lay out mid-slide.
///
/// On macOS 26 the item opts out of the shared glass and draws its own 36 pt circle. In the
/// collapsed sidebar section the toolbar drops `ToolbarSpacer`s, so a shared-glass item would
/// merge into one capsule with the item before it (`+`); the native toggle keeps its own.
struct SidebarToggleToolbarItem: ToolbarContent {
  let isSidebarVisible: Bool
  let toggle: () -> Void

  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .primaryAction) {
        SidebarToggleButton(isSidebarVisible: isSidebarVisible, toggle: toggle)
          .frame(width: 36, height: 36)
          .glassEffect(.regular.interactive(), in: .circle)
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .primaryAction) {
        SidebarToggleButton(isSidebarVisible: isSidebarVisible, toggle: toggle)
      }
    }
  }
}
