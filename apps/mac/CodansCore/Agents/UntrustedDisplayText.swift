import Foundation

/// Program text (OSC 7501 `title` / `message`, OSC 0/2 pane titles) shown
/// outside the terminal grid. It must not carry bidirectional overrides or
/// invisible formatting characters (the protocol's security guidance): they
/// can reorder or hide what the user reads. The text stays untrusted: only
/// display it, never interpret it, and keep it out of durable logs.
public nonisolated enum UntrustedDisplayText {
  /// `value` without bidi overrides and invisible formatting characters, or
  /// nil when nothing is left.
  public static func sanitized(_ value: String?) -> String? {
    guard let value else { return nil }
    let scalars = value.unicodeScalars.filter { !isInvisibleFormatting($0) }
    let text = String(String.UnicodeScalarView(scalars))
    return text.isEmpty ? nil : text
  }

  private static func isInvisibleFormatting(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
      return true
    default:
      return false
    }
  }
}
