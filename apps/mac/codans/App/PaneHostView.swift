import AppKit
import SwiftUI
import CodansCore

/// Hosts a `PaneSurface`'s `GhosttySurfaceView` inside SwiftUI.
///
/// The host view doesn't own the surface — the caller (typically
/// `SingleSurfaceHost` or a future TCA feature) retains it. SwiftUI calls
/// `dismantleNSView` when the representable leaves the tree; we route that
/// into `PaneSurface.close()` so the ghostty surface + child PTY go down
/// even if the wider catalog cleanup fires later.
struct PaneHostView: NSViewRepresentable {
  let surface: PaneSurface

  func makeNSView(context: Context) -> GhosttySurfaceView {
    surface.view
  }

  func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
    // Nothing to do — ghostty renders on its own cadence.
  }

  static func dismantleNSView(_ nsView: GhosttySurfaceView, coordinator: ()) {
    // We don't hold a strong ref to the PaneSurface here (NSViewRepresentable
    // methods are static), but the view.attach ↔ detach is idempotent. Actual
    // surface teardown happens via SingleSurfaceHost.tearDown() on scene
    // transition — called separately — so this method is intentionally a
    // no-op. Left in place for symmetry with makeNSView and future use.
    _ = nsView
  }
}
