import SwiftUI

/// Shared swatch wrapper for inline colour pickers. Centralises the visual
/// rules — fixed 24pt hit area, 1pt subdued ring on hover, 2pt accent ring
/// when selected — so every chip stays pixel-aligned regardless of its inner
/// fill (named colour, glyph, conic rainbow, or solid custom hex). Used by the
/// Project colour swatch row and the command tint swatch row.
///
/// The selected ring is the system accent, matching how every other macOS
/// control marks a selection. It used to be near-black, which read as a
/// border drawn around the swatch rather than as selection, and collided with
/// the dark swatches in the palette.
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
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .frame(width: 23, height: 23)
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
