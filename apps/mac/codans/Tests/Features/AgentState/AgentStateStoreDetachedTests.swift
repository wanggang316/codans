import CodansCore
import Foundation
import Testing

@testable import Codans

/// A pane without a surface: its screen is not read, so a screen-derived
/// state is cached, while a program status report is still observed.
@MainActor
struct AgentStateStoreDetachedTests {
  typealias Fixture = AgentStateStoreTests.Fixture

  @Test
  func restoredSeedOfADetachedPaneIsCached() {
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: .working)])
    f.registry.setDetached(f.paneID, true)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.registry.setDetached(f.paneID, false)
    #expect(f.registry.entries[f.paneID]?.source == .screen)
  }

  @Test
  func programStatusOfADetachedPaneIsObserved() {
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: .idle)])
    f.registry.setDetached(f.paneID, true)

    f.apply([ProgramStatusReport(state: .working, app: "claude-code")])
    #expect(f.registry.entries[f.paneID]?.state == .working)
    #expect(f.registry.entries[f.paneID]?.source == .programStatus)

    // The agent drops its report: the state falls back to the screen,
    // which nothing reads while the pane is detached.
    f.apply([ProgramStatusReport(state: .clear)])
    #expect(f.registry.entries[f.paneID]?.source == .cached)
  }

  @Test
  func screenRefreshWhileDetachedStaysCached() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.registry.setDetached(f.paneID, true)
    f.registry.onPaneFocused(f.paneID)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
  }

  @Test
  func detachedMarkWithoutAnEntryAppliesOnBind() {
    let f = Fixture()
    f.registry.setDetached(f.paneID, true)
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.source == .cached)
  }

  @Test
  func reconcileForgetsDetachedPanesThatLeftTheCatalog() {
    let f = Fixture()
    f.registry.setDetached(f.paneID, true)
    f.registry.reconcileMembership(livePaneIDs: [])
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.source == .screen)
  }
}
