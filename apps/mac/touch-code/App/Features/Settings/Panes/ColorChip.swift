import SwiftUI

/// Shared swatch wrapper for inline colour pickers. Centralises the visual
/// rules — fixed 24pt hit area, 1pt subdued ring on hover, 1.5pt accent ring
/// when selected — so every chip stays pixel-aligned regardless of its inner
/// fill (named colour, glyph, conic rainbow, or solid custom hex). Used by the
/// Project colour swatch row and the command tint swatch row.
struct ColorChip<Content: View>: View {
  let isSelected: Bool
  let action: () -> Void
  let accessibilityName: String
  @ViewBuilder var content: () -> Content

  @State private var isHovering: Bool = false

  var body: some View {
    Button(action: action) {
      ZStack {
        if isSelected {
          Circle()
            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
            .frame(width: 22, height: 22)
        } else if isHovering {
          Circle()
            .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
            .frame(width: 22, height: 22)
        }
        content()
      }
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(accessibilityName)
    .accessibilityLabel(accessibilityName)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
