import AppKit
import SwiftUI

/// Menu items for every `HelpMenuLink`, in order. Used as the content of the
/// menubar Help menu and of the sidebar footer's help menu.
struct HelpMenuItems: View {
  var body: some View {
    ForEach(HelpMenuLink.allCases, id: \.self) { link in
      Button {
        NSWorkspace.shared.open(link.url(in: .current))
      } label: {
        Label(link.title, systemImage: link.systemImage)
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
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Help")
    .accessibilityLabel("Help")
    .accessibilityIdentifier("sidebar.helpMenu")
  }
}
