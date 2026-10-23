import CodansCore
import ComposableArchitecture
import Foundation
import os

/// Why a workspace operation could not run. Every case names the path,
/// group, or member involved so the CLI and the sheets can show it verbatim.
nonisolated enum WorkspaceError: LocalizedError, Equatable, Sendable {
  case invalidPlan([WorkspacePlan.ValidationIssue])
  /// A source plan the client refuses before any I/O (empty title, no root).
  case invalidSourcePlan(reason: String)
  case rootAlreadyRegistered(path: String)
  case rootIsFile(path: String)
  case rootAlreadyWorkspace(path: String)
  /// The workspace root would sit inside a repository. Older builds probe a
  /// folder project for a git root on every reconcile and would adopt that
  /// repository, so this is refused up front rather than tolerated.
  case rootInsideRepository(path: String, gitRoot: String)
  case destinationExists(path: String)
  case sourceNotRepository(path: String)
  /// Workspace members are linked worktrees of a repository with a working
  /// tree; a bare repository is not accepted as a source.
  case bareRepository(path: String)
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
  /// The source is already listed in the Workspace.
  case sourceExists(path: String)
  /// The Workspace lists no source at this path.
  case sourceNotFound(path: String)
  case groupNotFound(WorkspaceGroupID)
  /// The `default` group exists as long as the Workspace does.
  case cannotDeleteDefault
  /// A new group's preflight found blocking issues.
  case groupPreflightFailed(WorkspacePreflight)
  /// The delete would lose data the request did not acknowledge.
  case risksNotAcknowledged(GroupDeletionCheck)
  /// A deletion probe failed; nothing was deleted.
  case checkFailed(GroupDeletionCheck)
  /// The manifest could not be read or written.
  case manifestUnavailable(reason: String)
  /// The operation has no implementation in this build yet.
  case notImplemented(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .invalidPlan(let issues):
      return issues.map(\.description).joined(separator: "; ")
    case .invalidSourcePlan(let reason):
      return reason
    case .rootAlreadyRegistered(let path):
      return "\(path) is already a project in codans"
    case .rootIsFile(let path):
      return "\(path) is a file, not a folder"
    case .rootAlreadyWorkspace(let path):
      return "\(path) is already a workspace (it carries \(WorkspaceLayout.stateDirectoryName)/)"
    case .rootInsideRepository(let path, let gitRoot):
      return "\(path) is inside the repository at \(gitRoot); a workspace root must not be inside a git repository"
    case .destinationExists(let path):
      return "\(path) already exists"
    case .sourceNotRepository(let path):
      return "\(path) is not a git repository"
    case .bareRepository(let path):
      return "\(path) is a bare repository, which workspaces do not support"
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
    case .sourceExists(let path):
      return "\(path) is already a project of this workspace"
    case .sourceNotFound(let path):
      return "the workspace has no project at \(path)"
    case .groupNotFound(let id):
      return "the workspace has no group \(id)"
    case .cannotDeleteDefault:
      return "the \"default\" group cannot be deleted"
    case .groupPreflightFailed(let preflight):
      let messages = (preflight.groupIssues + preflight.memberIssues.values.flatMap { $0 })
        .filter { !$0.isInformational }
        .map(\.message)
      return messages.isEmpty ? "the group cannot be created" : messages.joined(separator: "; ")
    case .risksNotAcknowledged(let check):
      return "deleting group \"\(check.groupName)\" would lose work; acknowledge the risks to continue"
    case .checkFailed(let check):
      return "group \"\(check.groupName)\" could not be checked; nothing was deleted"
    case .manifestUnavailable(let reason):
      return reason
    case .notImplemented(let operation):
      return "\(operation) is not available in this build"
    case .cancelled:
      return "workspace creation was cancelled; everything it created has been removed"
    }
  }
}

