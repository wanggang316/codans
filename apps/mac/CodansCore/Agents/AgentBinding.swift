import Foundation

/// Runtime ownership of a pane by one verified Agent instance.
public nonisolated struct AgentBinding: Equatable, Sendable {
  public let instanceID: AgentInstanceID
  public let paneID: PaneID
  public let surfaceGeneration: UUID
  public let kind: AgentKind
  public let process: AgentProcessIdentity
  public let sessionID: String?

  public init(
    instanceID: AgentInstanceID = AgentInstanceID(), paneID: PaneID,
    surfaceGeneration: UUID, kind: AgentKind, process: AgentProcessIdentity,
    sessionID: String?
  ) {
    self.instanceID = instanceID
    self.paneID = paneID
    self.surfaceGeneration = surfaceGeneration
    self.kind = kind
    self.process = process
    self.sessionID = sessionID
  }
}
