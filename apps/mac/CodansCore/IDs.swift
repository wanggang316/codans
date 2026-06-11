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
