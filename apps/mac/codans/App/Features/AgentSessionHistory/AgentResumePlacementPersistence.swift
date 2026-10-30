import CodansCore
import Foundation

/// Remembers the Agent Sessions popover's last resume placement in
/// `UserDefaults.standard`: one app-wide value, read when the popover opens
/// and written on every change. Same shape as `HandoffPlacementPersistence`,
/// including the test-only suite swap.
nonisolated enum AgentResumePlacementPersistence {
  static let key = "agentSessions.resumePlacement"

  /// Overridable store. Defaults to `.standard`; tests may rebind this to a
  /// `UserDefaults(suiteName:)` they own.
  nonisolated(unsafe) static var store: UserDefaults = .standard

  static func load() -> AgentResumePlacement {
    guard let raw = store.string(forKey: key),
      let placement = AgentResumePlacement(persisted: raw)
    else { return .default }
    return placement
  }

  static func save(_ placement: AgentResumePlacement) {
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
