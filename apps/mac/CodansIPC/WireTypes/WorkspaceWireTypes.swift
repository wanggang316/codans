import CodansCore
import Foundation

extension IPC {
  /// One repository to check out into a workspace. Exactly one of
  /// `projectID` (a registered local Project), `path` (any local
  /// repository, bare or not), or `remoteURL` (cloned first) names the
  /// source; the server resolves each to a repository root. Every other
  /// field falls back to a request-level or server default.
  public struct WorkspaceMemberRequest: Codable, Equatable, Sendable {
    /// Folder name under the workspace root; defaults to the repository's
    /// folder name.
    public let name: String?
    public let projectID: ProjectID?
    public let path: String?
    /// A remote to clone before checking out. The clone lands in
    /// `cloneDestination`, or under the request's clone base directory
    /// (default `~/.codans/sources/<name>`); an existing clone of the same
    /// remote there is reused.
    public let remoteURL: String?
    public let cloneDestination: String?
    /// Defaults to the request-level branch, then to a slug of the title.
    /// With `remoteRef`, defaults to the ref's branch part.
    public let branch: String?
    /// Base ref for a new branch; defaults to the repository's default
    /// remote branch.
    public let baseRef: String?
    /// Check out an existing local branch instead of creating one.
    public let useExistingBranch: Bool?
    /// Check out this remote-tracking ref (`origin/feature`) as `branch`.
    /// Exclusive with `useExistingBranch`.
    public let remoteRef: String?
    /// With a remote-tracking ref: when a local branch of that name already
    /// exists, point it at the remote tip instead of checking it out as is.
    /// Never implied.
    public let resetLocalBranch: Bool?
    public let role: String?

    public init(
      name: String? = nil,
      projectID: ProjectID? = nil,
      path: String? = nil,
      remoteURL: String? = nil,
      cloneDestination: String? = nil,
      branch: String? = nil,
      baseRef: String? = nil,
      useExistingBranch: Bool? = nil,
      remoteRef: String? = nil,
      resetLocalBranch: Bool? = nil,
      role: String? = nil
    ) {
      self.name = name
      self.projectID = projectID
      self.path = path
      self.remoteURL = remoteURL
      self.cloneDestination = cloneDestination
      self.branch = branch
      self.baseRef = baseRef
      self.useExistingBranch = useExistingBranch
      self.remoteRef = remoteRef
      self.resetLocalBranch = resetLocalBranch
      self.role = role
    }
  }

  /// Params for `workspace.create`.
  public struct WorkspaceCreateRequest: Codable, Equatable, Sendable {
    public let title: String
    /// Defaults to `~/.codans/workspaces/<slug>`, suffixed when taken.
    public let rootPath: String?
    public let description: String?
    public let taskLinks: [String]?
    /// Branch every member checks out unless it names its own.
    public let branch: String?
    public let baseRef: String?
    public let useExistingBranch: Bool?
    /// Every member without its own ref checks out `origin/<branch>` as a
    /// remote-tracking ref. Exclusive with `useExistingBranch`.
    public let trackRemote: Bool?
    /// Where remote members are cloned when they name no destination.
    public let cloneBaseDirectory: String?
    public let members: [WorkspaceMemberRequest]

    public init(
      title: String,
      rootPath: String? = nil,
      description: String? = nil,
      taskLinks: [String]? = nil,
      branch: String? = nil,
      baseRef: String? = nil,
      useExistingBranch: Bool? = nil,
      trackRemote: Bool? = nil,
      cloneBaseDirectory: String? = nil,
      members: [WorkspaceMemberRequest]
    ) {
      self.title = title
      self.rootPath = rootPath
      self.description = description
      self.taskLinks = taskLinks
      self.branch = branch
      self.baseRef = baseRef
      self.useExistingBranch = useExistingBranch
      self.trackRemote = trackRemote
      self.cloneBaseDirectory = cloneBaseDirectory
      self.members = members
    }
  }

  /// Params for `workspace.add`.
  public struct WorkspaceAddRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let member: WorkspaceMemberRequest
    /// Where a remote member is cloned when it names no destination.
    public let cloneBaseDirectory: String?

    public init(projectID: ProjectID, member: WorkspaceMemberRequest, cloneBaseDirectory: String? = nil) {
      self.projectID = projectID
      self.member = member
      self.cloneBaseDirectory = cloneBaseDirectory
    }
  }

  /// Where a member's source repository came from.
  public enum WorkspaceMemberSourceKind: String, Codable, Equatable, Sendable {
    /// A local repository with a working tree.
    case local
    /// A local bare repository.
    case bare
    /// Cloned from `remoteURL`.
    case remote
  }

  /// Params for `workspace.drop` — remove one member by its folder name.
  public struct WorkspaceDropRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let member: String
    /// Leave the member's branch in the source repository.
    public let keepBranch: Bool

    public init(projectID: ProjectID, member: String, keepBranch: Bool = false) {
      self.projectID = projectID
      self.member = member
      self.keepBranch = keepBranch
    }
  }

  /// Response for `workspace.drop`.
  public struct WorkspaceDropResponse: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    /// Set when the branch was kept because git refused to delete it.
    public let warning: String?

    public init(name: String, path: String, warning: String? = nil) {
      self.name = name
      self.path = path
      self.warning = warning
    }
  }

  /// Params for `workspace.remove`.
  public struct WorkspaceRemoveRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let cleanup: WorkspaceCleanup

    public init(projectID: ProjectID, cleanup: WorkspaceCleanup = .entryOnly) {
      self.projectID = projectID
      self.cleanup = cleanup
    }
  }

  /// Response for `workspace.remove`.
  public struct WorkspaceRemoveResponse: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let rootPath: String
    public let outcome: WorkspaceRemovalOutcome

    public init(projectID: ProjectID, rootPath: String, outcome: WorkspaceRemovalOutcome) {
      self.projectID = projectID
      self.rootPath = rootPath
      self.outcome = outcome
    }
  }

  /// Params for `workspace.describe`.
  public struct WorkspaceDescribeRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID

    public init(projectID: ProjectID) {
      self.projectID = projectID
    }
  }

  /// One member as the catalog currently sees it: the manifest entry plus
  /// the live row, when the reconcile has registered one.
  public struct WorkspaceMemberSummary: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let role: String?
    public let branch: String?
    public let sourceGitRoot: String?
    public let sourceKind: WorkspaceMemberSourceKind?
    public let remoteURL: String?
    public let worktreeID: WorktreeID?

    public init(
      name: String,
      path: String,
      role: String? = nil,
      branch: String? = nil,
      sourceGitRoot: String? = nil,
      sourceKind: WorkspaceMemberSourceKind? = nil,
      remoteURL: String? = nil,
      worktreeID: WorktreeID? = nil
    ) {
      self.name = name
      self.path = path
      self.role = role
      self.branch = branch
      self.sourceGitRoot = sourceGitRoot
      self.sourceKind = sourceKind
      self.remoteURL = remoteURL
      self.worktreeID = worktreeID
    }
  }

  /// Response for `workspace.create` and `workspace.describe`.
  public struct WorkspaceSummary: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let title: String
    public let rootPath: String
    public let description: String?
    public let taskLinks: [String]
    public let members: [WorkspaceMemberSummary]

    public init(
      projectID: ProjectID,
      title: String,
      rootPath: String,
      description: String? = nil,
      taskLinks: [String] = [],
      members: [WorkspaceMemberSummary]
    ) {
      self.projectID = projectID
      self.title = title
      self.rootPath = rootPath
      self.description = description
      self.taskLinks = taskLinks
      self.members = members
    }
  }
}
