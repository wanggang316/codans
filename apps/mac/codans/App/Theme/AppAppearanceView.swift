import SwiftUI
import CodansCore

/// Scene-root wrapper that drives the whole app's appearance from a single owner:
/// the AppKit `WindowAppearanceSetter`, which sets `NSApp.appearance` (and per-window
/// `appearance`) from the user's `AppearancePreference`.
///
/// We deliberately do *not* also apply SwiftUI's `.preferredColorScheme` here. On macOS
/// `.preferredColorScheme` pins each window's `NSWindow.appearance`, so it fought the
/// AppKit writer over the same property — and its `nil` ("follow system") case does not
/// reset a previously-pinned window back to nil. That left an explicit→Auto switch stuck
/// on the old light/dark scheme: the window never re-resolved, so neither the Ghostty
/// palette nor SwiftUI's `@Environment(\.colorScheme)` refreshed. With AppKit as the sole
/// writer of `NSApp.appearance`, SwiftUI derives `colorScheme` from the host window's
/// effective appearance automatically, and Auto resolves correctly. Placed at the root of
/// each scene so newly opened windows inherit the current appearance at birth.
struct AppAppearanceView<Content: View>: View {
  let settingsStore: SettingsStore
  let content: Content

  init(settingsStore: SettingsStore, @ViewBuilder content: () -> Content) {
    self.settingsStore = settingsStore
    self.content = content()
  }

  var body: some View {
    let preference = settingsStore.settings.general.appearance
    content
      .background {
        WindowAppearanceSetter(preference: preference)
      }
  }
}
