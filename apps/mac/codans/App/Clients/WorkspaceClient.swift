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
  /// The folder a remote would be cloned into exists and is not a clone of
  /// that remote, so it can neither be reused nor overwritten.
  case cloneDestinationTaken(path: String, remoteURL: String)
  case invalidBranchName(String, repository: String)
  case notWorkspace(ProjectID)
  case memberExists(name: String)
  case memberNotRegistered(name: String)
  case memberNotFound(name: String)
  /// The row is a hand-written manifest entry with no recorded source
  /// repository, so there is nothing to unregister it from.
  case memberWithoutSource(name: String)
  case cannotDropRoot
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
      return "\(path) is not a git repository"
    case .cloneDestinationTaken(let path, let remoteURL):
      return "\(path) already exists and is not a clone of \(remoteURL)"
    case .invalidBranchName(let branch, let repository):
      return "\"\(branch)\" is not a valid branch name for \(repository)"
    case .notWorkspace(let id):
      return "project \(id) is not a workspace"
    case .memberExists(let name):
      return "the workspace already has a repository named \"\(name)\""
    case .memberNotRegistered(let name):
      return "\"\(name)\" was checked out but did not appear in the catalog"
    case .memberNotFound(let name):
      return "the workspace has no repository named \"\(name)\""
    case .memberWithoutSource(let name):
      return "\"\(name)\" records no source repository, so its checkout cannot be unregistered"
    case .cannotDropRoot:
      return "the workspace root is not a member; remove the workspace instead"
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
/// create the root folder → for each member clone its remote if it has one,
/// fetch the remote its base ref names, `git worktree add` → write the
/// manifest → register the Project → reconcile it (which fills the child
/// rows from git) and each source Project (which shows its mirror rows).
/// Any failure or cancellation before the manifest is written rolls back
/// exactly what the ledger recorded.
///
/// The streaming variants report each step as a `WorkspaceCreationEvent`
/// and can be stopped by token; `create` / `add` drain them.
struct WorkspaceClient: Sendable {
  var create: @MainActor @Sendable (_ plan: WorkspacePlan) async throws -> ProjectID
  var add:
    @MainActor @Sendable (_ projectID: ProjectID, _ member: WorkspacePlan.Member) async throws
      -> WorktreeID
  /// Remove one member: unregister its checkout from the source repository
  /// (relocate-then-prune), optionally delete its branch, drop it from the
  /// manifest, and remove its row plus any mirror row under the source
  /// Project. Returns a note when the branch was kept (checked out elsewhere).
  var drop:
    @MainActor @Sendable (_ projectID: ProjectID, _ worktreeID: WorktreeID, _ deleteBranch: Bool)
      async throws -> String?
  /// Remove the workspace. With the default cleanup only the catalog entry
  /// goes; with `deleteFiles` every member is unregistered first and the
  /// folder is deleted only when all of them were.
  var remove:
    @MainActor @Sendable (_ projectID: ProjectID, _ cleanup: WorkspaceCleanup) async throws
      -> WorkspaceRemovalOutcome

  /// `create` as a stream of progress events. Finishes with `.registered`
  /// on success, or throws the underlying `WorkspaceError` /
  /// `GitWorktreeError` after rolling back (a `.memberFailed` event names
  /// the row first). `cancelCreation(token)` stops it and rolls back.
  var createStream:
    @MainActor @Sendable (_ plan: WorkspacePlan, _ token: UUID)
      -> AsyncThrowingStream<WorkspaceCreationEvent, Error> = { _, _ in
        AsyncThrowingStream { $0.finish(throwing: WorkspaceError.cancelled) }
      }
  /// `add` as a stream; `.registered` carries the new row's id.
  var addStream:
    @MainActor @Sendable (_ projectID: ProjectID, _ member: WorkspacePlan.Member, _ token: UUID)
      -> AsyncThrowingStream<WorkspaceCreationEvent, Error> = { _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: WorkspaceError.cancelled) }
      }
  /// Stops the run started with `token`. The stream keeps flowing until it
  /// has reported the rollback, then finishes with `WorkspaceError.cancelled`.
  var cancelCreation: @Sendable (_ token: UUID) async -> Void = { _ in }
  /// Everything `create` would refuse, collected without side effects so a
  /// form can show it live. Never throws; an empty result means go.
  var preflight: @MainActor @Sendable (_ plan: WorkspacePlan) async -> WorkspacePreflight = { _ in
    WorkspacePreflight()
  }
}

