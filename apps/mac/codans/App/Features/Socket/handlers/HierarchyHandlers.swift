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
/// reach the daemon out-of-band by ContentID rather than through a held client.
@MainActor
final class ZmxControlProbe: PaneRuntimeProbe {
  private let contentID: ContentID
  init(contentID: ContentID) { self.contentID = contentID }
  func requestInfo() async throws -> ZmxInfoPayload {
    try await ZmxControlClient.info(for: contentID)
  }
  func readHistory(format: ZmxHistoryFormat) async throws -> Data {
    try await ZmxControlClient.history(for: contentID, format: format)
  }
}

extension IPC.AliasResolveRequest.Kind {
  /// Kinds that name a session's level: any of the three ids, a `@label`,
  /// or a `t<n>` / `p<n>` handle resolves to them.
  var isSessionLevel: Bool {
    switch self {
    case .pane, .tab, .content: return true
    case .project, .worktree, .tag: return false
    }
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
  /// Closure that sends `.kill` to the zmx daemon backing `contentID` and
  /// waits for its control socket to disappear. Returns once the daemon
  /// is gone or the bounded timeout elapses. Injected so handlers stay
  /// independent of the libghostty surface registry; default is a no-op
  /// for tests that exercise the catalog-side mutation in isolation.
  private let daemonKiller: @MainActor (ContentID) async -> Void
  /// Probe surface for `pane.info` / `pane.read`. Returns a typed
  /// `PaneRuntimeProbe` view of the live `ZmxClient` for `contentID`, or
  /// `nil` when no surface is bound (no live daemon to talk to). Kept
  /// behind a protocol so tests can inject a fake without dragging
  /// `GhosttyRuntime` into the test target.
  let runtimeProbe: @MainActor (ContentID) -> PaneRuntimeProbe?
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
  private let callerPaneResolver: @MainActor (pid_t) -> ContentID?
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
  /// Starts an agent profile in a worktree — the New Agent dialog's pipeline —
  /// for `hierarchy.createWorktree`'s `agentProfile` / `agent`. `nil` makes
  /// those params unsupported (tests, harness).
  private let agentLauncher: (@MainActor @Sendable (AgentLaunchSpec) async throws -> AgentLaunchOutcome)?
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "hierarchy")

