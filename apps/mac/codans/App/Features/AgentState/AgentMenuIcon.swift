import AppKit
import CodansCore
import SwiftUI

/// Agent glyph sized for a native menu row.
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
    image(for: .brand(kind))
  }

  static func image(for icon: AgentIconRef) -> Image {
    if let sized = nsImage(for: icon) { return Image(nsImage: sized) }
    switch icon {
    case .brand: return Image(systemName: "sparkles")
    case .symbol(let name): return Image(systemName: name)
    }
  }

  /// The same glyph as an `NSImage`, for menus built directly in AppKit.
  /// `nil` when the asset or symbol does not resolve.
  static func nsImage(for icon: AgentIconRef) -> NSImage? {
    switch icon {
    case .brand(let kind):
      return brandImage(assetName: AgentCatalog.descriptor(for: kind).iconAssetName)
    case .symbol(let name):
      let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
      return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    }
  }

  private static func brandImage(assetName: String) -> NSImage? {
    guard let base = NSImage(named: assetName) else { return nil }
    // `copy()` so resizing does not mutate the shared cached asset — the
    // 16pt row logo and this 14pt menu glyph come from the same name.
    guard let sized = base.copy() as? NSImage else { return base }
    sized.size = NSSize(width: size, height: size)
    sized.isTemplate = true
    return sized
  }
}
