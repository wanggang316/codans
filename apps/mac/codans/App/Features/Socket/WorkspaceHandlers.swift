import CodansCore
import CodansIPC
import Foundation

/// Server-side handler for the `workspace.*` IPC surface.
///
/// Resolves each member's source (a registered Project id, any local
/// repository path, or a remote URL to clone) to a repository root, fills
/// request defaults (folder name, branch, clone destination, workspace
/// root), and hands the resulting `WorkspacePlan`
/// to the same `WorkspaceClient` the GUI sheet uses. The handler owns only
/// the wire-to-plan translation and the error mapping; every disk and git
/// effect lives in the client.
@MainActor
final class WorkspaceHandlers {
  private let hierarchy: HierarchyClient
  private let workspace: WorkspaceClient
  private let gitCLI: GitWorktreeCLI

  init(hierarchy: HierarchyClient, workspace: WorkspaceClient, gitCLI: GitWorktreeCLI) {
    self.hierarchy = hierarchy
    self.workspace = workspace
    self.gitCLI = gitCLI
  }

  // MARK: - create

  func create(_ request: IPC.WorkspaceCreateRequest) async throws -> IPC.WorkspaceSummary {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw IPCError.invalidParams(message: "workspace.create requires a non-empty title", path: ["title"])
    }
    let defaultBranch = request.branch ?? WorkspaceLayout.folderName(forTitle: title)
    if request.useExistingBranch == true, request.trackRemote == true {
      throw IPCError.invalidParams(
        message: "useExistingBranch and trackRemote are exclusive", path: ["trackRemote"])
    }
    var members: [WorkspacePlan.Member] = []
    for member in request.members {
      members.append(
        try await resolveMember(
          member,
          defaults: MemberDefaults(
            branch: defaultBranch,
            baseRef: request.baseRef,
            useExisting: request.useExistingBranch ?? false,
            trackRemote: request.trackRemote ?? false,
            cloneBaseDirectory: request.cloneBaseDirectory)
        ))
    }
    let rootPath =
      request.rootPath.map { ($0 as NSString).expandingTildeInPath }
      ?? Self.uniqueDefaultRootPath(forTitle: title)
    let plan = WorkspacePlan(
      title: title,
      rootPath: rootPath,
      description: request.description,
      taskLinks: request.taskLinks ?? [],
      members: members
    )
    let projectID: ProjectID
    do {
      projectID = try await workspace.create(plan)
    } catch {
      throw Self.ipcError(for: error)
    }
    return try describe(IPC.WorkspaceDescribeRequest(projectID: projectID))
  }

  // MARK: - add

  func add(_ request: IPC.WorkspaceAddRequest) async throws -> IPC.WorkspaceMemberSummary {
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == request.projectID })
    else {
      throw IPCError.notFound(kind: "project", id: request.projectID.description)
    }
    guard project.isWorkspace else {
      throw IPCError.invalidParams(
        message: "\(project.name) is not a workspace", path: ["projectID"])
    }
    let member = try await resolveMember(
      request.member,
      defaults: MemberDefaults(
        branch: WorkspaceLayout.folderName(forTitle: project.name),
        baseRef: nil,
        useExisting: false,
        trackRemote: false,
        cloneBaseDirectory: request.cloneBaseDirectory)
    )
    let worktreeID: WorktreeID
    do {
      worktreeID = try await workspace.add(request.projectID, member)
    } catch {
      throw Self.ipcError(for: error)
    }
    let summary = try describe(IPC.WorkspaceDescribeRequest(projectID: request.projectID))
    guard let added = summary.members.first(where: { $0.worktreeID == worktreeID }) else {
      throw IPCError.internal("added repository did not appear in the workspace")
    }
    return added
  }

  // MARK: - drop / remove

  func drop(_ request: IPC.WorkspaceDropRequest) async throws -> IPC.WorkspaceDropResponse {
    let summary = try describe(IPC.WorkspaceDescribeRequest(projectID: request.projectID))
    guard let member = summary.members.first(where: { $0.name == request.member }) else {
      throw IPCError.notFound(kind: "workspace member", id: request.member)
    }
    guard let worktreeID = member.worktreeID else {
      throw IPCError.conflict(
        reason: "\(request.member) has no checkout on disk yet; refresh the workspace first")
    }
    let warning: String?
    do {
      warning = try await workspace.drop(request.projectID, worktreeID, !request.keepBranch)
    } catch {
      throw Self.ipcError(for: error)
    }
    return IPC.WorkspaceDropResponse(name: member.name, path: member.path, warning: warning)
  }

  func remove(_ request: IPC.WorkspaceRemoveRequest) async throws -> IPC.WorkspaceRemoveResponse {
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == request.projectID })
    else {
      throw IPCError.notFound(kind: "project", id: request.projectID.description)
    }
    guard project.isWorkspace else {
      throw IPCError.invalidParams(
        message: "\(project.name) is not a workspace", path: ["projectID"])
    }
    let outcome: WorkspaceRemovalOutcome
    do {
      outcome = try await workspace.remove(request.projectID, request.cleanup)
    } catch {
      throw Self.ipcError(for: error)
    }
    return IPC.WorkspaceRemoveResponse(
      projectID: project.id, rootPath: project.rootPath, outcome: outcome)
  }

  // MARK: - describe

  func describe(_ request: IPC.WorkspaceDescribeRequest) throws -> IPC.WorkspaceSummary {
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == request.projectID })
    else {
      throw IPCError.notFound(kind: "project", id: request.projectID.description)
    }
    guard project.isWorkspace else {
      throw IPCError.invalidParams(
        message: "\(project.name) is not a workspace", path: ["projectID"])
    }
    // The transient copy is filled by the reconcile; fall back to disk for a
    // project registered moments ago.
    let manifest: WorkspaceManifest
    if let cached = project.workspace {
      manifest = cached
    } else {
      do {
        manifest = try WorkspaceManifestStore.load(rootPath: project.rootPath)
      } catch {
        throw IPCError.internal(String(describing: error))
      }
    }
    let members = manifest.repositories.map { entry -> IPC.WorkspaceMemberSummary in
      let path = HierarchyManager.canonicalPath(entry.resolvedPath(rootPath: project.rootPath))
      let row = project.worktrees.first { HierarchyManager.canonicalPath($0.path) == path }
      let sourceGitRoot = row?.sourceGitRoot ?? entry.sourceGitRoot
      return IPC.WorkspaceMemberSummary(
        name: entry.name,
        path: path,
        role: entry.role,
        branch: row?.branch ?? entry.branch,
        sourceGitRoot: sourceGitRoot,
        sourceKind: Self.sourceKind(sourceGitRoot: sourceGitRoot, remoteURL: entry.remoteURL),
        remoteURL: entry.remoteURL,
        worktreeID: row?.id
      )
    }
    return IPC.WorkspaceSummary(
      projectID: project.id,
      title: manifest.title,
      rootPath: project.rootPath,
      description: manifest.description,
      taskLinks: manifest.taskLinks,
      members: members
    )
  }

  // MARK: - Resolution

  /// Request-level fallbacks a member inherits when it names none of its own.
  private struct MemberDefaults {
    let branch: String
    let baseRef: String?
    let useExisting: Bool
    let trackRemote: Bool
    let cloneBaseDirectory: String?
  }

  private func resolveMember(
    _ member: IPC.WorkspaceMemberRequest,
    defaults: MemberDefaults
  ) async throws -> WorkspacePlan.Member {
    let source = try await resolveSource(member, defaults: defaults)
    let name =
      member.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? Self.defaultName(for: source)
    let checkout = try Self.checkout(for: member, defaults: defaults)
    return WorkspacePlan.Member(name: name, source: source, role: member.role, checkout: checkout)
  }

  private func resolveSource(
    _ member: IPC.WorkspaceMemberRequest,
    defaults: MemberDefaults
  ) async throws -> WorkspacePlan.Member.Source {
    switch (member.projectID, member.path, member.remoteURL) {
    case (let projectID?, nil, nil):
      guard let project = hierarchy.snapshot().projects.first(where: { $0.id == projectID }) else {
        throw IPCError.notFound(kind: "project", id: projectID.description)
      }
      guard project.remoteHost == nil else {
        throw IPCError.invalidParams(
          message: "\(project.name) is a Server project; workspaces are local only",
          path: ["members", "projectID"])
      }
      guard let gitRoot = project.gitRoot else {
        throw IPCError.invalidParams(
          message: "\(project.name) is not a git repository", path: ["members", "projectID"])
      }
      return .local(gitRoot: gitRoot)
    case (nil, let path?, nil):
      // A subdirectory or linked worktree resolves to its repository root.
      let expanded = (path as NSString).expandingTildeInPath
      guard let probe = try? await gitCLI.inspectRepository(at: expanded) else {
        throw IPCError.invalidParams(
          message: "\(expanded) is not a git repository", path: ["members", "path"])
      }
      guard !probe.isBare else {
        throw IPCError.invalidParams(
          message: WorkspaceError.bareRepository(path: probe.root).localizedDescription,
          path: ["members", "path"])
      }
      return .local(gitRoot: HierarchyManager.canonicalPath(probe.root))
    case (nil, nil, let url?):
      let remoteURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !remoteURL.isEmpty else {
        throw IPCError.invalidParams(message: "remoteURL is empty", path: ["members", "remoteURL"])
      }
      let destination: String
      if let named = member.cloneDestination?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        destination = (named as NSString).expandingTildeInPath
      } else {
        guard let repoName = WorkspaceLayout.repositoryName(fromRemoteURL: remoteURL) else {
          throw IPCError.invalidParams(
            message: "cannot derive a repository name from \(remoteURL); pass name and cloneDestination",
            path: ["members", "remoteURL"])
        }
        destination = try await defaultCloneDestination(
          repoName: repoName, remoteURL: remoteURL, base: defaults.cloneBaseDirectory)
      }
      return .remote(url: remoteURL, cloneDestination: destination)
    default:
      throw IPCError.invalidParams(
        message: "each member names exactly one of projectID, path, or remoteURL", path: ["members"])
    }
  }

  /// `<base>/<repoName>` when free or already a clone of this remote (the
  /// client reuses it); otherwise the first free `-N` sibling, so a
  /// different repository that happens to share the name is left alone.
  private func defaultCloneDestination(
    repoName: String, remoteURL: String, base: String?
  ) async throws -> String {
    let baseURL =
      base.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
      ?? WorkspaceLayout.defaultSourcesDirectory()
    let candidate = (baseURL.path(percentEncoded: false) as NSString).appendingPathComponent(repoName)
    if FileManager.default.fileExists(atPath: candidate),
      let probe = try? await gitCLI.inspectRepository(at: candidate),
      HierarchyManager.canonicalPath(probe.root) == HierarchyManager.canonicalPath(candidate),
      let origin = try? await gitCLI.remoteURL(repoPath: candidate),
      WorkspaceClient.remoteURLsMatch(origin, remoteURL)
    {
      return candidate
    }
    return WorkspaceLayout.uniquePath(base: baseURL, folder: repoName)
  }

  private static func defaultName(for source: WorkspacePlan.Member.Source) -> String {
    switch source {
    case .local(let gitRoot):
      return (gitRoot as NSString).lastPathComponent
    case .remote(let url, let cloneDestination):
      return WorkspaceLayout.repositoryName(fromRemoteURL: url)
        ?? (cloneDestination as NSString).lastPathComponent
    }
  }

  /// Per-member checkout flags as the wire carries them.
  nonisolated struct CheckoutFlags: Equatable, Sendable {
    var useExisting: Bool?
    var remoteRef: String?
    var resetLocal: Bool?
    var branch: String?
    var baseRef: String?
  }

  /// Request-level checkout fallbacks.
  nonisolated struct CheckoutDefaults: Equatable, Sendable {
    var branch: String
    var baseRef: String?
    var useExisting: Bool
    var trackRemote: Bool
  }

  /// `remoteRef` (or the request-level `trackRemote`) makes a remote-tracking
  /// checkout, `useExistingBranch` an existing local one, else a new branch.
  /// The reset flag is only meaningful with a remote-tracking ref.
  nonisolated static func checkout(
    _ flags: CheckoutFlags, defaults: CheckoutDefaults
  ) throws -> WorkspaceCheckout {
    let useExisting = flags.useExisting ?? defaults.useExisting
    let remoteRef = flags.remoteRef?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let resetLocal = flags.resetLocal ?? false
    if useExisting, remoteRef != nil || defaults.trackRemote {
      throw IPCError.invalidParams(
        message: "useExistingBranch and a remote-tracking ref are exclusive", path: ["members", "remoteRef"])
    }
    if let remoteRef {
      guard let split = WorkspaceCheckout.splitRemoteRef(remoteRef) else {
        throw IPCError.invalidParams(
          message: "remoteRef must be <remote>/<branch>, got \(remoteRef)", path: ["members", "remoteRef"])
      }
      return .remoteTrackingRef(remoteRef: remoteRef, branch: flags.branch ?? split.branch, resetLocal: resetLocal)
    }
    let branch = flags.branch ?? defaults.branch
    if defaults.trackRemote {
      return .remoteTrackingRef(remoteRef: "origin/\(branch)", branch: branch, resetLocal: resetLocal)
    }
    if resetLocal {
      throw IPCError.invalidParams(
        message: "resetLocalBranch needs a remote-tracking ref (remoteRef or trackRemote)",
        path: ["members", "resetLocalBranch"])
    }
    return useExisting
      ? .existingBranch(branch)
      : .newBranch(branch: branch, baseRef: flags.baseRef ?? defaults.baseRef)
  }

  private static func checkout(
    for member: IPC.WorkspaceMemberRequest, defaults: MemberDefaults
  ) throws -> WorkspaceCheckout {
    try checkout(
      CheckoutFlags(
        useExisting: member.useExistingBranch, remoteRef: member.remoteRef,
        resetLocal: member.resetLocalBranch, branch: member.branch, baseRef: member.baseRef),
      defaults: CheckoutDefaults(
        branch: defaults.branch, baseRef: defaults.baseRef,
        useExisting: defaults.useExisting, trackRemote: defaults.trackRemote))
  }

  /// Classification for `describe`: a recorded remote URL marks a clone;
  /// any other recorded source is local. Nil for a row that records none.
  nonisolated static func sourceKind(
    sourceGitRoot: String?, remoteURL: String?
  ) -> IPC.WorkspaceMemberSourceKind? {
    if remoteURL != nil { return .remote }
    return sourceGitRoot == nil ? nil : .local
  }

  /// `~/.codans/workspaces/<slug>`, suffixed `-2`, `-3`, … while taken.
  nonisolated static func uniqueDefaultRootPath(
    forTitle title: String,
    base: URL = WorkspaceLayout.defaultWorkspacesDirectory(),
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> String {
    WorkspaceLayout.uniquePath(base: base, folder: WorkspaceLayout.folderName(forTitle: title), exists: exists)
  }

  // MARK: - Error mapping

  nonisolated static func ipcError(for error: Error) -> IPCError {
    if let ipc = error as? IPCError { return ipc }
    if let workspace = error as? WorkspaceError {
      switch workspace {
      case .invalidPlan, .rootIsFile, .rootInsideRepository, .sourceNotRepository, .bareRepository,
        .invalidBranchName:
        return .invalidParams(message: workspace.localizedDescription, path: nil)
      case .rootAlreadyRegistered, .rootAlreadyWorkspace, .destinationExists, .cloneDestinationTaken,
        .memberExists, .memberWithoutSource, .cannotDropRoot:
        return .conflict(reason: workspace.localizedDescription)
      case .notWorkspace(let id):
        return .notFound(kind: "workspace", id: id.description)
      case .memberNotFound(let name):
        return .notFound(kind: "workspace member", id: name)
      case .cancelled, .memberNotRegistered:
        return .internal(workspace.localizedDescription)
      }
    }
    if let git = error as? GitWorktreeError {
      switch git {
      case .branchExists:
        return .conflict(reason: git.localizedDescription)
      case .invalidBranchName:
        return .invalidParams(message: git.localizedDescription, path: nil)
      default:
        return .internal(git.localizedDescription)
      }
    }
    return .internal(String(describing: error))
  }
}

extension String {
  fileprivate nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
