import AppKit
import SwiftUI

/// Menu items for every `HelpMenuLink`, in `HelpMenuLink.groups` order with a
/// separator between groups. Used as the content of the menubar Help menu and
/// of the sidebar footer's help menu.
struct HelpMenuItems: View {
  var body: some View {
    ForEach(Array(HelpMenuLink.groups.enumerated()), id: \.offset) { index, group in
      if index > 0 {
        Divider()
      }
      ForEach(group, id: \.self) { link in
        Button {
          NSWorkspace.shared.open(link.url(in: .current))
        } label: {
          // NSMenu hides item images unless the label asks for them.
          Label(link.title, systemImage: link.systemImage)
            .labelStyle(.titleAndIcon)
        }
      }
    }
  }
}

/// Question-mark button at the leading edge of the sidebar footer. It opens
/// a native menu with the help links.
struct SidebarHelpMenuButton: View {
  var body: some View {
    Menu {
      HelpMenuItems()
    } label: {
      Image(systemName: "questionmark.circle")
        .accessibilityLabel("Help")
    }
    .menuStyle(.button)
    .buttonStyle(.sidebarFooter)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Help")
    .accessibilityLabel("Help")
    .accessibilityIdentifier("sidebar.helpMenu")
  }
}
