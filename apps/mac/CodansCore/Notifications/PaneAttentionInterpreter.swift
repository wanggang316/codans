import Foundation

/// Pure translation from terminal runtime events to per-Content attention cues.
///
/// This layer owns the shared interpretation rules used by higher-level
/// surfaces. It deliberately stops before any product-specific action:
/// callers decide whether a cue becomes an inbox row, a system banner, or
/// an in-memory runtime state.
public nonisolated enum PaneAttentionInterpreter {
  /// Lower bound on `paneIdle.duration` below which an idle event is
  /// treated as terminal noise rather than a task-quiet signal.
  public static let idleThreshold: TimeInterval = 30

  public struct Step: Equatable, Sendable {
    public let cue: Cue?
    public let outputFlag: OutputFlag
    public let drop: InboxDropReason?

    public init(cue: Cue?, outputFlag: OutputFlag, drop: InboxDropReason? = nil) {
      self.cue = cue
      self.outputFlag = outputFlag
      self.drop = drop
    }
  }

  public struct Cue: Equatable, Sendable {
    public let contentID: ContentID
    public let kind: InboxEntry.Kind
    public let title: String
    public let body: String

    public init(contentID: ContentID, kind: InboxEntry.Kind, title: String, body: String) {
      self.contentID = contentID
      self.kind = kind
      self.title = title
      self.body = body
    }
  }

  public enum OutputFlag: Equatable, Sendable {
    case markProduced(ContentID)
    case clearProduced(ContentID)
    case unchanged

    public var isTeardown: Bool {
      switch self {
      case .clearProduced: return true
      case .markProduced, .unchanged: return false
      }
    }
  }

  public static func interpret(
    _ event: TerminalEvent,
    hasProducedOutput: Set<ContentID>
  ) -> Step {
    interpret(event, context: Context(hasProducedOutput: hasProducedOutput))
  }

  public static func interpret(
    _ event: TerminalEvent,
    context: Context
  ) -> Step {
    switch event {
    case .paneOutput(let contentID, _):
      return Step(cue: nil, outputFlag: .markProduced(contentID))

    // Live state, not an event: the agent-state machine owns it.
    case .paneViewportChanged, .paneProgramStatusChanged:
      return Step(cue: nil, outputFlag: .unchanged)

    case .paneInfoChanged(let contentID, let delta):
      switch delta {
      case .desktopNotification(let title, let body):
        return Step(
          cue: Cue(
            contentID: contentID,
            kind: classify(title: title, body: body),
            title: title,
            body: body
          ),
          outputFlag: .unchanged
        )
      case .bellRang:
        return Step(
          cue: Cue(
            contentID: contentID,
            kind: .waitingForInput,
            title: "Pane bell",
            body: "A pane rang the terminal bell."
          ),
          outputFlag: .unchanged
        )
      case .commandFinished(let exitCode, let durationNs):
        return interpretCommandFinished(
          contentID: contentID,
          exitCode: exitCode,
          durationNs: durationNs,
          context: context
        )
      default:
        return Step(cue: nil, outputFlag: .unchanged)
      }

    case .paneExited(let contentID, _, _):
      return Step(cue: nil, outputFlag: .clearProduced(contentID))

    case .paneCrashed(let contentID, let reason):
      return Step(
        cue: Cue(contentID: contentID, kind: .taskFinished, title: "Pane crashed", body: reason),
        outputFlag: .clearProduced(contentID)
      )

    case .paneIdle(let contentID, let duration):
      guard duration >= idleThreshold, context.hasProducedOutput.contains(contentID) else {
        return Step(cue: nil, outputFlag: .unchanged)
      }
      return Step(
        cue: Cue(
          contentID: contentID,
          kind: .taskFinished,
          title: "Pane idle",
          body: "No output for \(Int(duration.rounded())) s."
        ),
        outputFlag: .unchanged
      )

    case .paneClosedByTab(let contentID, _):
      return Step(cue: nil, outputFlag: .clearProduced(contentID))

    case .paneCreated, .paneReady,
      .tabActivated, .tabAutoClosed, .worktreeActivated, .hierarchyMutated,
      .foregroundJobChanged, .paneActionRequested, .windowActionRequested, .configChanged:
      return Step(cue: nil, outputFlag: .unchanged)
    }
  }

  /// Heuristic for user-attention desktop notifications.
  public static func classify(title: String, body: String) -> InboxEntry.Kind {
    let combined = (title + " " + body).lowercased()
    let lexicalCues = ["permission", "approval", "approve", "input"]
    if lexicalCues.contains(where: combined.contains) {
      return .waitingForInput
    }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
      return .waitingForInput
    }
    return .taskFinished
  }

  private static func interpretCommandFinished(
    contentID: ContentID,
    exitCode: Int32,
    durationNs: UInt64,
    context: Context
  ) -> Step {
    guard context.commandFinishedEnabled else {
      return Step(cue: nil, outputFlag: .unchanged, drop: .commandFinishedDisabled)
    }
    if exitCode == 130 || exitCode == 143 {
      return Step(cue: nil, outputFlag: .unchanged, drop: .commandCancelled)
    }
    let durationSec = Double(durationNs) / 1_000_000_000
    guard durationSec >= Double(context.commandFinishedThresholdSec) else {
      return Step(cue: nil, outputFlag: .unchanged, drop: .commandFinishedShort)
    }
    // Keystroke-recency gate: if the user pressed a key in this Content in the
    // last 3 s, suppress the "command finished" cue. A user-driven `/exit`
    // or `Ctrl-C` produces a command-finished event whose notification value
    // is zero — the user already knows the command ended. 3 s matches the
    // window upstream reference projects use; tighter windows (1 s) miss
    // the case where the command's wrap-up shells take ~2 s to settle.
    if let lastKey = context.lastUserKeystrokeAt[contentID],
      context.now.timeIntervalSince(lastKey) < 3.0
    {
      return Step(cue: nil, outputFlag: .unchanged, drop: .userTypingRecently)
    }
    let durationLabel = formatDuration(durationSec)
    let (title, body): (String, String) =
      exitCode == 0
      ? ("Command finished", "Completed in \(durationLabel).")
      : ("Command failed (exit \(exitCode))", "Ran for \(durationLabel) before failing.")
    return Step(
      cue: Cue(contentID: contentID, kind: .taskFinished, title: title, body: body),
      outputFlag: .unchanged
    )
  }

  private static func formatDuration(_ seconds: Double) -> String {
    if seconds < 60 { return "\(Int(seconds.rounded())) s" }
    let minutes = Int(seconds / 60)
    let remainSec = Int(seconds) % 60
    if minutes < 60 { return remainSec == 0 ? "\(minutes) m" : "\(minutes) m \(remainSec) s" }
    let hours = minutes / 60
    let remainMin = minutes % 60
    return remainMin == 0 ? "\(hours) h" : "\(hours) h \(remainMin) m"
  }
}

extension PaneAttentionInterpreter {
  public struct Context: Equatable, Sendable {
    public let hasProducedOutput: Set<ContentID>
    public let lastUserKeystrokeAt: [ContentID: Date]
    public let now: Date
    public let commandFinishedEnabled: Bool
    public let commandFinishedThresholdSec: Int

    public init(
      hasProducedOutput: Set<ContentID>,
      lastUserKeystrokeAt: [ContentID: Date] = [:],
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
  }
}
