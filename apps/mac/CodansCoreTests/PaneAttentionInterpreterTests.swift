import Foundation
import Testing

@testable import CodansCore

struct PaneAttentionInterpreterTests {
  // MARK: - paneOutput

  @Test
  func paneOutputMarksProducedAndProducesNoCue() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneOutput(pane, Data()),
      hasProducedOutput: []
    )
    #expect(step.cue == nil)
    #expect(step.outputFlag == .markProduced(pane))
  }

  // MARK: - desktopNotification (OSC 9)

  @Test
  func desktopNotificationWithoutPromptCueIsTaskFinished() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(pane, .desktopNotification(title: "Build done", body: "5 targets compiled")),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .taskFinished)
    #expect(step.cue?.title == "Build done")
    #expect(step.cue?.paneID == pane)
  }

  @Test
  func desktopNotificationWithPermissionCueIsWaitingForInput() {
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Permission required", body: "")),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .waitingForInput)
  }

  @Test
  func desktopNotificationWithTitleSuffixedQuestionMarkIsWaitingForInput() {
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Apply migration?", body: "")),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .waitingForInput)
  }

  @Test
  func desktopNotificationWithQuestionMarkOnlyInBodyIsTaskFinished() {
    // "Add tests?" is rhetorical informational text in a build summary,
    // not a prompt. The classifier scopes the `?` cue to the title
    // suffix to avoid misclassifying these as waiting-for-input.
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(
        PaneID(),
        .desktopNotification(title: "Build done", body: "5 targets in 2.3s. Add tests?")
      ),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .taskFinished)
  }

  @Test
  func desktopNotificationWithApprovalCueIsWaitingForInput() {
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Approval needed", body: "rm /tmp/x")),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .waitingForInput)
  }

  @Test
  func classifyIsCaseInsensitive() {
    #expect(PaneAttentionInterpreter.classify(title: "PERMISSION", body: "") == .waitingForInput)
    #expect(PaneAttentionInterpreter.classify(title: "Done", body: "no cue here") == .taskFinished)
  }

  // MARK: - bellRang

  @Test
  func bellRangIsWaitingForInput() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(pane, .bellRang),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .waitingForInput)
    #expect(step.cue?.paneID == pane)
    #expect(step.outputFlag == .unchanged)
  }

  // MARK: - commandFinished

  /// Convenience: 30 s in nanoseconds, comfortably above the default 10 s
  /// threshold so success / failure cases fire without suppression.
  private static let longDurationNs: UInt64 = 30 * 1_000_000_000

  @Test
  func commandFinishedZeroExitIsTaskFinished() {
    // Default threshold is 10 s; pass 30 s so the event fires.
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(
        PaneID(),
        .commandFinished(exitCode: 0, duration: Self.longDurationNs)
      ),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .taskFinished)
    #expect(step.cue?.title == "Command finished")
    #expect(step.drop == nil)
  }

  @Test
  func commandFinishedNonZeroExitMentionsStatus() {
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(
        PaneID(),
        .commandFinished(exitCode: 137, duration: Self.longDurationNs)
      ),
      hasProducedOutput: []
    )
    #expect(step.cue?.kind == .taskFinished)
    #expect(step.cue?.title.contains("failed") == true)
    #expect(step.cue?.title.contains("exit 137") == true)
  }

  // MARK: - commandFinished suppression rules

  @Test
  func commandFinishedDisabled_suppressesEvenLongSuccess() {
    let pane = PaneID()
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedEnabled: false,
      commandFinishedThresholdSec: 10
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.cue == nil)
    #expect(step.drop == .commandFinishedDisabled)
  }

  @Test
  func commandFinishedShort_suppressesBelowThreshold() {
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    // 5 s < 10 s threshold.
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 5 * 1_000_000_000)),
      context: context
    )
    #expect(step.cue == nil)
    #expect(step.drop == .commandFinishedShort)
  }

  @Test
  func commandFinishedExactlyAtThreshold_fires() {
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 10 * 1_000_000_000)),
      context: context
    )
    #expect(step.cue != nil)
    #expect(step.drop == nil)
    #expect(step.cue?.title == "Command finished")
  }

  @Test
  func commandFinishedLongSuccess_fires() {
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.cue?.title == "Command finished")
    #expect(step.drop == nil)
  }

  @Test
  func commandCancelledSIGINT_suppressed() {
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 130, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.cue == nil)
    #expect(step.drop == .commandCancelled)
  }

  @Test
  func commandCancelledSIGTERM_suppressed() {
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 143, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.cue == nil)
    #expect(step.drop == .commandCancelled)
  }

  @Test
  func commandFinishedNonZeroExit_firesWithFailureTitle() {
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 1, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.cue != nil)
    #expect(step.cue?.title.contains("failed") == true)
    #expect(step.cue?.title.contains("exit 1") == true)
  }

  @Test
  func keystrokeWithinSuppressionWindow_suppresses() {
    let pane = PaneID()
    let now = Date()
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [pane: now.addingTimeInterval(-2.5)],
      now: now,
      commandFinishedThresholdSec: 1
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: 2 * 1_000_000_000)),
      context: context
    )
    #expect(step.cue == nil)
    #expect(step.drop == .userTypingRecently)
  }

  @Test
  func keystrokeOutsideSuppressionWindow_doesNotSuppress() {
    let pane = PaneID()
    let now = Date()
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [pane: now.addingTimeInterval(-3.5)],
      now: now,
      commandFinishedThresholdSec: 1
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: 2 * 1_000_000_000)),
      context: context
    )
    #expect(step.cue != nil)
    #expect(step.drop == nil)
  }

  @Test
  func keystrokeForDifferentPane_doesNotSuppress() {
    let pane = PaneID()
    let otherPane = PaneID()
    let now = Date()
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [otherPane: now.addingTimeInterval(-0.1)],
      now: now,
      commandFinishedThresholdSec: 1
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: 2 * 1_000_000_000)),
      context: context
    )
    #expect(step.cue != nil)
    #expect(step.drop == nil)
  }

  @Test
  func outOfRangeThresholdInContextDoesNotCrash() {
    // The interpreter deliberately does not re-clamp; the input-validation
    // contract lives in `NotificationsSettings` decode (and the UI).
    // A zero threshold means every long-enough duration fires.
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 0
    )
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 1_000_000_000)),
      context: context
    )
    #expect(step.cue != nil)
    #expect(step.drop == nil)
  }

  // MARK: - paneExited (deliberately not notified)

  @Test
  func paneExitedCleanProducesNoCue() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneExited(pane, code: 0, signal: nil),
      hasProducedOutput: [pane]
    )
    #expect(step.cue == nil)
    // Cache management still runs so a recreated PaneID can't
    // inherit the prior 'has produced output' gate state.
    #expect(step.outputFlag == .clearProduced(pane))
  }

  @Test
  func paneExitedNonZeroProducesNoCue() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneExited(pane, code: 1, signal: nil),
      hasProducedOutput: [pane]
    )
    #expect(step.cue == nil)
    #expect(step.outputFlag == .clearProduced(pane))
  }

  @Test
  func paneExitedBySignalProducesNoCue() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneExited(pane, code: 0, signal: 9),
      hasProducedOutput: [pane]
    )
    #expect(step.cue == nil)
    #expect(step.outputFlag == .clearProduced(pane))
  }

  // MARK: - paneCrashed

  @Test
  func paneCrashedSurfacesReason() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneCrashed(pane, reason: "Subprocess panicked"),
      hasProducedOutput: [pane]
    )
    #expect(step.cue?.kind == .taskFinished)
    #expect(step.cue?.title == "Pane crashed")
    #expect(step.cue?.body == "Subprocess panicked")
    #expect(step.outputFlag == .clearProduced(pane))
  }

  // MARK: - paneIdle gating

  @Test
  func paneIdleBelowThresholdIsDropped() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneIdle(pane, duration: PaneAttentionInterpreter.idleThreshold - 1),
      hasProducedOutput: [pane]
    )
    #expect(step.cue == nil)
    #expect(step.outputFlag == .unchanged)
  }

  @Test
  func paneIdleAboveThresholdWithoutPriorOutputIsDropped() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneIdle(pane, duration: PaneAttentionInterpreter.idleThreshold + 60),
      hasProducedOutput: []  // pane has not produced anything yet
    )
    #expect(step.cue == nil)
  }

  @Test
  func paneIdleAboveThresholdWithPriorOutputIsTaskFinished() {
    let pane = PaneID()
    let step = PaneAttentionInterpreter.interpret(
      .paneIdle(pane, duration: 45),
      hasProducedOutput: [pane]
    )
    #expect(step.cue?.kind == .taskFinished)
    #expect(step.cue?.title == "Pane idle")
    #expect(step.cue?.body == "No output for 45 s.")
  }

  // MARK: - non-notification events

  @Test
  func untrackedEventsProduceNoCueAndNoFlagChange() {
    let cases: [TerminalEvent] = [
      .paneCreated(PaneID(), TabID()),
      .paneReady(PaneID()),
      .tabActivated(TabID()),
      .worktreeActivated(WorktreeID()),
      .hierarchyMutated(.catalog),
      .foregroundJobChanged(PaneID(), ForegroundJob(processGroupID: 1, processes: [])),
      .paneViewportChanged(PaneID(), text: "screen"),
      .configChanged,
    ]
    for event in cases {
      let step = PaneAttentionInterpreter.interpret(event, hasProducedOutput: [])
      #expect(step.cue == nil)
      #expect(step.outputFlag == .unchanged)
    }
  }

  @Test
  func paneInfoChangedWithUnrelatedDeltaIsIgnored() {
    let step = PaneAttentionInterpreter.interpret(
      .paneInfoChanged(PaneID(), .title("New title")),
      hasProducedOutput: []
    )
    #expect(step.cue == nil)
    #expect(step.outputFlag == .unchanged)
  }

  // MARK: - agent activity

  @Test
  func agentActivityClassifiesSupportedViewportShapes() {
    let samples: [AgentActivitySample] = [
      .init(kind: .pi, working: "Working...", blocked: nil, idle: "pi> "),
      .init(
        kind: .claudeCode,
        working: "✢ Editing…",
        blocked: "Do you want to proceed?\n❯ 1. Yes\n  2. No",
        idle: "❯ "
      ),
      .init(
        kind: .codex,
        working: "• Working (12s)",
        blocked: "Allow command?\n[y/n]",
        idle: "codex> "
      ),
      .init(
        kind: .gemini,
        working: "Esc to cancel",
        blocked: "│ Do you want to proceed",
        idle: "gemini> "
      ),
      .init(
        kind: .cursorAgent,
        working: "Ctrl+C to stop",
        blocked: "Run this command?\nRun (y) (enter)",
        idle: "cursor> "
      ),
      .init(
        kind: .cline,
        working: "Esc to interrupt",
        blocked: "Let Cline use this tool?",
        idle: "cline> "
      ),
      .init(
        kind: .opencode,
        working: "Esc to interrupt",
        blocked: "△ Permission required",
        idle: "opencode> "
      ),
      .init(
        kind: .copilot,
        working: "Esc to cancel",
        blocked: "│ do you want to continue",
        idle: "copilot> "
      ),
      .init(
        kind: .kimi,
        working: "thinking",
        blocked: "approve?",
        idle: "kimi> "
      ),
      .init(
        kind: .droid,
        working: "⠋ Esc to stop",
        blocked: "EXECUTE\nenter to select\n> yes, allow",
        idle: "droid> "
      ),
      .init(
        kind: .amp,
        working: "Esc to cancel",
        blocked: "Waiting for approval\nInvoke tool\nApprove\nAllow all for this session",
        idle: "amp> "
      ),
      .init(
        kind: .omp,
        working: "⠋ Working… ⟦esc⟧",
        blocked: "Allow tool: bash\nReason: destructive\n❯ Approve\n  Deny",
        idle: "❯ fix the login bug"
      ),
    ]

    for sample in samples {
      #expect(activity(sample.kind, sample.working) == .working)
      if let blocked = sample.blocked {
        #expect(activity(sample.kind, blocked) == .blocked)
      }
      #expect(activity(sample.kind, sample.idle) == .idle)
    }
  }

  @Test
  func codexActivityDetectsWorkingAndBlockedStates() {
    #expect(
      activity(.codex, "• Working (12s)") == .working
    )
    #expect(
      activity(.codex, "Allow command?\n[y/n]") == .blocked
    )
  }

  @Test
  func agentActivityUsesRecentNonBlankLines() {
    let oldWorking = Array(repeating: "• Working (1s)", count: 30).joined(separator: "\n")
    let recentIdle = oldWorking + "\n\ncodex> "
    #expect(
      activity(.codex, recentIdle) == .idle
    )
  }

  @Test
  func workingStateIsHeldBrieflyForAnyKind() {
    // The hold is kind-independent: a momentary idle frame within the hold
    // window keeps `working`, and once the window lapses it settles to idle.
    var lastWorkingAt: Date?
    let start = Date(timeIntervalSince1970: 1_000)
    let working = PaneAttentionInterpreter.stabilizeAgentActivity(
      previous: .idle,
      raw: .working,
      now: start,
      lastWorkingAt: &lastWorkingAt
    )
    #expect(working == .working)

    let held = PaneAttentionInterpreter.stabilizeAgentActivity(
      previous: .working,
      raw: .idle,
      now: start.addingTimeInterval(0.5),
      lastWorkingAt: &lastWorkingAt
    )
    #expect(held == .working)

    let settled = PaneAttentionInterpreter.stabilizeAgentActivity(
      previous: .working,
      raw: .idle,
      now: start.addingTimeInterval(PaneAttentionInterpreter.agentWorkingHold + 0.1),
      lastWorkingAt: &lastWorkingAt
    )
    #expect(settled == .idle)
  }

  @Test
  func claudeRecapLineAfterCompletionStaysIdle() {
    // Regression (fix/agents-view-done-wrong): Claude's post-completion
    // recap line `※ recap: …` matched the spinner-activity heuristic (`※`
    // was in the spinner set, and a width-truncated recap ends in `…`),
    // flipping a *finished* agent back to `working` (the observed
    // done→working flicker). A done screen — completion summary, a
    // truncated recap, and an empty `❯` prompt — must classify as idle.
    let screen = """
          ✻ Crunched for 34m 0s

        ※ recap: Goal: fix the width bug. The serializer change is committed and tests pass. Next: push the submodule then the main repo, and optionally rebuild …

        ────────────────────────────────────────
        ❯
        ────────────────────────────────────────
          [Opus 4.8 (1M context)] ██░░░░░░░░ 22% | resume-width
        """
    #expect(activity(.claudeCode, screen) == .idle)
  }

  @Test
  func claudeLiveSpinnerStillClassifiesWorking() {
    // Guard the other side of the recap fix: the sparkle/asterisk spinner
    // frames are still working cues, so removing `※` must not regress live
    // spinner detection.
    #expect(activity(.claudeCode, "✻ Searching…") == .working)
    #expect(activity(.claudeCode, "✶ Thinking…") == .working)
  }

  @Test
  func ompActivityClassifiesLoaderAndApprovalStates() {
    // Working loader, as observed live on v18.0.7 (titanium theme):
    // `⠋ Working… ⟦esc⟧`. The bracket pair is theme-configurable, so the
    // hint matcher accepts any esc token trailing the ellipsis; the bare
    // message covers a redraw without the hint.
    #expect(activity(.omp, "⠋ Working… ⟦esc⟧") == .working)
    #expect(activity(.omp, "Working… [esc]") == .working)
    #expect(activity(.omp, "Still working… ⟦esc⟧") == .working)
    #expect(activity(.omp, "Working…") == .working)
    // A transcript line with esc BEFORE the ellipsis is not a hint.
    #expect(activity(.omp, "press esc… done") == .idle)
    // Approval selector: title cue alone, and the Approve/Deny option
    // rows with the default cursor symbol.
    #expect(activity(.omp, "Allow tool: bash\n❯ Approve\n  Deny") == .blocked)
    #expect(activity(.omp, "Allow tool: bash") == .blocked)
    #expect(activity(.omp, "❯ Approve\n  Deny") == .blocked)
    // Idle composer: no loader, no approval dialog (live idle screen).
    #expect(activity(.omp, "╭── π  > ⬢ GLM-5.3 · ◒ high > 🗑 omp-probe > ⑂ main\n❯ ") == .idle)
  }

  @Test
  func ompProseMentioningApproveDenyStaysIdle() {
    // Guard the reverse of the selector cue: transcript prose that merely
    // contains the words "approve"/"deny" inside longer lines must not
    // read as the approval dialog (options render as standalone rows).
    #expect(
      activity(.omp, "You can approve or deny the tool call in settings.\n❯ ")
        == .idle)
  }

  @Test
  func ompWorkingOutranksNothingWhenBlocked() {
    // A blocked frame wins: the approval dialog can render while the
    // loader line is still on screen, and the user's action is required.
    #expect(
      activity(.omp, "Working… [esc]\nAllow tool: bash\n❯ Approve\n  Deny")
        == .blocked)
  }

  private func activity(
    _ kind: AgentKind,
    _ viewportText: String
  ) -> PaneAttentionInterpreter.AgentActivityState {
    PaneAttentionInterpreter.classifyAgentActivity(kind: kind, viewportText: viewportText)
  }

  private struct AgentActivitySample {
    let kind: AgentKind
    let working: String
    let blocked: String?
    let idle: String
  }
}
