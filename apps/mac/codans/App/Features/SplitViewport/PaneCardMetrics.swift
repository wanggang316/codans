import CoreGraphics

/// Numeric design tokens for the pane cards. Each pane in the split
/// viewport is drawn as a rounded card with a title header, floating on the
/// window backdrop with a fixed gap between cards.
enum PaneCardMetrics {
  /// Gap between two cards, and between the cards and the viewport edges.
  /// The split divider is exactly this thick, so the gap is also the drag
  /// target that resizes the split.
  static let gap: CGFloat = 6

  static let cornerRadius: CGFloat = 12

  /// Card header row: icon + title on the leading side, pane actions on the
  /// trailing side.
  static let headerHeight: CGFloat = 32
  static let headerHorizontalInset: CGFloat = 6
  static let headerIconSize: CGFloat = 14
  static let headerTitleFontSize: CGFloat = 13

  /// Square hit box of one header action button.
  static let actionButtonSize: CGFloat = 22
  static let actionGlyphSize: CGFloat = 12
  static let actionSpacing: CGFloat = 2
  /// Top edge of an action button inside the header.
  static let actionButtonTop: CGFloat = (headerHeight - actionButtonSize) / 2
  /// Distance from the card's trailing edge to the trailing edge of the
  /// actions-menu slot, which sits just left of the close button.
  static let menuSlotTrailingOffset: CGFloat =
    headerHorizontalInset + actionButtonSize + actionSpacing

  /// Hairline around the card, so a card keeps its edge when the terminal
  /// background is close to the window backdrop.
  static let borderWidth: CGFloat = 0.5

  /// Inset of the terminal surface inside the card, on the sides and the
  /// bottom, so text does not touch the card edge.
  static let surfaceInset: CGFloat = 6

  /// Opacity of an unfocused card in a split Tab.
  static let unfocusedOpacity: CGFloat = 0.7
}
