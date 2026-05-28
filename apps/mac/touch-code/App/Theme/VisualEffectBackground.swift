import AppKit
import SwiftUI

/// SwiftUI bridge around `NSVisualEffectView` so a view can render with
/// the real AppKit glass materials (HUD, sidebar, popover, ...) instead of
/// SwiftUI's `Material` shim. The shim is layer-bound and cannot reach
/// past the hosting window; the real `NSVisualEffectView` with
/// `.behindWindow` blending samples the desktop / windows beneath, which
/// is what the system sidebar list does — using it lets surrounding
/// panels match the sidebar tone exactly without a hand-mixed Color.
struct VisualEffectBackground: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    // `.active` keeps the blur live even when the host window is not key —
    // without this the surface goes flat / opaque on focus loss because
    // the default `.followsWindowActiveState` treats every background
    // window as inactive.
    view.state = .active
    view.isEmphasized = false
    view.autoresizingMask = [.width, .height]
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
  }
}
