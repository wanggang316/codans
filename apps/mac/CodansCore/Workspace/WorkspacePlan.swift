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
  /// Check out a remote-tracking ref such as `origin/feature` as the local
  /// branch `branch`. When no local branch of that name exists this is
  /// `git worktree add --track -b <branch> <path> <remoteRef>`. When one does
  /// exist the caller decides: `resetLocal == false` checks the local branch
  /// out as it is (the remote ref only names it); `resetLocal == true` runs
  /// `--track -B`, which points the local branch at the remote tip and
  /// discards local-only commits. The reset is never implied.
  case remoteTrackingRef(remoteRef: String, branch: String, resetLocal: Bool)

  public var branch: String {
    switch self {
    case .newBranch(let branch, _): return branch
    case .existingBranch(let branch): return branch
    case .remoteTrackingRef(_, let branch, _): return branch
    }
  }

  /// The ref the checkout starts from: the base of a new branch, or the
  /// remote-tracking ref. Nil for an existing local branch.
  public var baseRef: String? {
    switch self {
    case .newBranch(_, let baseRef): return baseRef
    case .existingBranch: return nil
    case .remoteTrackingRef(let remoteRef, _, _): return remoteRef
    }
  }

  public var manifestMode: WorkspaceManifest.CheckoutMode {
    switch self {
    case .newBranch: return .newBranch
    case .existingBranch: return .existingBranch
    case .remoteTrackingRef: return .remoteTrackingRef
    }
  }

  /// `<remote>/<branch>` split at the first slash; nil when the ref names
  /// no remote. `origin/feature/x` → (`origin`, `feature/x`).
  public static func splitRemoteRef(_ ref: String) -> (remote: String, branch: String)? {
    guard let slash = ref.firstIndex(of: "/") else { return nil }
    let remote = String(ref[..<slash])
    let branch = String(ref[ref.index(after: slash)...])
    guard !remote.isEmpty, !branch.isEmpty else { return nil }
    return (remote, branch)
  }
}

/// Everything needed to create a workspace, before any disk or git work:
/// the root folder, and for each member which repository it comes from and
/// how it is checked out. Pure data; `validate()` checks only what can be
/// known without touching the filesystem, so it runs in a reducer or a
/// handler before the app-tier client does the I/O checks.
public nonisolated struct WorkspacePlan: Equatable, Sendable {
  public struct Member: Equatable, Sendable, Identifiable {
    /// Where the member's repository comes from. Every member ends up as a
    /// linked worktree of a local repository; a remote source only adds a
    /// clone step that produces that local repository first.
    public enum Source: Equatable, Sendable {
      /// Root of a local repository — a normal checkout or a bare one.
      case local(gitRoot: String)
      /// A repository to clone from `url` into `cloneDestination`, which
      /// then serves as the local source. An existing clone of the same
      /// remote at that path is reused.
      case remote(url: String, cloneDestination: String)

      /// The local repository the worktree is added from: the path itself
      /// for a local source, the clone destination for a remote one.
      public var gitRoot: String {
        switch self {
        case .local(let gitRoot): return gitRoot
        case .remote(_, let cloneDestination): return cloneDestination
        }
      }

      public var remoteURL: String? {
        if case .remote(let url, _) = self { return url }
        return nil
      }
    }

    public var id: String { name }
    /// Folder name under the workspace root; also the row's display name.
    public var name: String
    public var source: Source
    public var role: String?
    public var checkout: WorkspaceCheckout

    /// Absolute path of the repository the checkout is created from. For a
    /// remote source this is where the clone lands; setting it rewrites the
    /// destination and keeps the URL.
    public var sourceGitRoot: String {
      get { source.gitRoot }
      set {
        switch source {
        case .local: source = .local(gitRoot: newValue)
        case .remote(let url, _): source = .remote(url: url, cloneDestination: newValue)
        }
      }
    }

    public init(name: String, source: Source, role: String? = nil, checkout: WorkspaceCheckout) {
      self.name = name
      self.source = source
      self.role = role
      self.checkout = checkout
    }

    /// A member from a local repository root.
    public init(name: String, sourceGitRoot: String, role: String? = nil, checkout: WorkspaceCheckout) {
      self.init(name: name, source: .local(gitRoot: sourceGitRoot), role: role, checkout: checkout)
    }

    public var manifestEntry: WorkspaceManifest.Entry {
      WorkspaceManifest.Entry(
        name: name,
        role: role,
        sourceGitRoot: sourceGitRoot,
        remoteURL: source.remoteURL,
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
    case emptyRemoteURL(member: String)
    case emptyCloneDestination(member: String)
    case emptyBranch(member: String)
    /// A remote-tracking checkout whose ref does not read as `<remote>/<branch>`.
    case invalidRemoteRef(member: String, ref: String)

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
      case .emptyRemoteURL(let member):
        return "member \"\(member)\" has no remote URL"
      case .emptyCloneDestination(let member):
        return "member \"\(member)\" has no folder to clone into"
      case .emptyBranch(let member):
        return "member \"\(member)\" has no branch"
      case .invalidRemoteRef(let member, let ref):
        return "member \"\(member)\" names \"\(ref)\" as a remote branch; expected <remote>/<branch>"
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
      switch member.source {
      case .local(let gitRoot):
        if gitRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(.emptySource(member: member.name))
        }
      case .remote(let url, let cloneDestination):
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(.emptyRemoteURL(member: member.name))
        }
        if cloneDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(.emptyCloneDestination(member: member.name))
        }
      }
      if member.checkout.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.emptyBranch(member: member.name))
      }
      if case .remoteTrackingRef(let remoteRef, _, _) = member.checkout,
        WorkspaceCheckout.splitRemoteRef(remoteRef) == nil
      {
        issues.append(.invalidRemoteRef(member: member.name, ref: remoteRef))
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
