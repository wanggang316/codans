import CodansCore
import ComposableArchitecture
import Foundation
import Observation
import Testing

@testable import Codans

/// The OSC 7501 path of `AgentStateStore`: a root record from the bound
/// agent decides the state ahead of the screen.
@MainActor
struct AgentStateStoreProgramStatusTests {
  typealias Fixture = AgentStateStoreTests.Fixture

  private func bindClaude(_ f: Fixture) {
    f.registry.onAgentBound(f.contentID, kind: .claudeCode, sessionID: nil)
  }

  @Test
  func codexReportsOverrideScreenAndClearRestoresFallback() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.apply([ProgramStatusReport(state: .working, app: "codex")])
    #expect(f.registry.entries[f.contentID]?.state == .working)
    #expect(f.registry.entries[f.contentID]?.source == .programStatus)
    f.apply([ProgramStatusReport(state: .idle, app: "codex")])
    f.viewport("• Working (12s)")
    #expect(f.registry.entries[f.contentID]?.state == .idle)
    #expect(f.registry.entries[f.contentID]?.source == .programStatus)
    f.apply([ProgramStatusReport(state: .clear)])
    #expect(f.registry.entries[f.contentID]?.source == .screen)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (12s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func openCodeReportsPendingSessionSummary() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .opencode, sessionID: nil)
    f.apply([
      ProgramStatusReport(state: .working, app: "opencode"),
      ProgramStatusReport(state: .blocked, kind: .question, id: "ses_1", app: "opencode"),
    ])
    #expect(f.registry.entries[f.contentID]?.state == .blocked)
    #expect(f.registry.entries[f.contentID]?.blockedKind == .question)
    #expect(f.registry.entries[f.contentID]?.source == .programStatus)
    f.apply([ProgramStatusReport(state: .idle, app: "opencode")])
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test(arguments: [AgentKind.droid, .opencode])
  func reportsOverrideScreenAndMissingReportsUseFallback(_ kind: AgentKind) {
    let f = Fixture()
    let screen = kind == .droid ? "⠋ Running (esc to stop)" : "Esc to interrupt"
    f.registry.onAgentBound(f.contentID, kind: kind, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport(screen)
    #expect(f.registry.entries[f.contentID]?.state == .working)
    #expect(f.registry.entries[f.contentID]?.source == .screen)
    f.apply([ProgramStatusReport(state: .blocked, kind: .permission, app: kind.rawValue)])
    #expect(f.registry.entries[f.contentID]?.state == .blocked)
    #expect(f.registry.entries[f.contentID]?.source == .programStatus)
    f.apply([ProgramStatusReport(state: .idle, app: kind.rawValue)])
    f.viewport(screen)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
    f.apply([ProgramStatusReport(state: .clear)])
    f.viewport(screen)
    #expect(f.registry.entries[f.contentID]?.state == .working)
    #expect(f.registry.entries[f.contentID]?.source == .screen)
  }

  @Test
  func workingReportNeedsNoKeystroke() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    let entry = f.registry.entries[f.contentID]
    #expect(entry?.state == .working)
    #expect(entry?.source == .programStatus)
  }

  @Test
  func blockedReportCarriesKindAndMessage() {
    let f = Fixture()
    bindClaude(f)
    f.report(.blocked, kind: .permission, message: "approve Bash: touch x")
    let entry = f.registry.entries[f.contentID]
    #expect(entry?.state == .blocked)
    #expect(entry?.blockedKind == .permission)
    #expect(entry?.message == "approve Bash: touch x")
  }

