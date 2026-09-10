import Foundation

/// How a workspace member is checked out from its source repository.
public nonisolated enum WorkspaceCheckout: Equatable, Sendable {
  /// `git worktree add -b <branch> <path> [<baseRef>]`. A nil base ref lets
  /// the caller substitute the repository's default remote branch, falling
  /// back to git's own default (HEAD).
  case newBranch(branch: String, baseRef: String?)
  /// `git worktree add <path> <branch>` on a branch that already exists
  /// locally.
  case existingBranch(String)

  public var branch: String {
    switch self {
    case .newBranch(let branch, _): return branch
    case .existingBranch(let branch): return branch
    }
  }

  public var baseRef: String? {
    switch self {
    case .newBranch(_, let baseRef): return baseRef
    case .existingBranch: return nil
    }
  }

  public var manifestMode: WorkspaceManifest.CheckoutMode {
    switch self {
    case .newBranch: return .newBranch
    case .existingBranch: return .existingBranch
    }
  }
}

/// Everything needed to create a workspace, before any disk or git work:
/// the root folder, and for each member which repository it comes from and
/// how it is checked out. Pure data; `validate()` checks only what can be
/// known without touching the filesystem, so it runs in a reducer or a
/// handler before the app-tier client does the I/O checks.
public nonisolated struct WorkspacePlan: Equatable, Sendable {
  public struct Member: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Folder name under the workspace root; also the row's display name.
    public var name: String
    /// Absolute path of the repository the checkout is created from.
    public var sourceGitRoot: String
    public var role: String?
    public var checkout: WorkspaceCheckout

    public init(name: String, sourceGitRoot: String, role: String? = nil, checkout: WorkspaceCheckout) {
      self.name = name
      self.sourceGitRoot = sourceGitRoot
      self.role = role
      self.checkout = checkout
    }

    public var manifestEntry: WorkspaceManifest.Entry {
      WorkspaceManifest.Entry(
        name: name,
        role: role,
        sourceGitRoot: sourceGitRoot,
        checkoutMode: checkout.manifestMode,
        branch: checkout.branch,
        baseRef: checkout.baseRef
      )
    }
  }

  public var title: String
  public var rootPath: String
  public var description: String?
  public var taskLinks: [String]
  public var members: [Member]

  /// A workspace exists to hold more than one repository; one member is a
  /// worktree with extra steps.
  public static let minimumMembers = 2

  public init(
    title: String,
    rootPath: String,
    description: String? = nil,
    taskLinks: [String] = [],
    members: [Member]
  ) {
    self.title = title
    self.rootPath = rootPath
    self.description = description
    self.taskLinks = taskLinks
    self.members = members
  }

  public enum ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    case emptyTitle
    case emptyRootPath
    case tooFewMembers(Int)
    case invalidMemberName(String)
    case duplicateMemberName(String)
    case emptySource(member: String)
    case emptyBranch(member: String)

    public var description: String {
      switch self {
      case .emptyTitle:
        return "workspace title is empty"
      case .emptyRootPath:
        return "workspace folder is empty"
      case .tooFewMembers(let count):
        return "a workspace needs at least \(WorkspacePlan.minimumMembers) repositories (got \(count))"
      case .invalidMemberName(let name):
        return "member name \"\(name)\" is not a valid folder name"
      case .duplicateMemberName(let name):
        return "member name \"\(name)\" appears more than once"
      case .emptySource(let member):
        return "member \"\(member)\" has no source repository"
      case .emptyBranch(let member):
        return "member \"\(member)\" has no branch"
      }
    }
  }

  /// Structural checks only — no filesystem or git access.
  public func validate() -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.emptyTitle)
    }
    if rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.emptyRootPath)
    }
    if members.count < Self.minimumMembers {
      issues.append(.tooFewMembers(members.count))
    }
    issues.append(contentsOf: Self.validate(members: members))
    return issues
  }

  /// Per-member checks shared by `validate()` and the single-member add
  /// flow, which has no minimum-count rule.
  public static func validate(members: [Member]) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var seen = Set<String>()
    for member in members {
      if !WorkspaceManifest.isValidChildPath(member.name) {
        issues.append(.invalidMemberName(member.name))
      }
      if !seen.insert(member.name).inserted {
        issues.append(.duplicateMemberName(member.name))
      }
      if member.sourceGitRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.emptySource(member: member.name))
      }
      if member.checkout.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.emptyBranch(member: member.name))
      }
    }
    return issues
  }

  /// The manifest this plan writes once every member is on disk.
  public func manifest(createdAt: Date? = nil) -> WorkspaceManifest {
    WorkspaceManifest(
      title: title,
      description: description,
      taskLinks: taskLinks,
      repositories: members.map(\.manifestEntry),
      createdAt: createdAt,
      updatedAt: createdAt
    )
  }
}
