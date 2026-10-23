import CodansCore
import Foundation

/// Why one deletion step left a member or group directory in place. It is
/// recorded in the outcome, never thrown out of the client.
nonisolated enum GroupDeletionStepError: LocalizedError, Equatable {
  case notOwned(path: String, WorkspaceOwnership.Rejection)

  var errorDescription: String? {
    switch self {
    case .notOwned(let path, let rejection):
      switch rejection {
      case .outsideRoot: return "\(path) is outside the workspace folder; it was kept"
      case .workspaceRoot: return "\(path) is the workspace folder itself; it was kept"
      case .notRecorded: return "\(path) is not recorded in the workspace manifest; it was kept"
      case .symbolicLink(let link): return "\(link) is a symbolic link; \(path) was kept"
      case .insideSource(let source): return "\(path) is inside the project at \(source); it was kept"
      }
    }
  }
}

// Group deletion and Workspace removal. Every destructive path re-runs the
// check, goes through `WorkspaceOwnership` before it removes a directory,
// and removes checkouts only through their source repository, so a source
// main checkout is never deleted, also not through a `default` link.
extension WorkspaceClient {
  /// A named group as the manifest records it, with its Workspace.
  struct GroupDeletionTarget {
    let project: Project
    let manifest: WorkspaceGroupsManifest
    let group: WorkspaceGroupsManifest.Group

    var rootPath: String { project.rootPath }
  }

  /// Finder writes this file into any folder it shows; it is never user data.
  static let disposableEntries: Set<String> = [".DS_Store"]

  // MARK: Check

  @MainActor
  static func checkGroupDeletion(
    projectID: ProjectID, groupID: WorkspaceGroupID, context: Context
  ) async -> GroupDeletionCheck {
    do {
      let target = try groupDeletionTarget(projectID: projectID, groupID: groupID, context: context)
      return await check(target, context: context)
    } catch {
      let name = context.hierarchy.snapshot().projects.first { $0.id == projectID }?
        .workspaceGroups.first { $0.id == groupID }?.name
      return GroupDeletionCheck(
        projectID: projectID, groupID: groupID, groupName: name ?? "", groupCheckFailures: [describe(error)])
    }
  }

  @MainActor
  static func groupDeletionTarget(
    projectID: ProjectID, groupID: WorkspaceGroupID, context: Context
  ) throws -> GroupDeletionTarget {
    guard let project = context.hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    let manifest = try loadGroupsManifest(rootPath: project.rootPath)
    guard let group = manifest.groups.first(where: { $0.id == groupID }) else {
      throw WorkspaceError.groupNotFound(groupID)
    }
    guard group.kind == .named else { throw WorkspaceError.cannotDeleteDefault }
    return GroupDeletionTarget(project: project, manifest: manifest, group: group)
  }

  /// Collects the check without side effects. The catalog row supplies the
  /// source repository a migrated member did not record.
  @MainActor
  static func check(_ target: GroupDeletionTarget, context: Context) async -> GroupDeletionCheck {
    var members: [GroupDeletionCheck.Member] = []
    for member in target.group.members {
      let path = absolutePath(member.path, rootPath: target.rootPath)
      let row = row(at: path, in: target.project)
      members.append(
        await probeMember(
          name: member.name,
          // A member whose row the reconcile has not added yet still needs a
          // stable identity in the check.
          worktreeID: row?.id ?? WorktreeID(raw: member.id.raw),
          path: path,
          sourceGitRoot: member.sourceGitRoot ?? row?.sourceGitRoot,
          createdBranch: member.createdBranch == true))
    }
    var result = GroupDeletionCheck(
      projectID: target.project.id,
      groupID: target.group.id,
      groupName: target.group.name,
      members: members,
      busyPaneIDs: context.hierarchy.workspaceGroupBusyPanes(target.project.id, target.group.id))
    if target.group.path != WorkspaceLayout.migratedGroupPath {
      do {
        result.extraEntries = try extraEntries(of: target.group, rootPath: target.rootPath)
      } catch {
        result.groupCheckFailures.append(describe(error))
      }
    }
    return result
  }

  /// Entries of a group directory that are not its member checkouts.
  static func extraEntries(of group: WorkspaceGroupsManifest.Group, rootPath: String) throws -> [String] {
    let directory = absolutePath(group.path, rootPath: rootPath)
    guard FileManager.default.fileExists(atPath: directory) else { return [] }
    let groupComponents = group.path.split(separator: "/")
    let memberEntries = Set(
      group.members.compactMap { member -> Substring? in
        let components = member.path.split(separator: "/")
        guard components.count > groupComponents.count, components.starts(with: groupComponents) else {
          return nil
        }
        return components[groupComponents.count]
      })
    return try FileManager.default.contentsOfDirectory(atPath: directory)
      .filter { !memberEntries.contains(Substring($0)) && !disposableEntries.contains($0) }
      .sorted()
  }

