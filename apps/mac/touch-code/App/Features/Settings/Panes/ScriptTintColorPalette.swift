import AppKit
import SwiftUI
import TouchCodeCore

/// View-side mapping from the model-layer `ScriptTintColor` token to a
/// SwiftUI `Color`. Lives here so `TouchCodeCore` stays UI-framework-free
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

  /// Symbol image with the tint colour baked in as a *non-template* `NSImage`.
  /// Native `Menu` items render their icon as a monochrome template and strip
  /// SwiftUI's `.foregroundStyle`, so baking the colour into the image (and
  /// clearing `isTemplate`) is the only way to show a coloured glyph in a menu.
  static func menuIcon(systemName: String, tint: ScriptTintColor) -> Image {
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color(for: tint))]))
    if let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil),
      let tinted = base.withSymbolConfiguration(configuration)
    {
      tinted.isTemplate = false
      return Image(nsImage: tinted)
    }
    return Image(systemName: systemName)
  }
}
