import CodansCore
import ComposableArchitecture
import Foundation
import os

/// Why a workspace could not be created or extended. Every case names the
/// path or member involved so the CLI and the sheet can show it verbatim.
nonisolated enum WorkspaceError: LocalizedError, Equatable, Sendable {
  case invalidPlan([WorkspacePlan.ValidationIssue])
  case rootAlreadyRegistered(path: String)
  case rootIsFile(path: String)
  case rootAlreadyWorkspace(path: String)
  /// The workspace root would sit inside a repository. Older builds probe a
  /// folder project for a git root on every reconcile and would adopt that
  /// repository, so this is refused up front rather than tolerated.
  case rootInsideRepository(path: String, gitRoot: String)
  case destinationExists(path: String)
  case sourceNotRepository(path: String)
  case invalidBranchName(String, repository: String)
  case notWorkspace(ProjectID)
  case memberExists(name: String)
  case memberNotRegistered(name: String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .invalidPlan(let issues):
      return issues.map(\.description).joined(separator: "; ")
    case .rootAlreadyRegistered(let path):
      return "\(path) is already a project in codans"
    case .rootIsFile(let path):
      return "\(path) is a file, not a folder"
    case .rootAlreadyWorkspace(let path):
      return "\(path) is already a workspace (it carries \(WorkspaceLayout.rootRelativeManifestPath))"
    case .rootInsideRepository(let path, let gitRoot):
      return "\(path) is inside the repository at \(gitRoot); a workspace root must not be inside a git repository"
    case .destinationExists(let path):
      return "\(path) already exists"
    case .sourceNotRepository(let path):
      return "\(path) is not the root of a git repository"
    case .invalidBranchName(let branch, let repository):
      return "\"\(branch)\" is not a valid branch name for \(repository)"
    case .notWorkspace(let id):
      return "project \(id) is not a workspace"
    case .memberExists(let name):
      return "the workspace already has a repository named \"\(name)\""
    case .memberNotRegistered(let name):
      return "\"\(name)\" was checked out but did not appear in the catalog"
    case .cancelled:
      return "workspace creation was cancelled; everything it created has been removed"
    }
  }
}

/// Creates workspaces and adds repositories to them. The GUI sheet and the
/// `workspace.*` IPC handlers share this one orchestration so both entry
/// points materialize, record, and register identically.
///
/// Order of operations, chosen so the catalog only ever sees a workspace
/// whose folders exist: validate → preflight the root and every source →
/// create the root folder → `git worktree add` each member → write the
/// manifest → register the Project → reconcile it (which fills the child
/// rows from git) and each source Project (which shows its mirror rows).
/// Any failure or cancellation before the manifest is written rolls back
/// exactly what the ledger recorded.
struct WorkspaceClient: Sendable {
  var create: @MainActor @Sendable (_ plan: WorkspacePlan) async throws -> ProjectID
  var add:
    @MainActor @Sendable (_ projectID: ProjectID, _ member: WorkspacePlan.Member) async throws
      -> WorktreeID
}

extension WorkspaceClient: TestDependencyKey {
  static let testValue = WorkspaceClient(
    create: unimplemented("WorkspaceClient.create", placeholder: ProjectID()),
    add: unimplemented("WorkspaceClient.add", placeholder: WorktreeID())
  )
}

extension DependencyValues {
  var workspaceClient: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}

// MARK: - Live

extension WorkspaceClient {
  nonisolated private static let logger = Logger(
    subsystem: "com.gumpw.codans.hierarchy", category: "workspace")

  static func live(
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI
  ) -> WorkspaceClient {
    WorkspaceClient(
      create: { plan in
        try await Self.create(
          plan, hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient, gitCLI: gitCLI)
      },
      add: { projectID, member in
        try await Self.add(
          projectID: projectID, member: member,
          hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient, gitCLI: gitCLI)
      }
    )
  }

  /// A member after preflight: canonical source root, absolute destination,
  /// and a checkout whose base ref has been resolved.
  private struct ResolvedMember: Sendable {
    let member: WorkspacePlan.Member
    let sourceGitRoot: String
    let destination: String
    let checkout: WorkspaceCheckout
  }

