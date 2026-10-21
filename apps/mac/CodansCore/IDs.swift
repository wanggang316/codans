import Foundation

public protocol HierarchyID: Codable, Hashable, Sendable, CustomStringConvertible {
  var raw: UUID { get }
  init(raw: UUID)
}

nonisolated extension HierarchyID {
  public init() { self.init(raw: UUID()) }
  public var description: String { raw.uuidString }
}

public nonisolated struct ProjectID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct WorktreeID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct TabID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct PaneID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

/// Identity of a session (a Tab's Content). Keys everything that outlives
/// a layout change: zmx session names, agent state, notifications, command
/// queues, run-script bindings, `CODANS_CONTENT_ID`.
public nonisolated struct ContentID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct TagID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

/// Identifier for a `Notification` row in the inbox. Distinct from
/// `HierarchyID` because notifications are time-series records, not nodes
/// in the project tree — keeping them separate avoids accidental mixing
/// in stores keyed by hierarchy id.
public nonisolated struct NotificationID: Codable, Hashable, Sendable, CustomStringConvertible {
  public let raw: UUID
  public init(raw: UUID = UUID()) { self.raw = raw }
  public var description: String { raw.uuidString }
}

/// Identifier of a Workspace group. Not a `HierarchyID` node of its own:
/// group rows are `Worktree`s that carry it in their `WorkspaceSlot`.
public nonisolated struct WorkspaceGroupID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

/// Identifier of one member checkout inside a Workspace group manifest.
public nonisolated struct WorkspaceMemberID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}