  init(
    manager: HierarchyManager,
    handleRegistry: TargetHandleRegistry = TargetHandleRegistry(),
    envProvider: @escaping @MainActor (ProjectID) -> [String: String] = { _ in [:] },
    settingsProvider: @escaping @MainActor () -> Settings = { Settings() },
    daemonKiller: @escaping @MainActor (ContentID) async -> Void = { _ in },
    runtimeProbe: @escaping @MainActor (ContentID) -> PaneRuntimeProbe? = { _ in nil },
    sessionCoordinator: SessionCoordinator? = nil,
    callerPaneResolver: @escaping @MainActor (pid_t) -> ContentID? = { _ in nil },
    gitRootDiscovery: @escaping @MainActor (String) async -> String? = { _ in nil },
    reconcileWorktrees: @escaping @MainActor (ProjectID) async -> Void = { _ in },
    worktreeCreator: (@MainActor @Sendable (CreateWorktreeSpec) async throws -> URL)? = nil,
    defaultBaseRef: @escaping @MainActor (URL) async -> String? = { _ in nil },
    worktreeRemover: (@MainActor @Sendable (WorktreeID, ProjectID) async throws -> String?)? = nil,
    worktreePruner: (@MainActor @Sendable (URL) async throws -> Int)? = nil,
    agentLauncher: (@MainActor @Sendable (AgentLaunchSpec) async throws -> AgentLaunchOutcome)? = nil
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
    self.agentLauncher = agentLauncher
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
      case .directoryMissing(let path):
        return .failed(.notFound(kind: "directory", id: path))
      }
    }
    return .failed(.internal("\(error)"))
  }

  // MARK: - Reads

  /// `hierarchy.resolveAlias` — turn a string identifier into the
  /// canonical UUID for `kind`. Supports the set the CLI drives: Pane, Tab
  /// and Content ids (converted to the requested level), `current` / `.`
  /// (the calling Tab, attributed from `peerPID` + process ancestry or the
  /// request's `contextContentID`, and for the other kinds the Tab's
  /// containers), Content labels (`@label`), short target handles (`p<n>`
  /// for Panes, `t<n>` for Tabs), and names — a project's name, a
  /// worktree's name or branch, a Tab's title — scoped to the calling
  /// Tab's containers when there is one.
  public func resolveAlias(_ params: JSONValue, peerPID: pid_t? = nil) async -> RouterOutcome {
    await Task.yield()
    let request: IPC.AliasResolveRequest
    do {
      request = try params.decoded(as: IPC.AliasResolveRequest.self)
    } catch {
      return .failed(.invalidParams(message: "resolveAlias requires {kind, value}", path: nil))
    }
    if let uuid = UUID(uuidString: request.value) {
      guard let match = convert(uuid, to: request.kind) else {
        return .failed(.notFound(kind: request.kind.rawValue, id: request.value))
      }
      return resolved(request.kind, match)
    }
    if request.value == "current" || request.value == "." {
      return resolveCurrent(request, peerPID: peerPID)
    }
    if request.value == Self.selectedPronoun, request.kind == .project || request.kind == .worktree {
      return resolveSelected(request)
    }
    if request.kind.isSessionLevel, request.value.hasPrefix("@") {
      let label = String(request.value.dropFirst())
      let matches = Self.contentsMatchingLabel(label: label, catalog: manager.catalog)
      if matches.count == 1, let match = convert(matches[0].raw, to: request.kind) {
        return resolved(request.kind, match)
      }
      if matches.count > 1 {
        return .failed(.conflict(reason: "label @\(label) matches \(matches.count) tabs"))
      }
      return .failed(.notFound(kind: request.kind.rawValue, id: "@\(label)"))
    }
    if request.kind.isSessionLevel, let handle = TargetHandleRegistry.parse(request.value, prefix: "t") {
      handleRegistry.sync(with: manager.catalog)
      guard let tabID = handleRegistry.tab(forHandle: handle), let match = convert(tabID.raw, to: request.kind)
      else {
        return .failed(.notFound(kind: "tab", id: request.value))
      }
      return resolved(request.kind, match)
    }
    if request.kind.isSessionLevel, let handle = TargetHandleRegistry.parse(request.value, prefix: "p") {
      handleRegistry.sync(with: manager.catalog)
      guard let paneID = handleRegistry.pane(forHandle: handle), let match = convert(paneID.raw, to: request.kind)
      else {
        return .failed(.notFound(kind: "pane", id: request.value))
      }
      return resolved(request.kind, match)
    }
    return resolveByName(request, peerPID: peerPID)
  }

  /// An id converted to the level a verb needs, with the level the id
  /// itself named.
  struct ResolvedID {
    let id: UUID
    let matched: IPC.AliasResolveRequest.Kind?
  }

  /// Any id position accepts a Pane, Tab or Content id and resolves to the
  /// level the verb needs: a Content or Tab names its owning Pane; a Pane
  /// (its selected Tab) or Content names its Tab; a Tab or Pane (its
  /// selected Tab) names its Content. Project / Worktree / Tag ids pass
  /// through. `nil` when the id is not in the catalog.
  func convert(_ uuid: UUID, to kind: IPC.AliasResolveRequest.Kind) -> ResolvedID? {
    let catalog = manager.catalog
    guard kind.isSessionLevel else { return ResolvedID(id: uuid, matched: nil) }
    if let pane = catalog.pane(PaneID(raw: uuid)) {
      let id: UUID? =
        switch kind {
        case .pane: pane.id.raw
        case .tab: pane.selectedTabID?.raw
        default: pane.selectedTab?.contentID.raw
        }
      return id.map { ResolvedID(id: $0, matched: .pane) }
    }
    if let tab = catalog.tab(TabID(raw: uuid)) {
      let id: UUID? =
        switch kind {
        case .pane: catalog.paneID(forTab: tab.id)?.raw
        case .tab: tab.id.raw
        default: tab.contentID.raw
        }
      return id.map { ResolvedID(id: $0, matched: .tab) }
    }
    let contentID = ContentID(raw: uuid)
    guard catalog.content(contentID) != nil else { return nil }
    let id: UUID? =
      switch kind {
      case .pane: catalog.paneID(forContent: contentID)?.raw
      case .tab: catalog.tabID(forContent: contentID)?.raw
      default: contentID.raw
      }
    return id.map { ResolvedID(id: $0, matched: .content) }
  }

  private func resolved(_ kind: IPC.AliasResolveRequest.Kind, _ match: ResolvedID) -> RouterOutcome {
    let result = IPC.AliasResolveResult(kind: kind, id: match.id, matched: match.matched)
    return (try? JSONValue.encoded(result)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode resolveAlias result"))
  }

  private func resolved(_ kind: IPC.AliasResolveRequest.Kind, _ id: UUID) -> RouterOutcome {
    resolved(kind, ResolvedID(id: id, matched: kind.isSessionLevel ? kind : nil))
  }

  /// The session a request comes from. Kernel peer-PID attribution wins
  /// over the request's env-derived `contextContentID`: the former is
  /// ground truth, the latter is the caller's claim.
  private func callerContent(_ request: IPC.AliasResolveRequest, peerPID: pid_t?) -> ContentID? {
    peerPID.flatMap { callerPaneResolver($0) } ?? request.contextContentID
  }

  /// `current` / `.`, server-side. The CLI resolves the pronoun from the
  /// Tab's `CODANS_PANE_ID` / `CODANS_TAB_ID` / `CODANS_CONTENT_ID`
  /// locally and dials only when that variable is missing (agent-spawned
  /// subshells, wrappers, env-scrubbing tools) or when it needs a
  /// container the Tab never exports, so `--project current` and friends
  /// land here and are read off the catalog row that holds the calling
  /// Tab.
  private func resolveCurrent(
    _ request: IPC.AliasResolveRequest, peerPID: pid_t?
  ) -> RouterOutcome {
    guard let content = callerContent(request, peerPID: peerPID) else {
      return .failed(.notFound(kind: request.kind.rawValue, id: request.value))
    }
    let catalog = manager.catalog
    let id: UUID?
    switch request.kind {
    case .content: id = content.raw
    case .tab: id = catalog.tabID(forContent: content)?.raw
    case .pane: id = catalog.paneID(forContent: content)?.raw
    case .worktree: id = catalog.worktreeID(forContent: content)?.raw
    case .project: id = catalog.projectID(forContent: content)?.raw
    case .tag: id = nil
    }
    guard let id else {
      return .failed(.notFound(kind: request.kind.rawValue, id: request.value))
    }
    return resolved(request.kind, id)
  }

  /// `@selected` — the project / worktree the window shows. A caller
  /// outside any Tab (a plain terminal) has no `current` and must name its
  /// containers; this pronoun is the explicit way to name the shown ones.
  static let selectedPronoun = "@selected"

  private func resolveSelected(_ request: IPC.AliasResolveRequest) -> RouterOutcome {
    let catalog = manager.catalog
    let projectID = catalog.displayedSelectedProjectID
    let id: UUID? =
      request.kind == .project
      ? projectID?.raw
      : catalog.projects.first(where: { $0.id == projectID })?.selectedWorktreeID?.raw
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
    let caller = callerContent(request, peerPID: peerPID)
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
      let scope = caller.flatMap { catalog.projectID(forContent: $0) }
      for project in catalog.projects where scope == nil || project.id == scope {
        for worktree in project.worktrees where !worktree.archived {
          if worktree.name.lowercased() == needle || worktree.branch?.lowercased() == needle {
            matches.append(worktree.id.raw)
          }
        }
      }
    case .tab:
      let scope = caller.flatMap { catalog.worktreeID(forContent: $0) }
      for project in catalog.projects {
        for worktree in project.worktrees where scope == nil || worktree.id == scope {
          for tab in worktree.allTabs {
            let title = tab.name ?? tab.cachedDisplayTitle
            if title?.lowercased() == needle {
              matches.append(tab.id.raw)
            }
          }
        }
      }
    case .pane, .content:
      return .failed(
        .invalidParams(
          message:
            "unknown \(request.kind.rawValue) \"\(request.value)\"; pass an id, a p<n> / t<n> handle, @label, "
            + "or current (quote multi-word text)",
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

  private static func contentsMatchingLabel(label: String, catalog: Catalog) -> [ContentID] {
    var matches: [ContentID] = []
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.allTabs where tab.content.terminal?.labels.contains(label) == true {
          matches.append(tab.contentID)
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
    // A folder carrying `.codans/workspace.json` registers as a workspace
    // root, whatever `gitRoot` the caller sent: it is never probed for one,
    // and the reconcile below takes its manifest path, not the git one.
    let isWorkspace = WorkspaceManifestStore.hasManifest(rootPath: canonical)
    let gitRoot: String?
    if isWorkspace {
      gitRoot = nil
    } else if let supplied = req.gitRoot, !supplied.isEmpty {
      gitRoot = supplied
    } else {
      gitRoot = await gitRootDiscovery(canonical)
    }
    let id = manager.addProject(name: req.name, rootPath: canonical, gitRoot: gitRoot, isWorkspace: isWorkspace)
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
    /// Agent profile (name or id) to start in the worktree once it — and
    /// the project's setup script — is in place; the New Worktree sheet's
    /// "Launch agent". Resolved like `agent.launch`: with only `agent`, that
    /// agent's first enabled profile. Both absent ⇒ no agent.
    public let agentProfile: String?
    /// Agent token (claude, codex, …) narrowing or standing in for
    /// `agentProfile`.
    public let agent: String?

    public init(
      projectID: ProjectID, name: String, path: String?, branch: String?,
      reuseExisting: Bool?, baseRef: String? = nil,
      agentProfile: String? = nil, agent: String? = nil
    ) {
      self.projectID = projectID
      self.name = name
      self.path = path
      self.branch = branch
      self.reuseExisting = reuseExisting
      self.baseRef = baseRef
      self.agentProfile = agentProfile
      self.agent = agent
    }
  }
  public struct CreateWorktreeResult: Codable, Sendable {
    public let id: WorktreeID
    public let path: String
    /// True when this call ran `git worktree add`; false when the path
    /// already existed and was registered as-is.
    public let created: Bool
    /// The agent started in the new worktree; absent when none was asked for.
    public let agent: IPC.AgentLaunchResponse?

    public init(
      id: WorktreeID, path: String, created: Bool = false, agent: IPC.AgentLaunchResponse? = nil
    ) {
      self.id = id
      self.path = path
      self.created = created
      self.agent = agent
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
    // A workspace's rows are checkouts of other repositories, materialized on
    // disk by the workspace flow; a catalog-only row under a workspace would
    // point at nothing and carry no source repository.
    if project.isWorkspace {
      return .failed(
        .invalidParams(
          message: "createWorktree is not available on a workspace; use `workspace add`",
          path: nil
        ))
    }
    let settings = settingsProvider()
    // Resolve the agent up front so an unknown or disabled profile fails the
    // call before anything lands on disk.
    let agentProfile: AgentProfile?
    switch resolveCreateAgent(req, agents: settings.agents) {
    case .success(let profile): agentProfile = profile
    case .failure(let error): return .failed(error)
    }
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
      let spec = await materializeSpec(
        req, branch: branch, gitRoot: gitRoot, path: resolvedPath,
        projectGit: settings.projects[project.id]?.git, worktree: settings.worktree)
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
      let launch = await launchCreateAgent(
        agentProfile, projectID: req.projectID, worktreeID: id, path: canonical)
      let launched: IPC.AgentLaunchResponse?
      switch launch {
      case .success(let response): launched = response
      case .failure(let error): return .failed(error)
      }
      return .unary(
        try JSONValue.encoded(
          CreateWorktreeResult(id: id, path: canonical, created: created, agent: launched)))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.projectID.description)
    }
  }

  /// The profile `hierarchy.createWorktree` should start, `nil` when the
  /// request names none.
  private func resolveCreateAgent(
    _ req: CreateWorktreeParams, agents: AgentSettings
  ) -> Result<AgentProfile?, IPCError> {
    guard req.agentProfile != nil || req.agent != nil else { return .success(nil) }
    guard agentLauncher != nil else {
      return .failure(.unsupported(reason: "launching an agent is not available here"))
    }
    do {
      return .success(
        try AgentProfileSelector.resolveLaunchable(
          selector: req.agentProfile, agentToken: req.agent, in: agents))
    } catch let error as IPCError {
      return .failure(error)
    } catch {
      return .failure(.internal("resolve agent profile: \(error)"))
    }
  }

  /// The `wt sw` spec for a worktree `hierarchy.createWorktree` must put on
  /// disk: the sheet's pipeline with the project's effective copy / fetch /
  /// setup settings. Base ref: explicit → project pin → repo default.
  private func materializeSpec(
    _ req: CreateWorktreeParams, branch: String, gitRoot: String, path: String,
    projectGit: GitProjectSettings?, worktree: WorktreeSettings
  ) async -> CreateWorktreeSpec {
    let repoRoot = URL(fileURLWithPath: gitRoot, isDirectory: true)
    let baseRef: String
    if let explicit = req.baseRef, !explicit.isEmpty {
      baseRef = explicit
    } else if let pinned = projectGit?.worktreeBaseRef, !pinned.isEmpty {
      baseRef = pinned
    } else {
      baseRef = await defaultBaseRef(repoRoot) ?? ""
    }
    let target = URL(fileURLWithPath: path, isDirectory: true)
    return CreateWorktreeSpec(
      repoRoot: repoRoot,
      baseDirectory: target.deletingLastPathComponent(),
      name: branch,
      baseRef: baseRef,
      fetchOrigin: projectGit?.fetchRemoteOnWorktreeCreate ?? worktree.fetchRemoteOnCreate,
      copyIgnored: projectGit?.copyIgnoredOnWorktreeCreate ?? worktree.copyIgnoredOnCreate,
      copyUntracked: projectGit?.copyUntrackedOnWorktreeCreate ?? worktree.copyUntrackedOnCreate,
      setupCommand: projectGit?.createScript?.command,
      pathOverride: target
    )
  }

  /// Starts `profile` (if any) in the worktree `hierarchy.createWorktree`
  /// just registered. Called with no suspension after the catalog write, so
  /// the agent's tab exists before the selection change reaches the root
  /// reducer and its auto-seed finds tabs already.
  private func launchCreateAgent(
    _ profile: AgentProfile?, projectID: ProjectID, worktreeID: WorktreeID, path: String
  ) async -> Result<IPC.AgentLaunchResponse?, IPCError> {
    guard let profile else { return .success(nil) }
    guard let agentLauncher else {
      return .failure(.unsupported(reason: "launching an agent is not available here"))
    }
    do {
      let outcome = try await agentLauncher(
        AgentLaunchSpec(profile: profile, projectID: projectID, worktreeID: worktreeID))
      return .success(
        IPC.AgentLaunchResponse(
          profileID: outcome.profile.id,
          profileName: outcome.profile.displayName,
          agent: outcome.profile.kind.rawValue,
          command: outcome.command,
          tabID: outcome.tabID,
          contentID: outcome.contentID,
          paneID: outcome.paneID
        ))
    } catch {
      return .failure(
        .internal(
          "worktree \(worktreeID.description) is ready at \(path), but launching "
            + "\(profile.displayName) failed: \(error)"))
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
    /// The Pane whose strip takes the Tab: a Pane id, or a Tab / Content id
    /// (its Pane). Absent → the Worktree's focused Pane; a Worktree with no
    /// Pane gets its first one.
    public let paneID: UUID?
    public let name: String?
    /// Absent → the worktree root.
    public let workingDirectory: String?
    public let initialCommand: String?
    public let labels: [String]?
  }
  /// The Tab a spawn produced: the CLI drives it right away by any of the
  /// three ids.
  public struct CreatedTab: Codable, Sendable {
    public let id: TabID
    public let handle: String?
    public let paneID: PaneID
    public let contentID: ContentID
  }
  /// `hierarchy.createTab` — a new Tab at the end of a Pane's strip,
  /// selected, with its terminal started at once and the project env every
  /// CLI-spawned session gets.
  public func createTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateTabParams
    do {
      req = try params.decoded(as: CreateTabParams.self)
    } catch {
      return .failed(.invalidParams(message: "createTab requires {projectID, worktreeID}", path: nil))
    }
    guard
      let worktree = manager.catalog.projects.first(where: { $0.id == req.projectID })?
        .worktrees.first(where: { $0.id == req.worktreeID })
    else {
      return .failed(.notFound(kind: "worktree", id: req.worktreeID.description))
    }
    var hostPane: PaneID?
    if let requested = req.paneID {
      guard let paneID = layoutPane(for: requested) else {
        return .failed(.notFound(kind: "pane", id: requested.uuidString))
      }
      guard worktree.pane(paneID) != nil else {
        return .failed(
          .invalidParams(
            message: "pane \(paneID.description) is not in worktree \(worktree.name)", path: ["paneID"]))
      }
      hostPane = paneID
    }
    // Server (remote) projects: the CLI defaults the cwd to the caller's
    // local pwd, which is meaningless on the host; see
    // `effectiveWorkingDirectory`.
    let workingDirectory = effectiveWorkingDirectory(
      req.workingDirectory ?? worktree.path, projectID: req.projectID, worktreeID: req.worktreeID)
    do {
      try manager.requireLocalDirectory(workingDirectory, in: req.projectID)
      let created = try manager.newTab(
        in: hostPane, worktreeID: req.worktreeID, projectID: req.projectID,
        content: .terminal(
          workingDirectory: workingDirectory, initialCommand: req.initialCommand, labels: Set(req.labels ?? [])),
        name: req.name
      )
      try await manager.ensureSurface(for: created.contentID, env: envProvider(req.projectID))
      handleRegistry.sync(with: manager.catalog)
      return .unary(
        try JSONValue.encoded(
          CreatedTab(
            id: created.tabID,
            handle: handleRegistry.handle(forTab: created.tabID).map { "t\($0)" },
            paneID: created.paneID,
            contentID: created.contentID)))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.worktreeID.description)
    }
  }

  /// The cwd a new Tab in (`projectID`, `worktreeID`) starts in. Local
  /// projects take `requested` as-is; a remote project accepts it only when
  /// it targets the worktree (or a subpath) on the host, else the worktree
  /// root: the remote shell would otherwise `cd` into whatever local
  /// directory the caller happened to be in, or fall back to `$HOME`.
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

  public struct SetTabLabelsParams: Codable, Sendable {
    public let contentID: ContentID
    public let labels: [String]
    public let replace: Bool
  }
  /// `hierarchy.setTabLabels` — labels live on the Tab's terminal Content.
  public func setTabLabels(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: SetTabLabelsParams
    do {
      req = try params.decoded(as: SetTabLabelsParams.self)
    } catch {
      return .failed(.invalidParams(message: "setTabLabels requires {contentID, labels}", path: nil))
    }
    do {
      try manager.setContentLabels(req.contentID, labels: Set(req.labels), replace: req.replace)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.contentID.description)
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
    // Workspace membership is edited through the workspace flow: a child row
    // is a checkout the manifest still names, and the same folder listed
    // under its source repository belongs to the workspace too.
    if let project = manager.catalog.projects.first(where: { $0.id == req.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == req.id })
    {
      if project.isWorkspace, worktree.path != project.rootPath {
        return .failed(
          .conflict(reason: "\(worktree.name) is a workspace repository; remove it from the workspace instead"))
      }
      if !project.isWorkspace, let membership = manager.workspaceMembership(forPath: worktree.path) {
        return .failed(
          .conflict(
            reason:
              "\(worktree.name) is checked out for workspace \(membership.workspaceName); remove it there"))
      }
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
  }
  public struct ClosedTab: Codable, Sendable {
    public let id: TabID
    public let contentID: ContentID
  }
  /// `hierarchy.closeTab` — the explicit termination verb. Kills the Tab's
  /// zmx daemon (bounded ≤ 2 s wait for its control socket to vanish),
  /// drops the persisted session entry, then removes the Tab; the last Tab
  /// of a Pane closes the Pane. The RPC returns only once the daemon is
  /// gone, so a script can rely on it.
  public func closeTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CloseTabParams
    do { req = try params.decoded(as: CloseTabParams.self) } catch {
      return .failed(.invalidParams(message: "closeTab requires {id}", path: nil))
    }
    guard let address = manager.catalog.address(forTab: req.id) else {
      return .failed(.notFound(kind: "tab", id: req.id.description))
    }
    await terminate(address.contentID)
    do {
      try manager.closeTab(req.id)
      return .unary(try JSONValue.encoded(ClosedTab(id: req.id, contentID: address.contentID)))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.id.description)
    }
  }

  public struct ClosePaneParams: Codable, Sendable {
    /// Must name a Pane. A Tab or Content id is refused rather than
    /// widened to its Pane: the caller meant one session.
    public let id: UUID
  }
  public struct ClosedPane: Codable, Sendable {
    public let id: PaneID
    public let tabIDs: [TabID]
  }
  /// `hierarchy.closePane` — closes the Pane and every Tab on its strip,
  /// each session terminated as `closeTab` does.
  public func closePane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ClosePaneParams
    do { req = try params.decoded(as: ClosePaneParams.self) } catch {
      return .failed(.invalidParams(message: "closePane requires {id}", path: nil))
    }
    guard let pane = manager.catalog.pane(PaneID(raw: req.id)) else {
      if let match = convert(req.id, to: .tab) {
        return .failed(Self.closePaneRefusal(id: req.id.uuidString, matched: match.matched))
      }
      return .failed(.notFound(kind: "pane", id: req.id.uuidString))
    }
    for contentID in pane.contentIDs {
      await terminate(contentID)
    }
    do {
      try manager.closePane(pane.id)
      return .unary(try JSONValue.encoded(ClosedPane(id: pane.id, tabIDs: pane.tabIDs)))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.id.uuidString)
    }
  }

  /// `pane close` given a Tab or Content id: refused, naming the verb that
  /// closes one Tab.
  static func closePaneRefusal(id: String, matched: IPC.AliasResolveRequest.Kind?) -> IPCError {
    let level = matched == .content ? "a Content (session)" : "a Tab"
    return .invalidParams(
      message:
        "\(id) names \(level), not a Pane; `pane close` closes a whole Pane with all its Tabs. "
        + "Use `codans tab close` to close one Tab",
      path: ["id"])
  }

  /// Kill the session's daemon and drop its persisted entry. Best-effort
  /// on the entry: the verb only promises the daemon is gone.
  private func terminate(_ contentID: ContentID) async {
    await daemonKiller(contentID)
    guard let coordinator = sessionCoordinator else { return }
    do {
      try coordinator.recordClose(contentID)
    } catch {
      logger.warning("close: sessions.json reap failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Handles `tab.info` — probe the Tab's zmx daemon for shell pid, pwd,
  /// and (when available) cursor + terminal modes. The daemon's frozen
  /// `.Info` payload only carries `pid` + `cwd` today; `cursor` and
  /// `modes` are surfaced as `nil` so callers can fall back to
  /// `tab.read --raw` for byte-faithful assertions.
  public func tabInfo(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: IPC.TabInfoRequest
    do {
      req = try params.decoded(as: IPC.TabInfoRequest.self)
    } catch {
      return .failed(.invalidParams(message: "tab.info requires {contentID}", path: nil))
    }
    guard let probe = runtimeProbe(req.contentID) else {
      return .failed(.notFound(kind: "tab", id: req.contentID.description))
    }
    let payload: ZmxInfoPayload
    do {
      payload = try await probe.requestInfo()
    } catch {
      return .failed(.internal("tab.info: \(error)"))
    }
    let response = IPC.TabInfoResponse(
      contentID: req.contentID,
      shellPid: payload.pid,
      pwd: payload.cwd,
      cursor: nil,
      modes: nil
    )
    return (try? JSONValue.encoded(response)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode tab.info result"))
  }

  /// Handles `tab.read` — pull serialized terminal state from the Tab's
  /// zmx daemon. The daemon returns the full `serializeTerminalState` dump
  /// in the requested format (`plain` strips ANSI; `vt` keeps them,
  /// including cursor / modes / OSC 7). `range` and `tail` are applied
  /// here after the dump arrives.
  public func tabRead(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: IPC.TabReadRequest
    do {
      req = try params.decoded(as: IPC.TabReadRequest.self)
    } catch {
      return .failed(.invalidParams(message: "tab.read requires {contentID}", path: nil))
    }
    if let tail = req.tail, tail <= 0 {
      return .failed(.invalidParams(message: "tail must be a positive integer", path: ["tail"]))
    }
    guard let probe = runtimeProbe(req.contentID) else {
      return .failed(.notFound(kind: "tab", id: req.contentID.description))
    }
    let format: ZmxHistoryFormat = req.raw ? .vt : .plain
    let dump: Data
    do {
      dump = try await probe.readHistory(format: format)
    } catch {
      return .failed(.internal("tab.read: \(error)"))
    }
    let content = String(data: dump, encoding: .utf8) ?? ""
    let filtered = Self.applyRange(content, range: req.range)
    let trimmed = Self.applyTail(filtered, tail: req.tail)
    let response = IPC.TabReadResponse(
      contentID: req.contentID,
      format: req.raw ? .vt : .plain,
      content: trimmed
    )
    return (try? JSONValue.encoded(response)).map(RouterOutcome.unary)
      ?? .failed(.internal("encode tab.read result"))
  }

  /// Client-side range filtering. The daemon dumps scrollback above
  /// the viewport followed by the viewport itself; we split on a blank
  /// row boundary as an approximation since the dump is not annotated
  /// with the split point. `all` is the canonical (pass-through) shape;
  /// `visible` / `scrollback` are best-effort filters until the daemon
  /// learns to label the boundary.
  static func applyRange(_ content: String, range: IPC.TabReadRange) -> String {
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

  /// The Pane an id names for placement: the Pane itself, or the Pane
  /// holding that Tab / session. `nil` when the id is unknown.
  func layoutPane(for id: UUID) -> PaneID? {
    convert(id, to: .pane).map { PaneID(raw: $0.id) }
  }

  /// `hierarchy.activateTab` — `tab focus`: selects the Tab, focuses its
  /// Pane, brings its Worktree forward, and hands its terminal the
  /// keyboard.
  public func activateTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ActivateParams
    do { req = try params.decoded(as: ActivateParams.self) } catch {
      return .failed(.invalidParams(message: "activateTab requires {id}", path: nil))
    }
    guard let address = manager.catalog.address(forTab: TabID(raw: req.id)) else {
      return .failed(.notFound(kind: "tab", id: req.id.uuidString))
    }
    do {
      try await reveal(address)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.id.uuidString)
    }
  }

  /// Bring a Tab on screen with keyboard focus: its Worktree selected, its
  /// Pane focused, the Tab selected, its surface started.
  func reveal(_ address: TabAddress) async throws {
    try manager.selectWorktree(address.worktreeID, in: address.projectID)
    try manager.focusPane(address.paneID)
    try manager.selectTab(address.tabID)
    try await manager.ensureSurface(for: address.contentID, env: envProvider(address.projectID))
    manager.focusSurfaceView(for: address.contentID)
  }

  public enum FocusDirectionParam: String, Codable, Sendable {
    case left, right, up, down, previous, next
  }
  public struct FocusPaneParams: Codable, Sendable {
    /// The Pane to focus, or with `direction` the Pane to move from.
    /// Absent → the focused Pane of (`projectID`, `worktreeID`).
    public let id: PaneID?
    public let projectID: ProjectID?
    public let worktreeID: WorktreeID?
    public let direction: FocusDirectionParam?
  }
  public struct FocusedPane: Codable, Sendable {
    public let paneID: PaneID
    /// False when `direction` found no neighbour (an edge is a no-op).
    public let moved: Bool
  }
  /// `hierarchy.focusPane` — focus a Pane by id, or move focus to the
  /// neighbour in a direction, the way the keyboard does.
  public func focusPane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: FocusPaneParams
    do { req = try params.decoded(as: FocusPaneParams.self) } catch {
      return .failed(.invalidParams(message: "focusPane requires {id} or {worktreeID, direction}", path: nil))
    }
    let origin: PaneID? =
      req.id
      ?? manager.catalog.projects.first(where: { $0.id == req.projectID })?
      .worktrees.first(where: { $0.id == req.worktreeID })?.focusedPaneID
    guard let origin else {
      if req.id == nil, req.worktreeID == nil {
        return .failed(.invalidParams(message: "focusPane requires {id} or {worktreeID, direction}", path: nil))
      }
      return .failed(.notFound(kind: "pane", id: req.worktreeID?.description ?? "focused"))
    }
    var target = origin
    var moved = true
    do {
      if let direction = req.direction {
        let mapped: FocusDirection =
          switch direction {
          case .left: .left
          case .right: .right
          case .up: .up
          case .down: .down
          case .previous: .previous
          case .next: .next
          }
        if let neighbour = try manager.focusNeighbour(of: origin, direction: mapped) {
          target = neighbour
        } else {
          moved = false
        }
      }
      let catalog = manager.catalog
      guard let address = catalog.address(forPane: target), let selected = catalog.pane(target)?.selectedTab
      else {
        return .failed(.notFound(kind: "pane", id: target.description))
      }
      try await reveal(
        TabAddress(
          projectID: address.projectID, worktreeID: address.worktreeID, paneID: target, tabID: selected.id,
          contentID: selected.contentID))
      return .unary(try JSONValue.encoded(FocusedPane(paneID: target, moved: moved)))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: origin.description)
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
    let worktrees = overlayLiveDirectories(in: project.worktrees)
    return await Self.encodeOffMain("listWorktrees") {
      try JSONValue.encoded(ListWorktreesPayload(worktrees: worktrees))
    }
  }

  public struct ListTabsParams: Codable, Sendable {
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
    /// Narrows the listing to one Pane's strip (a Pane id, or a Tab /
    /// Content id resolving to its Pane). Absent → every Tab of the
    /// Worktree, Panes in layout order.
    public let paneID: UUID?
  }
  public func listTabs(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListTabsParams
    do { req = try params.decoded(as: ListTabsParams.self) } catch {
      return .failed(.invalidParams(message: "listTabs requires {worktreeID, projectID}", path: nil))
    }
    guard let worktree = worktree(req.worktreeID, in: req.projectID) else {
      return .failed(.notFound(kind: "worktree", id: req.worktreeID.description))
    }
    var panes = TargetHandleRegistry.panesInLayoutOrder(worktree)
    if let filter = req.paneID {
      guard let paneID = layoutPane(for: filter), panes.contains(where: { $0.id == paneID }) else {
        return .failed(.notFound(kind: "pane", id: filter.uuidString))
      }
      panes = panes.filter { $0.id == paneID }
    }
    let tabs = panes.flatMap(\.tabs).compactMap { tabDescription($0.id) }
    return await Self.encodeOffMain("listTabs") {
      try JSONValue.encoded(ListTabsPayload(tabs: tabs))
    }
  }

  public struct ListPanesParams: Codable, Sendable {
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
  }
  /// `hierarchy.listPanes` — the Worktree's Panes in layout order.
  public func listPanes(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListPanesParams
    do { req = try params.decoded(as: ListPanesParams.self) } catch {
      return .failed(.invalidParams(message: "listPanes requires {worktreeID, projectID}", path: nil))
    }
    guard let worktree = worktree(req.worktreeID, in: req.projectID) else {
      return .failed(.notFound(kind: "worktree", id: req.worktreeID.description))
    }
    let panes = TargetHandleRegistry.panesInLayoutOrder(worktree).compactMap { paneDescription($0.id) }
    return await Self.encodeOffMain("listPanes") {
      try JSONValue.encoded(ListPanesPayload(panes: panes))
    }
  }

  func worktree(_ worktreeID: WorktreeID, in projectID: ProjectID) -> Worktree? {
    manager.catalog.projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  private func overlayLivePaneDirectories(in projects: [Project]) -> [Project] {
    projects.map { project in
      var copy = project
      copy.worktrees = overlayLiveDirectories(in: project.worktrees)
      return copy
    }
  }

  private func overlayLiveDirectories(in worktrees: [Worktree]) -> [Worktree] {
    worktrees.map { worktree in
      var copy = worktree
      copy.panes = overlayLiveDirectories(in: worktree.panes)
      return copy
    }
  }

  func overlayLiveDirectories(in panes: [Pane]) -> [Pane] {
    panes.map { pane in
      var copy = pane
      copy.tabs = overlayLiveDirectories(in: pane.tabs)
      return copy
    }
  }

  /// The shell-reported directory of a live session replaces the catalog's
  /// creation-time one in listings.
  func overlayLiveDirectories(in tabs: [Tab]) -> [Tab] {
    tabs.map { tab in
      guard let cwd = manager.currentWorkingDirectory(for: tab.contentID), var terminal = tab.content.terminal
      else { return tab }
      var copy = tab
      terminal.workingDirectory = cwd
      copy.content.terminal = terminal
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
nonisolated struct ListTabsPayload: Codable, Sendable { let tabs: [IPC.TabDescription] }
nonisolated struct ListPanesPayload: Codable, Sendable { let panes: [IPC.PaneDescription] }
struct ListTagsPayload: Codable, Sendable { let tags: [Tag] }
struct ProjectIDPayload: Codable, Sendable { let id: ProjectID }
struct TagIDPayload: Codable, Sendable { let id: TagID }
