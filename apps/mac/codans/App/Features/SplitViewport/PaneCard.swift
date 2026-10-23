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
  /// rounded shape with a hairline rim and a soft shadow, content clipped
  /// to the shape.
  func paneCard(fill: Color) -> some View {
    let shape = RoundedRectangle(cornerRadius: PaneCardMetrics.cornerRadius, style: .continuous)
    return
      self
      .clipShape(shape)
      // The shadow is cast by a plain shape behind the content, not by the
      // content itself: shadowing the content would composite the terminal
      // surface off screen.
      .background {
        shape
          .fill(fill)
          .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
      }
      .overlay {
        shape
          .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
          .allowsHitTesting(false)
      }
  }
}

/// The surface the Pane cards float on: the terminal background, darkened
/// so the cards stand off it in both appearances — a little in light mode,
/// more in dark mode, where a small step does not read.
struct PaneCardBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme
  /// Bumped on a ghostty theme reload, which `colorScheme` does not cover.
  @State private var configReloadTick = 0

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: color))
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
        configReloadTick &+= 1
      }
  }

  private var color: NSColor {
    _ = configReloadTick
    let terminal = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
    let fraction: CGFloat = colorScheme == .dark ? 0.35 : 0.07
    return terminal.blended(withFraction: fraction, of: .black) ?? terminal
  }
}
