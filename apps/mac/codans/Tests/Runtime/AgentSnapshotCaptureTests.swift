import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentSnapshotCaptureTests {
  @Test
  func replacementDuringCaptureRejectsText() {
    let binding = makeBinding()
    var current = true
    let snapshot = TerminalEngine.captureAgentSnapshot(
      binding: binding, sequence: 1, observedAt: Date(),
      isCurrent: { current },
      readText: {
        current = false
        return "API Error: stale process output"
      })
    #expect(snapshot == nil)
  }

  @Test
  func invalidIdentityPreventsReadingTheTerminal() {
    var didRead = false
    let snapshot = TerminalEngine.captureAgentSnapshot(
      binding: makeBinding(), sequence: 1, observedAt: Date(),
      isCurrent: { false },
      readText: {
        didRead = true
        return "old error"
      })
    #expect(snapshot == nil)
    #expect(!didRead)
  }

  @Test
  func unchangedTextStillProducesAFreshVerifiedCapture() throws {
    let binding = makeBinding()
    let first = try #require(
      TerminalEngine.captureAgentSnapshot(
        binding: binding, sequence: 1, observedAt: Date(timeIntervalSinceReferenceDate: 10),
        isCurrent: { true }, readText: { "unchanged" }))
    let second = try #require(
      TerminalEngine.captureAgentSnapshot(
        binding: binding, sequence: 2, observedAt: Date(timeIntervalSinceReferenceDate: 20),
        isCurrent: { true }, readText: { "unchanged" }))
    #expect(second.binding == first.binding)
    #expect(second.text == first.text)
    #expect(second.sequence > first.sequence)
    #expect(second.observedAt > first.observedAt)
  }

  private func makeBinding() -> AgentBinding {
    AgentBinding(
      paneID: PaneID(), surfaceGeneration: UUID(), kind: .codex,
      process: AgentProcessIdentity(
        processID: 123, processStartedAt: Date(timeIntervalSinceReferenceDate: 1), processGroupID: 123),
      sessionID: nil)
  }
}
