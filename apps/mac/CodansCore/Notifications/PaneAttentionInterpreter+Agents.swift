import Foundation

extension PaneAttentionInterpreter {
  public typealias AgentActivityState = AgentObservedActivity

  public static let agentActivityRecentLineLimit = AgentObservationText.recentLineLimit
  /// How long a rendered `working` cue keeps the badge on `working` after
  /// the live classification drops back to `idle`. A single missed frame
  /// between spinner/header repaints must not flip the badge `working →
  /// idle` and back — the Working↔Done flicker. Applied uniformly to every
  /// agent kind by `stabilizeAgentActivity`.
  public static let agentWorkingHold: TimeInterval = 1.2

  public static func classifyAgentActivity(
    kind: AgentKind,
    viewportText: String
  ) -> AgentActivityState {
    switch AgentObservationParsers.parser(for: kind).parse(viewportText).state {
    case .unknown: return .unknown
    case .idle: return .idle
    case .working: return .working
    case .blocked: return .blocked
    case .error: return .error
    }
  }

  public static func agentErrorFingerprint(kind: AgentKind, viewportText: String) -> String? {
    AgentObservationParsers.parser(for: kind).parse(viewportText).evidence.currentErrorBanner?.value
  }

  /// Hysteresis on the `working → idle` trailing edge, applied uniformly to
  /// every agent kind. Once a pane has rendered a `working` cue, a following
  /// `idle` classification is held as `working` until `agentWorkingHold` has
  /// elapsed since the last working frame. Spinner- and header-based
  /// detectors alike drop the occasional frame between repaints; without this
  /// hold that single missed frame flips the badge `working → idle` and back —
  /// the Working↔Done flicker this store exists to prevent. `blocked` is a
  /// stable prompt state and is never held; `working` refreshes the timer.
  ///
  /// `lastWorkingAt` is per-pane derivation scratch owned by the caller and
  /// updated in place on each working frame. Callers must supply a fresh idle
  /// derivation on a timer once the screen settles (see the engine's quiet
  /// `.paneIdle` nudge) so a held `working` gets a post-hold follow-up and can
  /// settle to `finished`.
  public static func stabilizeAgentActivity(
    previous: AgentActivityState,
    raw: AgentActivityState,
    now: Date,
    lastWorkingAt: inout Date?
  ) -> AgentActivityState {
    switch raw {
    case .unknown:
      return .unknown
    case .working:
      lastWorkingAt = now
      return .working
    case .blocked:
      return .blocked
    case .error:
      lastWorkingAt = nil
      return .error
    case .idle where previous == .working:
      guard let lastWorkingAt else { return .idle }
      return now.timeIntervalSince(lastWorkingAt) < agentWorkingHold ? .working : .idle
    case .idle:
      return .idle
    }
  }
}
