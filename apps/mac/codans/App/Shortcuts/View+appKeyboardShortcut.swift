import SwiftUI
import CodansCore

extension View {
  /// Bind the SwiftUI `.keyboardShortcut` for `id` from the supplied resolved map.
  ///
  /// Use this overload inside `Commands` scenes (which cannot read `@Environment` directly).
  /// The modifier short-circuits — returns `self` unchanged — when the resolved entry is
  /// missing, disabled, or has no matching `KeyEquivalent`.
  @ViewBuilder
  public func appKeyboardShortcut(_ id: CommandID, in map: ResolvedShortcutMap) -> some View {
    if let resolved = AppKeyboardShortcutResolver.resolve(id, in: map) {
      self.keyboardShortcut(resolved.key, modifiers: resolved.modifiers)
    } else {
      self
    }
  }

  /// Env-driven overload for ordinary view contexts. Reads `\.resolvedShortcuts` and
  /// delegates to the explicit-map form.
  public func appKeyboardShortcut(_ id: CommandID) -> some View {
    AppKeyboardShortcutEnvironmentReader(id: id, content: { self })
  }
}

/// Pure helper that turns `(CommandID, ResolvedShortcutMap)` into the `(key, modifiers)`
/// pair SwiftUI's `.keyboardShortcut` consumes — or `nil` when the row should not bind.
public enum AppKeyboardShortcutResolver {
  public struct Binding: Equatable {
    public let key: KeyEquivalent
    public let modifiers: SwiftUI.EventModifiers
  }

  public static func resolve(_ id: CommandID, in map: ResolvedShortcutMap) -> Binding? {
    guard let resolved = map[id], resolved.isEnabled,
      let binding = resolved.binding,
      let key = ShortcutDisplay.keyEquivalent(for: binding.keyCode)
    else { return nil }
    return Binding(key: key, modifiers: ShortcutDisplay.eventModifiers(for: binding.modifiers))
  }
}

/// Wrapper that makes the env-driven overload's `@ViewBuilder` legal: SwiftUI requires
/// `@Environment` reads to live inside a `View`, not inside an extension method.
private struct AppKeyboardShortcutEnvironmentReader<Content: View>: View {
  let id: CommandID
  @ViewBuilder let content: () -> Content
  @Environment(\.resolvedShortcuts) private var shortcuts

  var body: some View {
    content().appKeyboardShortcut(id, in: shortcuts)
  }
}
