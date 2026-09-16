import Foundation

extension IPC {
  public struct WorkflowRunRequest: Codable, Equatable, Sendable {
    public let runID: UUID

    public init(runID: UUID) {
      self.runID = runID
    }
  }

  public struct WorkflowClaimRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let stepID: String
    public let paneID: String

    public init(runID: UUID, stepID: String, paneID: String) {
      self.runID = runID
      self.stepID = stepID
      self.paneID = paneID
    }
  }

  public struct WorkflowDeliverRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let attemptID: UUID
    public let deliveryID: UUID
    public let paneID: String
    public let content: String

    public init(runID: UUID, attemptID: UUID, deliveryID: UUID, paneID: String, content: String) {
      self.runID = runID
      self.attemptID = attemptID
      self.deliveryID = deliveryID
      self.paneID = paneID
      self.content = content
    }
  }
}
