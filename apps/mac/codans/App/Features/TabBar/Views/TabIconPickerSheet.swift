import SwiftUI
import CodansCore

/// Sheet-hosted SF Symbol picker for a tab. Grid of curated dev-focused
/// symbols plus a "No Icon" reset option. Committing with a symbol
/// stores it under `.user` lock; the reset path sends nil so the model
/// drops the lock back to `.auto` and the runtime fallback takes over.
struct TabIconPickerSheet: View {
  let initialIcon: String?
  let onCommit: (String?) -> Void
  let onCancel: () -> Void

  @State private var selectedIcon: String?

  /// Curated SF Symbol palette. Names land alphabetically inside each
  /// row to avoid implying a hierarchy between adjacent glyphs.
  static let palette: [String] = [
    "terminal",
    "command",
    "chevron.left.forwardslash.chevron.right",
    "hammer",
    "wrench.and.screwdriver",
    "shippingbox",
    "play.rectangle.fill",
    "bolt",
    "testtube.2",
    "checkmark.shield",
    "ladybug",
    "magnifyingglass",
    "sparkles",
    "wand.and.stars",
    "brain",
    "circle.hexagongrid.fill",
    "doc.text",
    "folder",
    "arrow.triangle.branch",
    "server.rack",
    "globe",
    "paintbrush",
  ]

  init(
    initialIcon: String?,
    onCommit: @escaping (String?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialIcon = initialIcon
    self.onCommit = onCommit
    self.onCancel = onCancel
    _selectedIcon = State(initialValue: initialIcon)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Tab Icon")
          .font(.headline)
        Text("Pick an icon for this tab. Choose No Icon to fall back to the default.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(minimum: 36), spacing: 10), count: 6),
        spacing: 10
      ) {
        ForEach(Self.palette, id: \.self) { symbol in
          IconButton(
            symbol: symbol,
            isSelected: selectedIcon == symbol,
            onSelect: { selectedIcon = symbol }
          )
        }
        Button {
          selectedIcon = nil
        } label: {
          Image(systemName: "nosign")
            .font(.system(size: 18))
            .foregroundStyle(selectedIcon == nil ? Color.accentColor : Color.gray.opacity(0.55))
            .frame(width: 36, height: 36)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(selectedIcon == nil ? Color.accentColor.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No Icon")
        .accessibilityAddTraits(selectedIcon == nil ? .isSelected : [])
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Done") { onCommit(selectedIcon) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 380)
  }
}

private struct IconButton: View {
  let symbol: String
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onSelect) {
      Image(systemName: symbol)
        .font(.system(size: 18))
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .frame(width: 36, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(backgroundFill)
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.1)) {
        isHovering = hovering
      }
    }
    .accessibilityLabel(symbol)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var backgroundFill: Color {
    if isSelected { return Color.accentColor.opacity(0.18) }
    if isHovering { return Color.primary.opacity(0.06) }
    return .clear
  }
}

#if DEBUG
  #Preview {
    TabIconPickerSheet(
      initialIcon: "sparkles",
      onCommit: { _ in },
      onCancel: {}
    )
  }
#endif
