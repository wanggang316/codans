import Foundation

/// A destructive group delete that has started and still has unresolved
/// items. Persisted so a restart shows "Deletion incomplete" and Retry.
public nonisolated struct GroupDeletionState: Codable, Equatable, Sendable {
  public var deleteBranches: Bool
  public var startedAt: Date

  public init(deleteBranches: Bool, startedAt: Date) {
    self.deleteBranches = deleteBranches
    self.startedAt = startedAt
  }
}
