import Foundation
import Testing

@testable import CodansCore

extension AgentResumePlacement.Context {
  fileprivate static let idlePane = Self(hasFocusedPane: true, focusedPaneRunsAgent: false)
  fileprivate static let agentPane = Self(hasFocusedPane: true, focusedPaneRunsAgent: true)
}

struct AgentResumePlacementTests {
  @Test
  func defaultIsANewTab() {
    #expect(AgentResumePlacement.default == .newTab)
  }

  @Test
  func targetAndDirectionMapOntoTheScriptPipeline() {
    #expect(AgentResumePlacement.newTab.target == .newTab)
    #expect(AgentResumePlacement.newTab.direction == nil)
    #expect(AgentResumePlacement.inPlace.target == .focused)
    #expect(AgentResumePlacement.inPlace.direction == nil)
    #expect(AgentResumePlacement.split(.left).target == .split)
    #expect(AgentResumePlacement.split(.left).direction == .left)
  }

  @Test
  func persistedTokenRoundTripsForEveryPlacement() {
    let all: [AgentResumePlacement] =
      [.newTab, .inPlace] + ScriptSplitDirection.allCases.map { .split($0) }
    for placement in all {
      #expect(AgentResumePlacement(persisted: placement.persisted) == placement)
    }
    #expect(AgentResumePlacement.newTab.persisted == "tab")
    #expect(AgentResumePlacement.inPlace.persisted == "focused")
    #expect(AgentResumePlacement.split(.right).persisted == "split:right")
  }

  /// Same token shape as the hand-off placement, so both read the same way.
  @Test
  func sharedTokensMatchTheHandoffPlacement() {
    #expect(AgentResumePlacement.newTab.persisted == HandoffPlacement.newTab.persisted)
    #expect(
      AgentResumePlacement.split(.down).persisted == HandoffPlacement.split(.down).persisted)
  }

  @Test
  func unknownTokensAreRejected() {
    #expect(AgentResumePlacement(persisted: "") == nil)
    #expect(AgentResumePlacement(persisted: "split") == nil)
    #expect(AgentResumePlacement(persisted: "split:sideways") == nil)
    #expect(AgentResumePlacement(persisted: "inPlace") == nil)
  }

  @Test
  func inPlaceNeedsAFocusedPaneWithoutAnAgent() {
    #expect(AgentResumePlacement.Context.idlePane.allowsInPlace)
    #expect(!AgentResumePlacement.Context.agentPane.allowsInPlace)
    #expect(!AgentResumePlacement.Context.noFocusedPane.allowsInPlace)
  }

  @Test
  func shownPlacementReplacesOnlyAnUnavailableInPlace() {
    let busy = AgentResumePlacement.Context.agentPane
    #expect(AgentResumePlacement.inPlace.shown(in: busy) == .newTab)
    #expect(AgentResumePlacement.inPlace.shown(in: .noFocusedPane) == .newTab)
    // New Split stays selectable without a pane; the resume falls back instead.
    #expect(AgentResumePlacement.split(.up).shown(in: .noFocusedPane) == .split(.up))
    #expect(AgentResumePlacement.inPlace.shown(in: .idlePane) == .inPlace)
  }

  @Test
  func resolvedFallsBackToANewTabWhenThePlacementCannotRun() {
    let idle = AgentResumePlacement.Context.idlePane
    let busy = AgentResumePlacement.Context.agentPane
    #expect(AgentResumePlacement.inPlace.resolved(in: idle) == .inPlace)
    #expect(AgentResumePlacement.inPlace.resolved(in: busy) == .newTab)
    #expect(AgentResumePlacement.inPlace.resolved(in: .noFocusedPane) == .newTab)
    #expect(AgentResumePlacement.split(.down).resolved(in: busy) == .split(.down))
    #expect(AgentResumePlacement.split(.down).resolved(in: .noFocusedPane) == .newTab)
    #expect(AgentResumePlacement.newTab.resolved(in: .noFocusedPane) == .newTab)
  }

  @Test
  func contextReadsTheSelectedTabsLastFocusedPane() {
    let idle = Pane(workingDirectory: "/w")
    let agent = Pane(workingDirectory: "/w", agentKind: .codex)
    let tab = Tab(panes: [idle, agent])
    let other = Tab(panes: [Pane(workingDirectory: "/w")])
    let worktree = Worktree(name: "w", path: "/w", tabs: [other, tab], selectedTabID: tab.id)

    let onAgent = AgentResumePlacement.Context(worktree: worktree) {
      $0 == tab.id ? agent.id : nil
    }
    #expect(onAgent == .agentPane)
    // Never focused since launch: the tab's first pane stands in.
    let unfocused = AgentResumePlacement.Context(worktree: worktree) { _ in nil }
    #expect(unfocused == .idlePane)
  }

  @Test
  func contextWithoutTabsOrPanesHasNoFocusedPane() {
    let empty = Worktree(name: "w", path: "/w")
    #expect(AgentResumePlacement.Context(worktree: empty) { _ in nil } == .noFocusedPane)
    let paneless = Worktree(name: "w", path: "/w", tabs: [Tab()])
    #expect(AgentResumePlacement.Context(worktree: paneless) { _ in nil } == .noFocusedPane)
  }
}
