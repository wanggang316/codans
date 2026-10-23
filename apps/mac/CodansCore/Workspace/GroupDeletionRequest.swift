import Foundation

/// A destructive group delete request.
public nonisolated struct GroupDeletionRequest: Equatable, Sendable {
  /// Also delete each member branch the check lists as deletable.
  public var deleteBranches: Bool
  /// The caller saw the check's risks and accepts losing them.
  public var acknowledgeRisks: Bool

  public init(deleteBranches: Bool = false, acknowledgeRisks: Bool = false) {
    self.deleteBranches = deleteBranches
    self.acknowledgeRisks = acknowledgeRisks
  }
}
