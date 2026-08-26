import AppKit
import CodansCore
import SwiftUI

/// Agent brand glyph sized for a native menu row.
///
/// A bare `Image("codex")` inside a `Menu`'s `Label` renders at the asset's
/// intrinsic size — SwiftUI's usual `.resizable().frame(…)` chain does not
/// survive the bridge to `NSMenuItem.image`, so one oversized SVG blows the
/// whole menu's layout apart. Building the `NSImage` and pinning its `size`
/// here is the same trick `ScriptTintColorPalette.menuIcon` uses for tinted
/// SF Symbols.
enum AgentMenuIcon {
  /// Menu-row glyph edge, matching the 14pt point size used for script icons.
  static let size: CGFloat = 14

  static func image(for kind: AgentKind) -> Image {
    let assetName = AgentCatalog.descriptor(for: kind).iconAssetName
    guard let base = NSImage(named: assetName) else {
      return Image(systemName: "sparkles")
    }
    // `copy()` so resizing does not mutate the shared cached asset — the
    // 16pt row logo and this 14pt menu glyph come from the same name.
    guard let sized = base.copy() as? NSImage else { return Image(nsImage: base) }
    sized.size = NSSize(width: size, height: size)
    sized.isTemplate = true
    return Image(nsImage: sized)
  }
}
