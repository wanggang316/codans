import AppKit

/// A chord in the form an `NSMenuItem` shows it: the key equivalent and its
/// modifier flags. Lets Runtime-built menus show the app's effective chords
/// without reading the shortcut registry.
struct MenuKeyEquivalent: Equatable {
  let key: String
  let modifiers: NSEvent.ModifierFlags
}
