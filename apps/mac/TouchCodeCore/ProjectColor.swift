import AppKit
import SwiftUI

/// Per-Project accent color shown in Settings → Projects → General. Either
/// a named entry from the macOS Finder palette (mirrors `TagColor` /
/// `TabColor`) or a free-form `#RRGGBB` value supplied via the system color
/// panel. `nil` on `Project.color` means "No Color" — fall back to the
/// system accent.
///
/// Codable shape is a single string: named cases encode as their lower-case
/// label (`"red"`, `"orange"`, …); custom encodes as the uppercase hex
/// (`"#FF00AA"`). The `#` prefix is the discriminator on decode, so adding
/// future named cases never collides with a custom value.
public nonisolated enum ProjectColor: Equatable, Hashable, Sendable {
  case red
  case orange
  case yellow
  case green
  case blue
  case purple
  case grey
  case custom(hex: String)

  /// Named entries surfaced as inline swatches in the picker. Custom colors
  /// live behind a separate trigger so the steady-state row has a fixed
  /// number of dots.
  public static let namedCases: [ProjectColor] = [
    .red, .orange, .yellow, .green, .blue, .purple, .grey,
  ]

  public var swiftUIColor: Color {
    switch self {
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .blue: .blue
    case .purple: .purple
    case .grey: .gray
    case .custom(let hex): Self.parseHex(hex) ?? .accentColor
    }
  }

  public var displayName: String {
    switch self {
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .blue: "Blue"
    case .purple: "Purple"
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

  /// Convert an `NSColor` (in any color space) into a canonical
  /// `#RRGGBB` string. Routes through sRGB so the persisted hex round-trips
  /// stably regardless of the source color space.
  public static func hex(from nsColor: NSColor) -> String? {
    guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }

  /// Inverse of `hex(from:)` — `#RRGGBB` or `RRGGBB` to an sRGB `NSColor`.
  /// Used to seed `NSColorPanel.color` with the last picked custom value so
  /// re-opening the panel starts where the user left off.
  public static func nsColor(from hex: String) -> NSColor? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >> 8) & 0xFF) / 255
    let b = CGFloat(v & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
  }
}

extension ProjectColor: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    switch raw {
    case "red": self = .red
    case "orange": self = .orange
    case "yellow": self = .yellow
    case "green": self = .green
    case "blue": self = .blue
    case "purple": self = .purple
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
    case .red: try container.encode("red")
    case .orange: try container.encode("orange")
    case .yellow: try container.encode("yellow")
    case .green: try container.encode("green")
    case .blue: try container.encode("blue")
    case .purple: try container.encode("purple")
    case .grey: try container.encode("grey")
    case .custom(let hex): try container.encode(hex.uppercased())
    }
  }
}
