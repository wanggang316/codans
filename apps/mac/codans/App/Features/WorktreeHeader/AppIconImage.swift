import AppKit
import SwiftUI

/// SwiftUI image that resolves the macOS app icon for a given bundle
/// identifier via `NSWorkspace`. Falls back to a generic SF Symbol if
/// the bundle can't be located (app not installed, or shell editors
/// without a bundle id).
///
/// The NSImage from Launch Services is full-size (~256pt). When this
/// view is hosted inside a `Menu(primaryAction:)` label or any other
/// surface that bridges to AppKit, the AppKit side reads the source
/// NSImage's intrinsic size — `.resizable().frame(...)` only constrains
/// the SwiftUI render and does not propagate. We therefore redraw the
/// NSImage at the AppKit layer before handing it to SwiftUI, so its
/// intrinsic size matches the requested point-size square.
struct AppIconImage: View {
  let bundleIdentifier: String
  let fallbackSystemName: String
  /// Edge length of the rendered icon in points. Defaults to the macOS
  /// menu / toolbar glyph slot size.
  var size: CGFloat = 16

  var body: some View {
    if let nsImage = Self.resolve(bundleIdentifier: bundleIdentifier) {
      Image(nsImage: Self.resized(nsImage, to: size))
        .renderingMode(.original)
        .accessibilityHidden(true)
    } else {
      Image(systemName: fallbackSystemName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  private static func resolve(bundleIdentifier: String) -> NSImage? {
    guard !bundleIdentifier.isEmpty,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  /// Redraws an NSImage at the requested point-size square so its
  /// intrinsic size matches the slot the icon will live in. Mirrors
  /// `EditorPickerRow.icon`'s pre-resize so menu rows + toolbar chips
  /// stay compact regardless of the source icon's native dimensions.
  private static func resized(_ image: NSImage, to side: CGFloat) -> NSImage {
    let target = NSSize(width: side, height: side)
    let resized = NSImage(size: target)
    resized.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: target),
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: 1.0
    )
    resized.unlockFocus()
    return resized
  }
}
