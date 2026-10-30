import AppKit
import SwiftUI

/// Numeric design tokens for the pane cards. Each pane in the split
/// viewport is drawn as a rounded card with a title header, floating on the
/// window backdrop with a fixed gap between cards.
enum PaneCardMetrics {
  /// Gap between two cards, and between the cards and the viewport edges.
  /// The split divider is exactly this thick, so the gap is also the drag
  /// target that resizes the split.
  static let gap: CGFloat = 8

  static let cornerRadius: CGFloat = 12

  /// Card header row: icon + title on the leading side, pane actions on the
  /// trailing side.
  static let headerHeight: CGFloat = 32
  static let headerHorizontalInset: CGFloat = 12
  static let headerIconSize: CGFloat = 14
  static let headerTitleFontSize: CGFloat = 13

  /// Square hit box of one header action button.
  static let actionButtonSize: CGFloat = 22
  static let actionGlyphSize: CGFloat = 12

  /// Hairline around the card, so a card keeps its edge when the terminal
  /// background is close to the window backdrop.
  static let borderWidth: CGFloat = 0.5

  /// Window backdrop the cards float on, behind the tab bar and in the gaps.
  /// A shade off the window background so a card on a light terminal theme
  /// still stands out from it.
  static let backdrop: Color = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .black.withAlphaComponent(0.25)
        : .black.withAlphaComponent(0.06)
    })

  /// Inset of the terminal surface inside the card, on the sides and the
  /// bottom, so text does not touch the card edge.
  static let surfaceInset: CGFloat = 6
}
