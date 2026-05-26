import Foundation

/// Stable per-install anonymous identifier. Generated lazily on first read,
/// persisted in `UserDefaults` under `Key.current` so the same id survives
/// app relaunches but resets when the user disables crash reporting (via
/// `SettingsStore.setCrashReportsEnabled(false)`). The id is a v4 UUID with
/// no derivation from device hardware, account, or filesystem state — it
/// is meaningful only as a join key between separate reports from the
/// same install.
nonisolated enum InstallIdentifier {
  private enum Key {
    static let current = "app.touch-code.install-id"
  }

  /// Reads the current id, generating + persisting a new one if absent.
  static var current: String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: Key.current), !existing.isEmpty {
      return existing
    }
    let fresh = UUID().uuidString
    defaults.set(fresh, forKey: Key.current)
    return fresh
  }

  /// Clears the stored id. Called when the user opts out of crash
  /// reporting so a future re-opt-in starts with a fresh anonymous id
  /// rather than re-using the previous one.
  static func reset() {
    UserDefaults.standard.removeObject(forKey: Key.current)
  }
}
