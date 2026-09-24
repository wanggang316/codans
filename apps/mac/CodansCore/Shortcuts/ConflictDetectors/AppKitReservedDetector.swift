import Foundation

/// AppKit standard-menu chords that are claimed by the default app menu unless deliberately
/// overridden. We surface these to the user as "reserved" so the recorder UI can warn before
/// committing a binding that would shadow (or be shadowed by) the standard menu item.
///
/// The detector encodes AppKit *defaults* as data — key codes come from `KeyCode` (the same
/// source the schema uses). CodansCore stays AppKit-free; the reserved set is a static lookup
/// table, not a runtime introspection of `NSApp.mainMenu`.
public enum AppKitReservedDetector {
  public struct ReservedChord: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ModifierMask

    public init(keyCode: UInt16, modifiers: ModifierMask) {
      self.keyCode = keyCode
      self.modifiers = modifiers
    }
  }

  public static let reservedChords: Set<ReservedChord> = [
    ReservedChord(keyCode: KeyCode.ansiQ, modifiers: [.command]),  // Quit
    ReservedChord(keyCode: KeyCode.ansiW, modifiers: [.command]),  // Close Window
    ReservedChord(keyCode: KeyCode.ansiH, modifiers: [.command]),  // Hide
    ReservedChord(keyCode: KeyCode.ansiM, modifiers: [.command]),  // Minimize
    ReservedChord(keyCode: KeyCode.ansiComma, modifiers: [.command]),  // Settings
    ReservedChord(keyCode: KeyCode.ansiSlash, modifiers: [.command, .shift]),  // Help (⌘?)
  ]

  public static func isReserved(keyCode: UInt16, modifiers: ModifierMask) -> Bool {
    reservedChords.contains(ReservedChord(keyCode: keyCode, modifiers: modifiers))
  }
}
