import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

@MainActor struct WorkflowHandoffV2Tests {
  private let briefing = """
    # Objective
    Continue the current task.
    # Current State
    The implementation is ready for verification.
    # Completed Work
    Reviewed the existing changes.
    # Next Steps
    Run the focused tests and report their result.
    """

  private func settle(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1000 {
      if predicate() { return }
      await Task.yield()
    }
  }

  @MainActor private final class Harness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-v2-\(UUID())")
    let author = PaneID()
    let receiver = PaneID()
    let service: WorkflowServiceV2
    let source: String
    var trace: [String] = []
    var prompts: [String] = []
    var id: UUID?

    init() throws {
      service = WorkflowServiceV2(root: directory)
      let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/WorkflowDefinitions")
      source = try String(
        contentsOf: resources.appendingPathComponent("handoff.codansworkflow/workflow.yaml"), encoding: .utf8)
      service.validateBinding = { _ in true }
      service.saveHandoffContext = { [weak self] record, arguments in
        let harness = try #require(self)
        #expect(record.nodes["briefing"]?.status == "succeeded")
        #expect(record.nodes["packet"]?.status == "pending")
        #expect(record.nodes["launch_receiver"]?.status == "pending")
        #expect(arguments["mode"] == .string("transition"))
        harness.trace.append("context")
        return ["briefing": try #require(arguments["briefing"])]
      }
      service.launch = { [weak self] binding, _ in
        let harness = try #require(self)
        let id = try #require(harness.id)
        #expect(harness.service.run(id)?.nodes["context"]?.status == "succeeded")
        #expect(harness.service.run(id)?.nodes["packet"]?.status == "succeeded")
        harness.trace.append("launch")
        var launched = binding
        launched.paneID = harness.receiver
        launched.sessionID = "receiver-session"
        return launched
      }
      service.send = { [weak self] binding, prompt, canDispatch in
        let harness = try #require(self)
        #expect(canDispatch())
        harness.trace.append(binding.paneID == harness.author ? "briefing" : "receiver")
        harness.prompts.append(prompt)
      }
    }

    func start() throws -> UUID {
      let result = try service.start(
        definition: WorkflowDefinitionParserV2.parse(source), source: source, title: "Handoff test",
        inputs: [:],
        bindings: [
          "author": .init(source: "current", paneID: author),
          "receiver": .init(source: "launch", profile: AgentProfile(kind: .codex)),
        ])
      id = result
      return result
    }

    func deliver(_ content: String, nodeID: String, pane: PaneID) throws {
      let runID = try #require(id)
      let execution = try #require(service.run(runID)?.nodes[nodeID]?.execution)
      let request = try #require(execution.request)
      _ = try service.deliver(
        id: runID, attemptID: execution.id, deliveryID: request.deliveryID,
        paneID: pane.description, content: content)
    }

    func acknowledgement(digest: String? = nil, blockers: [String] = []) throws -> String {
      let runID = try #require(id)
      let packet = try #require(service.run(runID)?.nodes["packet"]?.outputs["packet"]?.v2Object)
      let packetDigest = try #require(packet["digest"])
      let value: JSONValue = .object([
        "packetId": try #require(packet["id"]),
        "packetDigest": digest.map(JSONValue.string) ?? packetDigest,
        "understanding": .string("Continue the existing implementation without repeating completed work."),
        "nextAction": .string("Run the focused tests."),
        "blockers": .array(blockers.map(JSONValue.string)),
      ])
      return try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
    }
  }

  private func reachAcknowledgement(_ harness: Harness, id: UUID) async throws {
    await settle { harness.service.run(id)?.nodes["briefing"]?.execution?.request?.status == "sent" }
    try harness.deliver(briefing, nodeID: "briefing", pane: harness.author)
    await settle { harness.service.run(id)?.nodes["receive"]?.execution?.request?.status == "sent" }
    #expect(harness.service.run(id)?.nodes["receive"]?.status == "running")
  }

  @Test func builtInHandoffInfersObjectiveAndSavesContextBeforeLaunching() async throws {
    let harness = try Harness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let definition = try WorkflowDefinitionParserV2.parse(harness.source)
    #expect(definition.inputs["objective"] == nil)
    #expect(definition.inputs["note"]?.required != true)
    #expect(definition.inputs["note"]?.defaultValue == .string(""))
    let id = try harness.start()
    await settle { !harness.prompts.isEmpty }
    #expect(harness.service.run(id)?.inputs["note"] == .string(""))
    #expect(harness.prompts.first?.contains("Infer the objective from the current task") == true)
    try await reachAcknowledgement(harness, id: id)
    #expect(harness.trace == ["briefing", "context", "launch", "receiver"])
    let packet = try #require(harness.service.run(id)?.nodes["packet"]?.outputs["packet"]?.v2Object)
    #expect(packet["content"] == .string(briefing))
    let path = try #require(packet["contentRef"]?.v2String)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == briefing)
    try harness.service.cancel(id)
  }