  @MainActor
  static func probeMember(
    name: String,
    worktreeID: WorktreeID,
    path: String,
    sourceGitRoot: String?,
    createdBranch: Bool
  ) async -> GroupDeletionCheck.Member {
    var result = GroupDeletionCheck.Member(name: name, worktreeID: worktreeID, path: path)
    // A checkout that is already gone holds nothing to lose; the delete only
    // clears its registration.
    guard FileManager.default.fileExists(atPath: path) else { return result }
    do {
      guard let sourceGitRoot else { throw WorkspaceError.memberWithoutSource(name: name) }
      let branch = try await currentBranch(at: path)
      result.branch = branch
      result.uncommittedCount = try await uncommittedCount(at: path)
      result.unpushedCount = try await unpushedCount(at: path, branch: branch)
      if createdBranch, let branch,
        try await isDeletable(branch: branch, memberPath: path, sourceGitRoot: sourceGitRoot)
      {
        result.deletableBranches = [branch]
      }
    } catch {
      result.checkFailure = describe(error)
    }
    return result
  }

  // MARK: Git probes

  /// The checked-out branch; `nil` when HEAD is detached.
  static func currentBranch(at path: String) async throws -> String? {
    let output = try await git(["symbolic-ref", "--short", "-q", "HEAD"], at: path, allowedCodes: [0, 1])
    guard output.code == 0 else { return nil }
    let branch = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return branch.isEmpty ? nil : branch
  }

  /// Changed and untracked files, as `git status` lists them.
  static func uncommittedCount(at path: String) async throws -> Int {
    let output = try await git(GitCommand.status(), at: path)
    return try GitOutputParser.parseStatus(output.data).entries.count
  }

