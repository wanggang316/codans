import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The OSC 7501 path of `AgentStateStore`: a root record from the bound
/// agent decides the state ahead of the screen.
@MainActor
struct AgentStateStoreProgramStatusTests {
  typealias Fixture = AgentStateStoreTests.Fixture

  private func bindClaude(_ f: Fixture) {
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
  }

  @Test
  func codexReportsOverrideScreenAndClearRestoresFallback() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.apply([ProgramStatusReport(state: .working, app: "codex")])
    #expect(f.registry.entries[f.paneID]?.state == .working)
    #expect(f.registry.entries[f.paneID]?.source == .programStatus)
    f.apply([ProgramStatusReport(state: .idle, app: "codex")])
    f.viewport("• Working (12s)")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
    #expect(f.registry.entries[f.paneID]?.source == .programStatus)
    f.apply([ProgramStatusReport(state: .clear)])
    #expect(f.registry.entries[f.paneID]?.source == .screen)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (12s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func workingReportNeedsNoKeystroke() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    let entry = f.registry.entries[f.paneID]
    #expect(entry?.state == .working)
    #expect(entry?.source == .programStatus)
  }

  @Test
  func blockedReportCarriesKindAndMessage() {
    let f = Fixture()
    bindClaude(f)
    f.report(.blocked, kind: .permission, message: "approve Bash: touch x")
    let entry = f.registry.entries[f.paneID]
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
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func doneShowsUntilTheUserLooks() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.report(.done)
    #expect(f.registry.entries[f.paneID]?.state == .done)
    f.registry.onPaneFocused(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func doneWhileFocusedIsIdle() {
    let f = Fixture()
    bindClaude(f)
    f.focused.setValue(f.paneID)
    f.report(.working)
    f.report(.done)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func idleReportNeverShowsDone() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.report(.idle)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func errorStaysUntilTheNextReport() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working)
    f.report(.error, message: "invalid API key")
    #expect(f.registry.entries[f.paneID]?.state == .error)
    f.registry.onPaneFocused(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .error)
    f.report(.working)
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func focusDoesNotClearAReportedBlock() {
    let f = Fixture()
    bindClaude(f)
    f.report(.blocked, kind: .question)
    f.registry.onPaneFocused(f.paneID)
    f.registry.onPaneKeyboardActivity(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .blocked)
  }

  @Test
  func blockedChildBlocksThePane() {
    let f = Fixture()
    bindClaude(f)
    f.apply([
      ProgramStatusReport(state: .working, app: "claude-code"),
      ProgramStatusReport(state: .working, id: "agent-1"),
    ])
    #expect(f.registry.entries[f.paneID]?.state == .working)
    f.apply([
      ProgramStatusReport(state: .done, app: "claude-code"),
      ProgramStatusReport(state: .blocked, kind: .question, id: "agent-1"),
    ])
    #expect(f.registry.entries[f.paneID]?.state == .blocked)
    #expect(f.registry.entries[f.paneID]?.blockedKind == .question)
  }

  @Test
  func reportFromAnotherAppFallsBackToTheScreen() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.report(.working)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
    #expect(f.registry.entries[f.paneID]?.source == .screen)
  }

  @Test
  func reportBeforeBindingAppliesOnBind() {
    let f = Fixture()
    f.report(.working)
    bindClaude(f)
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func losingTheRecordsHandsBackToTheScreen() {
    let f = Fixture()
    bindClaude(f)
    f.viewport("✻ Thinking… (esc to interrupt)")
    f.report(.blocked, kind: .permission)
    f.registry.onTerminalEvent(.paneProgramStatusChanged(f.paneID, nil))
    let entry = f.registry.entries[f.paneID]
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
    #expect(f.registry.hasObservedAttention(f.paneID))
    f.inView.setValue(false)
    f.report(.working)
    f.report(.blocked, kind: .permission)
    #expect(!f.registry.hasObservedAttention(f.paneID))
  }

  @Test
  func messageChangeKeepsTheTransitionTime() {
    let f = Fixture()
    bindClaude(f)
    f.report(.working, message: "Reading files")
    let first = f.registry.entries[f.paneID]?.lastTransitionAt
    f.nowBox.setValue(f.nowBox.value.addingTimeInterval(5))
    f.report(.working, message: "Running tests")
    let entry = f.registry.entries[f.paneID]
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
    registry.onTerminalEvent(.paneProgramStatusChanged(paneID, records.summary))
  }
}
