import Foundation

/// Result of asking the planner what happens when the user resets a single command.
///
/// `cascadingResets` lists every *other* `CommandID` whose user override the planner had to
/// clear in order to keep the registry collision-free after the target's reset. The list does
/// not include `target` itself; it is in stable schema order so the Settings pane's
/// confirmation dialog can render the cascade deterministically.
///
/// `resultingMap` is the resolved view of the registry once the planned mutations have been
/// applied. Callers compare it against the current resolved map to decide whether the plan is
/// a no-op (`cascadingResets.isEmpty` plus an unchanged target row) and skip the confirmation
/// step.
public struct ShortcutResetPlan: Equatable, Sendable {
  public let target: CommandID
  public let cascadingResets: [CommandID]
  public let resultingMap: ResolvedShortcutMap

  public init(
    target: CommandID,
    cascadingResets: [CommandID],
    resultingMap: ResolvedShortcutMap
  ) {
    self.target = target
    self.cascadingResets = cascadingResets
    self.resultingMap = resultingMap
  }
}

/// Pure planner for "reset one command back to its schema default", with cascading clears so
/// the result is collision-free.
///
/// The hazard the cascade addresses: clearing `target`'s override may surface a *new*
/// collision because `target`'s schema default now coincides with some *other* command's user
/// override. Naive reset would silently leave two commands bound to the same chord — exactly
/// the failure the registry is supposed to prevent. The planner therefore iterates: after
/// each clear, it scans the resolved map for any `(keyCode, modifiers)` that the freshly
/// reverted target now shares with a `.userOverride` row, clears that override too, and
/// continues until a fixed point.
///
/// Only `.configurable` rows participate. `.systemFixed` and `.localOnly` rows can never be
/// reached as cascade victims (they have no user override to clear) and `.systemFixed` rows
/// also cannot be the *driver* of a cascade — even when `.systemFixed` and a configurable row
/// share a chord, the configurable row's override is the user's deliberate choice and is
/// preserved unless the user resets *that* row directly. The cascade fires only on collisions
/// the user could resolve themselves, mirroring the `InternalConflictDetector` policy
/// (§3.4 of the design doc).
public enum ShortcutResetPlanner {
  public static func plan(
    resetting target: CommandID,
    schema: ShortcutSchema = .app,
    overrides: ShortcutOverrideStore
  ) -> ShortcutResetPlan {
    var working = overrides
    var cascaded: [CommandID] = []

    // Step 1: clear the target's override. If the target had no override the entire plan is
    // a no-op — but we still construct a plan with the current resolved map so callers have a
    // consistent shape to consume.
    working.overrides.removeValue(forKey: target)

    // Step 2: cascade. Each iteration looks for a `.configurable` row whose *user override*
    // collides with another row's currently-resolved binding. We resolve fresh on every pass
    // so newly cleared rows participate in subsequent collision checks.
    //
    // Termination: every iteration removes one entry from `working.overrides` (the loop
    // breaks when no collision is found), so the loop runs at most `overrides.count` times —
    // a 3-way cycle clears at most three overrides, then exits.
    let configurableIDs = Set(
      schema.entries.filter { $0.scope == .configurable }.map { $0.id }
    )

    while true {
      let resolved = ShortcutResolver.resolve(schema: schema, overrides: working)
      guard
        let victim = nextCascadeVictim(
          in: resolved,
          overrides: working,
          configurableIDs: configurableIDs
        )
      else {
        break
      }
      working.overrides.removeValue(forKey: victim)
      cascaded.append(victim)
    }

    let finalMap = ShortcutResolver.resolve(schema: schema, overrides: working)
    return ShortcutResetPlan(
      target: target,
      cascadingResets: cascaded,
      resultingMap: finalMap
    )
  }

  /// Returns the `CommandID` of the next override to clear, or `nil` if the resolved map is
  /// already collision-free among `.configurable` rows.
  ///
  /// A "collision" is two distinct, enabled, `.configurable` resolved rows sharing the same
  /// `(keyCode, modifiers)`. When found, we always clear the row whose `source ==
  /// .userOverride`; if both rows are user overrides we clear the one whose `CommandID` comes
  /// later in `CommandID.allCases` so the choice is deterministic and so the "older" command
  /// (the one that the user just reset, or the one that has been on its default longer) is
  /// preserved as the winner. In practice the typical cascade case has exactly one
  /// `.userOverride` and one `.schemaDefault` involved, and the override is the natural
  /// victim.
  private static func nextCascadeVictim(
    in map: ResolvedShortcutMap,
    overrides: ShortcutOverrideStore,
    configurableIDs: Set<CommandID>
  ) -> CommandID? {
    // Build a stable iteration order so the planner is deterministic across runs.
    let orderedIDs = CommandID.allCases.filter { configurableIDs.contains($0) }

    for i in orderedIDs.indices {
      let lhsID = orderedIDs[i]
      guard let lhs = map[lhsID], lhs.isEnabled, let lhsBinding = lhs.binding else { continue }

      for j in orderedIDs.index(after: i)..<orderedIDs.endIndex {
        let rhsID = orderedIDs[j]
        guard let rhs = map[rhsID], rhs.isEnabled, let rhsBinding = rhs.binding else { continue }

        guard lhsBinding.keyCode == rhsBinding.keyCode,
          lhsBinding.modifiers == rhsBinding.modifiers
        else { continue }

        // Prefer the user-override side as the victim. If both are user overrides we clear
        // the later one in `CommandID.allCases` order; if neither is, the schema itself has
        // a default-vs-default collision the planner cannot heal — return `nil` and let the
        // schema audit catch it.
        let lhsIsOverride = overrides.overrides[lhsID] != nil
        let rhsIsOverride = overrides.overrides[rhsID] != nil

        if rhsIsOverride { return rhsID }
        if lhsIsOverride { return lhsID }
        // Two `.schemaDefault` rows colliding is a schema bug; skip rather than loop forever.
        continue
      }
    }
    return nil
  }
}
