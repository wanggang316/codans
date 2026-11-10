import AppKit

extension NSImage {
  /// Stretchable rounded-rect mask for an `NSVisualEffectView`: only the
  /// corners keep their shape. The window server cuts a borderless panel's
  /// shadow from the same mask, so glass and shadow share one outline.
  static func roundedMask(cornerRadius radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
