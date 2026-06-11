import Foundation

/// Appearance preference rendered in General settings. Drives the app's visual appearance
/// via the dual-path wrapper in `App/Theme/AppAppearanceView`: SwiftUI's
/// `.preferredColorScheme` for SwiftUI descendants and `NSApp.appearance` for AppKit-hosted
/// surfaces (notably Ghostty). See `docs/design-docs/app-appearance.md`.
public nonisolated enum AppearancePreference: String, Equatable, Codable, Sendable, CaseIterable {
  case system
  case light
  case dark
}
