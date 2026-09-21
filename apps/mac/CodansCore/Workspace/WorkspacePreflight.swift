import Foundation

/// What creating a plan would run into on disk and in git, collected rather
/// than thrown so a form can show every problem at once, next to the field
/// it belongs to. The app-tier client fills it; nothing here is derivable
/// from the plan alone.
public nonisolated struct WorkspacePreflight: Equatable, Sendable {
  public struct Issue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case rootAlreadyRegistered
      case rootIsFile
      case rootAlreadyWorkspace
      case rootInsideRepository
      /// The root exists as a plain folder; checkouts will be added inside
      /// it. Informational.
      case rootExists
      /// `<root>/<name>` is already taken.
      case destinationExists
      case sourceNotRepository
      /// The clone destination exists but is not a clone of that remote.
      case cloneDestinationTaken
      /// The clone destination already holds a clone of that remote; it
      /// will be reused. Informational.
      case cloneDestinationReused
      case invalidBranchName
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
      self.kind = kind
      self.message = message
    }

    /// Informational issues describe what will happen; they never block.
    public var isInformational: Bool {
      switch kind {
      case .rootExists, .cloneDestinationReused: return true
      default: return false
      }
    }
  }

  public var rootIssues: [Issue]
  /// Keyed by member name.
  public var memberIssues: [String: [Issue]]

  public init(rootIssues: [Issue] = [], memberIssues: [String: [Issue]] = [:]) {
    self.rootIssues = rootIssues
    self.memberIssues = memberIssues
  }

  public var hasBlockingIssues: Bool {
    rootIssues.contains { !$0.isInformational }
      || memberIssues.values.contains { $0.contains { !$0.isInformational } }
  }
}
