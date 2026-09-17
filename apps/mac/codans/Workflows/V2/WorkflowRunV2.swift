import CodansCore
import CodansIPC
import Foundation

nonisolated struct WorkflowBindingV2: Codable, Equatable, Sendable {
  var source: String
  var profile: AgentProfile?
  var projectID: ProjectID?
  var worktreeID: WorktreeID?
  var paneID: PaneID?
  var agentKind: AgentKind?
  var sessionID: String?
  var generation: Int = 1
  var target: ScriptTarget?
  var direction: ScriptSplitDirection?
  var anchorPaneID: PaneID?
}

nonisolated struct WorkflowNodeRunV2: Codable, Equatable, Sendable {
  var status = "pending"
  var executions: [WorkflowNodeExecutionV2]?
  var attemptID: UUID?
  var deliveryID: UUID?
  var paneID: String?
  var inputs: [String: JSONValue] = [:]
  var outputs: [String: JSONValue] = [:]
  var error: String?
  var startedAt: Date?
  var finishedAt: Date?
}

/// One execution of a node; submissions are revisions within that execution.
nonisolated struct WorkflowNodeExecutionV2: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var action: String
  var nodeID: String
  var status: String
  var inputs: [String: JSONValue]
  var outputs: [String: JSONValue] = [:]
  var error: String?
  var startedAt: Date?
  var finishedAt: Date?
  var request: WorkflowAgentRequestV2?
  var submissions: [WorkflowSubmissionV2] = []
}

nonisolated struct WorkflowAgentRequestV2: Codable, Equatable, Sendable {
  var prompt: String
  var deliveryID: UUID
  var paneID: String
  var sessionID: String?
  var generation: Int
  var status = "prepared"
  var preparedAt = Date()
  var sentAt: Date?
  var error: String?
}

nonisolated struct WorkflowSubmissionV2: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var deliveryID: UUID
  var content: String
  var accepted: Bool
  var issues: [String]
  var receivedAt = Date()
}

extension WorkflowNodeRunV2 {
  var execution: WorkflowNodeExecutionV2? {
    get { executions?.last }
    set {
      guard let newValue, let count = executions?.count, count > 0,
        executions?.last?.id == newValue.id
      else { return }
      executions?[count - 1] = newValue
    }
  }

  mutating func synchronizeExecution() {
    guard var current = execution else { return }
    current.status = status
    current.inputs = inputs
    current.outputs = outputs
    current.error = error
    current.startedAt = startedAt
    current.finishedAt = finishedAt
    if ["cancelled", "interrupted"].contains(status),
      ["prepared", "sending"].contains(current.request?.status)
    {
      current.request?.status = status
    }
    execution = current
  }
}

nonisolated struct WorkflowEventV2: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var sequence: Int
  var message: String
  var date = Date()
  var type: String
  var nodeID: String?
}

nonisolated enum WorkflowHistoryScopeV2: String, CaseIterable {
  case pane, worktree, all
}

nonisolated struct WorkflowRunOriginV2: Codable, Equatable, Sendable {
  var projectID: ProjectID?
  var worktreeID: WorktreeID?
  var paneID: PaneID?
}

nonisolated struct WorkflowRunV2: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var title: String
  var source: String
  var definition: WorkflowDefinitionV2
  var inputs: [String: JSONValue]
  var bindings: [String: WorkflowBindingV2]
  var origin: WorkflowRunOriginV2?
  var status = "running"
  var nodes: [String: WorkflowNodeRunV2]
  var events: [WorkflowEventV2] = []
  var outputs: [String: JSONValue] = [:]
  var createdAt = Date()
  var updatedAt = Date()

  func matches(_ scope: WorkflowHistoryScopeV2, paneID: PaneID?, worktreeID: WorktreeID?) -> Bool {
    switch scope {
    case .all: return true
    case .pane:
      guard let paneID else { return false }
      return origin?.paneID == paneID || bindings.values.contains { $0.paneID == paneID }
        || nodes.values.contains { $0.paneID == paneID.raw.uuidString }
    case .worktree:
      guard let worktreeID else { return false }
      return origin?.worktreeID == worktreeID || bindings.values.contains { $0.worktreeID == worktreeID }
    }
  }

  mutating func event(_ type: String, _ message: String, node: String? = nil) {
    updatedAt = Date()
    events.append(.init(sequence: events.count + 1, message: message, type: type, nodeID: node))
  }
}

nonisolated enum WorkflowRuntimeErrorV2: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    }
  }
}

nonisolated extension JSONValue {
  var v2Object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
  var v2String: String? { if case .string(let value) = self { value } else { nil } }
  var v2Text: String {
    if case .string(let value) = self { return value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "null"
  }
}
