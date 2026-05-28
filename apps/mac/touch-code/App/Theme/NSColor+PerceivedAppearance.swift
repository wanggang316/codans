import AppKit

extension NSColor {
  /// Returns the `NSAppearance` whose light / dark variant visually pairs
  /// with this colour. Nil if the colour cannot be normalised to sRGB
  /// (dynamic catalogue colours that need a draw context, primarily).
  ///
  /// Used by the chrome stack to flip sidebar / toolbar material into the
  /// tone that matches the actively rendered Ghostty terminal background,
  /// so the surrounding window chrome does not clash with the palette the
  /// user is actually looking at.
  var perceivedAppearance: NSAppearance? {
    guard let rgb = usingColorSpace(.sRGB) else { return nil }
    // Rec. 601 luma. Good-enough perceptual proxy for the "is this colour
    // closer to white or black" question we care about here; the exact
    // threshold isn't load-bearing because Ghostty bg colours sit far
    // from the 0.5 midpoint in practice.
    let luminance =
      0.299 * rgb.redComponent
      + 0.587 * rgb.greenComponent
      + 0.114 * rgb.blueComponent
    return NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
  }
}
