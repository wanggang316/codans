import AppKit
import CodansCore
import SwiftUI

/// AppKit half of the dual-path appearance wiring. SwiftUI's `.preferredColorScheme`
/// doesn't reach AppKit-hosted surfaces (Metal-backed Ghostty views); this representable
/// pokes `NSApp.appearance` and each `NSApp.windows[n].appearance` so those surfaces and
/// the window chrome (title bar, traffic lights, shadow) re-render in sync with the
/// user's picker choice. `viewDidMoveToWindow` fires once per scene attachment so newly
/// opened windows pick up the current appearance at birth.
struct WindowAppearanceSetter: NSViewRepresentable {
  let preference: AppearancePreference

  func makeNSView(context: Context) -> AppearanceApplyingView {
    let view = AppearanceApplyingView()
    view.preference = preference
    return view
  }

  func updateNSView(_ nsView: AppearanceApplyingView, context: Context) {
    nsView.preference = preference
  }
}

final class AppearanceApplyingView: NSView {
  var preference: AppearancePreference = .system {
    didSet {
      guard preference != oldValue else { return }
      applyAppearance(reason: "preferenceChanged")
    }
  }

  /// Last scheme pushed to libghostty via `syncGhosttyScheme`. Skipping redundant
  /// pushes keeps AppKit's benign tick-driven `viewDidChangeEffectiveAppearance`
  /// calls from re-painting surfaces on every run-loop iteration.
  private var lastPushedGhosttyScheme: SwiftUI.ColorScheme?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance(reason: "viewDidMoveToWindow")
    syncGhosttyScheme(reason: "viewDidMoveToWindow")
  }

  /// AppKit-native hook that fires whenever the resolved appearance changes —
  /// covers both the manual preference toggle (via the `NSApp.appearance`
  /// cascade) and the macOS system dark-mode flip when preference is `.system`.
  /// Pushing from here is more reliable than `GhosttyColorSchemeSyncView`'s
  /// SwiftUI `onChange(of: \.colorScheme)`, which can miss system-level flips if
  /// the enclosing view body doesn't re-evaluate. Both paths coexist and are
  /// deduped by `lastPushedGhosttyScheme` + `setColorScheme`'s idempotency.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncGhosttyScheme(reason: "viewDidChangeEffectiveAppearance")
  }

  private func syncGhosttyScheme(reason: String) {
    // Explicit light/dark resolve from the preference *constant*, never from the
    // view's effective appearance: `applyAppearance` overrides the main window's
    // `appearance` with the value inferred from the Ghostty terminal
    // background's luminance, and sampling that back would form a feedback loop
    // that drops the user's picker whenever the inferred chrome appearance and
    // the picker disagree (e.g. user picks "Light" but the active Ghostty
    // palette has a dark background). `.system` is exempt — it leaves
    // `window.appearance` nil (no override, no loop), so it safely samples the
    // view's own effective appearance. See `resolveColorScheme`.
    let scheme = resolveColorScheme()
    guard lastPushedGhosttyScheme != scheme else { return }
    lastPushedGhosttyScheme = scheme
    GhosttyRuntime.shared?.setColorScheme(scheme)
    AppearanceDiagnostics.log(
      "ghostty-scheme-sync reason=\(reason) "
        + "preference=\(preference.rawValue) "
        + "scheme=\(scheme == .dark ? "dark" : "light")"
    )
  }

  /// User-picker-driven scheme. `.system` reads *this view's* effective
  /// appearance — which follows the OS dark-mode flag while both
  /// `NSApp.appearance` and the window's `appearance` are nil. We deliberately
  /// avoid `NSApp.effectiveAppearance`: inside `viewDidChangeEffectiveAppearance`
  /// the view's own value is the already-settled, authoritative one, whereas the
  /// app-level property can lag a runloop turn behind right after
  /// `NSApp.appearance` is cleared to nil. That lag made the light→system flip
  /// resolve stale-light, trip the `lastPushedGhosttyScheme` dedup, and never
  /// push the dark palette — with no second callback to retry (the sidebar
  /// chrome then kept the light tone until the next explicit toggle).
  private func resolveColorScheme() -> SwiftUI.ColorScheme {
    switch preference {
    case .light: return .light
    case .dark: return .dark
    case .system:
      let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return isDark ? .dark : .light
    }
  }

  private func applyAppearance(reason: String) {
    guard window != nil else { return }
    let appearance = preference.appearance
    NSApp.appearance = appearance
    // Push the resolved scheme to Ghostty *before* we sample its background —
    // otherwise we'd infer chrome luminance from the *previous* palette and
    // then have to re-apply on the next pass. setColorScheme also paints
    // each NSWindow's backgroundColor, so the loop below is purely about
    // appearance + invalidation.
    syncGhosttyScheme(reason: "applyAppearance")
    let ghosttyBackground = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
    // Infer chrome appearance from the resolved Ghostty background. Only
    // applied to main windows in *explicit* picker modes (light / dark) —
    // in `.system` the window's appearance stays nil so OS dark-mode flips
    // cascade naturally via NSApp.effectiveAppearance.
    let inferredChromeAppearance: NSAppearance? =
      (preference == .system) ? nil : ghosttyBackground.perceivedAppearance
    for window in NSApp.windows {
      let isSettings = SettingsWindowTagger.matches(window)
      if isSettings {
        // Settings window opts out of the Ghostty terminal-background stain
        // *and* the luminance-derived chrome override so its panes keep the
        // standard macOS Settings tone. See `SettingsWindowTagger`.
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
      } else {
        window.appearance = inferredChromeAppearance ?? appearance
        // Route through the runtime so the window picks up `background-opacity`
        // / `background-blur` (frosted glass) consistently with the
        // color-scheme path. Fall back to a plain opaque stain when the runtime
        // isn't up yet (tests / pre-bringUp), matching the prior behavior.
        if let runtime = GhosttyRuntime.shared {
          runtime.applyTerminalWindowBackground(window)
        } else {
          window.backgroundColor = ghosttyBackground
        }
      }
      window.contentView?.needsLayout = true
      window.contentView?.needsDisplay = true
      window.invalidateShadow()
    }
    let windowEffectives = NSApp.windows
      .map { $0.effectiveAppearance.name.rawValue.replacingOccurrences(of: "NSAppearanceName", with: "") }
      .joined(separator: ",")
    AppearanceDiagnostics.log(
      "app-appearance reason=\(reason) mode=\(preference.rawValue) "
        + "requested=\(appearance?.name.rawValue ?? "nil") "
        + "inferred=\(inferredChromeAppearance?.name.rawValue ?? "nil") "
        + "appEffective=\(NSApp.effectiveAppearance.name.rawValue) "
        + "windowEffectives=[\(windowEffectives)] "
        + "windowCount=\(NSApp.windows.count)"
    )
  }
}