  /// Commits only this checkout holds: ahead of the upstream when there is
  /// one, otherwise not reachable from any other branch or remote ref.
  static func unpushedCount(at path: String, branch: String?) async throws -> Int {
    let arguments: [String]
    if let branch {
      let upstream = try await git(
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], at: path, allowedCodes: nil)
      arguments =
        upstream.code == 0
        ? ["rev-list", "--count", "@{upstream}..HEAD"]
        // `--exclude` patterns for `--branches` name the branch without
        // `refs/heads/`; a branch name holds no glob characters.
        : ["rev-list", "--count", "HEAD", "--not", "--exclude=\(branch)", "--branches", "--remotes"]
    } else {
      arguments = ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"]
    }
    let output = try await git(arguments, at: path)
    guard let count = Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw GitWorktreeError.commandFailed(command: "git rev-list --count", stderr: "unexpected output")
    }
    return count
  }

  /// A branch the group created may be deleted unless it is the repository's
  /// default branch or another worktree has it checked out. The default
  /// branch is read from the local `origin/HEAD` only: a check must not wait
  /// on the network.
  static func isDeletable(branch: String, memberPath: String, sourceGitRoot: String) async throws -> Bool {
    let head = try await git(
      ["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], at: sourceGitRoot, allowedCodes: [0, 1])
    if head.code == 0,
      WorkspaceCheckout.splitRemoteRef(head.text.trimmingCharacters(in: .whitespacesAndNewlines))?.branch == branch
    {
      return false
    }
    let list = try await git(["worktree", "list", "--porcelain"], at: sourceGitRoot)
    let member = HierarchyManager.canonicalPath(memberPath)
    var worktree: String?
    for line in list.text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("worktree ") {
        worktree = String(line.dropFirst("worktree ".count))
      } else if line == "branch refs/heads/\(branch)", let worktree,
        HierarchyManager.canonicalPath(worktree) != member
      {
        return false
      }
    }
    return true
  }

  struct GitOutput {
    let code: Int32
    let data: Data
    var text: String { GitWorktreeShell.decodeUTF8(data) }
  }

  /// Runs git in `path`. Throws unless the exit code is in `allowedCodes`
  /// (`nil` accepts any exit code).
  static func git(_ arguments: [String], at path: String, allowedCodes: Set<Int32>? = [0]) async throws -> GitOutput {
    let command = "git " + arguments.prefix(2).joined(separator: " ")
    let outcome = await GitWorktreeShell.run(
      executable: GitWorktreeShell.gitURL,
      arguments: ["-C", path] + arguments,
      cwd: URL(fileURLWithPath: path, isDirectory: true))
    switch outcome {
    case .exited(let code, let stdout, let stderr, _):
      if let allowedCodes, !allowedCodes.contains(code) {
        throw GitWorktreeError.commandFailed(
          command: command,
          stderr: GitWorktreeShell.decodeUTF8(stderr).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return GitOutput(code: code, data: stdout)
    case .timedOut:
      throw GitWorktreeError.commandFailed(command: command, stderr: "timed out")
    case .spawnFailed(let reason):
      throw GitWorktreeError.commandFailed(command: command, stderr: reason)
    }
  }

  // MARK: Delete

  @MainActor
  static func deleteGroup(
    projectID: ProjectID, groupID: WorkspaceGroupID, request: GroupDeletionRequest, context: Context
  ) async throws -> GroupDeletionOutcome {
    let target = try groupDeletionTarget(projectID: projectID, groupID: groupID, context: context)
    let check = await check(target, context: context)
    try requireDeletable(check, request: request)
    return try await performGroupDeletion(target, check: check, request: request, context: context)
  }

  static func requireDeletable(_ check: GroupDeletionCheck, request: GroupDeletionRequest) throws {
    if check.isBlocked { throw WorkspaceError.checkFailed(check) }
    if check.hasRisks, !request.acknowledgeRisks { throw WorkspaceError.risksNotAcknowledged(check) }
  }

  /// Marks the group as being deleted, stops its terminals, then removes
  /// each member. A member that fails stays in the manifest and keeps its
  /// row; the group then stays with its `deletion` state so a retry can
  /// finish. Only when every member is gone do the group directory, the
  /// manifest entry, and the group row go.
  @MainActor
  static func performGroupDeletion(
    _ target: GroupDeletionTarget,
    check: GroupDeletionCheck,
    request: GroupDeletionRequest,
    context: Context
  ) async throws -> GroupDeletionOutcome {
    let projectID = target.project.id
    let group = target.group
    let rootPath = target.rootPath
    let hierarchy = context.hierarchy
    var manifest = target.manifest

    let state = GroupDeletionState(
      deleteBranches: request.deleteBranches, startedAt: group.deletion?.startedAt ?? Date())
    manifest = try updateGroup(group.id, in: manifest, rootPath: rootPath) { $0.deletion = state }
    hierarchy.setWorkspaceGroupDeletion(projectID, group.id, state)

    let groupRows =
      hierarchy.snapshot().projects.first { $0.id == projectID }?
      .worktrees.filter { $0.workspaceSlot?.groupID == group.id } ?? []
    for row in groupRows {
      hierarchy.tearDownWorktreeSurfaces(row.id)
    }

    var outcome = GroupDeletionOutcome(deletedGroup: false)
    for member in group.members {
      let path = absolutePath(member.path, rootPath: rootPath)
      let canonical = HierarchyManager.canonicalPath(path)
      let rows = groupRows.filter { HierarchyManager.canonicalPath($0.path) == canonical }
      let sourceGitRoot = member.sourceGitRoot ?? rows.first?.sourceGitRoot
      do {
        try await removeMemberCheckout(
          name: member.name, path: path, sourceGitRoot: sourceGitRoot, rootPath: rootPath, manifest: manifest,
          git: context.git)
      } catch {
        outcome.failures.append(.init(name: member.name, path: path, reason: describe(error)))
        continue
      }
      if request.deleteBranches, let sourceGitRoot {
        let branches = check.members.first { $0.path == path }?.deletableBranches ?? []
        let sourceURL = URL(fileURLWithPath: sourceGitRoot, isDirectory: true)
        for branch in branches {
          switch await context.git.deleteBranchIfExists(sourceURL, branch) {
          case .deleted, .absent:
            outcome.deletedBranches.append(branch)
          case .kept(let reason):
            outcome.keptBranches.append("\(branch) in \(member.name): \(reason)")
          }
        }
      }
      manifest = try updateGroup(group.id, in: manifest, rootPath: rootPath) { recorded in
        recorded.members.removeAll { $0.id == member.id }
      }
      hierarchy.removeWorkspaceRows(projectID, rows.map(\.id))
      removeMirrorRows(forCanonicalPath: canonical, hierarchy: hierarchy)
      outcome.removedMembers.append(member.name)
    }

    if outcome.failures.isEmpty, group.path != WorkspaceLayout.migratedGroupPath {
      let directory = absolutePath(group.path, rootPath: rootPath)
      do {
        try removeGroupDirectory(directory, rootPath: rootPath, manifest: manifest)
      } catch {
        outcome.failures.append(.init(name: group.name, path: directory, reason: describe(error)))
      }
    }
    guard outcome.failures.isEmpty else {
      logger.notice(
        "group deletion incomplete: group=\(group.id.raw.uuidString, privacy: .public) failures=\(outcome.failures.count, privacy: .public)"
      )
      return outcome
    }

    manifest.groups.removeAll { $0.id == group.id }
    _ = try saveGroupsManifest(manifest, rootPath: rootPath)
    let remaining =
      hierarchy.snapshot().projects.first { $0.id == projectID }?
      .worktrees.filter { $0.workspaceSlot?.groupID == group.id }.map(\.id) ?? []
    hierarchy.removeWorkspaceRows(projectID, remaining)
    // The reconcile rewrites the catalog group records from the manifest.
    await hierarchy.reconcileDiscoveredWorktrees(projectID)
    outcome.deletedGroup = true
    return outcome
  }

  /// Removes one member checkout through its source repository. A path that
  /// still exists must pass `WorkspaceOwnership`; a path that is gone only
  /// has its registration cleared.
  static func removeMemberCheckout(
    name: String,
    path: String,
    sourceGitRoot: String?,
    rootPath: String,
    manifest: WorkspaceGroupsManifest,
    git: GitWorktreeClient
  ) async throws {
    if entryExists(path) {
      if case .notOwned(let rejection) = WorkspaceOwnership.check(path: path, rootPath: rootPath, manifest: manifest) {
        throw GroupDeletionStepError.notOwned(path: path, rejection)
      }
    }
    guard let sourceGitRoot else { throw WorkspaceError.memberWithoutSource(name: name) }
    try await git.removeWorktree(
      URL(fileURLWithPath: sourceGitRoot, isDirectory: true), URL(fileURLWithPath: path, isDirectory: true))
  }

  /// Deletes a group directory the Workspace owns. A directory that is not
  /// owned (for example a symbolic link) is left in place and logged.
  static func removeGroupDirectory(_ directory: String, rootPath: String, manifest: WorkspaceGroupsManifest) throws {
    guard entryExists(directory) else { return }
    guard WorkspaceOwnership.check(path: directory, rootPath: rootPath, manifest: manifest) == .owned else {
      logger.notice("group directory is not owned by the workspace; kept: \(directory, privacy: .private)")
      return
    }
    try FileManager.default.removeItem(atPath: directory)
  }

  // MARK: Workspace removal

  @MainActor
  static func removeWorkspace(
    projectID: ProjectID, request: WorkspaceRemovalRequest, context: Context
  ) async throws -> WorkspaceRemovalOutcome {
    guard let project = context.hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    switch request {
    case .sidebarOnly:
      try context.hierarchy.removeProject(projectID)
      return WorkspaceRemovalOutcome(deletedFolder: false)
    case .deleteOwnedFiles(let groupRequest):
      return try await deleteWorkspaceFiles(project, request: groupRequest, context: context)
    }
  }

  /// Checks every named group first (one acknowledgment covers all), deletes
  /// them, then the default links and directory, then the root when only
  /// codans state is left in it. The catalog entry goes only when every
  /// group is gone; files the Workspace does not own stay on disk.
  @MainActor
  static func deleteWorkspaceFiles(
    _ project: Project, request: GroupDeletionRequest, context: Context
  ) async throws -> WorkspaceRemovalOutcome {
    let rootPath = project.rootPath
    let manifest = try loadGroupsManifest(rootPath: rootPath)
    var checks: [GroupDeletionCheck] = []
    for group in manifest.groups where group.kind == .named {
      checks.append(
        await check(GroupDeletionTarget(project: project, manifest: manifest, group: group), context: context))
    }
    if let blocked = checks.first(where: \.isBlocked) { throw WorkspaceError.checkFailed(blocked) }
    if !request.acknowledgeRisks, let risky = checks.first(where: \.hasRisks) {
      throw WorkspaceError.risksNotAcknowledged(risky)
    }

    var failures: [String] = []
    var keptBranches: [String] = []
    for check in checks {
      // Each delete rewrites the manifest; read it again for the next one.
      let target = try groupDeletionTarget(projectID: project.id, groupID: check.groupID, context: context)
      let outcome = try await performGroupDeletion(target, check: check, request: request, context: context)
      failures += outcome.failures.map { "\(check.groupName)/\($0.name) at \($0.path): \($0.reason)" }
      keptBranches += outcome.keptBranches
    }
    guard failures.isEmpty else {
      return WorkspaceRemovalOutcome(deletedFolder: false, failures: failures, keptBranches: keptBranches)
    }

    let deletedRoot: Bool
    do {
      let remaining = try loadGroupsManifest(rootPath: rootPath)
      try removeDefaultDirectory(rootPath: rootPath, manifest: remaining)
      deletedRoot = try removeRootIfOnlyStateRemains(rootPath: rootPath, manifest: remaining)
    } catch {
      return WorkspaceRemovalOutcome(
        deletedFolder: false, failures: [describe(error)], keptBranches: keptBranches)
    }
    try context.hierarchy.removeProject(project.id)
    return WorkspaceRemovalOutcome(deletedFolder: deletedRoot, keptBranches: keptBranches)
  }

  /// Unlinks the default links and removes the directory. Only symbolic
  /// links are removed, which never touches their targets; any other entry
  /// is user data and keeps the directory.
  static func removeDefaultDirectory(rootPath: String, manifest: WorkspaceGroupsManifest) throws {
    guard let group = manifest.defaultGroup else { return }
    let directory = absolutePath(group.path, rootPath: rootPath)
    guard entryExists(directory) else { return }
    guard WorkspaceOwnership.check(path: directory, rootPath: rootPath, manifest: manifest) == .owned else {
      logger.notice("default directory is not owned by the workspace; kept: \(directory, privacy: .private)")
      return
    }
    var keepsUserData = false
    for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
      let path = (directory as NSString).appendingPathComponent(name)
      if isSymbolicLink(path) || disposableEntries.contains(name) {
        try FileManager.default.removeItem(atPath: path)
      } else {
        keepsUserData = true
      }
    }
    if !keepsUserData {
      try FileManager.default.removeItem(atPath: directory)
    }
  }

  /// Deletes the root when nothing but the codans state directory is left
  /// in it, the root is not a symbolic link, and it neither holds nor sits
  /// inside a source project. Returns whether it was deleted.
  static func removeRootIfOnlyStateRemains(rootPath: String, manifest: WorkspaceGroupsManifest) throws -> Bool {
    guard !isSymbolicLink(rootPath) else { return false }
    let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().pathComponents
    for source in manifest.projects {
      let sourceComponents = URL(fileURLWithPath: source.sourceGitRoot).resolvingSymlinksInPath().pathComponents
      if sourceComponents.starts(with: root) || root.starts(with: sourceComponents) { return false }
    }
    let allowed = disposableEntries.union([WorkspaceLayout.stateDirectoryName])
    guard try FileManager.default.contentsOfDirectory(atPath: rootPath).allSatisfy(allowed.contains) else {
      return false
    }
    try FileManager.default.removeItem(atPath: rootPath)
    return true
  }

  // MARK: Helpers

  static func loadGroupsManifest(rootPath: String) throws -> WorkspaceGroupsManifest {
    do {
      return try WorkspaceManifestStore.loadGroups(rootPath: rootPath)
    } catch {
      throw WorkspaceError.manifestUnavailable(reason: String(describing: error))
    }
  }

  @discardableResult
  static func saveGroupsManifest(
    _ manifest: WorkspaceGroupsManifest, rootPath: String
  ) throws -> WorkspaceGroupsManifest {
    do {
      return try WorkspaceManifestStore.saveGroups(manifest, rootPath: rootPath)
    } catch {
      throw WorkspaceError.manifestUnavailable(reason: String(describing: error))
    }
  }

  /// Applies `change` to one group and writes the manifest at once, so a
  /// crash mid-delete leaves the file matching the disk.
  static func updateGroup(
    _ groupID: WorkspaceGroupID,
    in manifest: WorkspaceGroupsManifest,
    rootPath: String,
    _ change: (inout WorkspaceGroupsManifest.Group) -> Void
  ) throws -> WorkspaceGroupsManifest {
    var updated = manifest
    guard let index = updated.groups.firstIndex(where: { $0.id == groupID }) else {
      throw WorkspaceError.groupNotFound(groupID)
    }
    change(&updated.groups[index])
    return try saveGroupsManifest(updated, rootPath: rootPath)
  }

  static func absolutePath(_ relative: String, rootPath: String) -> String {
    relative == WorkspaceLayout.migratedGroupPath
      ? rootPath : (rootPath as NSString).appendingPathComponent(relative)
  }

  static func row(at path: String, in project: Project) -> Worktree? {
    let canonical = HierarchyManager.canonicalPath(path)
    return project.worktrees.first { HierarchyManager.canonicalPath($0.path) == canonical }
  }

  /// True when anything, a dangling symbolic link included, is at `path`.
  static func entryExists(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
  }

  static func isSymbolicLink(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
  }
}