  @MainActor
  private static func create(
    _ plan: WorkspacePlan,
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI
  ) async throws -> ProjectID {
    let issues = plan.validate()
    guard issues.isEmpty else { throw WorkspaceError.invalidPlan(issues) }
    let rootPath = canonical(plan.rootPath)
    try await preflightRoot(rootPath, hierarchy: hierarchy, gitCLI: gitCLI)
    var resolved: [ResolvedMember] = []
    for member in plan.members {
      resolved.append(
        try await resolve(member, rootPath: rootPath, gitWorktreeClient: gitWorktreeClient, gitCLI: gitCLI))
    }

    var ledger = WorkspaceMaterializationLedger()
    do {
      try Task.checkCancellation()
      let fileManager = FileManager.default
      if !fileManager.fileExists(atPath: rootPath) {
        try fileManager.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        ledger.record(.createdDirectory(path: rootPath))
      }
      for entry in resolved {
        try Task.checkCancellation()
        try await materialize(entry, ledger: &ledger, gitWorktreeClient: gitWorktreeClient)
      }
      var materialized = plan
      materialized.rootPath = rootPath
      materialized.members = resolved.map { entry in
        var member = entry.member
        member.sourceGitRoot = entry.sourceGitRoot
        member.checkout = entry.checkout
        return member
      }
      try WorkspaceManifestStore.save(materialized.manifest(), rootPath: rootPath)
    } catch {
      await rollback(ledger, gitWorktreeClient: gitWorktreeClient)
      throw error is CancellationError ? WorkspaceError.cancelled : error
    }

    let projectID = hierarchy.addWorkspaceProject(plan.title, rootPath)
    await hierarchy.reconcileDiscoveredWorktrees(projectID)
    await reconcileSources(resolved.map(\.sourceGitRoot), hierarchy: hierarchy)
    return projectID
  }

