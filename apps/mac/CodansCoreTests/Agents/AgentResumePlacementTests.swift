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
}
