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
    if let nsImage = resolve() {
      Image(nsImage: nsImage)
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

  /// Resolves the bundle's icon through the process-lifetime
  /// `EditorAppIcons` cache — the LaunchServices lookup and the redraw
  /// each happen at most once per (bundle, size) per launch.
  private func resolve() -> NSImage? {
    guard let url = EditorAppIcons.appURL(bundleIdentifier: bundleIdentifier) else {
      return nil
    }
    return EditorAppIcons.resizedIcon(atPath: url.path, side: size)
  }
}
