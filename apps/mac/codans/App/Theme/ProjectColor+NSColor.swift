import AppKit
import CodansCore

// NSColor bridging stays app-side so CodansCore compiles for iOS too.
extension ProjectColor {
  /// Convert an `NSColor` (in any color space) into a canonical
  /// `#RRGGBB` string. Routes through sRGB so the persisted hex round-trips
  /// stably regardless of the source color space.
  static func hex(from nsColor: NSColor) -> String? {
    guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }

  /// Inverse of `hex(from:)` — `#RRGGBB` or `RRGGBB` to an sRGB `NSColor`.
  /// Used to seed `NSColorPanel.color` with the last picked custom value so
  /// re-opening the panel starts where the user left off.
  static func nsColor(from hex: String) -> NSColor? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >> 8) & 0xFF) / 255
    let b = CGFloat(v & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
  }
}
