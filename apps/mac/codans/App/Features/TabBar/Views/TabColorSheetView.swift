import SwiftUI
import CodansCore

/// Sheet-hosted color picker for a single tab. Horizontal row of circular
/// swatches plus a "no color" option. Commits on Done, discards on Esc / Cancel.
struct TabColorSheetView: View {
  let initialColor: TabColor?
  let onCommit: (TabColor?) -> Void
  let onCancel: () -> Void

  @State private var selectedColor: TabColor?

  init(
    initialColor: TabColor?,
    onCommit: @escaping (TabColor?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialColor = initialColor
    self.onCommit = onCommit
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Tab Color")
          .font(.headline)
        Text("Choose an accent color for the tab indicator.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        ForEach(TabColor.allCases, id: \.self) { color in
          ColorSwatchButton(
            color: color,
            isSelected: selectedColor == color,
            onSelect: { selectedColor = color }
          )
        }

        Button {
          selectedColor = nil
        } label: {
          Image(systemName: "nosign")
            .font(.system(size: 22))
            .foregroundStyle(Color.gray.opacity(0.45))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No Color")
        .accessibilityAddTraits(selectedColor == nil ? .isSelected : [])
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Done") { onCommit(selectedColor) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 360)
  }
}

private struct ColorSwatchButton: View {
  let color: TabColor
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onSelect) {
      ZStack {
        Circle()
          .strokeBorder(Color(red: 0.3, green: 0.3, blue: 0.3).opacity(0.5), lineWidth: 2)
          .frame(width: 32, height: 32)
          .opacity(isHovering || isSelected ? 1 : 0)

        Circle()
          .fill(color.swiftUIColor)
          .frame(width: 24, height: 24)
      }
      .frame(width: 32, height: 32)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.1)) {
        isHovering = hovering
      }
    }
    .accessibilityLabel(color.rawValue.capitalized)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#if DEBUG
  #Preview {
    TabColorSheetView(
      initialColor: .blue,
      onCommit: { _ in },
      onCancel: {}
    )
  }
#endif
