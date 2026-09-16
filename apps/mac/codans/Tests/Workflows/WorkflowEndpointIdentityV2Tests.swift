import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct WorkflowEndpointIdentityV2Tests {
  @Test
  func replacementInSamePaneCannotReuseGeneration() {
    let store = AgentStateStore(focusedPane: { nil })
    let pane = PaneID(raw: UUID())
    store.onAgentBound(pane, kind: .codex, sessionID: "first")
    let first = store.bindingGenerations[pane]
    store.onAgentBound(pane, kind: .codex, sessionID: "first")
    #expect(store.bindingGenerations[pane] == first)
    store.onAgentUnbound(pane)
    store.onAgentBound(pane, kind: .codex, sessionID: "first")
    #expect(store.bindingGenerations[pane] == (first ?? 0) + 1)
    store.onAgentBound(pane, kind: .codex, sessionID: "second")
    #expect(store.bindingGenerations[pane] == (first ?? 0) + 2)
  }

  @Test
  func restoredAgentGetsIdentityOnlyAfterLiveBinding() {
    let store = AgentStateStore(focusedPane: { nil })
    let pane = PaneID(raw: UUID())
    store.seedRestored([(paneID: pane, kind: .codex, state: .idle)])
    #expect(store.bindingGenerations[pane] == nil)
    store.onAgentBound(pane, kind: .codex, sessionID: nil)
    #expect(store.bindingGenerations[pane] == 1)
  }

  @Test
  func identityEnrichmentDoesNotRevokeCurrentAssignment() {
    let store = AgentStateStore(focusedPane: { nil })
    let pane = PaneID(raw: UUID())
    store.onAgentBound(pane, kind: .codex, sessionID: nil)
    let generation = store.bindingGenerations[pane]
    store.onAgentBound(pane, kind: .codex, sessionID: "discovered")
    #expect(store.bindingGenerations[pane] == generation)
    store.onAgentBound(pane, kind: .claudeCode, sessionID: "discovered")
    #expect(store.bindingGenerations[pane] == (generation ?? 0) + 1)
  }
}
