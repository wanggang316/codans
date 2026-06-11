import Foundation

/// Tunables for the session catalog + reaper that need to be shared
/// between `SessionStore` callers and the launch-time reaper. Kept as
/// constants on a no-instance enum so test code can either inject a
/// shorter window through `SessionReaper.init` or read the production
/// value directly without constructing a configuration object.
public enum SessionConfig {
  /// Default 7-day stale window. A daemon whose `lastAttachedAt` is
  /// older than `Date() - defaultStaleAfter` at sweep time is treated
  /// as abandoned and killed by `SessionReaper.sweep`. Test code
  /// injects a much shorter value to exercise the reap path
  /// deterministically.
  public static let defaultStaleAfter: TimeInterval = 7 * 24 * 60 * 60
}
