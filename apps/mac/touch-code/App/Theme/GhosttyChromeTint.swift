import AppKit
import OSLog
import SwiftUI

private let chromeTintLogger = Logger(
  subsystem: "com.touch-code.runtime", category: "chrome-tint-debug"
)

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

  /// Renders the receiver with the same surface as the floating sidebar
  /// overlay above it: `.sidebar` material + low-alpha Ghostty terminal
  /// tint. Use this on chrome surfaces that sit inside the sidebar column
  /// (e.g. the footer toolbar) — the system sidebar material samples the
  /// chrome tint band in the detail's leading inset, but standalone
  /// surfaces inside the sidebar column do not, so they need the tint
  /// applied directly to read as one continuous surface with the list.
  func ghosttySidebarSurface(alpha: Double = 0.18) -> some View {
    modifier(GhosttySidebarSurfaceModifier(alpha: alpha))
  }
}

private struct GhosttyChromeTintModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  /// Resolved tint color. Stored in `@State` so re-renders are driven by
  /// explicit writes from `refresh()` — we observe both the post-swap
  /// `.ghosttyRuntimeConfigApplied` signal (user theme reload / OS dark-mode
  /// flip — libghostty hands the new config back asynchronously, so the
  /// pre-swap `.ghosttyRuntimeReloadRequested` request notification fires
  /// while `backgroundColor()` still returns the previous palette) and
  /// `colorScheme` changes (SwiftUI Appearance toggle path).
  @State private var nsColor: NSColor = .windowBackgroundColor
  let edges: Edge.Set
  let alpha: Double

  func body(content: Content) -> some View {
    content
      .modifier(GhosttyChromeTintBands(color: Color(nsColor: nsColor), alpha: alpha, edges: edges))
      .onAppear {
        chromeTintLogger.log("modifier onAppear edges=\(String(describing: edges)) alpha=\(alpha)")
        refresh(reason: "onAppear")
      }
      .onChange(of: colorScheme) { _, new in
        chromeTintLogger.log("modifier onChange(colorScheme) new=\(new == .dark ? "dark" : "light")")
        refresh(reason: "colorScheme")
      }
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
        chromeTintLogger.log("modifier received .ghosttyRuntimeConfigApplied")
        refresh(reason: "configApplied")
      }
  }

  private func refresh(reason: String) {
    let resolved = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
    let srgb = resolved.usingColorSpace(.sRGB)
    let r = Int((srgb?.redComponent ?? 0) * 255)
    let g = Int((srgb?.greenComponent ?? 0) * 255)
    let b = Int((srgb?.blueComponent ?? 0) * 255)
    chromeTintLogger.log("refresh(\(reason)) → sRGB(\(r),\(g),\(b))")
    nsColor = resolved
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

/// Backing for `ghosttySidebarSurface`: lays down the system `.sidebar`
/// glass and a Ghostty-terminal tint on top, refreshing the tint on the
/// same signals as `GhosttyChromeTintModifier` (`colorScheme` flip,
/// post-swap `.ghosttyRuntimeConfigApplied`).
private struct GhosttySidebarSurfaceModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @State private var nsColor: NSColor = .windowBackgroundColor
  let alpha: Double

  func body(content: Content) -> some View {
    content
      .background {
        // `.behindWindow` mirrors the original footer choice — avoids the
        // HAN-63 within-window-pixel bleed regression — and the explicit
        // tint above does the colour-match work that `.withinWindow` would
        // otherwise have attempted (and failed, since the macOS 26 floating
        // sidebar overlay is a separate render layer the safe-area-inset
        // surface cannot sample).
        VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
          .overlay(Color(nsColor: nsColor).opacity(alpha))
      }
      .onAppear { refresh() }
      .onChange(of: colorScheme) { _, _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
        refresh()
      }
  }

  private func refresh() {
    nsColor = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
  }
}