extension WorkspaceClient: TestDependencyKey {
  static let testValue = WorkspaceClient(
    create: unimplemented("WorkspaceClient.create", placeholder: ProjectID()),
    add: unimplemented("WorkspaceClient.add", placeholder: WorktreeID()),
    drop: unimplemented("WorkspaceClient.drop", placeholder: nil),
    remove: unimplemented(
      "WorkspaceClient.remove", placeholder: WorkspaceRemovalOutcome(deletedFolder: false)),
    createStream: unimplemented(
      "WorkspaceClient.createStream", placeholder: AsyncThrowingStream { $0.finish() }),
    addStream: unimplemented(
      "WorkspaceClient.addStream", placeholder: AsyncThrowingStream { $0.finish() }),
    cancelCreation: unimplemented("WorkspaceClient.cancelCreation"),
    preflight: unimplemented("WorkspaceClient.preflight", placeholder: WorkspacePreflight())
  )
}

extension DependencyValues {
  var workspaceClient: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}

/// Runs in flight, keyed by the caller's token, so `cancelCreation` can
/// reach the task driving a stream from any isolation context.
nonisolated final class WorkspaceCreationRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func register(_ token: UUID, _ task: Task<Void, Never>) {
    lock.lock()
    tasks[token] = task
    lock.unlock()
  }

  func cancel(_ token: UUID) {
    lock.lock()
    let task = tasks[token]
    lock.unlock()
    task?.cancel()
  }

  func remove(_ token: UUID) {
    lock.lock()
    tasks.removeValue(forKey: token)
    lock.unlock()
  }
}

// MARK: - Live

extension WorkspaceClient {
  nonisolated private static let logger = Logger(
    subsystem: "com.gumpw.codans.hierarchy", category: "workspace")

  /// Everything the orchestration reaches for, bundled so the static steps
  /// take one argument.
  private struct Context: Sendable {
    let hierarchy: HierarchyClient
    let git: GitWorktreeClient
    let cli: GitWorktreeCLI
    /// Whether to `git fetch` the remote a base ref names before checking
    /// out — the same switch worktree creation honours.
    let fetchRemoteOnCreate: @MainActor @Sendable () -> Bool
    let registry: WorkspaceCreationRegistry
  }

  static func live(
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient,
    gitCLI: GitWorktreeCLI,
    fetchRemoteOnCreate: @escaping @MainActor @Sendable () -> Bool = { true }
  ) -> WorkspaceClient {
    let context = Context(
      hierarchy: hierarchy, git: gitWorktreeClient, cli: gitCLI,
      fetchRemoteOnCreate: fetchRemoteOnCreate, registry: WorkspaceCreationRegistry())
    return WorkspaceClient(
      create: { plan in
        try await drain(makeCreateStream(plan, token: UUID(), context: context)).projectID
      },
      add: { projectID, member in
        let registered = try await drain(
          makeAddStream(projectID: projectID, member: member, token: UUID(), context: context))
        guard let worktreeID = registered.worktreeID else {
          throw WorkspaceError.memberNotRegistered(name: member.name)
        }
        return worktreeID
      },
      drop: { projectID, worktreeID, deleteBranch in
        try await Self.drop(
          projectID: projectID, worktreeID: worktreeID, deleteBranch: deleteBranch,
          hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient)
      },
      remove: { projectID, cleanup in
        try await Self.remove(
          projectID: projectID, cleanup: cleanup,
          hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient)
      },
      createStream: { plan, token in
        makeCreateStream(plan, token: token, context: context)
      },
      addStream: { projectID, member, token in
        makeAddStream(projectID: projectID, member: member, token: token, context: context)
      },
      cancelCreation: { token in
        context.registry.cancel(token)
      },
      preflight: { plan in
        await preflight(plan, context: context)
      }
    )
  }

  // MARK: Streams

