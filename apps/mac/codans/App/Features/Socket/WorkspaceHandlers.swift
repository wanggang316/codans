import CodansCore
import CodansIPC
import Foundation

/// Server-side handler for the `workspace.*` IPC surface.
///
/// Resolves each member's source (a registered Project id, or any local
/// repository path) to a repository root, fills request defaults (folder
/// name, branch, workspace root), and hands the resulting `WorkspacePlan`
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
    var members: [WorkspacePlan.Member] = []
    for member in request.members {
      members.append(
        try await resolveMember(
          member,
          defaultBranch: defaultBranch,
          defaultBaseRef: request.baseRef,
          defaultUseExisting: request.useExistingBranch ?? false
        ))
    }
    let rootPath = request.rootPath.map { ($0 as NSString).expandingTildeInPath }
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
      defaultBranch: WorkspaceLayout.folderName(forTitle: project.name),
      defaultBaseRef: nil,
      defaultUseExisting: false
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
      return IPC.WorkspaceMemberSummary(
        name: entry.name,
        path: path,
        role: entry.role,
        branch: row?.branch ?? entry.branch,
        sourceGitRoot: row?.sourceGitRoot ?? entry.sourceGitRoot,
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

  private func resolveMember(
    _ member: IPC.WorkspaceMemberRequest,
    defaultBranch: String,
    defaultBaseRef: String?,
    defaultUseExisting: Bool
  ) async throws -> WorkspacePlan.Member {
    let sourceGitRoot: String
    switch (member.projectID, member.path) {
    case (let projectID?, nil):
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
      sourceGitRoot = gitRoot
    case (nil, let path?):
      let expanded = (path as NSString).expandingTildeInPath
      guard let discovered = try? await gitCLI.discoverGitRoot(candidatePath: expanded),
        !discovered.isEmpty
      else {
        throw IPCError.invalidParams(
          message: "\(expanded) is not inside a git repository", path: ["members", "path"])
      }
      sourceGitRoot = discovered
    default:
      throw IPCError.invalidParams(
        message: "each member names exactly one of projectID or path", path: ["members"])
    }
    let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? (sourceGitRoot as NSString).lastPathComponent
    let branch = member.branch ?? defaultBranch
    let checkout: WorkspaceCheckout =
      (member.useExistingBranch ?? defaultUseExisting)
      ? .existingBranch(branch)
      : .newBranch(branch: branch, baseRef: member.baseRef ?? defaultBaseRef)
    return WorkspacePlan.Member(
      name: name, sourceGitRoot: sourceGitRoot, role: member.role, checkout: checkout)
  }

  /// `~/.codans/workspaces/<slug>`, suffixed `-2`, `-3`, … while taken.
  nonisolated static func uniqueDefaultRootPath(
    forTitle title: String,
    base: URL = WorkspaceLayout.defaultWorkspacesDirectory(),
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> String {
    let folder = WorkspaceLayout.folderName(forTitle: title)
    var suffix = 1
    while true {
      let candidate = suffix == 1 ? folder : "\(folder)-\(suffix)"
      let path = base.appending(path: candidate, directoryHint: .isDirectory).path
      if !exists(path) { return path }
      suffix += 1
    }
  }

  // MARK: - Error mapping

  nonisolated static func ipcError(for error: Error) -> IPCError {
    if let ipc = error as? IPCError { return ipc }
    if let workspace = error as? WorkspaceError {
      switch workspace {
      case .invalidPlan, .rootIsFile, .rootInsideRepository, .sourceNotRepository,
        .invalidBranchName:
        return .invalidParams(message: workspace.localizedDescription, path: nil)
      case .rootAlreadyRegistered, .rootAlreadyWorkspace, .destinationExists, .memberExists:
        return .conflict(reason: workspace.localizedDescription)
      case .notWorkspace(let id):
        return .notFound(kind: "workspace", id: id.description)
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
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
