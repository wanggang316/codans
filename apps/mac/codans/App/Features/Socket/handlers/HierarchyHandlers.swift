import CodansCore
import CodansIPC
import Foundation
import os

/// Narrow read-only view onto a pane's zmx daemon. Implemented in
/// production by `ZmxControlProbe` (transient control-socket queries via
/// `ZmxControlClient`); tests inject a fake so they exercise the handler's
/// encoding/error paths without spinning up a real daemon socket.
@MainActor
public protocol PaneRuntimeProbe: AnyObject, Sendable {
  /// Resolves with the daemon's next `.info` response (shell PID + cwd).
  func requestInfo() async throws -> ZmxInfoPayload
  /// Resolves with the raw bytes of the daemon's `.history` response in
  /// the requested format.
  func readHistory(format: ZmxHistoryFormat) async throws -> Data
}

/// `PaneRuntimeProbe` backed by transient control-socket queries
/// (`ZmxControlClient`) to a Pane's daemon. The live byte stream now runs
/// through the in-surface `zmx attach` client, so `pane.info` / `pane.read`
/// reach the daemon out-of-band by PaneID rather than through a held client.
@MainActor
final class ZmxControlProbe: PaneRuntimeProbe {
  private let paneID: PaneID
  init(paneID: PaneID) { self.paneID = paneID }
  func requestInfo() async throws -> ZmxInfoPayload {
    try await ZmxControlClient.info(for: paneID)
  }
  func readHistory(format: ZmxHistoryFormat) async throws -> Data {
    try await ZmxControlClient.history(for: paneID, format: format)
  }
}

