import CodansCore
import Foundation

/// Frozen launch settings for a user-started workflow. Old snapshots remain readable without this field.
nonisolated struct AgentWorkflowExecution: Codable, Equatable, Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let primary: AgentProfile
  let secondary: AgentProfile?
  var dispatches: [String: AgentWorkflowDispatch] = [:]
}

nonisolated struct AgentWorkflowDispatch: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    case launching
    case submitted
    case attention
  }

  var status: Status
  var paneID: String?
  var message: String?
  let startedAt: Date
}
