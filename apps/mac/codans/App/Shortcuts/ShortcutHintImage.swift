import AppKit

/// A chord drawn as an image in the `ShortcutHintLabel` style (`.caption`, secondary), for
/// AppKit controls that show an image where a hint goes (a toolbar segment).
@MainActor
enum ShortcutHintImage {
  private static var cache: [String: NSImage] = [:]

  /// The chord, centered in an image at least `minHeight` tall so it takes the place of a
  /// glyph of that height without moving the control's content up or down. The color
  /// resolves when AppKit draws the image, so it follows the light or dark appearance.
  static func image(of chord: String, minHeight: CGFloat = 16) -> NSImage {
    let key = "\(chord)#\(Int(minHeight))"
    if let cached = cache[key] { return cached }
    let font = NSFont.preferredFont(forTextStyle: .caption1)
    let measured = (chord as NSString).size(withAttributes: [.font: font])
    let size = NSSize(width: ceil(measured.width), height: max(ceil(measured.height), minHeight))
    let image = NSImage(size: size, flipped: false) { rect in
      let origin = NSPoint(x: rect.minX, y: rect.midY - measured.height / 2)
      (chord as NSString).draw(
        at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
      return true
    }
    image.accessibilityDescription = chord
    cache[key] = image
    return image
  }
}