/// The only mutation route for Workspaces, shared by the GUI sheets and the
/// `workspace.*` IPC handlers so both entry points act identically.
///
/// Each part lives in its own file: sources and Workspace creation in
/// `WorkspaceClient+Sources.swift`, named groups in
/// `WorkspaceClient+Groups.swift`, deletion and removal in
/// `WorkspaceClient+Deletion.swift`. Every closure defaults to
/// `unimplemented`, so a test stubs only what it drives.
struct WorkspaceClient: Sendable {
  /// Validate the root, resolve the sources to main checkouts (cloning
  /// remotes), write the group manifest with `default` only, sync the
  /// default links, register, and reconcile. No branch is created or
  /// switched. A failure rolls back the created root and clones only.
  var createWorkspace: @MainActor @Sendable (_ plan: WorkspaceSourcePlan) async throws -> ProjectID =
    unimplemented("WorkspaceClient.createWorkspace", placeholder: ProjectID())
  /// Root and source findings of `createWorkspace`, collected without side
  /// effects so a form can show them live. `memberIssues` is keyed by the
  /// source's index in the plan, as a string.
  var preflightWorkspace: @MainActor @Sendable (_ plan: WorkspaceSourcePlan) async -> WorkspacePreflight =
    unimplemented("WorkspaceClient.preflightWorkspace", placeholder: WorkspacePreflight())
  /// Append a source project, sync the default links, and reconcile. Named
  /// groups are unchanged. Returns the new reference row.
  var addSource: @MainActor @Sendable (_ projectID: ProjectID, _ source: WorkspaceSource) async throws -> WorktreeID =
    unimplemented("WorkspaceClient.addSource", placeholder: WorktreeID())
  /// Remove a source project, unlink it, and remove its reference row.
  /// Never deletes a checkout or touches the source directory.
  var removeSource: @MainActor @Sendable (_ projectID: ProjectID, _ sourceGitRoot: String) async throws -> Void =
    unimplemented("WorkspaceClient.removeSource")

  /// Per-source defaults for a new group: base ref, fetch, copy options,
  /// agent profile, and setup command from the source Project's settings
  /// (global settings for an unregistered source).
  var groupCreationDefaults: @MainActor @Sendable (_ projectID: ProjectID) async -> [MemberCreationOptions] =
    unimplemented("WorkspaceClient.groupCreationDefaults", placeholder: [])
  /// Everything `createGroupStream` would refuse, per project, without
  /// side effects. `memberIssues` is keyed by member name.
  var preflightGroup: @MainActor @Sendable (_ plan: WorkspaceGroupPlan) async -> WorkspacePreflight =
    unimplemented("WorkspaceClient.preflightGroup", placeholder: WorkspacePreflight())
  /// Creates a named group: preflight, every checkout (rolled back as a
  /// whole on failure), manifest and catalog, then setup commands. Ends with
  /// `.groupCreated(result)` on success. `cancelCreation(token)` stops it.
  var createGroupStream:
    @MainActor @Sendable (_ plan: WorkspaceGroupPlan, _ token: UUID)
      -> AsyncThrowingStream<WorkspaceCreationEvent, Error> = unimplemented(
        "WorkspaceClient.createGroupStream",
        placeholder: AsyncThrowingStream { $0.finish(throwing: WorkspaceError.cancelled) })
  /// Stops the run started with `token`. The stream keeps flowing until it
  /// has reported the rollback, then finishes with `WorkspaceError.cancelled`.
  var cancelCreation: @Sendable (_ token: UUID) async -> Void = unimplemented(
    "WorkspaceClient.cancelCreation")

