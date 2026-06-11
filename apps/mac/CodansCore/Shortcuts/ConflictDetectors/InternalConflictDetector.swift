import Foundation

/// Internal-conflict tier of the multi-tier conflict detector (design doc §3.4).
///
/// Reports a collision when a candidate `(keyCode, modifiers)` chord is already in use by a
/// *different* `.configurable` command that is currently enabled and bound. `.systemFixed` and
/// `.localOnly` rows are intentionally skipped here — `AppKitReservedDetector` and
/// `SystemReservedDetector` cover those tiers; surfacing them through this detector would
/// double-count the rejection and bypass the typed-error path the recorder uses to render
/// distinct user-facing reasons.
///
/// The candidate's `isEnabled` flag is ignored: a user can record a chord and immediately
/// disable it; the conflict question is purely "is anyone else holding this chord today?".
public enum InternalConflictDetector {
  /// Returns the `CommandID` of the first existing entry whose binding equals
  /// `(candidate.keyCode, candidate.modifiers)`, or `nil` if no conflict.
  ///
  /// Iteration order follows `CommandID.allCases` so that, in the (defensive) edge case of two
  /// resolved entries sharing the candidate chord, the result is deterministic — the case
  /// declared earliest in `CommandID` wins. Resolved maps produced by `ShortcutResolver` from
  /// a well-formed schema + override store cannot reach that state in practice, but pinning
  /// the choice keeps the function total and test-stable.
  public static func conflicts(
    in map: ResolvedShortcutMap,
    candidate: ShortcutBinding,
    excluding: CommandID,
    schema: ShortcutSchema = .app
  ) -> CommandID? {
    for id in CommandID.allCases where id != excluding {
      guard
        let resolved = map[id],
        resolved.isEnabled,
        let binding = resolved.binding,
        binding.keyCode == candidate.keyCode,
        binding.modifiers == candidate.modifiers,
        schema.entry(for: id)?.scope == .configurable
      else { continue }
      return id
    }
    return nil
  }
}
