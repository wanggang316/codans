import SwiftUI

/// Per-Project accent color shown in Settings → Projects → General, and the
/// tint the Project's icon renders in. Either a named entry from the
/// codans palette or a free-form `#RRGGBB` value supplied via the system
/// color panel. `nil` on `Project.color` means "No Color" — fall back to the
/// system accent.
///
/// The named palette is codans's own designed set, not the macOS Finder one
/// `TagColor` / `TabColor` follow — those two are unchanged and still mirror
/// the system colors. Exact values live on `hexValue`.
///
/// Codable shape is a single string: named cases encode as their lower-case
/// label (`"red"`, `"orange"`, …); custom encodes as the uppercase hex
/// (`"#FF00AA"`). The `#` prefix is the discriminator on decode, so adding
/// future named cases never collides with a custom value.
public nonisolated enum ProjectColor: Equatable, Hashable, Sendable {
  case blue
  case purple
  case pink
  case red
  case orange
  case yellow
  case green
  case grey
  case custom(hex: String)

  /// Named entries surfaced as inline swatches in the picker, in palette
  /// order. Custom colors live behind a separate trigger so the steady-state
  /// row has a fixed number of dots.
  public static let namedCases: [ProjectColor] = [
    .blue, .purple, .pink, .red, .orange, .yellow, .green, .grey,
  ]

  /// Canonical sRGB hex. Named entries are fixed designed values rather than
  /// the system palette (`.red`, `.blue`, …): the set is tuned to sit together
  /// as a row of swatches and to stay legible at icon size, which the system
  /// colors — individually vivid, collectively unbalanced — did not. The
  /// trade-off is that these do not shift with the system appearance; they are
  /// mid-tone enough to hold up on both light and dark backgrounds.
  ///
  /// `.custom` returns the hex it carries, so every case resolves through one
  /// path.
  public var hexValue: String {
    switch self {
    case .blue: "#1594F9"
    case .purple: "#A05EA3"
    case .pink: "#F179AC"
    case .red: "#DF6055"
    case .orange: "#F29A46"
    case .yellow: "#FCD05E"
    case .green: "#84C068"
    case .grey: "#A8A8A8"
    case .custom(let hex): hex
    }
  }

  public var swiftUIColor: Color {
    Self.parseHex(hexValue) ?? .accentColor
  }

  public var displayName: String {
    switch self {
    case .blue: "Blue"
    case .purple: "Purple"
    case .pink: "Pink"
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .grey: "Grey"
    case .custom: "Custom"
    }
  }

  /// Parse a `#RRGGBB` (or `RRGGBB`) string into a SwiftUI `Color`. Returns
  /// `nil` for malformed input so callers can fall back to the accent.
  public static func parseHex(_ hex: String) -> Color? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    return Color(red: r, green: g, blue: b)
  }
}

extension ProjectColor: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    switch raw {
    case "blue": self = .blue
    case "purple": self = .purple
    case "pink": self = .pink
    case "red": self = .red
    case "orange": self = .orange
    case "yellow": self = .yellow
    case "green": self = .green
    case "grey": self = .grey
    default:
      // Custom hex is the catch-all. Validate via `parseHex` so a typo
      // can't smuggle in an unparseable value that the renderer would
      // fall back on every paint.
      if raw.hasPrefix("#"), Self.parseHex(raw) != nil {
        self = .custom(hex: raw.uppercased())
      } else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Unknown ProjectColor value: \(raw)"
        )
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .blue: try container.encode("blue")
    case .purple: try container.encode("purple")
    case .pink: try container.encode("pink")
    case .red: try container.encode("red")
    case .orange: try container.encode("orange")
    case .yellow: try container.encode("yellow")
    case .green: try container.encode("green")
    case .grey: try container.encode("grey")
    case .custom(let hex): try container.encode(hex.uppercased())
    }
  }
}
