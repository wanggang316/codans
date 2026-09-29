import AppKit
import CodansCore
import SwiftUI

extension ToolMark {
  /// Asset catalog name of the mark's template SVG (`tool-<raw>`).
  var assetName: String { "tool-\(rawValue)" }
}

/// Draws a `CommandIconRef` the way an SF Symbol would sit in the same spot:
/// symbols render as-is, tool marks as template images boxed to the symbol's
/// optical size so both inherit `.foregroundStyle` and share a baseline.
struct CommandIconGlyph: View {
  let icon: CommandIconRef
  /// Box for a tool mark. Match the point size of neighbouring symbols.
  var markSize: CGFloat = 14

  var body: some View {
    switch icon {
    case .symbol(let name):
      Image(systemName: name)
    case .mark(let mark):
      Image(mark.assetName)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: markSize, height: markSize)
        .accessibilityLabel(mark.displayName)
    }
  }
}

/// Glyph for an icon string as stored on a tab or palette item: an
/// `agent:<kind>` brand mark, a `mark:<tool>` tool mark, or an SF Symbol name.
struct StoredIconGlyph: View {
  let icon: String
  var markSize: CGFloat = 14

  var body: some View {
    if let kind = TabIconRef.agentKind(from: icon) {
      Image(AgentCatalog.descriptor(for: kind).iconAssetName)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: markSize, height: markSize)
    } else if let ref = CommandIconRef(storedValue: icon) {
      CommandIconGlyph(icon: ref, markSize: markSize)
    }
  }
}

/// `NSImage` renderings for AppKit-backed surfaces (menus, toolbar items)
/// that re-template SwiftUI images and drop their colour.
enum CommandIconImage {
  /// Monochrome template image: the menu colours it like its text, including
  /// the inverted colour of a highlighted row. For menu items whose icon has
  /// no colour identity to keep.
  static func template(_ icon: CommandIconRef, pointSize: CGFloat = 14) -> NSImage? {
    switch icon {
    case .symbol(let name):
      let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
      image?.isTemplate = true
      return image
    case .mark(let mark):
      guard let base = NSImage(named: mark.assetName) else { return nil }
      let side = (pointSize * 0.95).rounded()
      let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        base.draw(in: rect)
        return true
      }
      image.isTemplate = true
      image.accessibilityDescription = mark.displayName
      return image
    }
  }

  /// Non-template image with `color` baked in. Symbols go through a palette
  /// symbol configuration; marks are filled with the colour over their alpha.
  static func tinted(_ icon: CommandIconRef, color: NSColor, pointSize: CGFloat = 14) -> NSImage? {
    switch icon {
    case .symbol(let name):
      let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
      guard
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
        let tinted = base.withSymbolConfiguration(configuration)
      else { return nil }
      tinted.isTemplate = false
      return tinted
    case .mark(let mark):
      guard let base = NSImage(named: mark.assetName) else { return nil }
      // Marks are square artwork; a symbol of the same point size is optically
      // a little smaller than its em box, so shave the box to match.
      let side = (pointSize * 0.95).rounded()
      let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
      }
      image.isTemplate = false
      image.accessibilityDescription = mark.displayName
      return image
    }
  }
}