  @MainActor
  private static func makeCreateStream(
    _ plan: WorkspacePlan, token: UUID, context: Context
  ) -> AsyncThrowingStream<WorkspaceCreationEvent, Error> {
    makeStream(token: token, registry: context.registry) { yield in
      _ = try await performCreate(plan, context: context, yield: yield)
    }
  }

  @MainActor
  private static func makeAddStream(
    projectID: ProjectID, member: WorkspacePlan.Member, token: UUID, context: Context
  ) -> AsyncThrowingStream<WorkspaceCreationEvent, Error> {
    makeStream(token: token, registry: context.registry) { yield in
      _ = try await performAdd(projectID: projectID, member: member, context: context, yield: yield)
    }
  }

  /// Drives `body` on the main actor inside a registered task. A consumer
  /// that stops iterating cancels the task, which the steps observe between
  /// subprocesses; the rollback then runs detached and finishes on its own.
  @MainActor
  private static func makeStream(
    token: UUID,
    registry: WorkspaceCreationRegistry,
    body:
      @escaping @MainActor @Sendable (
        _ yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
      ) async throws -> Void
  ) -> AsyncThrowingStream<WorkspaceCreationEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task { @MainActor in
        do {
          try await body { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        registry.remove(token)
      }
      registry.register(token, task)
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func drain(
    _ stream: AsyncThrowingStream<WorkspaceCreationEvent, Error>
  ) async throws -> (projectID: ProjectID, worktreeID: WorktreeID?) {
    var registered: (ProjectID, WorktreeID?)?
    for try await event in stream {
      if case .registered(let projectID, let worktreeID) = event {
        registered = (projectID, worktreeID)
      }
    }
    guard let registered else { throw WorkspaceError.cancelled }
    return registered
  }

  // MARK: Create / add

  @MainActor
  private static func performCreate(
    _ plan: WorkspacePlan,
    context: Context,
    yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
  ) async throws -> ProjectID {
    let issues = plan.validate()
    guard issues.isEmpty else { throw WorkspaceError.invalidPlan(issues) }
    let rootPath = canonical(plan.rootPath)
    try await preflightRoot(rootPath, context: context)
    var resolved: [ResolvedMember] = []
    for member in plan.members {
      resolved.append(try await resolve(member, rootPath: rootPath, context: context))
    }

    var ledger = WorkspaceMaterializationLedger()
    var members: [WorkspacePlan.Member] = []
    do {
      try Task.checkCancellation()
      let fileManager = FileManager.default
      if !fileManager.fileExists(atPath: rootPath) {
        try fileManager.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        ledger.record(.createdDirectory(path: rootPath))
      }
      for entry in resolved {
        try Task.checkCancellation()
        members.append(try await materialize(entry, ledger: &ledger, context: context, yield: yield))
      }
      var materialized = plan
      materialized.rootPath = rootPath
      materialized.members = members
      try WorkspaceManifestStore.save(materialized.manifest(), rootPath: rootPath)
      yield(.manifestWritten)
    } catch {
      yield(.rollingBack)
      let failures = await rollback(ledger, context: context)
      yield(.rolledBack(failures: failures))
      throw error is CancellationError ? WorkspaceError.cancelled : error
    }

    let projectID = context.hierarchy.addWorkspaceProject(plan.title, rootPath)
    await context.hierarchy.reconcileDiscoveredWorktrees(projectID)
    await reconcileSources(members.map(\.sourceGitRoot), hierarchy: context.hierarchy)
    yield(.registered(projectID: projectID, worktreeID: nil))
    return projectID
  }

  @MainActor
  private static func performAdd(
    projectID: ProjectID,
    member: WorkspacePlan.Member,
    context: Context,
    yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
  ) async throws -> WorktreeID {
    let issues = WorkspacePlan.validate(members: [member])
    guard issues.isEmpty else { throw WorkspaceError.invalidPlan(issues) }
    guard let project = context.hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    let rootPath = project.rootPath
    var manifest = try WorkspaceManifestStore.load(rootPath: rootPath)
    guard !manifest.repositories.contains(where: { $0.name == member.name }) else {
      throw WorkspaceError.memberExists(name: member.name)
    }
    let entry = try await resolve(member, rootPath: rootPath, context: context)

    var ledger = WorkspaceMaterializationLedger()
    let stored: WorkspacePlan.Member
    do {
      try Task.checkCancellation()
      stored = try await materialize(entry, ledger: &ledger, context: context, yield: yield)
      manifest.repositories.append(stored.manifestEntry)
      try WorkspaceManifestStore.save(manifest, rootPath: rootPath)
      yield(.manifestWritten)
    } catch {
      yield(.rollingBack)
      let failures = await rollback(ledger, context: context)
      yield(.rolledBack(failures: failures))
      throw error is CancellationError ? WorkspaceError.cancelled : error
    }

    await context.hierarchy.reconcileDiscoveredWorktrees(projectID)
    await reconcileSources([stored.sourceGitRoot], hierarchy: context.hierarchy)
    guard
      let worktreeID = context.hierarchy.snapshot().projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { HierarchyManager.canonicalPath($0.path) == entry.destination })?.id
    else { throw WorkspaceError.memberNotRegistered(name: member.name) }
    yield(.registered(projectID: projectID, worktreeID: worktreeID))
    return worktreeID
  }

  // MARK: Drop / remove

  @MainActor
  private static func drop(
    projectID: ProjectID,
    worktreeID: WorktreeID,
    deleteBranch: Bool,
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient
  ) async throws -> String? {
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    guard let row = project.worktrees.first(where: { $0.id == worktreeID }) else {
      throw WorkspaceError.memberNotFound(name: worktreeID.description)
    }
    guard row.path != project.rootPath else { throw WorkspaceError.cannotDropRoot }
    let rootPath = project.rootPath
    var manifest = try WorkspaceManifestStore.load(rootPath: rootPath)
    let canonicalRow = HierarchyManager.canonicalPath(row.path)
    let entryIndex = manifest.repositories.firstIndex {
      HierarchyManager.canonicalPath($0.resolvedPath(rootPath: rootPath)) == canonicalRow
    }

    let warning = try await unregister(
      row, sourceGitRoot: row.sourceGitRoot ?? entryIndex.flatMap { manifest.repositories[$0].sourceGitRoot },
      deleteBranch: deleteBranch, hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient)

    if let entryIndex {
      manifest.repositories.remove(at: entryIndex)
      try WorkspaceManifestStore.save(manifest, rootPath: rootPath)
    }
    try hierarchy.removeWorktree(worktreeID, projectID)
    removeMirrorRows(forCanonicalPath: canonicalRow, hierarchy: hierarchy)
    return warning
  }

  @MainActor
  private static func remove(
    projectID: ProjectID,
    cleanup: WorkspaceCleanup,
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient
  ) async throws -> WorkspaceRemovalOutcome {
    guard let project = hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    guard cleanup.deleteFiles else {
      try hierarchy.removeProject(projectID)
      return WorkspaceRemovalOutcome(deletedFolder: false)
    }
    let rootPath = project.rootPath
    let manifest = try? WorkspaceManifestStore.load(rootPath: rootPath)
    var failures: [String] = []
    var keptBranches: [String] = []
    for row in project.worktrees where row.path != project.rootPath {
      let canonicalRow = HierarchyManager.canonicalPath(row.path)
      let entry = manifest?.repositories.first {
        HierarchyManager.canonicalPath($0.resolvedPath(rootPath: rootPath)) == canonicalRow
      }
      do {
        if let warning = try await unregister(
          row, sourceGitRoot: row.sourceGitRoot ?? entry?.sourceGitRoot,
          deleteBranch: cleanup.deleteBranches, hierarchy: hierarchy,
          gitWorktreeClient: gitWorktreeClient)
        {
          keptBranches.append("\(row.name): \(warning)")
        }
        removeMirrorRows(forCanonicalPath: canonicalRow, hierarchy: hierarchy)
      } catch {
        logger.warning("could not unregister workspace member \(row.name, privacy: .public): \(error)")
        failures.append(row.name)
      }
    }
    // The entry goes regardless; the folder only when every checkout is
    // gone, since deleting it under a live registration strands the source
    // repository's `git worktree list`.
    try hierarchy.removeProject(projectID)
    var deletedFolder = false
    if failures.isEmpty {
      do {
        try FileManager.default.removeItem(atPath: rootPath)
        deletedFolder = true
      } catch {
        logger.warning("could not delete workspace folder \(rootPath, privacy: .private): \(error)")
        failures.append("folder")
      }
    }
    return WorkspaceRemovalOutcome(
      deletedFolder: deletedFolder, failures: failures, keptBranches: keptBranches)
  }

  /// Tear down the row's terminals, move its checkout out from under the
  /// source repository, and optionally delete the branch. Returns the
  /// kept-branch note when git refused the deletion.
  @MainActor
  private static func unregister(
    _ row: Worktree,
    sourceGitRoot: String?,
    deleteBranch: Bool,
    hierarchy: HierarchyClient,
    gitWorktreeClient: GitWorktreeClient
  ) async throws -> String? {
    guard let sourceGitRoot else { throw WorkspaceError.memberWithoutSource(name: row.name) }
    hierarchy.tearDownWorktreeSurfaces(row.id)
    let sourceURL = URL(fileURLWithPath: sourceGitRoot, isDirectory: true)
    try await gitWorktreeClient.removeWorktree(
      sourceURL, URL(fileURLWithPath: row.path, isDirectory: true))
    guard deleteBranch, let branch = row.branch, !branch.isEmpty else { return nil }
    switch await gitWorktreeClient.deleteBranchIfExists(sourceURL, branch) {
    case .deleted, .absent:
      return nil
    case .kept(let reason):
      return "branch \"\(branch)\" was kept: \(reason)"
    }
  }

  /// A member checkout also lists under its source Project once that
  /// Project reconciles; drop that row too, or it lingers pointing at a
  /// folder that is gone until the next stale sweep archives it.
  @MainActor
  private static func removeMirrorRows(forCanonicalPath path: String, hierarchy: HierarchyClient) {
    for project in hierarchy.snapshot().projects where !project.isWorkspace {
      for worktree in project.worktrees
      where HierarchyManager.canonicalPath(worktree.path) == path && worktree.path != project.rootPath {
        try? hierarchy.removeWorktree(worktree.id, project.id)
      }
    }
  }

  // MARK: Preflight

  /// A member after preflight: canonical source root (where the clone will
  /// land, for a remote that is not on disk yet), absolute destination, and
  /// the URL still to clone from, if any.
  private struct ResolvedMember: Sendable {
    let member: WorkspacePlan.Member
    let sourceGitRoot: String
    let destination: String
    let cloneFrom: String?
  }

  @MainActor
  private static func preflight(_ plan: WorkspacePlan, context: Context) async -> WorkspacePreflight {
    var result = WorkspacePreflight()
    let rootPath =
      plan.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "" : canonical(plan.rootPath)
    if !rootPath.isEmpty {
      do {
        try await preflightRoot(rootPath, context: context)
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue {
          result.rootIssues.append(
            .init(kind: .rootExists, message: "Folder exists; checkouts are added inside it."))
        }
      } catch let error as WorkspaceError {
        if let issue = preflightIssue(for: error) { result.rootIssues.append(issue) }
      } catch {
        result.rootIssues.append(.init(kind: .rootIsFile, message: describe(error)))
      }
    }
    for member in plan.members {
      var issues: [WorkspacePreflight.Issue] = []
      do {
        let resolved = try await resolve(member, rootPath: rootPath, context: context)
        if case .remote = member.source, resolved.cloneFrom == nil {
          issues.append(
            .init(
              kind: .cloneDestinationReused,
              message: "\(resolved.sourceGitRoot) already holds a clone of this remote; it will be reused."))
        }
      } catch let error as WorkspaceError {
        if let issue = preflightIssue(for: error) { issues.append(issue) }
      } catch {
        issues.append(.init(kind: .sourceNotRepository, message: describe(error)))
      }
      if !issues.isEmpty {
        result.memberIssues[member.name] = issues
      }
    }
    return result
  }

  private static func preflightIssue(for error: WorkspaceError) -> WorkspacePreflight.Issue? {
    let message = error.errorDescription ?? String(describing: error)
    switch error {
    case .rootAlreadyRegistered: return .init(kind: .rootAlreadyRegistered, message: message)
    case .rootIsFile: return .init(kind: .rootIsFile, message: message)
    case .rootAlreadyWorkspace: return .init(kind: .rootAlreadyWorkspace, message: message)
    case .rootInsideRepository: return .init(kind: .rootInsideRepository, message: message)
    case .destinationExists: return .init(kind: .destinationExists, message: message)
    case .sourceNotRepository: return .init(kind: .sourceNotRepository, message: message)
    case .cloneDestinationTaken: return .init(kind: .cloneDestinationTaken, message: message)
    case .invalidBranchName: return .init(kind: .invalidBranchName, message: message)
    case .invalidPlan, .notWorkspace, .memberExists, .memberNotRegistered, .memberNotFound,
      .memberWithoutSource, .cannotDropRoot, .cancelled:
      return nil
    }
  }

  @MainActor
  private static func preflightRoot(_ rootPath: String, context: Context) async throws {
    if context.hierarchy.isPathRegistered(rootPath) != nil {
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
    // it will be created under. The bare-aware probe also catches a root
    // placed inside a bare repository's directory.
    var probe = rootPath
    while !FileManager.default.fileExists(atPath: probe), probe != "/" {
      probe = (probe as NSString).deletingLastPathComponent
    }
    if let found = try? await context.cli.inspectRepository(at: probe) {
      throw WorkspaceError.rootInsideRepository(path: rootPath, gitRoot: found.root)
    }
  }

  /// Checks a member without touching disk: its source is a repository (or
  /// a remote whose destination is free or already a clone of it), its
  /// destination is free, and its branch name is well-formed. A remote that
  /// still needs cloning comes back with `cloneFrom` set.
  private static func resolve(
    _ member: WorkspacePlan.Member,
    rootPath: String,
    context: Context
  ) async throws -> ResolvedMember {
    let destination = (rootPath as NSString).appendingPathComponent(member.name)
    guard rootPath.isEmpty || !FileManager.default.fileExists(atPath: destination) else {
      throw WorkspaceError.destinationExists(path: destination)
    }
    let sourceGitRoot: String
    var cloneFrom: String?
    switch member.source {
    case .local(let path):
      let expanded = canonical(path)
      guard isDirectory(expanded), let probe = try? await context.cli.inspectRepository(at: expanded)
      else { throw WorkspaceError.sourceNotRepository(path: expanded) }
      sourceGitRoot = canonical(probe.root)
    case .remote(let url, let cloneDestination):
      let remoteURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
      let expanded = canonical(cloneDestination)
      if FileManager.default.fileExists(atPath: expanded) {
        // Reuse a clone of the same remote; refuse anything else at that path.
        guard isDirectory(expanded),
          let probe = try? await context.cli.inspectRepository(at: expanded),
          canonical(probe.root) == expanded,
          let origin = await context.git.remoteURL(URL(fileURLWithPath: expanded, isDirectory: true), "origin"),
          remoteURLsMatch(origin, remoteURL)
        else { throw WorkspaceError.cloneDestinationTaken(path: expanded, remoteURL: remoteURL) }
      } else {
        cloneFrom = remoteURL
      }
      sourceGitRoot = expanded
    }
    // `check-ref-format --branch` needs no repository, so the not-yet-cloned
    // source is asked the same way as a local one.
    let branch = member.checkout.branch
    let probeURL = URL(
      fileURLWithPath: cloneFrom == nil ? sourceGitRoot : NSHomeDirectory(), isDirectory: true)
    guard await context.git.isValidBranchName(probeURL, branch) else {
      throw WorkspaceError.invalidBranchName(branch, repository: sourceGitRoot)
    }
    return ResolvedMember(
      member: member, sourceGitRoot: sourceGitRoot, destination: destination, cloneFrom: cloneFrom)
  }

  /// Two spellings of one remote: trailing slashes and a `.git` suffix are
  /// noise, the rest must match.
  nonisolated static func remoteURLsMatch(_ lhs: String, _ rhs: String) -> Bool {
    func normalized(_ raw: String) -> String {
      var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      while text.hasSuffix("/") { text.removeLast() }
      if text.lowercased().hasSuffix(".git") { text.removeLast(4) }
      while text.hasSuffix("/") { text.removeLast() }
      return text
    }
    return normalized(lhs) == normalized(rhs)
  }

  // MARK: Materialize / rollback

  /// Clone (remote source), fetch (remote base ref), `git worktree add`;
  /// every step recorded so rollback can undo it. Returns the member as it
  /// should be written to the manifest: source root on disk, checkout with
  /// its base ref resolved and its remote-tracking choice applied.
  private static func materialize(
    _ entry: ResolvedMember,
    ledger: inout WorkspaceMaterializationLedger,
    context: Context,
    yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
  ) async throws -> WorkspacePlan.Member {
    let name = entry.member.name
    let sourceURL = URL(fileURLWithPath: entry.sourceGitRoot, isDirectory: true)
    let destinationURL = URL(fileURLWithPath: entry.destination, isDirectory: true)
    do {
      var freshlyCloned = false
      if let remoteURL = entry.cloneFrom {
        yield(.memberStarted(name: name, phase: .cloning))
        for try await line in context.git.cloneStream(remoteURL, sourceURL) {
          yield(.progressLine(name: name, line: line))
        }
        // A cancelled consumer ends the clone stream quietly; do not read
        // that as a finished clone.
        try Task.checkCancellation()
        ledger.record(.clonedRepository(path: entry.sourceGitRoot))
        freshlyCloned = true
      }

      if !freshlyCloned, await context.fetchRemoteOnCreate(),
        let remote = await remoteToFetch(for: entry.member.checkout, sourceURL: sourceURL, git: context.git)
      {
        yield(.memberStarted(name: name, phase: .fetching))
        try await context.git.fetchRemote(sourceURL, remote)
      }
      try Task.checkCancellation()

      let checkout = try await finalizeCheckout(entry.member.checkout, sourceURL: sourceURL, git: context.git)
      yield(.memberStarted(name: name, phase: .checkingOut))
      // `-B` moves the branch before the worktree exists, so the previous
      // tip is recorded ahead of the command that may fail after moving it.
      if case .remoteTrackingRef(_, let branch, true) = checkout,
        let tip = try await context.git.branchTip(sourceURL, branch)
      {
        ledger.record(.resetBranch(repoRoot: entry.sourceGitRoot, branch: branch, previousTip: tip))
      }
      try await context.git.addWorktreeAt(sourceURL, destinationURL, checkout)
      switch checkout {
      case .newBranch(let branch, _):
        ledger.record(.createdBranch(repoRoot: entry.sourceGitRoot, branch: branch))
      case .remoteTrackingRef(_, let branch, let resetLocal) where !resetLocal:
        // No local branch existed (a kept one becomes `.existingBranch`).
        ledger.record(.createdBranch(repoRoot: entry.sourceGitRoot, branch: branch))
      case .remoteTrackingRef, .existingBranch:
        break
      }
      ledger.record(.addedWorktree(repoRoot: entry.sourceGitRoot, path: entry.destination))
      yield(.memberFinished(name: name))

      var member = entry.member
      member.sourceGitRoot = entry.sourceGitRoot
      member.checkout = checkout
      return member
    } catch {
      if !(error is CancellationError) {
        yield(.memberFailed(name: name, message: describe(error)))
      }
      throw error
    }
  }

  /// The remote a checkout's base ref lives on, when the repository has it
  /// configured: `origin/main` → `origin`, an unnamed base → `origin` (the
  /// default remote branch is read from it). Nil when nothing needs fetching.
  private static func remoteToFetch(
    for checkout: WorkspaceCheckout, sourceURL: URL, git: GitWorktreeClient
  ) async -> String? {
    let candidate: String?
    switch checkout {
    case .newBranch(_, nil):
      candidate = "origin"
    case .newBranch(_, let baseRef?):
      candidate = WorkspaceCheckout.splitRemoteRef(baseRef)?.remote
    case .remoteTrackingRef(let remoteRef, _, _):
      candidate = WorkspaceCheckout.splitRemoteRef(remoteRef)?.remote
    case .existingBranch:
      candidate = nil
    }
    guard let candidate, await git.remoteURL(sourceURL, candidate) != nil else { return nil }
    return candidate
  }

  /// Fills what only the repository can answer: the default base ref of a
  /// new branch, and whether a remote-tracking checkout meets an existing
  /// local branch. Keeping the local branch turns the checkout into a plain
  /// `existingBranch`; a missing local branch never resets anything.
  private static func finalizeCheckout(
    _ checkout: WorkspaceCheckout, sourceURL: URL, git: GitWorktreeClient
  ) async throws -> WorkspaceCheckout {
    switch checkout {
    case .newBranch(let branch, nil):
      // Start from the repository's default remote branch when the caller
      // named none; git's own default (HEAD) applies when that is unknown or
      // not a ref this repository has — a bare clone reports `origin/main`
      // from its remote config yet keeps no remote-tracking refs.
      guard let base = try? await git.defaultRemoteBranchRef(sourceURL),
        let refs = try? await git.branchRefs(sourceURL), refs.contains(base)
      else { return .newBranch(branch: branch, baseRef: nil) }
      return .newBranch(branch: branch, baseRef: base)
    case .newBranch, .existingBranch:
      return checkout
    case .remoteTrackingRef(let remoteRef, let branch, let resetLocal):
      let locals = try await git.localBranchNames(sourceURL)
      guard locals.contains(branch) else {
        return .remoteTrackingRef(remoteRef: remoteRef, branch: branch, resetLocal: false)
      }
      return resetLocal ? checkout : .existingBranch(branch)
    }
  }

  /// Undo in reverse order. Runs detached so cancelling the creation task
  /// cannot SIGTERM the cleanup git subprocesses mid-flight; the caller
  /// still awaits the result. Returns what could not be undone.
  private static func rollback(
    _ ledger: WorkspaceMaterializationLedger, context: Context
  ) async -> [String] {
    guard !ledger.isEmpty else { return [] }
    let steps = ledger.rollbackSteps
    let git = context.git
    let task = Task.detached { () -> [String] in
      var failures: [String] = []
      for step in steps {
        switch step {
        case .addedWorktree(let repoRoot, let path):
          do {
            try await git.removeWorktree(
              URL(fileURLWithPath: repoRoot, isDirectory: true),
              URL(fileURLWithPath: path, isDirectory: true))
          } catch {
            logger.warning("rollback could not remove worktree at \(path, privacy: .private): \(error)")
            failures.append("worktree at \(path)")
          }
        case .createdBranch(let repoRoot, let branch):
          if case .kept(let reason) = await git.deleteBranchIfExists(
            URL(fileURLWithPath: repoRoot, isDirectory: true), branch)
          {
            failures.append("branch \(branch) in \(repoRoot): \(reason)")
          }
        case .resetBranch(let repoRoot, let branch, let previousTip):
          do {
            try await git.forceMoveBranch(URL(fileURLWithPath: repoRoot, isDirectory: true), branch, previousTip)
          } catch {
            logger.warning("rollback could not restore branch \(branch, privacy: .public): \(error)")
            failures.append("branch \(branch) in \(repoRoot) (was \(previousTip))")
          }
        case .clonedRepository(let path), .createdDirectory(let path):
          do {
            try FileManager.default.removeItem(atPath: path)
          } catch {
            logger.warning("rollback could not remove \(path, privacy: .private): \(error)")
            failures.append(path)
          }
        }
      }
      return failures
    }
    return await task.value
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

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  /// A one-line, user-facing reading of a step's error.
  nonisolated static func describe(_ error: Error) -> String {
    if let error = error as? GitWorktreeError {
      switch error {
      case .executableMissing: return "git is not available"
      case .branchExists(let branch): return "branch \"\(branch)\" already exists"
      case .invalidBranchName(let branch): return "\"\(branch)\" is not a valid branch name"
      case .refNotFound(let detail): return detail
      case .fetchFailed(let detail): return "fetch failed: \(detail)"
      case .uncommittedChanges: return "the checkout has uncommitted changes"
      case .worktreeLocked(let detail): return detail
      case .commandFailed(let command, let stderr):
        return stderr.isEmpty ? "\(command) failed" : "\(command): \(stderr)"
      }
    }
    if let described = (error as? LocalizedError)?.errorDescription { return described }
    return String(describing: error)
  }
}
