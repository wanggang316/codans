import CodansCore
import Foundation

/// Remembers the Hand Off panel's last placement choice in
/// `UserDefaults.standard`, so the picker opens on what the user picked last
/// time. Read when the panel opens; written on every change. Same shape as
/// `CommandPaletteRecencyPersistence`, including the test-only suite swap.
/// Nonisolated because `HandoffClient` reaches it from `@Sendable` closures.
nonisolated enum HandoffPlacementPersistence {
  static let key = "handoff.placement"

  /// Overridable store. Defaults to `.standard`; tests may rebind this to a
  /// `UserDefaults(suiteName:)` they own.
  nonisolated(unsafe) static var store: UserDefaults = .standard

  static func load() -> HandoffPlacement {
    guard let raw = store.string(forKey: key), let placement = HandoffPlacement(persisted: raw)
    else { return .default }
    return placement
  }

  static func save(_ placement: HandoffPlacement) {
    store.set(placement.persisted, forKey: key)
  }

  /// Test helper. Resets `store` on the way out.
  static func withSuite<T>(_ suite: UserDefaults, _ body: () throws -> T) rethrows -> T {
    let previous = store
    store = suite
    defer { store = previous }
    return try body()
  }
}
