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
      /// The group branch already exists as a local branch of this project.
      case localBranchExists
      /// The base ref does not resolve in this project.
      case baseRefMissing
      /// The group name is empty or not a single folder name.
      case invalidGroupName
      /// The group name is reserved (`default`).
      case reservedGroupName
      /// Another group of the Workspace already has this name.
      case duplicateGroupName
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
  /// Group-level findings of a new group: name and group directory.
  public var groupIssues: [Issue]
  /// Keyed by member name.
  public var memberIssues: [String: [Issue]]

  public init(rootIssues: [Issue] = [], groupIssues: [Issue] = [], memberIssues: [String: [Issue]] = [:]) {
    self.rootIssues = rootIssues
    self.groupIssues = groupIssues
    self.memberIssues = memberIssues
  }

  public var hasBlockingIssues: Bool {
    rootIssues.contains { !$0.isInformational }
      || groupIssues.contains { !$0.isInformational }
      || memberIssues.values.contains { $0.contains { !$0.isInformational } }
  }
}
