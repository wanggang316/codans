import SwiftUI

struct DiffComparisonPicker: View {
  @Binding var outgoing: Bool

  var body: some View {
    HStack(spacing: 0) {
      segment("Changes", symbol: "doc.text", isOutgoing: false)
      segment("Outgoing", symbol: "arrow.up.right", isOutgoing: true)
    }
    .background(.quaternary, in: Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Comparison")
    .accessibilityIdentifier("diff-sidebar-mode")
  }

  private func segment(_ title: String, symbol: String, isOutgoing: Bool) -> some View {
    let selected = outgoing == isOutgoing
    return Button {
      outgoing = isOutgoing
    } label: {
      Label(title, systemImage: symbol)
        .font(.system(size: 13, weight: .medium))
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
