import Foundation

/// What a group delete did. With any failure the group stays, with its
/// `deletion` state set, so a retry can finish the job.
public nonisolated struct GroupDeletionOutcome: Codable, Equatable, Sendable {
  public struct Failure: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var reason: String

    public init(name: String, path: String, reason: String) {
      self.name = name
      self.path = path
      self.reason = reason
    }
  }

  /// The group, its directory (when owned), and its rows are gone.
  public var deletedGroup: Bool
  public var removedMembers: [String]
  public var deletedBranches: [String]
  /// Branches git refused to delete, with the reason.
  public var keptBranches: [String]
  public var failures: [Failure]

  public init(
    deletedGroup: Bool,
    removedMembers: [String] = [],
    deletedBranches: [String] = [],
    keptBranches: [String] = [],
    failures: [Failure] = []
  ) {
    self.deletedGroup = deletedGroup
    self.removedMembers = removedMembers
    self.deletedBranches = deletedBranches
    self.keptBranches = keptBranches
    self.failures = failures
  }
}
