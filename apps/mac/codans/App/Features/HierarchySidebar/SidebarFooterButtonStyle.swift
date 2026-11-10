import SwiftUI

/// Chrome shared by the sidebar footer buttons (Help, Agents View, Settings).
/// The hover state matches the `+` button on a Project row: a 22×22 circle
/// filled with the primary color at 0.08 opacity, and the glyph changes from
/// secondary to primary. The style ignores `isPressed`, so the Help menu
/// button does not stay highlighted while its menu is open.
struct SidebarFooterButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SidebarFooterButtonLabel(label: configuration.label)
  }
}

private struct SidebarFooterButtonLabel<Label: View>: View {
  let label: Label
  @State private var isHovering = false

  var body: some View {
    label
      .font(.system(size: 13, weight: .regular))
      .foregroundStyle(isHovering ? .primary : .secondary)
      .frame(width: 22, height: 22)
      .background(Circle().fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
      .contentShape(Circle())
      .onHover { isHovering = $0 }
  }
}

extension ButtonStyle where Self == SidebarFooterButtonStyle {
  static var sidebarFooter: SidebarFooterButtonStyle { SidebarFooterButtonStyle() }
}
