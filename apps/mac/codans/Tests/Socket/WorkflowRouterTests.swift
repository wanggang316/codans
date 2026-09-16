import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct WorkflowRouterTests {
  @Test
  func advisorRoundTripsThroughRouterAndPersistsResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let router = MethodRouter(
      systemHandlers: SystemHandlers(versions: .init(server: "0.6.2", appBundle: "0.6.2+test")),
      workflowStore: store)
    let id = UUID()
    let created: AgentWorkflowRun = try await call(
      router, .workflowCreate,
      IPC.WorkflowCreateRequest(commandID: id, template: "advisor", title: "Review", input: "Inspect cancellation"))
    #expect(created.id == id)
    #expect(created.status == .running)
    #expect(created.readySteps.map(\.id) == ["advice"])

    for (step, content) in [("advice", "Keep cancellation explicit."), ("disposition", "Accepted the recommendation.")] {
      let paneID = UUID().uuidString
      let attempt: AgentWorkflowAttempt = try await call(
        router, .workflowClaim, IPC.WorkflowClaimRequest(runID: id, stepID: step, paneID: paneID))
      #expect(attempt.stepID == step)
      let updated: AgentWorkflowRun = try await call(
        router, .workflowDeliver,
        IPC.WorkflowDeliverRequest(
          runID: id, attemptID: attempt.id, deliveryID: UUID(), paneID: paneID, content: content))
      #expect(updated.attempts.last?.content == content)
    }

    let status: AgentWorkflowRun = try await call(router, .workflowStatus, IPC.WorkflowRunRequest(runID: id))
    #expect(status.status == .succeeded)
    #expect(status.steps.allSatisfy { $0.status == .accepted })
    #expect(try AgentWorkflowStore(root: root).status(id) == status)

    let otherID = UUID()
    let _: AgentWorkflowRun = try await call(
      router, .workflowCreate,
      IPC.WorkflowCreateRequest(commandID: otherID, template: "advisor", title: "Cancelled review", input: "Inspect"))
    let cancelled: AgentWorkflowRun = try await call(
      router, .workflowCancel, IPC.WorkflowRunRequest(runID: otherID))
    #expect(cancelled.status == .cancelled)
    #expect(try AgentWorkflowStore(root: root).status(otherID).status == .cancelled)
  }

  private func call<Params: Encodable, Result: Decodable>(
    _ router: MethodRouter, _ method: IPC.Method, _ params: Params
  ) async throws -> Result {
    let outcome = await router.route(
      IPC.Request(id: UUID().uuidString, method: method, params: try JSONValue.encoded(params)))
    switch outcome {
    case .unary(let value): return try value.decoded(as: Result.self)
    case .failed(let error): throw error
    case .streaming: throw IPCError.internal("Expected a unary workflow response")
    }
  }
}