  /// What deleting a named group would destroy, without side effects.
  var checkGroupDeletion:
    @MainActor @Sendable (_ projectID: ProjectID, _ groupID: WorkspaceGroupID) async -> GroupDeletionCheck =
      unimplemented(
        "WorkspaceClient.checkGroupDeletion",
        placeholder: GroupDeletionCheck(projectID: ProjectID(), groupID: WorkspaceGroupID(), groupName: ""))
  /// Deletes a named group after re-running the check. Throws
  /// `risksNotAcknowledged` / `checkFailed` / `cannotDeleteDefault`.
  var deleteGroup:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ groupID: WorkspaceGroupID, _ request: GroupDeletionRequest
    ) async throws -> GroupDeletionOutcome = unimplemented(
      "WorkspaceClient.deleteGroup", placeholder: GroupDeletionOutcome(deletedGroup: false))
  /// Removes the Workspace from the sidebar, or deletes the files it owns.
  /// Source main checkouts are kept either way.
  var removeWorkspace:
    @MainActor @Sendable (_ projectID: ProjectID, _ request: WorkspaceRemovalRequest) async throws
      -> WorkspaceRemovalOutcome = unimplemented(
        "WorkspaceClient.removeWorkspace", placeholder: WorkspaceRemovalOutcome(deletedFolder: false))
}

extension WorkspaceClient {
  /// `createGroupStream` drained to its result, for callers that only wait
  /// (IPC).
  @MainActor
  func createGroup(_ plan: WorkspaceGroupPlan) async throws -> GroupCreationResult {
    var result: GroupCreationResult?
    for try await event in createGroupStream(plan, UUID()) {
      if case .groupCreated(let created) = event { result = created }
    }
    guard let result else { throw WorkspaceError.cancelled }
    return result
  }
}

extension WorkspaceClient: TestDependencyKey {
  static let testValue = WorkspaceClient()
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
  nonisolated static let logger = Logger(
    subsystem: "com.gumpw.codans.hierarchy", category: "workspace")

