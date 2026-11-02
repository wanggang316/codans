import CodansCore
import Foundation
import Testing

@testable import Codans

/// A pane without a surface (a sleeping row): its screen is not read, so a
/// screen-derived state is cached, while program status from the passive
/// watcher is still observed.
@MainActor
struct AgentStateStoreDetachedTests {
  typealias Fixture = AgentStateStoreTests.Fixture

  @Test
  func restoredSeedOfADetachedPaneIsCached() {
    let f = Fixture(attached: false)
    f.registry.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: .working)])
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
    #expect(f.registry.entries[f.paneID]?.state == .working)
    #expect(f.registry.isSleeping(f.paneID))

    f.registry.onSurfaceAttachmentChanged(f.paneID, attached: true)
    #expect(f.registry.entries[f.paneID]?.source == .screen)
    #expect(!f.registry.isSleeping(f.paneID))
  }

  @Test
  func programStatusOfADetachedPaneIsObserved() {
    let f = Fixture(attached: false)
    f.registry.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: .idle)])

    f.apply([ProgramStatusReport(state: .working, app: "claude-code")])
    #expect(f.registry.entries[f.paneID]?.state == .working)
    #expect(f.registry.entries[f.paneID]?.source == .programStatus)
    // Still sleeping: no surface renders the pane.
    #expect(f.registry.isSleeping(f.paneID))

    // The agent drops its report: the state falls back to the screen,
    // which nothing reads while the pane is detached.
    f.apply([ProgramStatusReport(state: .clear)])
    #expect(f.registry.entries[f.paneID]?.source == .cached)
  }

  @Test
  func midTaskAgentReportingProgramStatusDoesNotNeedItsSurface() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.apply([ProgramStatusReport(state: .working, app: "claude-code")])
    #expect(f.registry.entries[f.paneID]?.source == .programStatus)
    #expect(!f.registry.needsSurfaceToTrackTurn(f.paneID))

    f.apply([ProgramStatusReport(state: .blocked, app: "claude-code")])
    #expect(!f.registry.needsSurfaceToTrackTurn(f.paneID))
  }

  @Test
  func midTaskAgentReadFromTheScreenNeedsItsSurface() {
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: .working)])
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.source == .screen)
    #expect(f.registry.needsSurfaceToTrackTurn(f.paneID))

    // Once detached the state is cached, and still not observed.
    f.registry.onSurfaceAttachmentChanged(f.paneID, attached: false)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
    #expect(f.registry.needsSurfaceToTrackTurn(f.paneID))
  }

  @Test
  func agentBetweenTurnsDoesNotNeedItsSurface() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
    #expect(!f.registry.needsSurfaceToTrackTurn(f.paneID))
    #expect(!f.registry.needsSurfaceToTrackTurn(PaneID()))
  }

  @Test
  func reclaimTurnsAScreenStateIntoACachedOne() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.source == .screen)

    f.registry.onSurfaceAttachmentChanged(f.paneID, attached: false)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
    f.registry.onPaneFocused(f.paneID)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
  }

  /// The app unbinds the agent when a detached pane's daemon exits: the
  /// row goes away, so it never shows as sleeping.
  @Test
  func unbindAfterADaemonExitRemovesTheSleepingRow() {
    let f = Fixture(attached: false)
    f.registry.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: .working)])
    #expect(f.registry.isSleeping(f.paneID))

    f.registry.onAgentUnbound(f.paneID)
    #expect(f.registry.entries[f.paneID] == nil)
    #expect(!f.registry.isSleeping(f.paneID))
  }
}