  @MainActor
  private static func add(
    projectID: ProjectID,
    member: WorkspacePlan.Member,
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI
  ) async throws -> WorktreeID {
    let issues = WorkspacePlan.validate(members: [member])
    guard issues.isEmpty else { throw WorkspaceError.invalidPlan(issues) }
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    let rootPath = project.rootPath
    var manifest = try WorkspaceManifestStore.load(rootPath: rootPath)
    guard !manifest.repositories.contains(where: { $0.name == member.name }) else {
      throw WorkspaceError.memberExists(name: member.name)
    }
    let entry = try await resolve(
      member, rootPath: rootPath, gitWorktreeClient: gitWorktreeClient, gitCLI: gitCLI)

    var ledger = WorkspaceMaterializationLedger()
    do {
      try Task.checkCancellation()
      try await materialize(entry, ledger: &ledger, gitWorktreeClient: gitWorktreeClient)
      var stored = entry.member
      stored.sourceGitRoot = entry.sourceGitRoot
      stored.checkout = entry.checkout
      manifest.repositories.append(stored.manifestEntry)
      try WorkspaceManifestStore.save(manifest, rootPath: rootPath)
    } catch {
      await rollback(ledger, gitWorktreeClient: gitWorktreeClient)
      throw error is CancellationError ? WorkspaceError.cancelled : error
    }

    await hierarchy.reconcileDiscoveredWorktrees(projectID)
    await reconcileSources([entry.sourceGitRoot], hierarchy: hierarchy)
    guard
      let worktreeID = hierarchy.snapshot().projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { HierarchyManager.canonicalPath($0.path) == entry.destination })?.id
    else { throw WorkspaceError.memberNotRegistered(name: member.name) }
    return worktreeID
  }

  // MARK: Preflight

  @MainActor
  private static func preflightRoot(
    _ rootPath: String,
    hierarchy: HierarchyClient,
    gitCLI: GitWorktreeCLI
  ) async throws {
    if hierarchy.isPathRegistered(rootPath) != nil {
      throw WorkspaceError.rootAlreadyRegistered(path: rootPath)
    }
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw WorkspaceError.rootIsFile(path: rootPath) }
      if WorkspaceManifestStore.hasManifest(rootPath: rootPath) {
        throw WorkspaceError.rootAlreadyWorkspace(path: rootPath)
      }
    }
    // Probe the nearest folder that exists: the root itself, or the ancestor
    // it will be created under.
    var probe = rootPath
    while !FileManager.default.fileExists(atPath: probe), probe != "/" {
      probe = (probe as NSString).deletingLastPathComponent
    }
    if let gitRoot = try? await gitCLI.discoverGitRoot(candidatePath: probe), !gitRoot.isEmpty {
      throw WorkspaceError.rootInsideRepository(path: rootPath, gitRoot: gitRoot)
    }
  }

  private static func resolve(
    _ member: WorkspacePlan.Member,
    rootPath: String,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI
  ) async throws -> ResolvedMember {
    let source = canonical(member.sourceGitRoot)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let discovered = try? await gitCLI.discoverGitRoot(candidatePath: source),
      HierarchyManager.canonicalPath(discovered) == source
    else { throw WorkspaceError.sourceNotRepository(path: source) }
    let destination = (rootPath as NSString).appendingPathComponent(member.name)
    guard !FileManager.default.fileExists(atPath: destination) else {
      throw WorkspaceError.destinationExists(path: destination)
    }
    let sourceURL = URL(fileURLWithPath: source, isDirectory: true)
    let branch = member.checkout.branch
    guard await gitWorktreeClient.isValidBranchName(sourceURL, branch) else {
      throw WorkspaceError.invalidBranchName(branch, repository: source)
    }
    var checkout = member.checkout
    if case .newBranch(let name, nil) = checkout {
      // Start from the repository's default remote branch when the caller
      // named none; git's own default (HEAD) applies when that is unknown.
      let base = try? await gitWorktreeClient.defaultRemoteBranchRef(sourceURL)
      checkout = .newBranch(branch: name, baseRef: base)
    }
    return ResolvedMember(
      member: member, sourceGitRoot: source, destination: destination, checkout: checkout)
  }

  // MARK: Materialize / rollback

  private static func materialize(
    _ entry: ResolvedMember,
    ledger: inout WorkspaceMaterializationLedger,
    gitWorktreeClient: GitWorktreeClient
  ) async throws {
    try await gitWorktreeClient.addWorktreeAt(
      URL(fileURLWithPath: entry.sourceGitRoot, isDirectory: true),
      URL(fileURLWithPath: entry.destination, isDirectory: true),
      entry.checkout
    )
    if case .newBranch(let branch, _) = entry.checkout {
      ledger.record(.createdBranch(repoRoot: entry.sourceGitRoot, branch: branch))
    }
    ledger.record(.addedWorktree(repoRoot: entry.sourceGitRoot, path: entry.destination))
  }

  /// Undo in reverse order. Runs detached so cancelling the creation task
  /// cannot SIGTERM the cleanup git subprocesses mid-flight; the caller
  /// still awaits the result before rethrowing.
  private static func rollback(
    _ ledger: WorkspaceMaterializationLedger,
    gitWorktreeClient: GitWorktreeClient
  ) async {
    guard !ledger.isEmpty else { return }
    let steps = ledger.rollbackSteps
    let task = Task.detached {
      for step in steps {
        switch step {
        case .addedWorktree(let repoRoot, let path):
          do {
            try await gitWorktreeClient.removeWorktree(
              URL(fileURLWithPath: repoRoot, isDirectory: true),
              URL(fileURLWithPath: path, isDirectory: true))
          } catch {
            logger.warning("rollback could not remove worktree at \(path, privacy: .private): \(error)")
          }
        case .createdBranch(let repoRoot, let branch):
          _ = await gitWorktreeClient.deleteBranchIfExists(
            URL(fileURLWithPath: repoRoot, isDirectory: true), branch)
        case .createdDirectory(let path):
          do {
            try FileManager.default.removeItem(atPath: path)
          } catch {
            logger.warning("rollback could not remove \(path, privacy: .private): \(error)")
          }
        }
      }
    }
    await task.value
  }

  // MARK: Helpers

  /// Every registered Project whose repository is one of `sourceRoots` gets
  /// a reconcile so the new checkout shows up as its mirror row right away.
  @MainActor
  private static func reconcileSources(_ sourceRoots: [String], hierarchy: HierarchyClient) async {
    let wanted = Set(sourceRoots)
    let projects = hierarchy.snapshot().projects.filter { project in
      guard project.remoteHost == nil, let gitRoot = project.gitRoot else { return false }
      return wanted.contains(HierarchyManager.canonicalPath(gitRoot))
    }
    for project in projects {
      await hierarchy.reconcileDiscoveredWorktrees(project.id)
    }
  }

  private static func canonical(_ path: String) -> String {
    HierarchyManager.canonicalPath((path as NSString).expandingTildeInPath)
  }
}
