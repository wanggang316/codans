import CodansCore
import CodansIPC
import Foundation

/// Server-side handler for the `workspace.*` IPC surface.
///
/// Translates the wire requests to `WorkspaceClient` calls, the same client
/// the GUI sheets use, and maps its errors to IPC errors. It resolves source
/// projects (a registered Project id, a path inside any local repository, or
/// a remote URL to clone) and request defaults; every disk and git effect
/// lives in the client.
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

  // MARK: - Sources

  func create(_ request: IPC.WorkspaceCreateRequest) async throws -> IPC.WorkspaceSummary {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw IPCError.invalidParams(message: "workspace.create requires a non-empty title", path: ["title"])
    }
    var sources: [WorkspaceSource] = []
    for source in request.projects {
      sources.append(try await resolveSource(source, cloneBaseDirectory: request.cloneBaseDirectory))
    }
    let rootPath =
      request.rootPath.map { ($0 as NSString).expandingTildeInPath }
      ?? Self.uniqueDefaultRootPath(forTitle: title)
    let plan = WorkspaceSourcePlan(
      title: title,
      rootPath: rootPath,
      description: request.description,
      taskLinks: request.taskLinks ?? [],
      sources: sources
    )
    let projectID = try await mapped { try await workspace.createWorkspace(plan) }
    return try describe(IPC.WorkspaceDescribeRequest(projectID: projectID))
  }

  func add(_ request: IPC.WorkspaceAddRequest) async throws -> IPC.WorkspaceProjectSummary {
    _ = try workspaceProject(request.projectID)
    let source = try await resolveSource(request.project, cloneBaseDirectory: request.cloneBaseDirectory)
    let worktreeID = try await mapped { try await workspace.addSource(request.projectID, source) }
    let summary = try describe(IPC.WorkspaceDescribeRequest(projectID: request.projectID))
    guard let added = summary.projects.first(where: { $0.worktreeID == worktreeID }) else {
      throw IPCError.internal("the added project did not appear in the workspace")
    }
    return added
  }

  func drop(_ request: IPC.WorkspaceDropRequest) async throws -> IPC.WorkspaceDropResponse {
    let project = try workspaceProject(request.projectID)
    let manifest = try groupsManifest(project)
    let wanted = request.project.trimmingCharacters(in: .whitespacesAndNewlines)
    let wantedPath = HierarchyManager.canonicalPath((wanted as NSString).expandingTildeInPath)
    guard
      let source = manifest.projects.first(where: {
        $0.name == wanted || HierarchyManager.canonicalPath($0.sourceGitRoot) == wantedPath
      })
    else {
      let isMember = manifest.groups.contains { group in
        group.members.contains {
          HierarchyManager.canonicalPath(WorkspaceClient.absolutePath($0.path, rootPath: project.rootPath))
            == wantedPath
        }
      }
      if isMember {
        throw IPCError.conflict(reason: "\(wanted) is a checkout of a group; delete its group instead")
      }
      throw IPCError.notFound(kind: "workspace project", id: wanted)
    }
    try await mapped { try await workspace.removeSource(request.projectID, source.sourceGitRoot) }
    return IPC.WorkspaceDropResponse(name: source.name, path: source.sourceGitRoot)
  }

  // MARK: - Workspace

  func remove(_ request: IPC.WorkspaceRemoveRequest) async throws -> IPC.WorkspaceRemoveResponse {
    let project = try workspaceProject(request.projectID)
    let removal: WorkspaceRemovalRequest =
      request.cleanup.deleteFiles
      ? .deleteOwnedFiles(
        GroupDeletionRequest(
          deleteBranches: request.cleanup.deleteBranches, acknowledgeRisks: request.acknowledgeRisks))
      : .sidebarOnly
    let outcome = try await mapped { try await workspace.removeWorkspace(request.projectID, removal) }
    return IPC.WorkspaceRemoveResponse(projectID: project.id, rootPath: project.rootPath, outcome: outcome)
  }

  func describe(_ request: IPC.WorkspaceDescribeRequest) throws -> IPC.WorkspaceSummary {
    let project = try workspaceProject(request.projectID)
    let manifest = try groupsManifest(project)
    func row(at path: String) -> Worktree? { WorkspaceClient.row(at: path, in: project) }

    let projects = manifest.projects.map { source -> IPC.WorkspaceProjectSummary in
      let path = HierarchyManager.canonicalPath(source.sourceGitRoot)
      let row = row(at: path)
      return IPC.WorkspaceProjectSummary(
        name: source.name,
        sourceGitRoot: path,
        sourceKind: source.remoteURL == nil ? .local : .remote,
        remoteURL: source.remoteURL,
        branch: row?.branch,
        worktreeID: row?.id)
    }
    let ordered = manifest.groups.filter { $0.kind == .default } + manifest.groups.filter { $0.kind != .default }
    let groups = ordered.map { group -> IPC.WorkspaceGroupSummary in
      let members: [IPC.WorkspaceGroupMemberSummary]
      if group.kind == .default {
        members = projects.map {
          IPC.WorkspaceGroupMemberSummary(
            name: $0.name, path: $0.sourceGitRoot, branch: $0.branch, sourceGitRoot: $0.sourceGitRoot,
            role: .reference, worktreeID: $0.worktreeID)
        }
      } else {
        members = group.members.map { member in
          let path = HierarchyManager.canonicalPath(
            WorkspaceClient.absolutePath(member.path, rootPath: project.rootPath))
          let row = row(at: path)
          return IPC.WorkspaceGroupMemberSummary(
            name: member.name, path: path, branch: row?.branch ?? member.branch,
            sourceGitRoot: row?.sourceGitRoot ?? member.sourceGitRoot, role: .member, worktreeID: row?.id)
        }
      }
      let terminal = project.worktrees.first {
        $0.workspaceSlot == WorkspaceSlot(groupID: group.id, role: .groupTerminal)
      }
      let record = project.workspaceGroups.first { $0.id == group.id }
      return IPC.WorkspaceGroupSummary(
        id: group.id,
        name: group.name,
        isDefault: group.kind == .default,
        path: HierarchyManager.canonicalPath(WorkspaceClient.absolutePath(group.path, rootPath: project.rootPath)),
        worktreeID: terminal?.id,
        deletion: group.deletion ?? record?.deletion,
        members: members)
    }
    return IPC.WorkspaceSummary(
      projectID: project.id,
      title: manifest.title,
      rootPath: project.rootPath,
      description: manifest.description,
      taskLinks: manifest.taskLinks,
      projects: projects,
      groups: groups
    )
  }

  // MARK: - Groups

  func createGroup(_ request: IPC.WorkspaceGroupCreateRequest) async throws -> IPC.WorkspaceGroupCreateResponse {
    _ = try workspaceProject(request.projectID)
    var members = await workspace.groupCreationDefaults(request.projectID)
    for (name, ref) in (request.baseRefs ?? [:]).sorted(by: { $0.key < $1.key }) {
      guard let index = members.firstIndex(where: { $0.name == name }) else {
        throw IPCError.invalidParams(
          message: "the workspace has no project named \"\(name)\" (projects: "
            + "\(members.map(\.name).joined(separator: ", ")))",
          path: ["baseRefs", name])
      }
      let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
      members[index].baseRef = trimmed.isEmpty ? nil : trimmed
    }
    for index in members.indices {
      if let fetch = request.fetch { members[index].fetch = fetch }
      if let copyIgnored = request.copyIgnored { members[index].copyIgnored = copyIgnored }
      if let copyUntracked = request.copyUntracked { members[index].copyUntracked = copyUntracked }
    }
    let plan = WorkspaceGroupPlan(
      projectID: request.projectID,
      name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
      branch: request.branch.trimmingCharacters(in: .whitespacesAndNewlines),
      members: members)
    let result = try await mapped { try await workspace.createGroup(plan) }
    let summary = try describe(IPC.WorkspaceDescribeRequest(projectID: request.projectID))
    guard let group = summary.groups.first(where: { $0.id == result.groupID }) else {
      throw IPCError.internal("the new group did not appear in the workspace")
    }
    return IPC.WorkspaceGroupCreateResponse(
      projectID: request.projectID, group: group, setupFailures: result.setupFailures)
  }

  func checkGroupDeletion(_ request: IPC.WorkspaceGroupRequest) async throws -> GroupDeletionCheck {
    let group = try deletableGroup(request.group, projectID: request.projectID)
    return await workspace.checkGroupDeletion(request.projectID, group.id)
  }

  func deleteGroup(_ request: IPC.WorkspaceGroupDeleteRequest) async throws -> IPC.WorkspaceGroupDeleteResponse {
    let group = try deletableGroup(request.group, projectID: request.projectID)
    let outcome = try await mapped {
      try await workspace.deleteGroup(
        request.projectID, group.id,
        GroupDeletionRequest(deleteBranches: request.deleteBranches, acknowledgeRisks: request.acknowledgeRisks))
    }
    return IPC.WorkspaceGroupDeleteResponse(
      projectID: request.projectID, groupID: group.id, groupName: group.name, outcome: outcome)
  }

  /// A named group by name or id. `default` is a `conflict`: it exists as
  /// long as the Workspace does.
  private func deletableGroup(_ selector: String, projectID: ProjectID) throws -> WorkspaceGroupsManifest.Group {
    let manifest = try groupsManifest(try workspaceProject(projectID))
    let wanted = selector.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let group = manifest.groups.first(where: { $0.name == wanted })
        ?? UUID(uuidString: wanted).flatMap({ id in manifest.groups.first { $0.id.raw == id } })
    else {
      throw IPCError.notFound(kind: "workspace group", id: wanted)
    }
    guard group.kind == .named else { throw Self.ipcError(for: WorkspaceError.cannotDeleteDefault) }
    return group
  }

  // MARK: - Lookup

  private func workspaceProject(_ projectID: ProjectID) throws -> Project {
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == projectID }) else {
      throw IPCError.notFound(kind: "project", id: projectID.description)
    }
    guard project.isWorkspace else {
      throw IPCError.invalidParams(message: "\(project.name) is not a workspace", path: ["projectID"])
    }
    return project
  }

  /// Read from disk, not the catalog's copy: a call right after a mutation
  /// must see the manifest that mutation wrote.
  private func groupsManifest(_ project: Project) throws -> WorkspaceGroupsManifest {
    do {
      return try WorkspaceManifestStore.loadOrMigrate(rootPath: project.rootPath)
    } catch {
      throw IPCError.internal(WorkspaceClient.describe(error))
    }
  }

  private func mapped<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch {
      throw Self.ipcError(for: error)
    }
  }

  // MARK: - Source resolution

  private func resolveSource(
    _ source: IPC.WorkspaceSourceRequest, cloneBaseDirectory: String?
  ) async throws -> WorkspaceSource {
    let name = source.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    switch (source.projectID, source.path, source.remoteURL) {
    case (let projectID?, nil, nil):
      guard let project = hierarchy.snapshot().projects.first(where: { $0.id == projectID }) else {
        throw IPCError.notFound(kind: "project", id: projectID.description)
      }
      guard project.remoteHost == nil else {
        throw IPCError.invalidParams(
          message: "\(project.name) is a Server project; workspaces are local only", path: ["projects", "projectID"])
      }
      guard let gitRoot = project.gitRoot else {
        throw IPCError.invalidParams(
          message: "\(project.name) is not a git repository", path: ["projects", "projectID"])
      }
      return WorkspaceSource(location: .local(path: gitRoot), name: name)
    case (nil, let path?, nil):
      // A subdirectory or linked worktree resolves to its repository root.
      let expanded = (path as NSString).expandingTildeInPath
      guard let probe = try? await gitCLI.inspectRepository(at: expanded) else {
        throw IPCError.invalidParams(message: "\(expanded) is not a git repository", path: ["projects", "path"])
      }
      guard !probe.isBare else {
        throw IPCError.invalidParams(
          message: WorkspaceError.bareRepository(path: probe.root).localizedDescription, path: ["projects", "path"])
      }
      return WorkspaceSource(location: .local(path: HierarchyManager.canonicalPath(probe.root)), name: name)
    case (nil, nil, let url?):
      let remoteURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !remoteURL.isEmpty else {
        throw IPCError.invalidParams(message: "remoteURL is empty", path: ["projects", "remoteURL"])
      }
      let destination: String
      if let named = source.cloneDestination?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        destination = (named as NSString).expandingTildeInPath
      } else {
        guard let repoName = WorkspaceLayout.repositoryName(fromRemoteURL: remoteURL) else {
          throw IPCError.invalidParams(
            message: "cannot derive a repository name from \(remoteURL); pass name and cloneDestination",
            path: ["projects", "remoteURL"])
        }
        destination = try await defaultCloneDestination(
          repoName: repoName, remoteURL: remoteURL, base: cloneBaseDirectory)
      }
      return WorkspaceSource(location: .remote(url: remoteURL, cloneDestination: destination), name: name)
    default:
      throw IPCError.invalidParams(
        message: "each project names exactly one of projectID, path, or remoteURL", path: ["projects"])
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
      let message = workspace.localizedDescription
      switch workspace {
      case .invalidSourcePlan, .rootIsFile, .rootInsideRepository, .sourceNotRepository,
        .bareRepository, .invalidBranchName:
        return .invalidParams(message: message, path: nil)
      case .groupPreflightFailed(let preflight):
        let blocking = preflight.groupIssues + preflight.memberIssues.values.flatMap { $0 }
        return blocking.contains(where: { conflictKinds.contains($0.kind) })
          ? .conflict(reason: message) : .invalidParams(message: message, path: nil)
      case .risksNotAcknowledged(let check), .checkFailed(let check):
        return .conflict(reason: "\(message): " + riskLines(check).joined(separator: "; "))
      case .rootAlreadyRegistered, .rootAlreadyWorkspace, .destinationExists, .cloneDestinationTaken,
        .memberExists, .memberWithoutSource, .cannotDropRoot, .sourceExists, .cannotDeleteDefault:
        return .conflict(reason: message)
      case .notWorkspace(let id):
        return .notFound(kind: "workspace", id: id.description)
      case .memberNotFound(let name):
        return .notFound(kind: "workspace member", id: name)
      case .sourceNotFound(let path):
        return .notFound(kind: "workspace project", id: path)
      case .groupNotFound(let id):
        return .notFound(kind: "workspace group", id: id.description)
      case .cancelled, .memberNotRegistered, .manifestUnavailable:
        return .internal(message)
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

  /// Preflight findings that clash with something on disk, not with the
  /// shape of the request.
  private nonisolated static let conflictKinds: Set<WorkspacePreflight.Issue.Kind> = [
    .localBranchExists, .destinationExists, .duplicateGroupName, .cloneDestinationTaken,
  ]

  /// One line per finding of a deletion check, failed probes first.
  nonisolated static func riskLines(_ check: GroupDeletionCheck) -> [String] {
    var lines = check.groupCheckFailures.map { "check failed: \($0)" }
    lines += check.members.compactMap { member in
      member.checkFailure.map { "\(member.name): check failed: \($0)" }
    }
    for member in check.members {
      if member.uncommittedCount > 0 {
        lines.append("\(member.name): \(counted(member.uncommittedCount, "uncommitted file"))")
      }
      if member.unpushedCount > 0 {
        lines.append("\(member.name): \(counted(member.unpushedCount, "unpushed commit"))")
      }
    }
    if !check.busyPaneIDs.isEmpty {
      lines.append(counted(check.busyPaneIDs.count, "running terminal"))
    }
    if !check.extraEntries.isEmpty {
      lines.append("other files in the group folder: \(check.extraEntries.joined(separator: ", "))")
    }
    return lines
  }

  private nonisolated static func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }
}

extension String {
  fileprivate nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
