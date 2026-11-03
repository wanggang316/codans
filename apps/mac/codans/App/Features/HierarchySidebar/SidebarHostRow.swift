import CodansCore
import SwiftUI

/// A Host row (ADR 0002, decision 2): the heading of the Projects on one
/// machine. It cannot be selected; a click anywhere on it opens or closes
/// its Projects. It shows no connection state (ADR 0003, decision 11).
struct SidebarHostRow: View {
  let group: SidebarHostGroup
  let onToggleExpansion: () -> Void
  @State private var isHovering = false
  @State private var isChevronHovering = false

  var body: some View {
    Button(action: onToggleExpansion) {
      HStack(spacing: 6) {
        Image(systemName: group.record == nil ? "laptopcomputer" : "server.rack")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 14, alignment: .center)
          .accessibilityHidden(true)
        Text(group.displayName)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .help(group.record.map(\.endpoint.displayAuthority) ?? "")
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isChevronHovering ? .primary : .secondary)
          .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
          .frame(width: 22, height: 22)
          .background(Circle().fill(Color.primary.opacity(isChevronHovering ? 0.08 : 0)))
          .contentShape(Circle())
          .onHover { isChevronHovering = $0 }
          // Same as the Project rows: the chevron shows on hover.
          .opacity(isHovering ? 1 : 0)
          .accessibilityHidden(true)
      }
      .foregroundStyle(isHovering ? .primary : .secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    // A label on the Button keeps its press action for VoiceOver.
    .accessibilityLabel(group.displayName)
    .accessibilityValue(group.isExpanded ? "Expanded" : "Collapsed")
    .accessibilityAddTraits(.isHeader)
    .accessibilityHint(group.isExpanded ? "Collapse" : "Expand")
  }
}
