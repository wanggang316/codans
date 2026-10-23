import SwiftUI

/// Design tokens for a Pane drawn as a card that floats on the window
/// background, like the floating sidebar: the same inset from what is around
/// it and the same corner radius, both measured from the macOS 26 sidebar.
enum PaneCardMetrics {
  /// Gap between two cards, and between a card and the edge of the layout.
  static let gap: CGFloat = 8
  static let cornerRadius: CGFloat = 16
  /// Inset of the terminal surface from the card's sides and bottom, so the
  /// rounded corners never cut into its text.
  static let contentInset: CGFloat = 6
}

extension View {
  /// Draws the view as a Pane card: `fill` (the terminal background) in a
  /// rounded shape with a hairline rim, content clipped to the shape.
  func paneCard(fill: Color) -> some View {
    let shape = RoundedRectangle(cornerRadius: PaneCardMetrics.cornerRadius, style: .continuous)
    return
      self
      .clipShape(shape)
      .background { shape.fill(fill) }
      .overlay {
        shape
          .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
          .allowsHitTesting(false)
      }
  }
}
