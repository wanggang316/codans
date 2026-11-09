import Foundation

/// Where a catalog row sits inside a Workspace. Present on Workspace rows
/// only.
public nonisolated struct WorkspaceSlot: Codable, Equatable, Hashable, Sendable {
  public enum Role: String, Codable, Equatable, Hashable, Sendable {
    /// The row for the group directory. One per group.
    case groupTerminal
    /// A `default` member. Its path is the source main checkout, which the
    /// Workspace does not own.
    case reference
    /// A checkout the group owns.
    case member
  }

  public var groupID: WorkspaceGroupID
  public var role: Role

  public init(groupID: WorkspaceGroupID, role: Role) {
    self.groupID = groupID
    self.role = role
  }
}
