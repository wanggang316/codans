import CodansCore
import Foundation

// Named group creation. Every member is checked out on the group branch in
// `<root>/<group>/<name>`; the checkouts succeed or are rolled back as a
// whole, and setup commands run only after all of them exist.
extension WorkspaceClient {
  /// Per source, the same defaults ordinary worktree creation uses: the
  /// project's settings chained to the global ones. A source that is not a
  /// registered Project uses the global settings.
  @MainActor
  static func groupCreationDefaults(projectID: ProjectID, context: Context) async -> [MemberCreationOptions] {
    guard let project = try? workspaceProject(projectID, context: context),
      let manifest = try? loadManifest(rootPath: project.rootPath)
    else { return [] }
    let settings = context.settings()
    let projects = context.hierarchy.snapshot().projects
    let enabledProfiles = Set(settings.agents.enabledProfiles.map(\.id))
    var result: [MemberCreationOptions] = []
    for source in manifest.projects {
      let sourceGitRoot = canonical(source.sourceGitRoot)
      let sourceProject = projects.first { candidate in
        guard !candidate.isWorkspace, candidate.remoteHost == nil, let gitRoot = candidate.gitRoot else {
          return false
        }
        return canonical(gitRoot) == sourceGitRoot
      }
      let git = sourceProject.flatMap { settings.projects[$0.id]?.git }
      var baseRef = git?.worktreeBaseRef.flatMap { $0.isEmpty ? nil : $0 }
      if baseRef == nil {
        baseRef = try? await context.git.defaultRemoteBranchRef(URL(fileURLWithPath: sourceGitRoot, isDirectory: true))
      }
      let setup = git?.createScript?.command.trimmingCharacters(in: .whitespacesAndNewlines)
      result.append(
        MemberCreationOptions(
          sourceGitRoot: sourceGitRoot,
          name: source.name,
          baseRef: baseRef,
          fetch: git?.fetchRemoteOnWorktreeCreate ?? context.fetchRemoteOnCreate(),
          copyIgnored: git?.copyIgnoredOnWorktreeCreate ?? settings.worktree.copyIgnoredOnCreate,
          copyUntracked: git?.copyUntrackedOnWorktreeCreate ?? settings.worktree.copyUntrackedOnCreate,
          agentProfileID: git?.launchAgentProfileOnWorktreeCreate.flatMap { enabledProfiles.contains($0) ? $0 : nil },
          setupCommand: setup?.isEmpty == false ? setup : nil))
    }
    return result
  }

  @MainActor
  static func preflightGroup(_ plan: WorkspaceGroupPlan, context: Context) async -> WorkspacePreflight {
    var result = WorkspacePreflight()
    let project: Project
    let manifest: WorkspaceGroupsManifest
    do {
      project = try workspaceProject(plan.projectID, context: context)
      manifest = try loadManifest(rootPath: project.rootPath)
    } catch {
      result.groupIssues.append(.init(kind: .destinationExists, message: describe(error)))
      return result
    }
    result.groupIssues = groupIssues(plan, rootPath: project.rootPath, manifest: manifest)
    let branch = plan.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    if branch.isEmpty {
      result.groupIssues.append(.init(kind: .invalidBranchName, message: "Enter a branch name."))
    } else if await !context.git.isValidBranchName(URL(fileURLWithPath: NSHomeDirectory()), branch) {
      result.groupIssues.append(
        .init(kind: .invalidBranchName, message: "\u{201C}\(branch)\u{201D} is not a valid branch name."))
    }
    let listed = Set(manifest.projects.map { canonical($0.sourceGitRoot) })
    var names = Set<String>()
    for member in plan.members {
      var issues: [WorkspacePreflight.Issue] = []
      if !WorkspaceManifest.isValidChildPath(member.name) || !names.insert(member.name).inserted {
        issues.append(
          .init(kind: .destinationExists, message: "\u{201C}\(member.name)\u{201D} is not a usable folder name."))
      }
      if !listed.contains(canonical(member.sourceGitRoot)) {
        issues.append(.init(kind: .sourceNotRepository, message: "This project is not part of the workspace."))
      }
      issues += await memberIssues(member, branch: branch, context: context)
      if !issues.isEmpty {
        result.memberIssues[member.name] = issues
      }
    }
    return result
  }

