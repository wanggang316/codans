import Foundation
import Testing

@testable import TouchCodeCore

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

  // MARK: - commandFinished suppression rules (M4.T1)

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
  func keystrokeWithinOneSecond_suppresses() {
    let pane = PaneID()
    let now = Date()
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [pane: now.addingTimeInterval(-0.5)],
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
  func keystrokeOlderThanOneSecond_doesNotSuppress() {
    let pane = PaneID()
    let now = Date()
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [pane: now.addingTimeInterval(-1.5)],
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
    // contract lives in `NotificationsSettings` decode (and the M3.T1 UI).
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
}
