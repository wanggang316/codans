import AppKit
import SwiftUI

/// Window surface that matches the sidebar. On macOS 26 the sidebar column
/// is an `NSGlassEffectView`, so this is one too; earlier systems draw the
/// sidebar with the `.sidebar` visual-effect material.
struct SidebarMatchingBackground: View {
  var body: some View {
    if #available(macOS 26.0, *) {
      GlassBackground()
    } else {
      VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
    }
  }
}

@available(macOS 26.0, *)
private struct GlassBackground: NSViewRepresentable {
  private static let sidebarVariant = 17

  func makeNSView(context: Context) -> NSGlassEffectView {
    let view = NSGlassEffectView()
    view.cornerRadius = 0
    // The sidebar column's glass uses a variant that public API cannot
    // select (read from the live sidebar view: `_variant` 17). Without it
    // the glass is near-clear and reads lighter than the sidebar. Guarded,
    // so a system that drops the key falls back to the public look.
    if view.responds(to: NSSelectorFromString("set_variant:")) {
      view.setValue(Self.sidebarVariant, forKey: "_variant")
    }
    return view
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}
