import Foundation

/// Persists the Command Palette's recency map to `UserDefaults.standard`
/// under a single key. Read on each palette open; written after every
/// activation.
///
/// Values are stored as a `[String: Double]` dictionary — the native
/// plist-compatible encoding. `TimeInterval` is a typealias for `Double`,
/// so no conversion is needed.
///
/// Tests can inject an alternate `UserDefaults` suite via
/// `withSuite(_:)` to avoid polluting the host defaults.
enum CommandPaletteRecencyPersistence {
  static let key = "commandPaletteRecency"

  /// Overridable store. Defaults to `.standard`; tests may rebind this
  /// to a `UserDefaults(suiteName:)` they own.
  nonisolated(unsafe) static var store: UserDefaults = .standard

  static func load() -> [String: TimeInterval] {
    guard let raw = store.dictionary(forKey: key) as? [String: Double] else { return [:] }
    return raw
  }

  static func save(_ recency: [String: TimeInterval]) {
    store.set(recency as [String: Double], forKey: key)
  }

  /// Test helper. Resets `store` to `.standard` on teardown.
  static func withSuite<T>(_ suite: UserDefaults, _ body: () throws -> T) rethrows -> T {
    let previous = store
    store = suite
    defer { store = previous }
    return try body()
  }
}
