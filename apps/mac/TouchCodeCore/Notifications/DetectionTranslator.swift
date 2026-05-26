import Foundation

/// Backward-compatible inbox adapter over `PaneAttentionInterpreter`.
///
/// The shared terminal-event interpretation table lives in
/// `PaneAttentionInterpreter`; this type preserves the notification-facing
/// `Entry` / `Step` API used by `NotificationDetector` and existing tests.
/// The orchestration (catalog walk → SourcePath, mute label check, banner
/// gating, store.append) stays in the detector.
public nonisolated enum DetectionTranslator {
  public static let idleThreshold = PaneAttentionInterpreter.idleThreshold

  /// One step's translation result. The detector also gets back a hint
  /// for whether to update its `hasProducedOutput` membership for the
  /// pane (so a pane that exits or crashes loses its "has produced
  /// output" flag and a freshly spawned pane reaches `paneOutput` before
  /// it can ever fire `paneIdle`).
  public struct Step: Equatable, Sendable {
    public let entry: Entry?
    public let outputFlag: OutputFlag
    public let drop: InboxDropReason?

    public init(entry: Entry?, outputFlag: OutputFlag, drop: InboxDropReason? = nil) {
      self.entry = entry
      self.outputFlag = outputFlag
      self.drop = drop
    }
  }

  public struct Entry: Equatable, Sendable {
    public let paneID: PaneID
    public let kind: InboxEntry.Kind
    public let title: String
    public let body: String

    public init(paneID: PaneID, kind: InboxEntry.Kind, title: String, body: String) {
      self.paneID = paneID
      self.kind = kind
      self.title = title
      self.body = body
    }
  }

  public typealias OutputFlag = PaneAttentionInterpreter.OutputFlag

  /// Backward-compatible overload used by call sites that have not yet
  /// adopted `Context`. Constructs a `Context` with default
  /// commandFinished settings and an empty keystroke map. M5.T1 will swap
  /// `NotificationDetector` to the `Context`-aware path; until then this
  /// keeps the detector compiling unchanged.
  public static func translate(
    _ event: TerminalEvent,
    hasProducedOutput: Set<PaneID>
  ) -> Step {
    translate(event, context: Context(hasProducedOutput: hasProducedOutput))
  }

  /// Translate a single event. Returns `Step(entry: nil, outputFlag:
  /// ...)` when the event matters to bookkeeping but does not produce a
  /// notification; returns `Step(entry: ..., outputFlag: ...)` when it
  /// does. May also set `Step.drop` to record why a candidate
  /// notification was suppressed at the translator layer.
  public static func translate(
    _ event: TerminalEvent,
    context: Context
  ) -> Step {
    let step = PaneAttentionInterpreter.interpret(event, context: context.coreContext)
    return Step(
      entry: step.cue.map {
        Entry(paneID: $0.paneID, kind: $0.kind, title: $0.title, body: $0.body)
      },
      outputFlag: step.outputFlag,
      drop: step.drop
    )
  }

  /// Heuristic: pick `.waitingForInput` for desktop notifications whose
  /// title or body suggests the agent needs the user (permission /
  /// approval / input). The trailing question-mark cue applies only at
  /// the very end of the title — body text routinely contains rhetorical
  /// `?` characters (e.g. "Built 5 targets. Add tests?") which would
  /// otherwise misclassify routine completion as input-required.
  public static func classify(title: String, body: String) -> InboxEntry.Kind {
    PaneAttentionInterpreter.classify(title: title, body: body)
  }
}

extension DetectionTranslator {
  /// Per-event context the translator needs but cannot derive from the
  /// event alone: pane-level "has produced output" gate (for idle), a
  /// per-pane "last user keystroke at" map and current time (for the
  /// command-finished keystroke-suppression window), and the relevant
  /// `NotificationsSettings` knobs (so the translator stays pure and the
  /// app layer owns the settings lifecycle).
  public struct Context: Equatable, Sendable {
    public let hasProducedOutput: Set<PaneID>
    public let lastUserKeystrokeAt: [PaneID: Date]
    public let now: Date
    public let commandFinishedEnabled: Bool
    public let commandFinishedThresholdSec: Int

    public init(
      hasProducedOutput: Set<PaneID>,
      lastUserKeystrokeAt: [PaneID: Date] = [:],
      now: Date = Date(),
      commandFinishedEnabled: Bool = true,
      commandFinishedThresholdSec: Int = 10
    ) {
      self.hasProducedOutput = hasProducedOutput
      self.lastUserKeystrokeAt = lastUserKeystrokeAt
      self.now = now
      self.commandFinishedEnabled = commandFinishedEnabled
      self.commandFinishedThresholdSec = commandFinishedThresholdSec
    }

    fileprivate var coreContext: PaneAttentionInterpreter.Context {
      PaneAttentionInterpreter.Context(
        hasProducedOutput: hasProducedOutput,
        lastUserKeystrokeAt: lastUserKeystrokeAt,
        now: now,
        commandFinishedEnabled: commandFinishedEnabled,
        commandFinishedThresholdSec: commandFinishedThresholdSec
      )
    }
  }
}
