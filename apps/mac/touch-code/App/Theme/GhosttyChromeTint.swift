import AppKit
import SwiftUI

/// Paints a low-alpha Ghostty-terminal-background band into the requested
/// chrome edges of the detail body. The translucent toolbar and floating
/// sidebar glass blend on top, so the window chrome reads as a softened
/// version of the active terminal palette instead of the neutral system tone.
///
/// Why a band overlay instead of `NSWindow.backgroundColor`: SwiftUI's
/// `NavigationSplitView` fills the window opaquely, so a window-level
/// background-color stain has nothing to bleed through. The detail column
/// extends behind both the unified-style toolbar (top safe-area inset) and
/// the macOS 26 floating sidebar overlay (leading safe-area inset); painting
/// in those insets is the surface the chrome material actually samples.
extension View {
  /// Overlays a thin Ghostty-tinted band in the requested chrome edges.
  ///
  /// - Parameters:
  ///   - edges: which chrome regions to tint. Defaults to both — `.top`
  ///     paints behind the toolbar, `.leading` paints behind the floating
  ///     sidebar overlay.
  ///   - alpha: peak fill alpha for the band. Low values keep the system
  ///     glass material visible on top; raise toward 1.0 for a stronger
  ///     terminal-tone wash.
  func ghosttyChromeTint(
    edges: Edge.Set = [.top, .leading],
    alpha: Double = 0.18
  ) -> some View {
    modifier(GhosttyChromeTintModifier(edges: edges, alpha: alpha))
  }
}

private struct GhosttyChromeTintModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  /// Bumped on `.ghosttyRuntimeConfigApplied` so a user theme / palette
  /// change re-resolves the band color without an app restart. We deliberately
  /// observe the *applied* signal (post-swap) rather than `.ghosttyRuntimeReloadRequested`
  /// (pre-swap) — libghostty hands the new config back asynchronously, so
  /// the request notification fires while `backgroundColor()` still returns
  /// the previous palette. `colorScheme` covers the light/dark flip path.
  @State private var reloadTrigger: Int = 0
  let edges: Edge.Set
  let alpha: Double

  func body(content: Content) -> some View {
    // Reading both establishes the SwiftUI dependencies that drive
    // re-resolution of the underlying NSColor. The runtime returns the
    // already-resolved palette color, so we don't need a dynamic NSColor.
    _ = (colorScheme, reloadTrigger)
    let nsColor = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
    let color = Color(nsColor: nsColor)
    return
      content
      .modifier(GhosttyChromeTintBands(color: color, alpha: alpha, edges: edges))
      .onReceive(
        NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)
      ) { _ in
        reloadTrigger &+= 1
      }
  }
}

/// Geometry-driven painter: measures the top + leading safe-area insets of
/// the content (which equal the unified-toolbar height and the floating-
/// sidebar width respectively) and fills each requested edge with the band.
private struct GhosttyChromeTintBands: ViewModifier {
  let color: Color
  let alpha: Double
  let edges: Edge.Set

  @State private var topInset: CGFloat = 0
  @State private var leadingInset: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGFloat.self) {
        $0.safeAreaInsets.top
      } action: {
        topInset = $0
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.safeAreaInsets.leading
      } action: {
        leadingInset = $0
      }
      .overlay(alignment: .top) {
        if edges.contains(.top) {
          band
            .frame(height: topInset)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
      }
      .overlay(alignment: .leading) {
        if edges.contains(.leading) {
          band
            .frame(width: leadingInset)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.leading, .top, .bottom])
        }
      }
  }

  private var band: some View {
    color
      .opacity(alpha)
      .allowsHitTesting(false)
  }
}
