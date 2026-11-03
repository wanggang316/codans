import Foundation

/// Provider-neutral merge state of a Pull Request. Each Code Host's decoding layer maps
/// its own wire values into one of these statuses, with an optional reason text that the
/// popover shows when merge is not possible. See ADR 0004 item 14.
public nonisolated struct PullRequestMergeState: Equatable, Codable, Sendable {
  public enum Status: String, Codable, Sendable, CaseIterable {
    /// The Pull Request merges cleanly into its target.
    case clean
    /// The source branch has conflicts with the target.
    case conflicted
    /// The target moved on; the source branch must be updated first.
    case behind
    /// Required checks, reviews, or other rules block the merge.
    case blocked
    /// The Pull Request is a draft.
    case draft
    /// The Code Host has not computed the state yet.
    case unknown
  }

  public var status: Status
  /// Why merge is not possible, as the Code Host explains it. `nil` when there is
  /// nothing to explain.
  public var reason: String?

  public init(status: Status, reason: String? = nil) {
    self.status = status
    self.reason = reason
  }

  public static let unknown = PullRequestMergeState(status: .unknown)
}

/// One way to merge a Pull Request, with whether the Code Host allows it now. Capability
/// differences between Code Hosts are data here, not optional protocol methods.
public nonisolated struct PullRequestMergeOption: Equatable, Codable, Sendable, Identifiable {
  public var id: MergeStrategy { strategy }
  public var strategy: MergeStrategy
  public var isEnabled: Bool
  /// Why the option is disabled. `nil` when it is enabled.
  public var disabledReason: String?

  public init(strategy: MergeStrategy, isEnabled: Bool, disabledReason: String? = nil) {
    self.strategy = strategy
    self.isEnabled = isEnabled
    self.disabledReason = disabledReason
  }
}
