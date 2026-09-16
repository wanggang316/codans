import CodansCore
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
    let content = try #require(String(
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