/// Handlers for `hierarchy.*` — both reads (list / describe /
/// resolveAlias) and mutations (create / activate / close / label),
/// plus the Tag-scoped RPCs and the `tag` / `untagged` filters on
/// `hierarchy.listProjects`.
@MainActor
final class HierarchyHandlers {
  // Dependencies the `+Describe` / `+Layout` extensions share; kept
  // internal rather than private for that reason only.
  let manager: HierarchyManager
  let envProvider: @MainActor (ProjectID) -> [String: String]
  private let settingsProvider: @MainActor () -> Settings
  /// Closure that sends `.kill` to the zmx daemon backing `paneID` and
  /// waits for its control socket to disappear. Returns once the daemon
  /// is gone or the bounded timeout elapses. Injected so handlers stay
  /// independent of the libghostty surface registry; default is a no-op
  /// for tests that exercise the catalog-side mutation in isolation.
  private let daemonKiller: @MainActor (PaneID) async -> Void
  /// Probe surface for `pane.info` / `pane.read`. Returns a typed
  /// `PaneRuntimeProbe` view of the live `ZmxClient` for `paneID`, or
  /// `nil` when no surface is bound (no live daemon to talk to). Kept
  /// behind a protocol so tests can inject a fake without dragging
  /// `GhosttyRuntime` into the test target.
  let runtimeProbe: @MainActor (PaneID) -> PaneRuntimeProbe?
  /// Persistent zmx-session catalog accessor. The `pane.close` handler
  /// drops the closed pane's row synchronously through the coordinator
  /// so the on-disk state reflects the kill before the RPC returns.
  /// Default is `nil` for tests; production wiring passes the shared
  /// `SessionCoordinator`.
  private let sessionCoordinator: SessionCoordinator?
  /// Short-handle sugar (`t<n>` / `p<n>`) for tabs and panes. Lives with
  /// the handlers so it spans CLI connections: handles stay stable until
  /// the entity closes, and are never reused within one app session.
  let handleRegistry: TargetHandleRegistry
  /// Resolve the pane a connecting process belongs to from its kernel
  /// peer PID (ancestry walk against live pane shell PIDs). Injected so
  /// the handler stays independent of the libghostty surface registry;
  /// the default resolves nothing, matching transports that carry no
  /// peer PID (tests, in-memory harness).
  private let callerPaneResolver: @MainActor (pid_t) -> PaneID?
  /// `git rev-parse --show-toplevel` for a directory the CLI is adding as a
  /// project, so a CLI-added project is a git project from the start —
  /// the same probe the sidebar's Add Project runs. Default finds nothing
  /// (folder project), matching transports without git access (tests).
  private let gitRootDiscovery: @MainActor (String) async -> String?
  /// Re-reads `git worktree list` for a project and settles its rows —
  /// fired after `hierarchy.addProject` lands a row (so the worktree list
  /// fills in the way it does after the sidebar adds a project) and after
  /// `hierarchy.pruneWorktrees` drops stale registrations.
  let reconcileWorktrees: @MainActor (ProjectID) async -> Void
  /// Materialises a worktree on disk (`wt sw`, the New Worktree sheet's
  /// pipeline) and returns its final path. `nil` keeps
  /// `hierarchy.createWorktree` catalog-only, which is what tests and the
  /// in-memory harness want.
  private let worktreeCreator: (@MainActor @Sendable (CreateWorktreeSpec) async throws -> URL)?
  /// The ref a new branch starts from when the caller names none —
  /// `origin/<default branch>` when the repo has one, the sheet's own
  /// preselection. Default none ⇒ `wt` falls back to `HEAD`.
  private let defaultBaseRef: @MainActor (URL) async -> String?
  /// End-to-end removal — surfaces torn down, `git worktree remove`
  /// (relocate-then-prune), branch cleanup per Settings, catalog row
  /// dropped — for `deleteFromDisk`. Returns the client's non-fatal
  /// warning. `nil` makes `deleteFromDisk` unsupported (tests, harness).
  private let worktreeRemover: (@MainActor @Sendable (WorktreeID, ProjectID) async throws -> String?)?
  /// `git worktree prune` for a repository root, returning how many stale
  /// registrations went away — the sidebar's Prune Worktrees. `nil` makes
  /// `hierarchy.pruneWorktrees` unsupported (tests, harness).
  let worktreePruner: (@MainActor @Sendable (URL) async throws -> Int)?
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "hierarchy")

  init(
    manager: HierarchyManager,
    handleRegistry: TargetHandleRegistry = TargetHandleRegistry(),
    envProvider: @escaping @MainActor (ProjectID) -> [String: String] = { _ in [:] },
    settingsProvider: @escaping @MainActor () -> Settings = { Settings() },
    daemonKiller: @escaping @MainActor (PaneID) async -> Void = { _ in },
    runtimeProbe: @escaping @MainActor (PaneID) -> PaneRuntimeProbe? = { _ in nil },
    sessionCoordinator: SessionCoordinator? = nil,
    callerPaneResolver: @escaping @MainActor (pid_t) -> PaneID? = { _ in nil },
    gitRootDiscovery: @escaping @MainActor (String) async -> String? = { _ in nil },
    reconcileWorktrees: @escaping @MainActor (ProjectID) async -> Void = { _ in },
    worktreeCreator: (@MainActor @Sendable (CreateWorktreeSpec) async throws -> URL)? = nil,
    defaultBaseRef: @escaping @MainActor (URL) async -> String? = { _ in nil },
    worktreeRemover: (@MainActor @Sendable (WorktreeID, ProjectID) async throws -> String?)? = nil,
    worktreePruner: (@MainActor @Sendable (URL) async throws -> Int)? = nil
  ) {
    self.manager = manager
    self.handleRegistry = handleRegistry
    self.envProvider = envProvider
    self.settingsProvider = settingsProvider
    self.daemonKiller = daemonKiller
    self.runtimeProbe = runtimeProbe
    self.sessionCoordinator = sessionCoordinator
    self.callerPaneResolver = callerPaneResolver
    self.gitRootDiscovery = gitRootDiscovery
    self.reconcileWorktrees = reconcileWorktrees
    self.worktreeCreator = worktreeCreator
    self.defaultBaseRef = defaultBaseRef
    self.worktreeRemover = worktreeRemover
    self.worktreePruner = worktreePruner
  }

  // MARK: - Error mapping

  /// Funnel every mutation catch through here so `HierarchyError` maps to
  /// the right `IPCError` variant (and therefore the right `CLIExitCode`):
  /// a blanket `.notFound` would mask conflict / invariant-violation cases.
  func failure(for error: Error, fallbackKind: String, fallbackID: String) -> RouterOutcome {
    if let h = error as? HierarchyError {
      switch h {
      case .notFound(let message):
        return .failed(.notFound(kind: fallbackKind, id: fallbackID.isEmpty ? message : fallbackID))
      case .invariantViolation(let message):
        return .failed(.conflict(reason: message))
      case .zmxServeNoSocketPath:
        return .failed(.internal("zmx serve did not report a socket path"))
      case .zmxServeFailed(let detail):
        return .failed(.internal("zmx serve failed: \(detail)"))
      case .zmxBinaryMissing:
        return .failed(.internal("zmx binary missing from app bundle"))
      }
    }
    return .failed(.internal("\(error)"))
  }

  // MARK: - Reads

  /// `hierarchy.resolveAlias` — turn a string identifier into the
  /// canonical UUID for `kind`. Supports the set the CLI drives: `current`
  /// / `.` (the calling pane, attributed from `peerPID` + process ancestry
  /// or the request's `contextPaneID`, and for the other kinds the pane's
  /// containers), pane labels (`@label`), short target handles (`t<n>` /
  /// `p<n>`), and names — a project's name, a worktree's name or branch, a
  /// tab's title — scoped to the calling pane's containers when there is
  /// one.
  public func resolveAlias(_ params: JSONValue, peerPID: pid_t? = nil) async -> RouterOutcome {
    await Task.yield()
    let request: IPC.AliasResolveRequest
    do {
      request = try params.decoded(as: IPC.AliasResolveRequest.self)
    } catch {
      return .failed(.invalidParams(message: "resolveAlias requires {kind, value}", path: nil))
    }
    if let uuid = UUID(uuidString: request.value) {
      return resolved(request.kind, uuid)
    }
    if request.value == "current" || request.value == "." {
      return resolveCurrent(request, peerPID: peerPID)
    }
    if request.kind == .pane, request.value.hasPrefix("@") {
      let label = String(request.value.dropFirst())
      let matches = Self.panesMatchingLabel(label: label, catalog: manager.catalog)
      if matches.count == 1 {
        return resolved(.pane, matches[0])
      }
      if matches.count > 1 {
        return .failed(.conflict(reason: "label @\(label) matches \(matches.count) panes"))
      }
      return .failed(.notFound(kind: "pane", id: "@\(label)"))
    }
    if request.kind == .tab, let handle = TargetHandleRegistry.parse(request.value, prefix: "t") {
      handleRegistry.sync(with: manager.catalog)
      guard let id = handleRegistry.tab(forHandle: handle) else {
        return .failed(.notFound(kind: "tab", id: request.value))
      }
      return resolved(.tab, id.raw)
    }
    if request.kind == .pane, let handle = TargetHandleRegistry.parse(request.value, prefix: "p") {
      handleRegistry.sync(with: manager.catalog)
      guard let id = handleRegistry.pane(forHandle: handle) else {
        return .failed(.notFound(kind: "pane", id: request.value))
      }
      return resolved(.pane, id.raw)
    }
    return resolveByName(request, peerPID: peerPID)
  }

  private func resolved(_ kind: IPC.AliasResolveRequest.Kind, _ id: UUID) -> RouterOutcome {
    let result = IPC.AliasResolveResult(kind: kind, id: id)
    return (try? JSONValue.encoded(result)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode resolveAlias result"))
  }

  /// The pane a request comes from. Kernel peer-PID attribution wins over
  /// the request's env-derived `contextPaneID`: the former is ground
  /// truth, the latter is the caller's claim.
  private func callerPane(_ request: IPC.AliasResolveRequest, peerPID: pid_t?) -> PaneID? {
    peerPID.flatMap { callerPaneResolver($0) } ?? request.contextPaneID
  }

  /// `current` / `.`, server-side. The CLI resolves the pronoun from
  /// `$CODANS_PANE_ID` locally and dials only when that env var is missing
  /// (agent-spawned subshells, wrappers, env-scrubbing tools) or when it
  /// needs a container the pane never exports — a pane knows only its own
  /// id, so `--project current` and friends land here and are read off
  /// the catalog row that holds the calling pane.
  private func resolveCurrent(
    _ request: IPC.AliasResolveRequest, peerPID: pid_t?
  ) -> RouterOutcome {
    guard let pane = callerPane(request, peerPID: peerPID) else {
      return .failed(.notFound(kind: request.kind.rawValue, id: request.value))
    }
    let catalog = manager.catalog
    let id: UUID?
    switch request.kind {
    case .pane: id = pane.raw
    case .tab: id = catalog.tabID(forPane: pane)?.raw
    case .worktree: id = catalog.worktreeID(forPane: pane)?.raw
    case .project: id = catalog.projectID(forPane: pane)?.raw
    case .tag: id = nil
    }
    guard let id else {
      return .failed(.notFound(kind: request.kind.rawValue, id: request.value))
    }
    return resolved(request.kind, id)
  }

  /// Name lookup, the last resort for a value that is not an id, pronoun,
  /// label, or handle. A project matches on its name; a worktree on its
  /// name or branch; a tab on its title. When the caller sits in a pane,
  /// worktrees are searched within that pane's project and tabs within its
  /// worktree, so `--worktree main` means "this project's main". Exactly
  /// one hit resolves; several is a conflict the caller settles with an
  /// id; none is not-found. Panes carry no name — a bare word there is a
  /// usage error, most often unquoted text that was meant as input.
  private func resolveByName(
    _ request: IPC.AliasResolveRequest, peerPID: pid_t?
  ) -> RouterOutcome {
    let needle = request.value.lowercased()
    let catalog = manager.catalog
    let pane = callerPane(request, peerPID: peerPID)
    var matches: [UUID] = []
    switch request.kind {
    case .project:
      matches = catalog.projects
        .filter { $0.name.lowercased() == needle || $0.canonicalName.lowercased() == needle }
        .map(\.id.raw)
    case .worktree:
      // A path (absolute; the CLI resolves relative ones against its cwd
      // before calling) matches project-wide; names and branches stay
      // scoped to the caller's project.
      if request.value.hasPrefix("/") {
        matches = Self.worktreesMatchingPath(request.value, in: catalog)
        break
      }
      let scope = pane.flatMap { catalog.projectID(forPane: $0) }
      for project in catalog.projects where scope == nil || project.id == scope {
        for worktree in project.worktrees where !worktree.archived {
          if worktree.name.lowercased() == needle || worktree.branch?.lowercased() == needle {
            matches.append(worktree.id.raw)
          }
        }
      }
    case .tab:
      let scope = pane.flatMap { catalog.worktreeID(forPane: $0) }
      for project in catalog.projects {
        for worktree in project.worktrees where scope == nil || worktree.id == scope {
          for tab in worktree.tabs {
            let title = tab.name ?? tab.cachedDisplayTitle
            if title?.lowercased() == needle {
              matches.append(tab.id.raw)
            }
          }
        }
      }
    case .pane:
      return .failed(
        .invalidParams(
          message:
            "unknown pane \"\(request.value)\"; pass a pane id, p<n> handle, @label, or current "
            + "(quote multi-word text)",
          path: ["value"]))
    case .tag:
      matches = catalog.tags
        .filter { $0.name.lowercased() == needle }
        .map(\.id.raw)
    }
    return outcome(for: matches, request: request)
  }

  /// One match resolves; none is not-found; several is a conflict the
  /// caller settles by passing an id.
  private func outcome(for matches: [UUID], request: IPC.AliasResolveRequest) -> RouterOutcome {
    switch matches.count {
    case 1:
      return resolved(request.kind, matches[0])
    case 0:
      return .failed(.notFound(kind: request.kind.rawValue, id: request.value))
    default:
      return .failed(
        .conflict(
          reason:
            "\(request.kind.rawValue) \"\(request.value)\" matches \(matches.count) entries; pass an id"))
    }
  }

  /// Non-archived worktrees whose directory is `path` or contains it; when
  /// one nests under another, only the deepest is returned.
  static func worktreesMatchingPath(_ path: String, in catalog: Catalog) -> [UUID] {
    let canonical = HierarchyManager.canonicalPath(path)
    var deepest: Worktree?
    for project in catalog.projects {
      for worktree in project.worktrees where !worktree.archived {
        let root = HierarchyManager.canonicalPath(worktree.path)
        guard canonical == root || canonical.hasPrefix(root + "/") else { continue }
        if deepest.map({ root.count > HierarchyManager.canonicalPath($0.path).count }) ?? true {
          deepest = worktree
        }
      }
    }
    return deepest.map { [$0.id.raw] } ?? []
  }

  private static func panesMatchingLabel(label: String, catalog: Catalog) -> [UUID] {
    var matches: [UUID] = []
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          for pane in tab.panes where pane.labels.contains(label) {
            matches.append(pane.id.raw)
          }
        }
      }
    }
    return matches
  }

  // MARK: - Mutations

  public struct ActivateParams: Codable, Sendable { public let id: UUID }
  public func activateWorktree(_ params: JSONValue) async -> RouterOutcome {
    await runActivate(params) { id in
      try manager.activateWorktree(WorktreeID(raw: id))
    }
  }
  public func activateTab(_ params: JSONValue) async -> RouterOutcome {
    await runActivate(params) { id in
      try manager.activateTab(TabID(raw: id))
    }
  }

  private func runActivate(
    _ params: JSONValue,
    apply: (UUID) throws -> Void
  ) async -> RouterOutcome {
    await Task.yield()
    let req: ActivateParams
    do {
      req = try params.decoded(as: ActivateParams.self)
    } catch {
      return .failed(.invalidParams(message: "activate requires {id}", path: nil))
    }
    do {
      try apply(req.id)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "entity", fallbackID: req.id.uuidString)
    }
  }

  public struct AddProjectParams: Codable, Sendable {
    public let name: String
    public let rootPath: String
    public let gitRoot: String?
  }
  public struct AddProjectResult: Codable, Sendable {
    public let id: ProjectID
    public let rootPath: String
    public let gitRoot: String?
  }
  /// `hierarchy.addProject` — the CLI's Add Project. Validates at the edge
  /// the way the sidebar's folder picker does implicitly: the directory
  /// must exist and must not already be registered, and its git root is
  /// discovered when the caller did not supply one, so the new project
  /// gets real worktrees rather than a branchless synthetic row.
  public func addProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: AddProjectParams
    do {
      req = try params.decoded(as: AddProjectParams.self)
    } catch {
      return .failed(.invalidParams(message: "addProject requires {name, rootPath}", path: nil))
    }
    let canonical = HierarchyManager.canonicalPath(req.rootPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .failed(
        .invalidParams(message: "not a directory: \(req.rootPath)", path: ["rootPath"]))
    }
    if let existing = manager.isPathRegistered(canonical: canonical) {
      return .failed(
        .conflict(reason: "\(canonical) is already project \(existing.description)"))
    }
    let gitRoot: String?
    if let supplied = req.gitRoot, !supplied.isEmpty {
      gitRoot = supplied
    } else {
      gitRoot = await gitRootDiscovery(canonical)
    }
    let id = manager.addProject(name: req.name, rootPath: canonical, gitRoot: gitRoot)
    await reconcileWorktrees(id)
    do {
      return .unary(
        try JSONValue.encoded(AddProjectResult(id: id, rootPath: canonical, gitRoot: gitRoot)))
    } catch {
      return .failed(.internal("encode addProject result: \(error)"))
    }
  }

  public struct CreateWorktreeParams: Codable, Sendable {
    public let projectID: ProjectID
    public let name: String
    /// Optional. When nil, the daemon resolves the base directory through
    /// `WorktreeSettings.resolveBaseDirectory` (per-project override → global
    /// `defaultWorktreesDirectory` → system fallback) and appends the
    /// sanitized branch name — mirroring the GUI's Create Worktree sheet.
    public let path: String?
    public let branch: String?
    /// When true, a same-canonical-path collision returns the existing
    /// row's id instead of `.conflict`, so a dispatcher replaying
    /// create-after-partial-failure stays idempotent. Absent ⇒ strict mode.
    public let reuseExisting: Bool?
    /// Committish a *new* branch starts from. Absent ⇒ the repo's default
    /// remote branch when it has one, else `HEAD` — the sheet's default.
    public let baseRef: String?

    public init(
      projectID: ProjectID, name: String, path: String?, branch: String?,
      reuseExisting: Bool?, baseRef: String? = nil
    ) {
      self.projectID = projectID
      self.name = name
      self.path = path
      self.branch = branch
      self.reuseExisting = reuseExisting
      self.baseRef = baseRef
    }
  }
  public struct CreateWorktreeResult: Codable, Sendable {
    public let id: WorktreeID
    public let path: String
    /// True when this call ran `git worktree add`; false when the path
    /// already existed and was registered as-is.
    public let created: Bool

    public init(id: WorktreeID, path: String, created: Bool = false) {
      self.id = id
      self.path = path
      self.created = created
    }
  }
  /// `hierarchy.createWorktree` — the CLI's New Worktree. A path that
  /// already exists on disk is registered as-is (adopting a worktree made
  /// elsewhere); a missing one is materialised first through the same
  /// `wt sw` pipeline the sheet runs, so the branch is created or checked
  /// out and the project's copy / fetch / setup settings apply. Remote
  /// projects and folder projects (no git root) stay catalog-only.
  public func createWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateWorktreeParams
    do {
      req = try params.decoded(as: CreateWorktreeParams.self)
    } catch {
      return .failed(.invalidParams(message: "createWorktree requires {projectID, name}", path: nil))
    }
    guard let project = manager.catalog.projects.first(where: { $0.id == req.projectID }) else {
      return .failed(.notFound(kind: "project", id: req.projectID.description))
    }
    let settings = settingsProvider()
    let resolvedPath: String
    if let explicit = req.path, !explicit.isEmpty {
      resolvedPath = explicit
    } else {
      guard let branch = req.branch, !branch.isEmpty else {
        return .failed(
          .invalidParams(
            message: "createWorktree requires either `path` or `branch` to derive the default path",
            path: nil
          ))
      }
      let baseDirectory = settings.worktree.resolveBaseDirectory(
        // The path-derived canonical name is the anchor for new worktree
        // directories — a user-set display name in Settings → General must
        // not redirect where the CLI proposes to create new worktrees.
        forProjectName: project.canonicalName,
        projectOverride: settings.projects[project.id]?.worktreesDirectory
      )
      let sanitized = GitWorktreeClient.sanitizeBranchName(branch)
      guard !sanitized.isEmpty else {
        return .failed(
          .invalidParams(
            message: "branch \"\(branch)\" produces an empty directory name",
            path: nil
          ))
      }
      resolvedPath = baseDirectory.appending(path: sanitized).path(percentEncoded: false)
    }

    var materializedPath = resolvedPath
    var created = false
    let alreadyRegistered = project.worktrees.contains {
      HierarchyManager.canonicalPath($0.path) == HierarchyManager.canonicalPath(resolvedPath)
    }
    if let worktreeCreator, !project.isRemote, !alreadyRegistered,
      let gitRoot = project.gitRoot, let branch = req.branch, !branch.isEmpty,
      !FileManager.default.fileExists(atPath: resolvedPath)
    {
      let repoRoot = URL(fileURLWithPath: gitRoot, isDirectory: true)
      let projectGit = settings.projects[project.id]?.git
      let baseRef: String
      if let explicit = req.baseRef, !explicit.isEmpty {
        baseRef = explicit
      } else if let pinned = projectGit?.worktreeBaseRef, !pinned.isEmpty {
        baseRef = pinned
      } else {
        baseRef = await defaultBaseRef(repoRoot) ?? ""
      }
      let target = URL(fileURLWithPath: resolvedPath, isDirectory: true)
      let spec = CreateWorktreeSpec(
        repoRoot: repoRoot,
        baseDirectory: target.deletingLastPathComponent(),
        name: branch,
        baseRef: baseRef,
        fetchOrigin: projectGit?.fetchRemoteOnWorktreeCreate ?? settings.worktree.fetchRemoteOnCreate,
        copyIgnored: projectGit?.copyIgnoredOnWorktreeCreate ?? settings.worktree.copyIgnoredOnCreate,
        copyUntracked: projectGit?.copyUntrackedOnWorktreeCreate
          ?? settings.worktree.copyUntrackedOnCreate,
        setupCommand: projectGit?.createScript?.command,
        pathOverride: target
      )
      do {
        materializedPath = try await worktreeCreator(spec).path(percentEncoded: false)
        created = true
      } catch let error as GitWorktreeError {
        return .failed(Self.ipcError(for: error))
      } catch {
        return .failed(.internal("git worktree add failed: \(error)"))
      }
    }
    do {
      let id = try manager.createWorktree(
        in: req.projectID,
        name: req.name,
        path: materializedPath,
        branch: req.branch,
        // A worktree this call just materialised may already have been
        // adopted by a reconcile pulse racing the stream; return that row
        // rather than failing against our own worktree.
        reuseExisting: (req.reuseExisting ?? false) || created
      )
      let canonical = HierarchyManager.canonicalPath(materializedPath)
      return .unary(
        try JSONValue.encoded(CreateWorktreeResult(id: id, path: canonical, created: created)))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.projectID.description)
    }
  }

  /// Git failures by what the caller should do: fix the request
  /// (invalid branch / unknown ref → user error), pick another branch or
  /// clean up (conflict), or read the underlying command's stderr.
  static func ipcError(for error: GitWorktreeError) -> IPCError {
    switch error {
    case .invalidBranchName(let name):
      return .invalidParams(message: "invalid branch name: \(name)", path: ["branch"])
    case .refNotFound(let ref):
      return .invalidParams(message: "ref not found: \(ref)", path: ["baseRef"])
    case .branchExists(let name):
      return .conflict(reason: "branch already exists: \(name)")
    case .uncommittedChanges(let files):
      return .conflict(reason: "uncommitted changes in \(files.count) file(s)")
    case .worktreeLocked(let path):
      return .conflict(reason: "worktree is locked: \(path)")
    case .fetchFailed(let stderr):
      return .internal("git fetch failed: \(stderr)")
    case .executableMissing:
      return .internal("git executable missing")
    case .commandFailed(let command, let stderr):
      return .internal("\(command): \(stderr)")
    }
  }

  public struct CreateTabParams: Codable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let name: String?
  }
  public func createTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateTabParams
    do {
      req = try params.decoded(as: CreateTabParams.self)
    } catch {
      return .failed(.invalidParams(message: "createTab requires {projectID, worktreeID}", path: nil))
    }
    do {
      let id = try manager.createTab(
        in: req.worktreeID,
        in: req.projectID,
        name: req.name
      )
      return .unary(try JSONValue.encoded(TabIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.worktreeID.description)
    }
  }

  public struct OpenPaneParams: Codable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let tabID: TabID
    public let workingDirectory: String
    public let initialCommand: String?
    public let labels: [String]
  }
  public func openPane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: OpenPaneParams
    do {
      req = try params.decoded(as: OpenPaneParams.self)
    } catch {
      return .failed(
        .invalidParams(
          message: "openPane requires {projectID, worktreeID, tabID, workingDirectory}", path: nil))
    }
    // Server (remote) projects: the CLI defaults `--cwd` to the CALLER's local
    // pwd, which is meaningless on the host — the remote shell would `cd` into
    // whatever local directory the caller happened to be in (when it exists on
    // the host) or fall back to `$HOME`. Accept the supplied cwd only when it
    // targets the worktree (or a subpath of it) on the host; otherwise land in
    // the worktree root, matching what the UI's tab/pane creation does.
    let workingDirectory = effectiveWorkingDirectory(
      req.workingDirectory, projectID: req.projectID, worktreeID: req.worktreeID)
    do {
      // Same env the sidebar's new-pane paths resolve: the project's own
      // `envVars` plus the always-on keys (socket, `CODANS_CLI`, the
      // `TERM_PROGRAM` marker). Without it a CLI-spawned pane inherited the
      // bare app environment, so `codans-dev` was off its PATH and the
      // product marker read `ghostty`.
      let id = try await manager.openPane(
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID,
        workingDirectory: workingDirectory,
        initialCommand: req.initialCommand,
        env: envProvider(req.projectID)
      )
      if !req.labels.isEmpty {
        // Propagate label-apply failure rather than silently dropping —
        // a caller passing labels on create expects them to stick, and
        // .unsupported / .conflict gives the CLI an actionable error
        // through CLIExitCode.from(_:).
        do {
          try manager.setPaneLabels(id, labels: Set(req.labels), replace: true)
        } catch {
          return .failed(.internal("pane created (id=\(id)) but setPaneLabels failed: \(error)"))
        }
      }
      return .unary(try JSONValue.encoded(PaneIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.tabID.description)
    }
  }

  /// The cwd a new pane in (`projectID`, `worktreeID`) starts in. Local
  /// projects take `requested` as-is; a remote project accepts it only when
  /// it targets the worktree (or a subpath) on the host, else the worktree
  /// root — see `openPane` for why.
  func effectiveWorkingDirectory(
    _ requested: String, projectID: ProjectID, worktreeID: WorktreeID
  ) -> String {
    guard let project = manager.catalog.projects.first(where: { $0.id == projectID }),
      project.isRemote,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return requested }
    let normalized = HierarchyManager.normalizeRemotePath(requested)
    let root = HierarchyManager.normalizeRemotePath(worktree.path)
    if normalized != root, !normalized.hasPrefix(root + "/") {
      return worktree.path
    }
    return requested
  }

  public struct SetPaneLabelsParams: Codable, Sendable {
    public let id: PaneID
    public let labels: [String]
    public let replace: Bool
  }
  public func setPaneLabels(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: SetPaneLabelsParams
    do {
      req = try params.decoded(as: SetPaneLabelsParams.self)
    } catch {
      return .failed(.invalidParams(message: "setPaneLabels requires {id, labels}", path: nil))
    }
    do {
      try manager.setPaneLabels(req.id, labels: Set(req.labels), replace: req.replace)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.id.description)
    }
  }

  // MARK: - Extended mutations

  public struct RemoveProjectParams: Codable, Sendable {
    public let id: ProjectID
  }
  public func removeProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RemoveProjectParams
    do { req = try params.decoded(as: RemoveProjectParams.self) } catch {
      return .failed(.invalidParams(message: "removeProject requires {id}", path: nil))
    }
    do {
      try manager.removeProject(req.id)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.id.description)
    }
  }

  public struct RemoveWorktreeParams: Codable, Sendable {
    public let id: WorktreeID
    public let projectID: ProjectID
    /// True: the sidebar's Remove Worktree — the git worktree, its directory,
    /// and (per Settings) its branch go too. Absent / false: only the catalog
    /// row is dropped; a real git worktree is re-adopted by the next
    /// reconcile, so this is only meaningful for adopted directories.
    public let deleteFromDisk: Bool?

    public init(id: WorktreeID, projectID: ProjectID, deleteFromDisk: Bool? = nil) {
      self.id = id
      self.projectID = projectID
      self.deleteFromDisk = deleteFromDisk
    }
  }
  public struct RemoveWorktreeResult: Codable, Sendable {
    public let id: WorktreeID
    public let deleted: Bool
    /// Non-fatal note from the git removal (e.g. the branch was kept
    /// because another checkout holds it).
    public let warning: String?
  }
  public func removeWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RemoveWorktreeParams
    do { req = try params.decoded(as: RemoveWorktreeParams.self) } catch {
      return .failed(.invalidParams(message: "removeWorktree requires {id, projectID}", path: nil))
    }
    do {
      var warning: String?
      if req.deleteFromDisk == true {
        guard let worktreeRemover else {
          return .failed(.unsupported(reason: "deleteFromDisk is not available in this build"))
        }
        warning = try await worktreeRemover(req.id, req.projectID)
      } else {
        try manager.removeWorktree(req.id, from: req.projectID)
      }
      return .unary(
        try JSONValue.encoded(
          RemoveWorktreeResult(id: req.id, deleted: req.deleteFromDisk == true, warning: warning)))
    } catch let error as GitWorktreeError {
      return .failed(Self.ipcError(for: error))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.id.description)
    }
  }

  public struct CloseTabParams: Codable, Sendable {
    public let id: TabID
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
  }
  public func closeTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CloseTabParams
    do { req = try params.decoded(as: CloseTabParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "closeTab requires {id, worktreeID, projectID}",
          path: nil
        ))
    }
    do {
      try manager.closeTab(req.id, in: req.worktreeID, in: req.projectID)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.id.description)
    }
  }

  public struct PaneLocatorParams: Codable, Sendable {
    public let id: PaneID
    public let tabID: TabID
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
  }
  public func closePane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: PaneLocatorParams
    do { req = try params.decoded(as: PaneLocatorParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "closePane requires {id, tabID, worktreeID, projectID}",
          path: nil
        ))
    }
    do {
      try manager.closePane(
        req.id,
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID
      )
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.id.description)
    }
  }

  /// Handles `pane.close` — the user's explicit termination verb. Sends
  /// `.kill` to the pane's zmx daemon (bounded ≤ 2 s wait for the
  /// control socket to vanish), drops the persisted session-catalog
  /// entry, and removes the pane from the in-memory hierarchy.
  ///
  /// Distinct from `hierarchy.closePane`: the latter detaches the
  /// libghostty surface so a future attach can resume the same daemon;
  /// this verb guarantees the daemon is gone before returning.
  ///
  /// Returns `closed == false` (without raising) when the pane is not
  /// present in the catalog — the CLI maps that to a non-zero exit so
  /// scripts can distinguish a successful kill from a missing pane.
  public func paneClose(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: IPC.PaneCloseRequest
    do {
      req = try params.decoded(as: IPC.PaneCloseRequest.self)
    } catch {
      return .failed(.invalidParams(message: "pane.close requires {paneID}", path: nil))
    }

    // Resolve the catalog location for `paneID`. Caller-supplied locator
    // fields take precedence so labels-already-resolved CLI invocations
    // skip the catalog walk; absent fields fall back to a scan.
    let locator: PaneLocator?
    if let tabID = req.tabID, let worktreeID = req.worktreeID, let projectID = req.projectID {
      locator = PaneLocator(
        paneID: req.paneID,
        tabID: tabID,
        worktreeID: worktreeID,
        projectID: projectID
      )
    } else {
      locator = findPaneLocator(req.paneID)
    }

    guard let locator else {
      // Pane is not in the catalog. Surface the catalog-state truthfully
      // so the CLI can tell apart "already closed" from "kill succeeded".
      let response = IPC.PaneCloseResponse(paneID: req.paneID, closed: false)
      return (try? JSONValue.encoded(response)).map(RouterOutcome.unary)
        ?? .failed(.internal("encode pane.close result"))
    }

    // Kill the daemon first. ZmxClient.kill polls for socket-file
    // disappearance with a 2 s cap, so this awaits at most that long
    // even if the daemon is wedged.
    await daemonKiller(req.paneID)

    // Reap the persisted session-catalog entry. Best-effort: a missing
    // coordinator (no-resume mode) or a save failure is non-fatal — log
    // and continue rather than failing the RPC, which only promises that
    // the daemon was killed.
    if let coordinator = sessionCoordinator {
      do {
        try coordinator.recordClose(req.paneID)
      } catch {
        logger.warning(
          "pane.close: sessions.json reap failed: \(String(describing: error), privacy: .public)"
        )
      }
    }

    // Tear down the in-memory hierarchy entry. The libghostty surface
    // close inside `manager.closePane` is now redundant (daemonKiller
    // already shut the daemon socket), but it stays idempotent so the
    // call remains the canonical place to update split-tree state.
    do {
      try manager.closePane(
        locator.paneID,
        in: locator.tabID,
        in: locator.worktreeID,
        in: locator.projectID
      )
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.paneID.description)
    }

    let response = IPC.PaneCloseResponse(paneID: req.paneID, closed: true)
    return (try? JSONValue.encoded(response)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode pane.close result"))
  }

  /// Handles `pane.info` — probe the pane's zmx daemon for shell pid,
  /// pwd, and (when available) cursor + terminal modes. The daemon's
  /// frozen `.Info` payload only carries `pid` + `cwd` today; `cursor`
  /// and `modes` are surfaced as `nil` so callers can fall back to
  /// `pane.read --raw` for byte-faithful assertions.
  public func paneInfo(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: IPC.PaneInfoRequest
    do {
      req = try params.decoded(as: IPC.PaneInfoRequest.self)
    } catch {
      return .failed(.invalidParams(message: "pane.info requires {paneID}", path: nil))
    }
    guard let probe = runtimeProbe(req.paneID) else {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    let payload: ZmxInfoPayload
    do {
      payload = try await probe.requestInfo()
    } catch {
      return .failed(.internal("pane.info: \(error)"))
    }
    let response = IPC.PaneInfoResponse(
      paneID: req.paneID,
      shellPid: payload.pid,
      pwd: payload.cwd,
      cursor: nil,
      modes: nil
    )
    return (try? JSONValue.encoded(response)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode pane.info result"))
  }

  /// Handles `pane.read` — pull serialized terminal state from the
  /// pane's zmx daemon. The daemon returns the full
  /// `serializeTerminalState` dump in the requested format (`plain`
  /// strips ANSI; `vt` keeps them, including cursor / modes / OSC 7).
  /// `range` and `tail` are applied client-side after the dump arrives.
  public func paneRead(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: IPC.PaneReadRequest
    do {
      req = try params.decoded(as: IPC.PaneReadRequest.self)
    } catch {
      return .failed(.invalidParams(message: "pane.read requires {paneID}", path: nil))
    }
    if let tail = req.tail, tail <= 0 {
      return .failed(.invalidParams(message: "tail must be a positive integer", path: ["tail"]))
    }
    guard let probe = runtimeProbe(req.paneID) else {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    let format: ZmxHistoryFormat = req.raw ? .vt : .plain
    let dump: Data
    do {
      dump = try await probe.readHistory(format: format)
    } catch {
      return .failed(.internal("pane.read: \(error)"))
    }
    let content = String(data: dump, encoding: .utf8) ?? ""
    let filtered = Self.applyRange(content, range: req.range)
    let trimmed = Self.applyTail(filtered, tail: req.tail)
    let response = IPC.PaneReadResponse(
      paneID: req.paneID,
      format: req.raw ? .vt : .plain,
      content: trimmed
    )
    return (try? JSONValue.encoded(response)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode pane.read result"))
  }

  /// Client-side range filtering. The daemon dumps scrollback above
  /// the viewport followed by the viewport itself; we split on a blank
  /// row boundary as an approximation since the dump is not annotated
  /// with the split point. `all` is the canonical (pass-through) shape;
  /// `visible` / `scrollback` are best-effort filters until the daemon
  /// learns to label the boundary.
  static func applyRange(_ content: String, range: IPC.PaneReadRange) -> String {
    switch range {
    case .all:
      return content
    case .visible, .scrollback:
      // The daemon's serializer does not currently annotate the
      // scrollback / viewport boundary. Return the full dump so
      // callers see everything; the CLI documents this limitation.
      return content
    }
  }

  /// Trim to the last N newline-delimited rows. `nil` is a no-op.
  static func applyTail(_ content: String, tail: Int?) -> String {
    guard let tail else { return content }
    let rows = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if rows.count <= tail { return content }
    return rows.suffix(tail).joined(separator: "\n")
  }

  private struct PaneLocator {
    let paneID: PaneID
    let tabID: TabID
    let worktreeID: WorktreeID
    let projectID: ProjectID
  }

  /// Walk the catalog looking for the project/worktree/tab triple that
  /// owns `paneID`. Returns nil when no project contains a pane with
  /// that id — caller maps to `closed == false`.
  private func findPaneLocator(_ paneID: PaneID) -> PaneLocator? {
    for project in manager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return PaneLocator(
            paneID: paneID,
            tabID: tab.id,
            worktreeID: worktree.id,
            projectID: project.id
          )
        }
      }
    }
    return nil
  }

  public func focusPane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: PaneLocatorParams
    do { req = try params.decoded(as: PaneLocatorParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "focusPane requires {id, tabID, worktreeID, projectID}",
          path: nil
        ))
    }
    do {
      try manager.selectWorktree(req.worktreeID, in: req.projectID)
      try manager.selectTab(req.tabID, in: req.worktreeID, in: req.projectID)
      try manager.focusPane(
        req.id,
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID
      )
      try await manager.ensurePaneSurface(
        req.id,
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID,
        env: envProvider(req.projectID)
      )
      manager.focusSurfaceView(for: req.id)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.id.description)
    }
  }

  // MARK: - Extended reads

  /// Optional `tag` / `untagged` filters mirror the CLI surface
  /// (`codans project list --tag <id> | --untagged`). Both absent (e.g. a
  /// `{}` body) yields the unfiltered project list; passing both is a
  /// caller error.
  public struct ListProjectsParams: Codable, Sendable {
    public let tag: TagID?
    public let untagged: Bool?
  }
  public func listProjects(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListProjectsParams
    do {
      req = try params.decoded(as: ListProjectsParams.self)
    } catch {
      // Empty params body is valid — fall back to the unfiltered listing.
      req = ListProjectsParams(tag: nil, untagged: nil)
    }
    if req.tag != nil, req.untagged == true {
      return .failed(
        .invalidParams(message: "listProjects: pass at most one of {tag, untagged}", path: nil))
    }
    let all = overlayLivePaneDirectories(in: manager.catalog.projects)
    let filtered: [Project]
    if req.untagged == true {
      filtered = all.filter { $0.tagIDs.isEmpty }
    } else if let tagID = req.tag {
      filtered = all.filter { $0.tagIDs.contains(tagID) }
    } else {
      filtered = all
    }
    // Sync against the full catalog (not the tag-filtered slice) so a
    // filtered listing never shifts handle assignment order.
    handleRegistry.sync(with: manager.catalog)
    let handles = handleRegistry.snapshot()
    return await Self.encodeOffMain("listProjects") {
      try JSONValue.encoded(ListProjectsPayload(projects: filtered, handles: handles))
    }
  }

  // MARK: - Tag mutations and reads

  public func listTags(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    do {
      return .unary(try JSONValue.encoded(ListTagsPayload(tags: manager.catalog.tags)))
    } catch {
      return .failed(.internal("encode listTags: \(error)"))
    }
  }

  public struct CreateTagParams: Codable, Sendable {
    public let name: String
    public let color: String  // TagColor.rawValue
  }
  public func createTag(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateTagParams
    do {
      req = try params.decoded(as: CreateTagParams.self)
    } catch {
      return .failed(.invalidParams(message: "createTag requires {name, color}", path: nil))
    }
    guard let color = TagColor(rawValue: req.color) else {
      let valid = TagColor.allCases.map(\.rawValue).joined(separator: "|")
      return .failed(
        .invalidParams(
          message: "unknown color '\(req.color)'; expected one of \(valid)",
          path: ["color"]))
    }
    let id = manager.createTag(name: req.name, color: color)
    do {
      return .unary(try JSONValue.encoded(TagIDPayload(id: id)))
    } catch {
      return .failed(.internal("encode createTag: \(error)"))
    }
  }

  public struct RenameTagParams: Codable, Sendable {
    public let id: TagID
    public let name: String
  }
  public func renameTag(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RenameTagParams
    do {
      req = try params.decoded(as: RenameTagParams.self)
    } catch {
      return .failed(.invalidParams(message: "renameTag requires {id, name}", path: nil))
    }
    guard manager.catalog.tags.contains(where: { $0.id == req.id }) else {
      return .failed(.notFound(kind: "tag", id: req.id.description))
    }
    manager.renameTag(req.id, to: req.name)
    return .unary(.object([:]))
  }

  public struct RecolorTagParams: Codable, Sendable {
    public let id: TagID
    public let color: String  // TagColor.rawValue
  }
  public func recolorTag(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RecolorTagParams
    do {
      req = try params.decoded(as: RecolorTagParams.self)
    } catch {
      return .failed(.invalidParams(message: "recolorTag requires {id, color}", path: nil))
    }
    guard let color = TagColor(rawValue: req.color) else {
      let valid = TagColor.allCases.map(\.rawValue).joined(separator: "|")
      return .failed(
        .invalidParams(
          message: "unknown color '\(req.color)'; expected one of \(valid)",
          path: ["color"]))
    }
    guard manager.catalog.tags.contains(where: { $0.id == req.id }) else {
      return .failed(.notFound(kind: "tag", id: req.id.description))
    }
    manager.recolorTag(req.id, to: color)
    return .unary(.object([:]))
  }

  public struct RemoveTagParams: Codable, Sendable {
    public let id: TagID
  }
  public func removeTag(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RemoveTagParams
    do {
      req = try params.decoded(as: RemoveTagParams.self)
    } catch {
      return .failed(.invalidParams(message: "removeTag requires {id}", path: nil))
    }
    guard manager.catalog.tags.contains(where: { $0.id == req.id }) else {
      return .failed(.notFound(kind: "tag", id: req.id.description))
    }
    manager.removeTag(req.id)
    return .unary(.object([:]))
  }

  public struct SetProjectTagsParams: Codable, Sendable {
    public let projectID: ProjectID
    public let tagIDs: [TagID]
  }
  public func setProjectTags(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: SetProjectTagsParams
    do {
      req = try params.decoded(as: SetProjectTagsParams.self)
    } catch {
      return .failed(
        .invalidParams(message: "setProjectTags requires {projectID, tagIDs}", path: nil))
    }
    guard manager.catalog.projects.contains(where: { $0.id == req.projectID }) else {
      return .failed(.notFound(kind: "project", id: req.projectID.description))
    }
    manager.setProjectTags(req.projectID, tags: Set(req.tagIDs))
    return .unary(.object([:]))
  }

  public struct SetActiveTagFilterParams: Codable, Sendable {
    public let filter: TagFilter
  }
  public func setActiveTagFilter(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: SetActiveTagFilterParams
    do {
      req = try params.decoded(as: SetActiveTagFilterParams.self)
    } catch {
      return .failed(
        .invalidParams(message: "setActiveTagFilter requires {filter}", path: nil))
    }
    manager.setActiveTagFilter(req.filter)
    return .unary(.object([:]))
  }

  public struct ListWorktreesParams: Codable, Sendable {
    public let projectID: ProjectID
  }
  public func listWorktrees(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListWorktreesParams
    do { req = try params.decoded(as: ListWorktreesParams.self) } catch {
      return .failed(.invalidParams(message: "listWorktrees requires {projectID}", path: nil))
    }
    guard let project = manager.catalog.projects.first(where: { $0.id == req.projectID })
    else {
      return .failed(.notFound(kind: "project", id: req.projectID.description))
    }
    let worktrees = overlayLivePaneDirectories(in: project.worktrees)
    return await Self.encodeOffMain("listWorktrees") {
      try JSONValue.encoded(ListWorktreesPayload(worktrees: worktrees))
    }
  }

  public struct ListTabsParams: Codable, Sendable {
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
  }
  public func listTabs(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListTabsParams
    do { req = try params.decoded(as: ListTabsParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "listTabs requires {worktreeID, projectID}",
          path: nil
        ))
    }
    guard let project = manager.catalog.projects.first(where: { $0.id == req.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == req.worktreeID })
    else {
      return .failed(.notFound(kind: "worktree", id: req.worktreeID.description))
    }
    let tabs = overlayLivePaneDirectories(in: worktree.tabs)
    return await Self.encodeOffMain("listTabs") {
      try JSONValue.encoded(ListTabsPayload(tabs: tabs))
    }
  }

  public struct ListPanesParams: Codable, Sendable {
    public let tabID: TabID
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
  }
  public func listPanes(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListPanesParams
    do { req = try params.decoded(as: ListPanesParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "listPanes requires {tabID, worktreeID, projectID}",
          path: nil
        ))
    }
    guard let project = manager.catalog.projects.first(where: { $0.id == req.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == req.worktreeID }),
      let tab = worktree.tabs.first(where: { $0.id == req.tabID })
    else {
      return .failed(.notFound(kind: "tab", id: req.tabID.description))
    }
    let panes = overlayLivePaneDirectories(in: tab.panes)
    return await Self.encodeOffMain("listPanes") {
      try JSONValue.encoded(ListPanesPayload(panes: panes))
    }
  }

  private func overlayLivePaneDirectories(in projects: [Project]) -> [Project] {
    projects.map { project in
      var copy = project
      copy.worktrees = overlayLivePaneDirectories(in: project.worktrees)
      return copy
    }
  }

  private func overlayLivePaneDirectories(in worktrees: [Worktree]) -> [Worktree] {
    worktrees.map { worktree in
      var copy = worktree
      copy.tabs = overlayLivePaneDirectories(in: worktree.tabs)
      return copy
    }
  }

  private func overlayLivePaneDirectories(in tabs: [Tab]) -> [Tab] {
    tabs.map { tab in
      var copy = tab
      copy.panes = overlayLivePaneDirectories(in: tab.panes)
      return copy
    }
  }

  func overlayLivePaneDirectories(in panes: [Pane]) -> [Pane] {
    panes.map { pane in
      guard let cwd = manager.currentWorkingDirectory(for: pane.id) else {
        return pane
      }
      var copy = pane
      copy.workingDirectory = cwd
      return copy
    }
  }

  // MARK: - Encoding helpers

  /// Run a JSON-encoding closure off the main actor. Catalog snapshots are
  /// `Sendable` value types, so we hand them to a detached Task and await
  /// the result — keeping a large `listProjects` from starving every other
  /// `@MainActor` RPC and SwiftUI tick behind it. The closure is the only
  /// part that runs off main; the snapshot capture itself happens here on
  /// main, which is correct for reading `manager.catalog`.
  nonisolated private static func encodeOffMain(
    _ label: String,
    _ encode: sending @escaping () throws -> JSONValue
  ) async -> RouterOutcome {
    do {
      let value = try await Task.detached(priority: .userInitiated) {
        try encode()
      }.value
      return .unary(value)
    } catch {
      return .failed(.internal("encode \(label): \(error)"))
    }
  }
}

