import CodansCore
import Foundation

extension IPC {
  /// One repository to check out into a workspace. Exactly one of
  /// `projectID` (a registered local Project) or `path` (any local
  /// repository) names the source; the server resolves either to the
  /// repository root. Every other field falls back to a request-level or
  /// server default.
  public struct WorkspaceMemberRequest: Codable, Equatable, Sendable {
    /// Folder name under the workspace root; defaults to the repository's
    /// folder name.
    public let name: String?
    public let projectID: ProjectID?
    public let path: String?
    /// Defaults to the request-level branch, then to a slug of the title.
    public let branch: String?
    /// Base ref for a new branch; defaults to the repository's default
    /// remote branch.
    public let baseRef: String?
    /// Check out an existing local branch instead of creating one.
    public let useExistingBranch: Bool?
    public let role: String?

    public init(
      name: String? = nil,
      projectID: ProjectID? = nil,
      path: String? = nil,
      branch: String? = nil,
      baseRef: String? = nil,
      useExistingBranch: Bool? = nil,
      role: String? = nil
    ) {
      self.name = name
      self.projectID = projectID
      self.path = path
      self.branch = branch
      self.baseRef = baseRef
      self.useExistingBranch = useExistingBranch
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
    public let members: [WorkspaceMemberRequest]

    public init(
      title: String,
      rootPath: String? = nil,
      description: String? = nil,
      taskLinks: [String]? = nil,
      branch: String? = nil,
      baseRef: String? = nil,
      useExistingBranch: Bool? = nil,
      members: [WorkspaceMemberRequest]
    ) {
      self.title = title
      self.rootPath = rootPath
      self.description = description
      self.taskLinks = taskLinks
      self.branch = branch
      self.baseRef = baseRef
      self.useExistingBranch = useExistingBranch
      self.members = members
    }
  }

  /// Params for `workspace.add`.
  public struct WorkspaceAddRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let member: WorkspaceMemberRequest

    public init(projectID: ProjectID, member: WorkspaceMemberRequest) {
      self.projectID = projectID
      self.member = member
    }
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
    public let worktreeID: WorktreeID?

    public init(
      name: String,
      path: String,
      role: String? = nil,
      branch: String? = nil,
      sourceGitRoot: String? = nil,
      worktreeID: WorktreeID? = nil
    ) {
      self.name = name
      self.path = path
      self.role = role
      self.branch = branch
      self.sourceGitRoot = sourceGitRoot
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
