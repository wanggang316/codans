import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentWorkflowStoreTests {
  private enum WriteFailure: Error { case unavailable }

  private final class Writer {
    var failing = false
    var calls = 0

    func write(_ record: AgentWorkflowStore.Record, to url: URL) throws {
      calls += 1
      if failing { throw WriteFailure.unavailable }
      try AtomicFileStore.write(record, to: url)
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-store-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test
  func manualResultRecordsHumanProvenanceAndPreservesActiveAttemptIdentity() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let id = UUID()
    _ = try store.create(id: id, template: .committee, title: "Review", input: "Question")
    try store.recordResult(id: id, stepID: "analysis-a", content: "User supplied analysis A")
    #expect(try store.status(id).attempts.first?.paneID == "user")
    #expect(try store.status(id).events.last?.type == "human.result.recorded")
    let attempt = try store.claim(id, stepID: "analysis-b", paneID: "worker-b")
    #expect(throws: AgentWorkflowError.runBusy) {
      try store.recordResult(id: id, stepID: "review-a", content: "Premature review")
    }
    try store.recordResult(id: id, stepID: "analysis-b", content: "Manually recovered analysis B")
    let saved = try store.status(id)
    #expect(saved.attempts.count == 2)
    #expect(saved.attempts.last?.id == attempt.id)
    #expect(saved.attempts.last?.paneID == "worker-b")
    #expect(saved.attempts.last?.content == "Manually recovered analysis B")
    #expect(saved.events.last?.type == "human.result.recorded")
    #expect(throws: AgentWorkflowError.deliveryConflict) {
      try store.deliver(
        id, attemptID: attempt.id, deliveryID: UUID(), paneID: "worker-b", content: "Late worker report")
    }
  }

  @Test
  func manualResultRejectsHandoffDecisionsAndUnreadyOrEndedSteps() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let advisor = UUID()
    _ = try store.create(id: advisor, template: .advisor, title: "Advice", input: "Question")
    #expect(throws: (any Error).self) {
      try store.recordResult(id: advisor, stepID: "disposition", content: "Bypass decision")
    }
    try store.recordResult(id: advisor, stepID: "advice", content: "User supplied advice")
    try store.decide(advisor, content: "Use it")
    #expect(throws: AgentWorkflowError.terminalRun) {
      try store.recordResult(id: advisor, stepID: "advice", content: "Rewrite")
    }
    for template in [AgentWorkflowTemplate.handoff, .handoffSave] {
      let id = UUID()
      _ = try store.create(id: id, template: template, title: "Handoff", input: "Continue")
      for step in ["packet", "export", "receive"] {
        #expect(throws: (any Error).self) { try store.recordResult(id: id, stepID: step, content: "Bypass") }
      }
    }
    let committee = UUID()
    _ = try store.create(id: committee, template: .committee, title: "Review", input: "Question")
    #expect(throws: AgentWorkflowError.dependenciesUnsatisfied) {
      try store.recordResult(id: committee, stepID: "synthesis", content: "Premature result")
    }
    #expect(try store.status(committee).attempts.isEmpty)
  }

  @Test
  func failedManualResultWriteDoesNotPublishAnAttemptOrResult() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = Writer()
    let store = AgentWorkflowStore(root: root, write: { try writer.write($0, to: $1) })
    let id = UUID()
    _ = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    let before = try store.status(id)
    writer.failing = true
    #expect(throws: WriteFailure.self) { try store.recordResult(id: id, stepID: "advice", content: "Manual advice") }
    #expect(try store.status(id) == before)
    #expect(!store.canDispatch(id))
  }

  @Test
  func executionBindingSeparatesPendingFromWrongPaneAndPreservesConfiguration() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let id = UUID()
    _ = try store.create(id: id, template: .committee, title: "Review", input: "Question")
    let configuration = AgentWorkflowExecution(
      projectID: ProjectID(), worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode),
      secondary: AgentProfile(kind: .codex))
    try store.configureExecution(id, configuration: configuration)
    #expect(try store.beginDispatch(id, stepID: "analysis-a"))
    #expect(try !store.beginDispatch(id, stepID: "analysis-a"))
    #expect(try !store.beginDispatch(id, stepID: "analysis-b"))
    #expect(throws: IPCError.conflict(reason: "Agent binding is pending; retry claim shortly")) {
      try store.claim(id, stepID: "analysis-a", paneID: "a")
    }
    #expect(throws: AgentWorkflowError.invalidPane) {
      try store.bindDispatch(id, stepID: "analysis-a", paneID: " \n")
    }
    try store.bindDispatch(id, stepID: "analysis-a", paneID: "a")
    #expect(throws: IPCError.conflict(reason: "This assignment belongs to another pane")) {
      try store.claim(id, stepID: "analysis-a", paneID: "b")
    }
    try store.configureExecution(id, configuration: configuration)
    #expect(store.records[id]?.execution?.dispatches["analysis-a"]?.paneID == "a")
    #expect(throws: (any Error).self) {
      try store.configureExecution(
        id,
        configuration: AgentWorkflowExecution(
          projectID: configuration.projectID, worktreeID: WorktreeID(), primary: configuration.primary,
          secondary: configuration.secondary))
    }
    let attempt = try store.claim(id, stepID: "analysis-a", paneID: "a")
    let claimed = try store.status(id)
    #expect(try store.claim(id, stepID: "analysis-a", paneID: "a") == attempt)
    #expect(try store.status(id) == claimed)
    #expect(throws: IPCError.conflict(reason: "This assignment belongs to another pane")) {
      try store.claim(id, stepID: "analysis-a", paneID: "b")
    }
    _ = try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "a", content: "Analysis A")
    #expect(try store.beginDispatch(id, stepID: "analysis-b"))
  }

  @Test
  func boundAgentMayClaimAfterAttentionWithoutAllowingAnotherPane() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let id = UUID()
    _ = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    try store.configureExecution(
      id,
      configuration: AgentWorkflowExecution(
        projectID: ProjectID(), worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode), secondary: nil))
    #expect(try store.beginDispatch(id, stepID: "advice"))
    try store.dispatchIssue(id, stepID: "advice", message: "Unknown launch")
    #expect(throws: (any Error).self) { try store.claim(id, stepID: "advice", paneID: "a") }
    // An unbound unknown launch never acquires ownership through a late claim.
    #expect(store.records[id]?.execution?.dispatches["advice"]?.paneID == nil)

    let boundID = UUID()
    _ = try store.create(id: boundID, template: .advisor, title: "Bound", input: "Question")
    try store.configureExecution(
      boundID,
      configuration: AgentWorkflowExecution(
        projectID: ProjectID(), worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode), secondary: nil))
    #expect(try store.beginDispatch(boundID, stepID: "advice"))
    try store.bindDispatch(boundID, stepID: "advice", paneID: "a")
    try store.dispatchIssue(boundID, stepID: "advice", message: "Claim timed out")
    #expect(throws: IPCError.conflict(reason: "This assignment belongs to another pane")) {
      try store.claim(boundID, stepID: "advice", paneID: "b")
    }
    let attempt = try store.claim(boundID, stepID: "advice", paneID: "a")
    #expect(store.records[boundID]?.execution?.dispatches["advice"]?.status == .submitted)
    #expect(store.records[boundID]?.execution?.dispatches["advice"]?.message == nil)
    _ = try store.deliver(boundID, attemptID: attempt.id, deliveryID: UUID(), paneID: "a", content: "Late advice")
    #expect(try store.status(boundID).readySteps.map(\.id) == ["disposition"])
  }

  @Test
  func advisorDecisionRequiresAcceptedAdviceAndCommitsOnce() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let id = UUID()
    _ = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    #expect(throws: AgentWorkflowError.dependenciesUnsatisfied) { try store.decide(id, content: "Use advice") }
    let attempt = try store.claim(id, stepID: "advice", paneID: "advisor")
    _ = try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "advisor", content: "Recommendation")
    let before = try store.status(id)
    #expect(throws: (any Error).self) { try store.decide(id, content: " \n") }
    #expect(try store.status(id) == before)
    try store.decide(id, content: "Adopt the recommendation because it addresses the requirements.")
    let completed = try store.status(id)
    #expect(completed.status == .succeeded)
    #expect(completed.attempts.last?.paneID == "user")
    #expect(completed.events.last?.type == "decision.recorded")
    #expect(throws: AgentWorkflowError.terminalRun) { try store.decide(id, content: "Second decision") }
    #expect(try store.status(id) == completed)
  }

  @Test
  func failedDecisionWriteDoesNotPublishCompletion() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = Writer()
    let store = AgentWorkflowStore(root: root, write: { try writer.write($0, to: $1) })
    let id = UUID()
    _ = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    let attempt = try store.claim(id, stepID: "advice", paneID: "advisor")
    _ = try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "advisor", content: "Recommendation")
    let before = try store.status(id)
    writer.failing = true
    #expect(throws: WriteFailure.self) { try store.decide(id, content: "Adopt") }
    #expect(try store.status(id) == before)
    #expect(!store.canDispatch(id))
    let persisted = try #require(
      try AtomicFileStore.read(AgentWorkflowStore.Record.self, at: root.appendingPathComponent("\(id).json")))
    #expect(persisted.run == before)
  }

  @Test
  func failedWriteDoesNotPublishDeliveryAndFencesFurtherMutation() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = Writer()
    let store = AgentWorkflowStore(root: root, write: { try writer.write($0, to: $1) })
    let id = UUID()
    _ = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    let attempt = try store.claim(id, stepID: "advice", paneID: "advisor")
    let before = try store.status(id)
    writer.failing = true
    #expect(throws: WriteFailure.self) {
      try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "advisor", content: "Answer")
    }
    #expect(try store.status(id) == before)
    let disk = try #require(
      try AtomicFileStore.read(AgentWorkflowStore.Record.self, at: root.appendingPathComponent("\(id).json")))
    #expect(disk.run == before)
    #expect(!store.issues.isEmpty)
    writer.failing = false
    let calls = writer.calls
    #expect(throws: (any Error).self) {
      try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "advisor", content: "Answer")
    }
    #expect(throws: (any Error).self) { try store.claim(id, stepID: "disposition", paneID: "author") }
    #expect(writer.calls == calls)
  }

  @Test
  func createIsIdempotentAndRejectsDifferentInput() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = Writer()
    let store = AgentWorkflowStore(root: root, write: { try writer.write($0, to: $1) })
    let id = UUID()
    let first = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    let second = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
    #expect(first == second)
    #expect(writer.calls == 1)
    #expect(store.runs.count == 1)
    #expect(throws: (any Error).self) {
      try store.create(id: id, template: .advisor, title: "Advice", input: "Changed")
    }
    #expect(writer.calls == 1)
  }

  @Test
  func restartInterruptsAndRefusesOldExecution() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = AgentWorkflowStore(root: root)
    let id = UUID()
    _ = try original.create(id: id, template: .advisor, title: "Advice", input: "Question")
    let attempt = try original.claim(id, stepID: "advice", paneID: "advisor")
    let restarted = AgentWorkflowStore(root: root)
    #expect(try restarted.status(id).status == .interrupted)
    #expect(try restarted.status(id).attempts.first?.status == .revoked)
    #expect(throws: (any Error).self) {
      try restarted.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "advisor", content: "Late")
    }
    #expect(throws: (any Error).self) { try restarted.claim(id, stepID: "advice", paneID: "advisor") }
    let disk = try #require(
      try AtomicFileStore.read(AgentWorkflowStore.Record.self, at: root.appendingPathComponent("\(id).json")))
    #expect(disk.run.status == .interrupted)
  }

  @Test
  func handoffRequiresBoundReceiverAndMatchingPacketDigest() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let id = UUID()
    _ = try store.create(id: id, template: .handoff, title: "Handoff", input: "Continue")
    let digest = try store.installPacket(id, content: "Immutable packet", sourcePaneID: "author")
    #expect(try store.status(id).status == .running)
    try store.finishExport(id, sourcePaneID: "author")
    try store.bindReceiver(id, paneID: "receiver")
    #expect(throws: (any Error).self) { try store.claim(id, stepID: "receive", paneID: "wrong") }
    let attempt = try store.claim(id, stepID: "receive", paneID: "receiver")
    let before = try store.status(id)
    #expect(throws: (any Error).self) {
      try store.deliver(
        id, attemptID: attempt.id, deliveryID: UUID(), paneID: "receiver",
        content: #"{"packetDigest":"wrong","nextAction":"Continue"}"#)
    }
    #expect(try store.status(id) == before)
    let content = try #require(
      String(
        bytes: try JSONEncoder().encode(["packetDigest": digest, "nextAction": "Continue"]), encoding: .utf8))
    #expect(throws: (any Error).self) {
      try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "wrong", content: content)
    }
    let deliveryID = UUID()
    let completed = try store.deliver(
      id, attemptID: attempt.id, deliveryID: deliveryID, paneID: "receiver", content: content)
    #expect(completed.status == .succeeded)
    #expect(completed.attempts.first?.content == "Immutable packet")
    _ = try store.cancel(id)
    let retried = try store.deliver(
      id, attemptID: attempt.id, deliveryID: deliveryID, paneID: "receiver", content: content)
    #expect(retried == completed)
  }

  @Test
  func cancelRejectsLateDeliveryAndFailedCancelStillFences() throws {
    for failure in [false, true] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let writer = Writer()
      let store = AgentWorkflowStore(root: root, write: { try writer.write($0, to: $1) })
      let id = UUID()
      _ = try store.create(id: id, template: .advisor, title: "Advice", input: "Question")
      let attempt = try store.claim(id, stepID: "advice", paneID: "advisor")
      writer.failing = failure
      if failure {
        #expect(throws: WriteFailure.self) { try store.cancel(id) }
        #expect(try store.status(id).status == .running)
      } else {
        #expect(try store.cancel(id).status == .cancelled)
      }
      writer.failing = false
      let before = try store.status(id)
      let calls = writer.calls
      #expect(throws: (any Error).self) {
        try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: "advisor", content: "Late")
      }
      #expect(try store.status(id) == before)
      #expect(writer.calls == calls)
    }
  }
}
