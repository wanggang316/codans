import SwiftUI
import UIKit

/// The app's visual tokens. Monochrome: ink carries every control and
/// selection, and colour is reserved for meaning (agent and connection
/// state), so it stands out wherever it appears.
enum Theme {
  /// The spacing scale. Anything else is a one-off that needs a reason.
  enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
  }

  enum Radius {
    /// Rows, banners, cards.
    static let card: CGFloat = 12
    /// Floating panels and large cards.
    static let panel: CGFloat = 20
  }

  enum Motion {
    static let duration: Double = 0.25

    /// The one app-wide transition curve; nil under Reduce Motion, so
    /// changes land without movement.
    static func standard(reduceMotion: Bool) -> Animation? {
      reduceMotion ? nil : .easeInOut(duration: duration)
    }
  }
}

extension Color {
  /// Black in light mode, white in dark: the accent, primary buttons and
  /// primary text.
  static let ink = Color(light: .black, dark: .white)
  /// What sits on ink: the send arrow in its circle.
  static let onInk = Color(light: .white, dark: .black)
  static let inkSecondary = Color(uiColor: .secondaryLabel)
  static let inkTertiary = Color(uiColor: .tertiaryLabel)

  /// The page.
  static let surface = Color(light: .white, dark: .black)
  /// The page under grouped forms (Settings, connection details).
  static let surfaceGrouped = Color(uiColor: .systemGroupedBackground)
  /// Cards, banners and floating panels over the page.
  static let surfaceElevated = Color(light: UIColor(white: 0.965, alpha: 1), dark: UIColor(white: 0.11, alpha: 1))
  /// Pressed or selected rows, skeleton blocks.
  static let surfaceMuted = Color(light: UIColor(white: 0, alpha: 0.05), dark: UIColor(white: 1, alpha: 0.08))
  static let hairline = Color(light: UIColor(white: 0, alpha: 0.09), dark: UIColor(white: 1, alpha: 0.12))

  /// An agent waits for the user.
  static let needsInput = Color(light: UIColor(rgb: 0xC77700), dark: UIColor(rgb: 0xF5A524))
  /// An agent or the connection is doing its job.
  static let working = Color(light: UIColor(rgb: 0x1E9E5A), dark: UIColor(rgb: 0x3DD68C))
  static let failure = Color(light: UIColor(rgb: 0xD93025), dark: UIColor(rgb: 0xFF6259))
  static let offline = Color(light: UIColor(white: 0.62, alpha: 1), dark: UIColor(white: 0.45, alpha: 1))

  /// The provider is resolved on SwiftUI's render thread (sheets resolve
  /// materials asynchronously), so it must not inherit the main actor: a
  /// main-actor closure traps there on the isolation check.
  nonisolated init(light: UIColor, dark: UIColor) {
    let provider: @Sendable (UITraitCollection) -> UIColor = { $0.userInterfaceStyle == .dark ? dark : light }
    self.init(uiColor: UIColor(dynamicProvider: provider))
  }
}

extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(
      red: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1)
  }
}

extension Font {
  /// Row titles: worktrees, agents, settings rows.
  static let rowTitle = Font.system(size: 17, weight: .semibold)
  /// Secondary lines under a row title.
  static let rowDetail = Font.system(size: 13)
  /// Section and status captions.
  static let caption13 = Font.system(size: 13, weight: .medium)
}

extension View {
  /// Animates `value` changes with the standard curve, or not at all under
  /// Reduce Motion.
  func themeAnimation<V: Equatable>(_ value: V) -> some View {
    modifier(ThemeAnimation(value: value))
  }
}

private struct ThemeAnimation<V: Equatable>: ViewModifier {
  let value: V
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(Theme.Motion.standard(reduceMotion: reduceMotion), value: value)
  }
}
