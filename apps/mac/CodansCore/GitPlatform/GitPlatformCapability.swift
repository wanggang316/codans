import Foundation

/// One thing codans can do with a Git Platform, as the Settings pane lists it. The list of
/// each kind is static data that matches what its `GitPlatform` implementation does; a
/// test in the app target checks it against the merge options and the rerun support of
/// each implementation.
public nonisolated struct GitPlatformCapability: Equatable, Sendable, Identifiable {
  public enum Key: Hashable, Sendable {
    case pullRequestBadges
    case ciStatus
    case merge(MergeStrategy)
    case markReady
    case rerunFailedChecks
    case reviewStatus
  }

  public var id: Key
  /// Name of the capability in the terms of the Git Platform ("Merge Request badges").
  public var title: String
  /// Why the Git Platform does not support it. `nil` when it is supported.
  public var unsupportedReason: String?

  public init(id: Key, title: String, unsupportedReason: String? = nil) {
    self.id = id
    self.title = title
    self.unsupportedReason = unsupportedReason
  }

  public var isSupported: Bool { unsupportedReason == nil }
}

extension GitPlatformKind {
  /// What codans can do with this Git Platform, in the order the Settings pane shows it.
  public var capabilities: [GitPlatformCapability] {
    switch self {
    case .github:
      return [
        GitPlatformCapability(id: .pullRequestBadges, title: "Pull Request badges"),
        GitPlatformCapability(id: .ciStatus, title: "Check status"),
        GitPlatformCapability(id: .merge(.mergeCommit), title: MergeStrategy.mergeCommit.displayName),
        GitPlatformCapability(id: .merge(.squash), title: MergeStrategy.squash.displayName),
        GitPlatformCapability(id: .merge(.rebase), title: MergeStrategy.rebase.displayName),
        GitPlatformCapability(id: .markReady, title: "Mark ready for review"),
        GitPlatformCapability(id: .rerunFailedChecks, title: "Rerun failed checks"),
        GitPlatformCapability(id: .reviewStatus, title: "Review status"),
      ]
    case .gitlab:
      return [
        GitPlatformCapability(id: .pullRequestBadges, title: "Merge Request badges"),
        GitPlatformCapability(id: .ciStatus, title: "Pipeline status"),
        GitPlatformCapability(id: .merge(.mergeCommit), title: "Merge"),
        GitPlatformCapability(id: .merge(.squash), title: MergeStrategy.squash.displayName),
        GitPlatformCapability(
          id: .merge(.rebase), title: MergeStrategy.rebase.displayName,
          unsupportedReason: "The project's merge method applies"),
        GitPlatformCapability(id: .markReady, title: "Mark ready"),
        GitPlatformCapability(id: .rerunFailedChecks, title: "Retry failed pipeline jobs"),
        GitPlatformCapability(id: .reviewStatus, title: "Review status"),
      ]
    }
  }

  /// The capability with `id`, or `nil` when the list does not have it.
  public func capability(_ id: GitPlatformCapability.Key) -> GitPlatformCapability? {
    capabilities.first { $0.id == id }
  }

  /// Merge strategies this Git Platform offers, in `MergeStrategy.allCases` order.
  public var supportedMergeStrategies: [MergeStrategy] {
    MergeStrategy.allCases.filter { capability(.merge($0))?.isSupported == true }
  }
}
