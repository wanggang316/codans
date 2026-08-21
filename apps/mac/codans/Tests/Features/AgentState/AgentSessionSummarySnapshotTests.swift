import CodansCore
import Foundation
import Testing

@testable import Codans

/// The hover card renders from a snapshot captured before the popover
/// opens, so its size can never change while presented (see
/// `AgentSessionSummarySnapshot` for the crash that invariant prevents).
/// These cases pin the derivations that happen at capture time; the scan
/// itself (`make`) is I/O and stays out of unit tests.
@MainActor
struct AgentSessionSummarySnapshotTests {
  private func entry(
    state: AgentStateStore.AgentRuntimeState = .working,
    transitionAt: TimeInterval = 0,
    sessionID: String? = nil
  ) -> AgentStateStore.AgentEntry {
    .init(
      kind: .claudeCode,
      sessionID: sessionID,
      state: state,
      lastTransitionAt: Date(timeIntervalSince1970: transitionAt)
    )
  }

  private func snapshot(
    session: AgentSessionSummary? = nil,
    paneTitle: String? = nil,
    now: TimeInterval = 90,
    paneID: PaneID = PaneID()
  ) -> AgentSessionSummarySnapshot {
    AgentSessionSummarySnapshot(
      paneID: paneID,
      entry: entry(),
      projectName: "codans",
      worktreeName: "main",
      projectColor: .blue,
      session: session,
      paneTitle: paneTitle,
      now: Date(timeIntervalSince1970: now)
    )
  }

  @Test
  func ageIsFrozenAtCaptureTimeAndKeyedByPane() {
    let paneID = PaneID()
    let captured = snapshot(now: 90, paneID: paneID)
    #expect(captured.id == paneID)
    #expect(captured.ageText == "1m")
  }

  /// An idle agent retitles its pane to itself; that title says nothing
  /// the card's header doesn't already say, so it never becomes a line.
  @Test
  func redundantPaneTitleYieldsNoActivityLine() {
    #expect(snapshot(paneTitle: "✳ Claude Code").activity == nil)
    #expect(snapshot(paneTitle: "   ").activity == nil)
    #expect(snapshot(paneTitle: nil).activity == nil)
  }

  @Test
  func informativePaneTitleIsKeptTrimmed() {
    #expect(snapshot(paneTitle: "  Running tests…  ").activity == "Running tests…")
  }

  /// The session footer's relative age is formatted once, at capture —
  /// no live clock on a presented popover.
  @Test
  func sessionAgeIsFormattedOnlyWhenASessionIsFeatured() {
    let featured = AgentSessionSummary(
      agent: .claudeCode,
      sessionID: "abc",
      title: "fix the crash",
      updatedAt: Date(timeIntervalSince1970: 30)
    )
    #expect(snapshot(session: featured).sessionAgeText != nil)
    #expect(snapshot(session: nil).sessionAgeText == nil)
  }
}