// MARK: - Response payload types (shared with CLI CodansKit)

// `nonisolated` on the conformance so `encodeOffMain` can call `encode(to:)`
// from a detached Task without tripping `InferIsolatedConformances` —
// the file otherwise infers `@MainActor` for every type defined in it.
nonisolated struct ListProjectsPayload: Codable, Sendable {
  let projects: [Project]
  /// Short-handle map for the CLI's text renderer. Optional so the
  /// payload keeps decoding fixtures and responses that predate handles.
  let handles: IPC.TargetHandles?

  init(projects: [Project], handles: IPC.TargetHandles? = nil) {
    self.projects = projects
    self.handles = handles
  }
}
nonisolated struct ListWorktreesPayload: Codable, Sendable { let worktrees: [Worktree] }
nonisolated struct ListTabsPayload: Codable, Sendable { let tabs: [Tab] }
nonisolated struct ListPanesPayload: Codable, Sendable { let panes: [Pane] }
struct ListTagsPayload: Codable, Sendable { let tags: [Tag] }
struct ProjectIDPayload: Codable, Sendable { let id: ProjectID }
struct TabIDPayload: Codable, Sendable { let id: TabID }
struct PaneIDPayload: Codable, Sendable { let id: PaneID }
struct TagIDPayload: Codable, Sendable { let id: TagID }