  /// Everything the orchestration reaches for, bundled so the static steps
  /// in each part file take one argument.
  struct Context: Sendable {
    let hierarchy: HierarchyClient
    let git: GitWorktreeClient
    let cli: GitWorktreeCLI
    /// Whether to `git fetch` the remote a base ref names before checking
    /// out — the global switch worktree creation honours.
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
      createWorkspace: { plan in try await createWorkspace(plan, context: context) },
      preflightWorkspace: { plan in await preflightWorkspace(plan, context: context) },
      addSource: { projectID, source in
        try await addSource(projectID: projectID, source: source, context: context)
      },
      removeSource: { projectID, sourceGitRoot in
        try await removeSource(projectID: projectID, sourceGitRoot: sourceGitRoot, context: context)
      },
      groupCreationDefaults: { projectID in
        await groupCreationDefaults(projectID: projectID, context: context)
      },
      preflightGroup: { plan in await preflightGroup(plan, context: context) },
      createGroupStream: { plan, token in
        makeStream(token: token, registry: context.registry) { yield in
          try await performCreateGroup(plan, context: context, yield: yield)
        }
      },
      cancelCreation: { token in
        context.registry.cancel(token)
      },
      checkGroupDeletion: { projectID, groupID in
        await checkGroupDeletion(projectID: projectID, groupID: groupID, context: context)
      },
      deleteGroup: { projectID, groupID, request in
        try await deleteGroup(projectID: projectID, groupID: groupID, request: request, context: context)
      },
      removeWorkspace: { projectID, request in
        try await removeWorkspace(projectID: projectID, request: request, context: context)
      }
    )
  }

  // MARK: Streams

  /// Drives `body` on the main actor inside a registered task. A consumer
  /// that stops iterating cancels the task, which the steps observe between
  /// subprocesses; the rollback then runs detached and finishes on its own.
  @MainActor
  static func makeStream(
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

  // MARK: Removal helpers

  /// Tear down the row's terminals, move its checkout out from under the
  /// source repository, and optionally delete the branch. Returns the
  /// kept-branch note when git refused the deletion.
  @MainActor
  static func unregister(
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
  static func removeMirrorRows(forCanonicalPath path: String, hierarchy: HierarchyClient) {
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
  struct ResolvedMember: Sendable {
    let member: WorkspacePlan.Member
    let sourceGitRoot: String
    let destination: String
    let cloneFrom: String?
  }

  /// A finding worded for the form: short, with home-relative paths. The
  /// CLI keeps `errorDescription`'s full wording.
  static func preflightIssue(for error: WorkspaceError) -> WorkspacePreflight.Issue? {
    switch error {
    case .rootAlreadyRegistered:
      return .init(kind: .rootAlreadyRegistered, message: "This folder is already a project in codans.")
    case .rootIsFile:
      return .init(kind: .rootIsFile, message: "A file already exists at this location.")
    case .rootAlreadyWorkspace:
      return .init(kind: .rootAlreadyWorkspace, message: "This folder is already a workspace.")
    case .rootInsideRepository(_, let gitRoot):
      return .init(
        kind: .rootInsideRepository,
        message: "This location is inside the repository at \(tilde(gitRoot)). Choose a folder outside it.")
    case .destinationExists(let path):
      return .init(
        kind: .destinationExists, message: "\(tilde(path)) already exists. Choose another folder name.")
    case .sourceNotRepository(let path):
      return .init(kind: .sourceNotRepository, message: "\(tilde(path)) is not a git repository.")
    case .bareRepository(let path):
      return .init(
        kind: .sourceNotRepository, message: "\(tilde(path)) is a bare repository, which workspaces do not support.")
    case .cloneDestinationTaken(let path, _):
      return .init(
        kind: .cloneDestinationTaken,
        message: "\(tilde(path)) already exists and is not a clone of this remote. Choose another location.")
    case .invalidBranchName(let branch, _):
      return .init(kind: .invalidBranchName, message: "\u{201C}\(branch)\u{201D} is not a valid branch name.")
    case .invalidPlan, .invalidSourcePlan, .notWorkspace, .memberExists, .memberNotRegistered,
      .memberNotFound, .memberWithoutSource, .cannotDropRoot, .sourceExists, .sourceNotFound,
      .groupNotFound, .cannotDeleteDefault, .groupPreflightFailed, .risksNotAcknowledged, .checkFailed,
      .manifestUnavailable, .notImplemented, .cancelled:
      return nil
    }
  }

  static func isEmptyBranchName(_ error: WorkspaceError) -> Bool {
    if case .invalidBranchName(let branch, _) = error { return branch.isEmpty }
    return false
  }

  static func tilde(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  @MainActor
  static func preflightRoot(_ rootPath: String, context: Context) async throws {
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
    // it will be created under. The probe also catches a root placed inside
    // a bare repository's directory, which `--show-toplevel` would miss.
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
  static func resolve(
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
      guard !probe.isBare else { throw WorkspaceError.bareRepository(path: canonical(probe.root)) }
      sourceGitRoot = canonical(probe.root)
    case .remote(let url, let cloneDestination):
      let remoteURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
      let expanded = canonical(cloneDestination)
      if FileManager.default.fileExists(atPath: expanded) {
        // Reuse a clone of the same remote; refuse anything else at that path.
        guard isDirectory(expanded),
          let probe = try? await context.cli.inspectRepository(at: expanded),
          !probe.isBare, canonical(probe.root) == expanded,
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
  static func materialize(
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
  static func remoteToFetch(
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
  static func finalizeCheckout(
    _ checkout: WorkspaceCheckout, sourceURL: URL, git: GitWorktreeClient
  ) async throws -> WorkspaceCheckout {
    switch checkout {
    case .newBranch(let branch, nil):
      // Start from the repository's default remote branch when the caller
      // named none; git's own default (HEAD) applies when that is unknown or
      // names a ref this repository no longer has.
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
  static func rollback(
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
  static func reconcileSources(_ sourceRoots: [String], hierarchy: HierarchyClient) async {
    let wanted = Set(sourceRoots)
    let projects = hierarchy.snapshot().projects.filter { project in
      guard project.remoteHost == nil, let gitRoot = project.gitRoot else { return false }
      return wanted.contains(HierarchyManager.canonicalPath(gitRoot))
    }
    for project in projects {
      await hierarchy.reconcileDiscoveredWorktrees(project.id)
    }
  }

  static func canonical(_ path: String) -> String {
    HierarchyManager.canonicalPath((path as NSString).expandingTildeInPath)
  }

  static func isDirectory(_ path: String) -> Bool {
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
