import SwiftUI

/// Git-viewer color tokens. Added in 0005 M4a as a minimal namespace under the app theme
/// (no existing global theme layer in this project; expand into a full Theme type when one
/// lands). Colors deliberately low-saturation so the monospaced text stays readable on both
/// light and dark backgrounds.
enum ThemeGit {
  static let added = Color(nsColor: .systemGreen).opacity(0.85)
  static let removed = Color(nsColor: .systemRed).opacity(0.85)
  static let context = Color(nsColor: .labelColor)
  static let contextDim = Color(nsColor: .secondaryLabelColor)

  static let addedBackground = Color(nsColor: .systemGreen).opacity(0.12)
  static let removedBackground = Color(nsColor: .systemRed).opacity(0.12)

  /// Marker colours for `FileChange.Kind` glyphs in the file list.
  static let kindAdded = Color(nsColor: .systemGreen)
  static let kindDeleted = Color(nsColor: .systemRed)
  static let kindModified = Color(nsColor: .systemOrange)
  static let kindRenamed = Color(nsColor: .systemPurple)
  static let kindCopied = Color(nsColor: .systemTeal)
  static let kindTypeChanged = Color(nsColor: .systemGray)

  static let lineNumberColumn = Color(nsColor: .tertiaryLabelColor)
}
