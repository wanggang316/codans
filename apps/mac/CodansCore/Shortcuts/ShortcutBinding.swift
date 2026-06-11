import Foundation

/// Persistent, layout-independent description of a keyboard chord plus its enabled flag.
///
/// `keyCode` is a virtual key code (the same numeric space as `Carbon.HIToolbox.kVK_*` and
/// `NSEvent.keyCode`). Storing the *physical* key rather than the typed character keeps the
/// binding stable across input-source switches: the user who trained their muscle memory on
/// the `G` key continues to fire the chord on that physical key after switching to AZERTY,
/// even though that key now produces a different character.
///
/// `isEnabled == false` is a third state distinct from "no override" (the schema default
/// applies) and "no chord" (`binding == nil` in the resolver — not used in v1 since every
/// schema default is non-nil). It models *the user explicitly suppressed this command's
/// chord*.
public struct ShortcutBinding: Equatable, Hashable, Sendable, Codable {
  public let keyCode: UInt16
  public let modifiers: ModifierMask
  public let isEnabled: Bool

  public init(keyCode: UInt16, modifiers: ModifierMask, isEnabled: Bool = true) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.isEnabled = isEnabled
  }
}

/// Modifier-key set for a shortcut binding. Storage-layer mirror of SwiftUI's `EventModifiers`
/// and AppKit's `NSEvent.ModifierFlags`, deliberately not bridging to either so the type can
/// live in CodansCore (no SwiftUI / no AppKit imports). The upper layers convert at the
/// boundary in `ShortcutDisplay`.
///
/// Codable shape: a sorted JSON array of canonical lowercase strings
/// (`["command", "shift"]`). Sorting is enforced on encode so files diff cleanly across
/// machines and avoids gratuitous churn in user-edited files.
public struct ModifierMask: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let command = ModifierMask(rawValue: 1 << 0)
  public static let option = ModifierMask(rawValue: 1 << 1)
  public static let control = ModifierMask(rawValue: 1 << 2)
  public static let shift = ModifierMask(rawValue: 1 << 3)
}

extension ModifierMask: Codable {
  /// Stable lowercase tokens. Order is the canonical display order (⌃⌥⇧⌘) — encode emits a
  /// sorted-by-this-order array; decode is order-insensitive.
  private static let canonicalOrder: [(ModifierMask, String)] = [
    (.control, "control"),
    (.option, "option"),
    (.shift, "shift"),
    (.command, "command"),
  ]

  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var mask = ModifierMask()
    while !container.isAtEnd {
      let token = try container.decode(String.self)
      let match = Self.canonicalOrder.first { $0.1 == token }
      guard let entry = match else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Unknown modifier token '\(token)'."
        )
      }
      mask.insert(entry.0)
    }
    self = mask
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    for (flag, token) in Self.canonicalOrder where contains(flag) {
      try container.encode(token)
    }
  }
}
