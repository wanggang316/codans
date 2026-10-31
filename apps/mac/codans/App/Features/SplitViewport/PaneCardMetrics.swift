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
  /// Capsule around the glyph and title that shows the move affordance.
  /// It has the height of an action button, so all hover fills in the
  /// header have the same rounding.
  static let titleChipHeight: CGFloat = actionButtonSize
  static let titleChipLeadingInset: CGFloat = 6
  static let titleChipTrailingInset: CGFloat = 10
  static let titleChipSpacing: CGFloat = 8
  static let moveGlyphSize: CGFloat = 11
  /// Opacity of the primary color in every header hover fill.
  static let hoverFillOpacity: Double = 0.08

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

  /// Extra resize hit area on the two sides of the gap between cards. It
  /// reaches only into the terminal's own edge padding, so it does not
  /// take clicks from terminal text.
  static let dividerHitOverhang: CGFloat = 4

  /// Opacity of an unfocused card in a split Tab.
  static let unfocusedOpacity: CGFloat = 0.7
}