  /// Name and group directory findings.
  private static func groupIssues(
    _ plan: WorkspaceGroupPlan, rootPath: String, manifest: WorkspaceGroupsManifest
  ) -> [WorkspacePreflight.Issue] {
    let name = plan.name
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return [.init(kind: .invalidGroupName, message: "Enter a group name.")]
    }
    if name == WorkspaceLayout.defaultGroupName {
      return [.init(kind: .reservedGroupName, message: "\u{201C}\(name)\u{201D} is reserved.")]
    }
    guard WorkspaceManifest.isValidChildPath(name), name != WorkspaceLayout.stateDirectoryName else {
      return [.init(kind: .invalidGroupName, message: "\u{201C}\(name)\u{201D} is not a valid folder name.")]
    }
    if manifest.groups.contains(where: { $0.name == name || $0.path == name }) {
      return [
        .init(kind: .duplicateGroupName, message: "The workspace already has a group named \u{201C}\(name)\u{201D}.")
      ]
    }
    let directory = (rootPath as NSString).appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: directory) {
      return [.init(kind: .destinationExists, message: "\(tilde(directory)) already exists.")]
    }
    return []
  }

  /// Repository findings for one member: the branch must be new in this
  /// repository and the base ref must resolve. A base ref on a remote that
  /// will be fetched first is not judged before the fetch.
  private static func memberIssues(
    _ member: MemberCreationOptions, branch: String, context: Context
  ) async -> [WorkspacePreflight.Issue] {
    let repo = URL(fileURLWithPath: canonical(member.sourceGitRoot), isDirectory: true)
    guard isDirectory(repo.path(percentEncoded: false)) else {
      return [.init(kind: .sourceNotRepository, message: "\(tilde(repo.path(percentEncoded: false))) is missing.")]
    }
    var issues: [WorkspacePreflight.Issue] = []
    if !branch.isEmpty {
      guard let locals = try? await context.git.localBranchNames(repo) else {
        return [
          .init(
            kind: .sourceNotRepository, message: "\(tilde(repo.path(percentEncoded: false))) is not a git repository.")
        ]
      }
      if locals.contains(branch) {
        issues.append(
          .init(
            kind: .localBranchExists,
            message: "Branch \u{201C}\(branch)\u{201D} already exists in \(member.name)."))
      }
    }
    if let baseRef = member.baseRef, !baseRef.isEmpty,
      !(member.fetch && WorkspaceCheckout.splitRemoteRef(baseRef) != nil),
      !looksLikeCommit(baseRef)
    {
      let refs = (try? await context.git.branchRefs(repo)) ?? []
      if !refs.contains(baseRef) {
        issues.append(
          .init(kind: .baseRefMissing, message: "\u{201C}\(baseRef)\u{201D} does not exist in \(member.name)."))
      }
    }
    return issues
  }

  private static func looksLikeCommit(_ ref: String) -> Bool {
    (7...40).contains(ref.count) && ref.allSatisfy(\.isHexDigit)
  }

  @MainActor
  static func performCreateGroup(
    _ plan: WorkspaceGroupPlan,
    context: Context,
    yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
  ) async throws {
    let preflight = await preflightGroup(plan, context: context)
    guard !preflight.hasBlockingIssues else { throw WorkspaceError.groupPreflightFailed(preflight) }
    let project = try workspaceProject(plan.projectID, context: context)
    let rootPath = project.rootPath
    let branch = plan.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let groupPath = (rootPath as NSString).appendingPathComponent(plan.name)

    var ledger = WorkspaceMaterializationLedger()
    let group: WorkspaceGroupsManifest.Group
    do {
      try Task.checkCancellation()
      try FileManager.default.createDirectory(atPath: groupPath, withIntermediateDirectories: true)
      ledger.record(.createdDirectory(path: groupPath))
      for member in plan.members {
        try Task.checkCancellation()
        try await checkOut(
          member, branch: branch, groupPath: groupPath, ledger: &ledger, context: context, yield: yield)
      }
      group = WorkspaceGroupsManifest.Group(
        id: WorkspaceGroupID(), name: plan.name, kind: .named, path: plan.name, branch: branch,
        createdAt: Date(),
        members: plan.members.map { member in
          WorkspaceGroupsManifest.Member(
            id: WorkspaceMemberID(), name: member.name, path: "\(plan.name)/\(member.name)",
            sourceGitRoot: canonical(member.sourceGitRoot), checkoutMode: .newBranch, branch: branch,
            baseRef: member.baseRef, createdBranch: true)
        })
      var manifest = try loadManifest(rootPath: rootPath)
      manifest.groups.append(group)
      try saveManifest(manifest, rootPath: rootPath)
      yield(.manifestWritten)
    } catch {
      yield(.rollingBack)
      let failures = await rollback(ledger, context: context)
      yield(.rolledBack(failures: failures))
      throw mapCancellation(error)
    }

    await context.hierarchy.reconcileDiscoveredWorktrees(plan.projectID)
    await reconcileSources(plan.members.map { canonical($0.sourceGitRoot) }, hierarchy: context.hierarchy)
    let rows = context.hierarchy.snapshot().projects.first { $0.id == plan.projectID }?.worktrees ?? []
    func rowID(at path: String) -> WorktreeID? {
      let target = canonical(path)
      return rows.first { $0.workspaceSlot?.groupID == group.id && canonical($0.path) == target }?.id
    }
    guard let groupRowID = rowID(at: groupPath) else { throw WorkspaceError.memberNotRegistered(name: plan.name) }
    var members: [GroupCreationResult.Member] = []
    for member in plan.members {
      let path = (groupPath as NSString).appendingPathComponent(member.name)
      guard let id = rowID(at: path) else { throw WorkspaceError.memberNotRegistered(name: member.name) }
      members.append(.init(name: member.name, worktreeID: id, agentProfileID: member.agentProfileID))
    }
    yield(.groupRegistered(groupID: group.id, memberWorktreeIDs: members.map(\.worktreeID)))

    var setupFailures: [GroupCreationResult.SetupFailure] = []
    for member in plan.members {
      guard let command = member.setupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
      else { continue }
      try Task.checkCancellation()
      yield(.setupStarted(name: member.name))
      let directory = URL(
        fileURLWithPath: (groupPath as NSString).appendingPathComponent(member.name), isDirectory: true)
      let name = member.name
      let outcome = await context.git.runSetupScript(directory, command) { line in
        yield(.progressLine(name: name, line: line))
      }
      if let reason = outcome.failureReason {
        setupFailures.append(.init(name: member.name, reason: reason))
        yield(.setupFailed(name: member.name, reason: reason))
      }
    }
    yield(
      .groupCreated(
        GroupCreationResult(
          projectID: plan.projectID, groupID: group.id, groupWorktreeID: groupRowID, members: members,
          setupFailures: setupFailures)))
  }

  /// Optional fetch, then `wt sw` into the member folder without setup.
  /// The branch and worktree are recorded when they exist afterwards, even
  /// when the checkout failed part way (a copy step runs after `git
  /// worktree add`), so the rollback undoes exactly what is on disk.
  @MainActor
  private static func checkOut(
    _ member: MemberCreationOptions,
    branch: String,
    groupPath: String,
    ledger: inout WorkspaceMaterializationLedger,
    context: Context,
    yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
  ) async throws {
    let name = member.name
    let repoRoot = canonical(member.sourceGitRoot)
    let repo = URL(fileURLWithPath: repoRoot, isDirectory: true)
    let destination = (groupPath as NSString).appendingPathComponent(name)
    let baseRef = member.baseRef.flatMap { $0.isEmpty ? nil : $0 }
    let branchExisted = (try? await context.git.localBranchNames(repo).contains(branch)) ?? true
    do {
      if member.fetch,
        let remote = await remoteToFetch(
          for: .newBranch(branch: branch, baseRef: baseRef), sourceURL: repo, git: context.git)
      {
        yield(.memberStarted(name: name, phase: .fetching))
        try await context.git.fetchRemote(repo, remote)
      }
      try Task.checkCancellation()
      yield(.memberStarted(name: name, phase: .checkingOut))
      let spec = CreateWorktreeSpec(
        repoRoot: repo,
        baseDirectory: URL(fileURLWithPath: groupPath, isDirectory: true),
        name: branch,
        baseRef: baseRef ?? "",
        fetchOrigin: false,
        copyIgnored: member.copyIgnored,
        copyUntracked: member.copyUntracked,
        setupCommand: nil,
        pathOverride: URL(fileURLWithPath: destination, isDirectory: true))
      var finished = false
      do {
        for try await event in context.git.createWorktreeStream(spec) {
          switch event {
          case .progressLine(let line): yield(.progressLine(name: name, line: line))
          case .finished: finished = true
          case .setupPhaseBegan: break
          }
        }
        try Task.checkCancellation()
        guard finished else {
          throw GitWorktreeError.commandFailed(command: "wt sw", stderr: "no worktree was created")
        }
      } catch {
        if !branchExisted, (try? await context.git.localBranchNames(repo).contains(branch)) ?? true {
          ledger.record(.createdBranch(repoRoot: repoRoot, branch: branch))
        }
        if FileManager.default.fileExists(atPath: destination) {
          ledger.record(.addedWorktree(repoRoot: repoRoot, path: destination))
        }
        throw error
      }
      if !branchExisted {
        ledger.record(.createdBranch(repoRoot: repoRoot, branch: branch))
      }
      ledger.record(.addedWorktree(repoRoot: repoRoot, path: destination))
      yield(.memberFinished(name: name))
    } catch {
      if !(error is CancellationError) {
        yield(.memberFailed(name: name, message: describe(error)))
      }
      throw error
    }
  }
}
