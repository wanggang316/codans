import SwiftUI

struct DiffComparisonPicker: View {
  @Binding var outgoing: Bool

  var body: some View {
    HStack(spacing: 0) {
      segment("Uncommitted", isOutgoing: false)
      segment("Outgoing", isOutgoing: true)
    }
    .background(.quaternary, in: Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Comparison")
    .accessibilityIdentifier("diff-sidebar-mode")
  }

  private func segment(_ title: String, isOutgoing: Bool) -> some View {
    let selected = outgoing == isOutgoing
    return Button {
      outgoing = isOutgoing
    } label: {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
