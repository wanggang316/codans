import AppKit
import SwiftUI
import CodansCore

/// View-side mapping from the model-layer `ScriptTintColor` token to a
/// SwiftUI `Color`. Lives here so `CodansCore` stays UI-framework-free
/// and every consumer (script editor, header split button, command
/// palette icons) shares one palette.
enum ScriptTintColorPalette {
  static func color(for tint: ScriptTintColor) -> Color {
    switch tint {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    case .blue: return .blue
    case .teal: return .teal
    case .purple: return .purple
    case .gray: return .gray
    }
  }

  /// Icon image with the tint colour baked in as a *non-template* `NSImage`.
  /// Native `Menu` items render their icon as a monochrome template and strip
  /// SwiftUI's `.foregroundStyle`, so baking the colour into the image (and
  /// clearing `isTemplate`) is the only way to show a coloured glyph in a menu.
  static func menuIcon(_ icon: CommandIconRef, tint: ScriptTintColor) -> Image {
    if let tinted = CommandIconImage.tinted(icon, color: NSColor(color(for: tint))) {
      return Image(nsImage: tinted)
    }
    return Image(systemName: ScriptKind.custom.defaultSystemImage)
  }

  static func menuIcon(systemName: String, tint: ScriptTintColor) -> Image {
    menuIcon(.symbol(systemName), tint: tint)
  }
}
