import SwiftUI

/// Bridges SwiftUI's `@Environment(\.colorScheme)` (already resolved by
/// `AppAppearanceView`) into libghostty's runtime color-scheme signal. Fires once on
/// mount (`initial: true`) so a freshly created scene inherits the current palette
/// without waiting for a user toggle.
///
/// Wrapped around the terminal-hosting subtree rather than the whole app tree because
/// the cost is only meaningful where Ghostty surfaces actually render; placing it here
/// keeps the contract local ("this subtree stays in sync with Ghostty").
struct GhosttyColorSchemeSyncView<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content.onChange(of: colorScheme, initial: true) { _, newValue in
      GhosttyRuntime.shared?.setColorScheme(newValue)
    }
  }
}