  @Test func wrongAcknowledgementDigestNeverDispatchesContinuation() async throws {
    let harness = try Harness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let id = try harness.start()
    try await reachAcknowledgement(harness, id: id)
    try harness.deliver(harness.acknowledgement(digest: "wrong-digest"), nodeID: "receive", pane: harness.receiver)
    await settle { harness.service.run(id)?.status == "failed" }
    #expect(harness.service.run(id)?.nodes["verify"]?.status == "failed")
    #expect(harness.service.run(id)?.nodes["resume"]?.execution == nil)
    #expect(harness.prompts.count == 2)
  }

  @Test func receiverBlockersPreventContinuation() async throws {
    let harness = try Harness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let id = try harness.start()
    try await reachAcknowledgement(harness, id: id)
    try harness.deliver(
      harness.acknowledgement(blockers: ["Required credentials are unavailable"]),
      nodeID: "receive", pane: harness.receiver)
    await settle { harness.service.run(id)?.status == "failed" }
    #expect(harness.service.run(id)?.nodes["verify"]?.outputs["readiness"] == .string("blocked"))
    #expect(harness.service.run(id)?.nodes["resume"]?.status == "failed")
    #expect(harness.service.run(id)?.nodes["resume"]?.execution?.request == nil)
    #expect(harness.prompts.count == 2)
  }

  @Test func verifiedReceiptDispatchesContinuationWithoutWaitingForTaskResult() async throws {
    let harness = try Harness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let id = try harness.start()
    try await reachAcknowledgement(harness, id: id)
    try harness.deliver(harness.acknowledgement(), nodeID: "receive", pane: harness.receiver)
    await settle { harness.service.run(id)?.status == "succeeded" }
    let run = try #require(harness.service.run(id))
    #expect(run.status == "succeeded")
    #expect(run.outputs["continuation"] == .string("sent"))
    #expect(run.outputs["readiness"] == .string("ready"))
    let execution = try #require(run.nodes["resume"]?.execution)
    #expect(execution.request?.status == "sent")
    #expect(execution.request?.paneID == harness.receiver.description)
    #expect(execution.submissions.isEmpty)
    #expect(harness.prompts.count == 3)
    #expect(harness.prompts.last?.contains("Do not claim or deliver this node") == true)
    #expect(harness.prompts.last?.contains("workflow deliver") == false)
    #expect(run.events.contains { $0.type == "continuation_sent" && $0.nodeID == "resume" })
    #expect(WorkflowServiceV2(root: harness.directory).run(id)?.status == "succeeded")
  }

  @Test func continuationRejectsClaimAndDeliveryWhileTransportIsPending() async throws {
    let harness = try Harness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let id = try harness.start()
    try await reachAcknowledgement(harness, id: id)
    var continuation: CheckedContinuation<Void, Never>?
    harness.service.send = { _, _, _ in
      await withCheckedContinuation { continuation = $0 }
    }
    try harness.deliver(harness.acknowledgement(), nodeID: "receive", pane: harness.receiver)
    await settle { continuation != nil }
    let pending = try #require(continuation)
    var resumed = false
    defer { if !resumed { pending.resume() } }
    let execution = try #require(harness.service.run(id)?.nodes["resume"]?.execution)
    let request = try #require(execution.request)
    #expect(throws: (any Error).self) {
      _ = try harness.service.claim(id: id, nodeID: "resume", paneID: harness.receiver.description)
    }
    #expect(throws: (any Error).self) {
      _ = try harness.service.deliver(
        id: id, attemptID: execution.id, deliveryID: request.deliveryID,
        paneID: harness.receiver.description, content: "Premature task completion")
    }
    #expect(harness.service.run(id)?.nodes["resume"]?.status == "running")
    #expect(harness.service.run(id)?.nodes["resume"]?.execution?.submissions.isEmpty == true)
    #expect(harness.service.run(id)?.nodes["resume"]?.outputs.isEmpty == true)
    resumed = true
    pending.resume()
    await settle { harness.service.run(id)?.status == "succeeded" }
    #expect(harness.service.run(id)?.outputs["continuation"] == .string("sent"))
  }

  @Test func cancellationDuringContinuationSendCannotRestoreSuccess() async throws {
    let harness = try Harness()
    defer { try? FileManager.default.removeItem(at: harness.directory) }
    let id = try harness.start()
    try await reachAcknowledgement(harness, id: id)
    var continuation: CheckedContinuation<Void, Never>?
    var allowedAfterCancellation = true
    var finished = false
    harness.service.send = { _, _, canDispatch in
      await withCheckedContinuation { continuation = $0 }
      allowedAfterCancellation = canDispatch()
      finished = true
    }
    try harness.deliver(harness.acknowledgement(), nodeID: "receive", pane: harness.receiver)
    await settle { continuation != nil }
    let pending = try #require(continuation)
    try harness.service.cancel(id)
    pending.resume()
    await settle { finished }
    for _ in 0..<10 { await Task.yield() }
    #expect(!allowedAfterCancellation)
    #expect(harness.service.run(id)?.status == "cancelled")
    #expect(harness.service.run(id)?.nodes["resume"]?.execution?.status == "cancelled")
    #expect(harness.service.run(id)?.nodes["resume"]?.execution?.request?.status == "cancelled")
    #expect(harness.service.run(id)?.outputs["continuation"] == nil)
    #expect(harness.service.run(id)?.events.contains { $0.type == "continuation_sent" } == false)
  }
}
