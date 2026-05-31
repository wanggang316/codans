import Foundation
import TouchCodeCore
import TouchCodeIPC
import os

/// Narrow read-only view onto a pane's live zmx daemon. Implemented in
/// production by an adapter over `ZmxClient`; tests inject a fake so
/// they exercise the handler's encoding/error paths without spinning
/// up a real daemon socket.
@MainActor
public protocol PaneRuntimeProbe: AnyObject, Sendable {
  /// Resolves with the daemon's next `.info` response. Wraps
  /// `ZmxClient.requestInfo()`.
  func requestInfo() async throws -> ZmxInfoPayload
  /// Resolves with the raw bytes of the daemon's `.history` response in
  /// the requested format. Wraps `ZmxClient.readHistory(format:)`.
  func readHistory(format: ZmxHistoryFormat) async throws -> Data
}

extension ZmxClient: PaneRuntimeProbe {}

/// Handlers for `hierarchy.*` — both reads (list / describe /
/// resolveAlias) and mutations (create / activate / close / label).
///
/// M2 (rm-space) removed the `space.*` RPCs along with the Space level.
/// M6 added the Tag-scoped RPCs (`hierarchy.listTags`, `hierarchy.createTag`,
/// `hierarchy.renameTag`, `hierarchy.recolorTag`, `hierarchy.removeTag`,
/// `hierarchy.setProjectTags`, `hierarchy.setActiveTagFilter`) plus the
/// `tag` / `untagged` filters on `hierarchy.listProjects`.
@MainActor
final class HierarchyHandlers {
  private let manager: HierarchyManager
  private let envProvider: @MainActor (ProjectID) -> [String: String]
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
  private let runtimeProbe: @MainActor (PaneID) -> PaneRuntimeProbe?
  /// Persistent zmx-session catalog accessor. The `pane.close` handler
  /// drops the closed pane's row synchronously through the coordinator
  /// so the on-disk state reflects the kill before the RPC returns.
  /// Default is `nil` for tests; production wiring passes the shared
  /// `SessionCoordinator`.
  private let sessionCoordinator: SessionCoordinator?
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "hierarchy")

  init(
    manager: HierarchyManager,
    envProvider: @escaping @MainActor (ProjectID) -> [String: String] = { _ in [:] },
    settingsProvider: @escaping @MainActor () -> Settings = { Settings() },
    daemonKiller: @escaping @MainActor (PaneID) async -> Void = { _ in },
    runtimeProbe: @escaping @MainActor (PaneID) -> PaneRuntimeProbe? = { _ in nil },
    sessionCoordinator: SessionCoordinator? = nil
  ) {
    self.manager = manager
    self.envProvider = envProvider
    self.settingsProvider = settingsProvider
    self.daemonKiller = daemonKiller
    self.runtimeProbe = runtimeProbe
    self.sessionCoordinator = sessionCoordinator
  }

  // MARK: - Error mapping

  /// Funnel every mutation catch through here so `HierarchyError` maps
  /// to the right `IPCError` variant (and therefore the right
  /// `CLIExitCode` per DEC-8) — previously every catch hardcoded
  /// `.notFound`, which masked conflict / invariant-violation cases
  /// behind exit code 2.
  private func failure(for error: Error, fallbackKind: String, fallbackID: String) -> RouterOutcome {
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

  /// `hierarchy.resolveAlias` — turn a string identifier (index /
  /// label / glob) into the canonical UUID for `kind`. M6 supports the
  /// minimum set the CLI drives: `current` / `.` (handled client-side by
  /// `AliasResolver`, but the server still accepts it as a defensive
  /// fallback), and pane labels. Extended forms (path glob, index) land
  /// in M6.1.
  public func resolveAlias(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let request: IPC.AliasResolveRequest
    do {
      request = try params.decoded(as: IPC.AliasResolveRequest.self)
    } catch {
      return .failed(.invalidParams(message: "resolveAlias requires {kind, value}", path: nil))
    }
    if let uuid = UUID(uuidString: request.value) {
      let result = IPC.AliasResolveResult(kind: request.kind, id: uuid)
      return (try? JSONValue.encoded(result)).map(RouterOutcome.unary)
        ?? .failed(.internal("encode resolveAlias result"))
    }
    if request.kind == .pane, request.value.hasPrefix("@") {
      let label = String(request.value.dropFirst())
      let matches = Self.panesMatchingLabel(label: label, catalog: manager.catalog)
      if matches.count == 1 {
        let result = IPC.AliasResolveResult(kind: .pane, id: matches[0])
        return (try? JSONValue.encoded(result)).map(RouterOutcome.unary)
          ?? .failed(.internal("encode resolveAlias result"))
      }
      if matches.count > 1 {
        return .failed(.conflict(reason: "label @\(label) matches \(matches.count) panes"))
      }
      return .failed(.notFound(kind: "pane", id: "@\(label)"))
    }
    return .failed(.unsupported(reason: "alias form not yet supported: \(request.value)"))
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
  public func addProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: AddProjectParams
    do {
      req = try params.decoded(as: AddProjectParams.self)
    } catch {
      return .failed(.invalidParams(message: "addProject requires {name, rootPath}", path: nil))
    }
    do {
      let id = manager.addProject(
        name: req.name,
        rootPath: req.rootPath,
        gitRoot: req.gitRoot
      )
      return .unary(try JSONValue.encoded(ProjectIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.name)
    }
  }

  public struct CreateWorktreeParams: Codable, Sendable {
    public let projectID: ProjectID
    public let name: String
    /// Optional. When nil, the daemon resolves the base directory through
    /// `WorktreeSettings.resolveBaseDirectory` (per-project override → global
    /// `defaultWorktreesDirectory` → system fallback) and appends the
    /// sanitized branch name — mirroring the GUI's Create Worktree sheet
    /// (HAN-81).
    public let path: String?
    public let branch: String?
    /// HAN-82: when true, a same-canonical-path collision returns the
    /// existing row's id instead of `.conflict`, so a dispatcher
    /// replaying create-after-partial-failure stays idempotent. Absent
    /// (legacy clients) ⇒ strict mode.
    public let reuseExisting: Bool?
  }
  public struct CreateWorktreeResult: Codable, Sendable {
    public let id: WorktreeID
    public let path: String
  }
  public func createWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateWorktreeParams
    do {
      req = try params.decoded(as: CreateWorktreeParams.self)
    } catch {
      return .failed(.invalidParams(message: "createWorktree requires {projectID, name}", path: nil))
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
      guard let project = manager.catalog.projects.first(where: { $0.id == req.projectID }) else {
        return .failed(.notFound(kind: "project", id: req.projectID.description))
      }
      let settings = settingsProvider()
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
    do {
      let id = try manager.createWorktree(
        in: req.projectID,
        name: req.name,
        path: resolvedPath,
        branch: req.branch,
        reuseExisting: req.reuseExisting ?? false
      )
      let canonical = HierarchyManager.canonicalPath(resolvedPath)
      return .unary(try JSONValue.encoded(CreateWorktreeResult(id: id, path: canonical)))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.projectID.description)
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
    do {
      let id = try await manager.openPane(
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID,
        workingDirectory: req.workingDirectory,
        initialCommand: req.initialCommand
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
  }
  public func removeWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RemoveWorktreeParams
    do { req = try params.decoded(as: RemoveWorktreeParams.self) } catch {
      return .failed(.invalidParams(message: "removeWorktree requires {id, projectID}", path: nil))
    }
    do {
      try manager.removeWorktree(req.id, from: req.projectID)
      return .unary(.object([:]))
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
  /// (`tc project list --tag <id> | --untagged`). Both are absent by default
  /// — pre-M6 callers that send `{}` see the unfiltered project list.
  /// Passing both is a caller error.
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
    return await Self.encodeOffMain("listProjects") {
      try JSONValue.encoded(ListProjectsPayload(projects: filtered))
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

  private func overlayLivePaneDirectories(in panes: [Pane]) -> [Pane] {
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

// MARK: - Response payload types (shared with CLI tcKit)

// `nonisolated` on the conformance so `encodeOffMain` can call `encode(to:)`
// from a detached Task without tripping `InferIsolatedConformances` —
// the file otherwise infers `@MainActor` for every type defined in it.
nonisolated struct ListProjectsPayload: Codable, Sendable { let projects: [Project] }
nonisolated struct ListWorktreesPayload: Codable, Sendable { let worktrees: [Worktree] }
nonisolated struct ListTabsPayload: Codable, Sendable { let tabs: [Tab] }
nonisolated struct ListPanesPayload: Codable, Sendable { let panes: [Pane] }
struct ListTagsPayload: Codable, Sendable { let tags: [Tag] }
struct ProjectIDPayload: Codable, Sendable { let id: ProjectID }
struct TabIDPayload: Codable, Sendable { let id: TabID }
struct PaneIDPayload: Codable, Sendable { let id: PaneID }
struct TagIDPayload: Codable, Sendable { let id: TagID }