  @Test
  func reportOverridesTheScreen() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.viewport("Do you want to proceed?\n❯ 1. Yes\n  2. No")
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func doneShowsUntilTheUserLooks() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.report(.done)
    #expect(f.registry.entries[f.contentID]?.state == .done)
    f.registry.onPaneFocused(f.contentID)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func doneWhileFocusedIsIdle() {
    let f = Fixture()
    bindClaude(f)
    f.focused.setValue(f.contentID)
    f.report(.working)
    f.report(.done)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func idleReportNeverShowsDone() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.report(.idle)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func errorStaysUntilTheNextReport() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.report(.error, message: "invalid API key")
    #expect(f.registry.entries[f.contentID]?.state == .error)
    f.registry.onPaneFocused(f.contentID)
    #expect(f.registry.entries[f.contentID]?.state == .error)
    f.report(.working)
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func focusDoesNotClearAReportedBlock() {
    let f = Fixture()
    bindClaude(f)
    f.report(.blocked, kind: .question)
    f.registry.onPaneFocused(f.contentID)
    f.registry.onPaneKeyboardActivity(f.contentID)
    #expect(f.registry.entries[f.contentID]?.state == .blocked)
  }

  @Test
  func blockedChildBlocksThePane() {
    let f = Fixture()
    bindClaude(f)
    f.apply([
      ProgramStatusReport(state: .working, app: "claude-code"),
      ProgramStatusReport(state: .working, id: "agent-1"),
    ])
    #expect(f.registry.entries[f.contentID]?.state == .working)
    f.apply([
      ProgramStatusReport(state: .done, app: "claude-code"),
      ProgramStatusReport(state: .blocked, kind: .question, id: "agent-1"),
    ])
    #expect(f.registry.entries[f.contentID]?.state == .blocked)
    #expect(f.registry.entries[f.contentID]?.blockedKind == .question)
  }

  @Test
  func reportFromAnotherAppFallsBackToTheScreen() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.report(.working)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
    #expect(f.registry.entries[f.contentID]?.source == .screen)
  }

  @Test
  func reportBeforeBindingAppliesOnBind() {
    let f = Fixture()
    f.report(.working)
    bindClaude(f)
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func losingTheRecordsHandsBackToTheScreen() {
    let f = Fixture()
    bindClaude(f)
    f.viewport("✻ Thinking… (esc to interrupt)")
    f.report(.blocked, kind: .permission)
    f.registry.onTerminalEvent(.paneProgramStatusChanged(f.contentID, nil))
    let entry = f.registry.entries[f.contentID]
    #expect(entry?.source == .screen)
    #expect(entry?.state == .idle)
    #expect(entry?.blockedKind == nil)
  }

  @Test
  func reportedStopsFeedObservedAttention() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.inView.setValue(true)
    f.report(.done)
    #expect(f.registry.hasObservedAttention(f.contentID))
    f.inView.setValue(false)
    f.report(.working)
    f.report(.blocked, kind: .permission)
    #expect(!f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func sidebarActivityIgnoresMessageChangesAndTracksUnbind() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working, message: "Reading files")
    #expect(f.registry.workingContentIDs == [f.contentID])
    #expect(f.registry.needsAttention)
    let invalidated = LockIsolated(false)
    withObservationTracking {
      _ = f.registry.workingContentIDs
      _ = f.registry.needsAttention
    } onChange: {
      invalidated.setValue(true)
    }
    f.report(.working, message: "Running tests")
    #expect(!invalidated.value)
    f.report(.blocked, kind: .permission)
    #expect(invalidated.value)
    #expect(f.registry.workingContentIDs.isEmpty)
    #expect(f.registry.needsAttention)
    f.registry.onAgentUnbound(f.contentID)
    #expect(!f.registry.needsAttention)
  }

  @Test
  func sidebarActivityTracksRestoredAndRetiredAgents() {
    let f = Fixture()
    f.registry.seedRestored([(contentID: f.contentID, kind: .claudeCode, state: .working)])
    #expect(f.registry.workingContentIDs == [f.contentID])
    #expect(f.registry.needsAttention)
    f.registry.reconcileMembership(liveContentIDs: [])
    #expect(f.registry.workingContentIDs.isEmpty)
    #expect(!f.registry.needsAttention)
  }

  @Test
  func messageChangeKeepsTheTransitionTime() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working, message: "Reading files")
    let first = f.registry.entries[f.contentID]?.lastTransitionAt
    f.nowBox.setValue(f.nowBox.value.addingTimeInterval(5))
    f.report(.working, message: "Running tests")
    let entry = f.registry.entries[f.contentID]
    #expect(entry?.message == "Running tests")
    #expect(entry?.lastTransitionAt == first)
  }
}

extension AgentStateStoreTests.Fixture {
  /// Deliver the summary of a root report from Claude Code.
  func report(
    _ state: ProgramStatusState,
    kind: ProgramStatusKind? = nil,
    message: String? = nil
  ) {
    apply([ProgramStatusReport(state: state, kind: kind, app: "claude-code", message: message)])
  }

  /// Deliver the summary of these reports applied to empty records.
  func apply(_ reports: [ProgramStatusReport]) {
    var records = ProgramStatusRecords()
    for report in reports { records.apply(report) }
    registry.onTerminalEvent(.paneProgramStatusChanged(contentID, records.summary))
  }
}
