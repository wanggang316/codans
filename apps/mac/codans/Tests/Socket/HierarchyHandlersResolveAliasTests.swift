import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct HierarchyHandlersResolveAliasTests {
  @Test
  func currentPaneResolvesViaPeerPID() async throws {
    let pane = PaneID()
    let handlers = Self.makeHandlers { pid in
      pid == 4242 ? pane : nil
    }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "current"))

    let outcome = await handlers.resolveAlias(params, peerPID: 4242)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.kind == .pane)
    #expect(result.id == pane.raw)
  }

  @Test
  func dotPronounResolvesLikeCurrent() async throws {
    let pane = PaneID()
    let handlers = Self.makeHandlers { _ in pane }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "."))

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == pane.raw)
  }

  @Test
  func peerAttributionWinsOverContextPaneID() async throws {
    let peerPane = PaneID()
    let envPane = PaneID()
    let handlers = Self.makeHandlers { _ in peerPane }
    let params = try JSONValue.encoded(
      IPC.AliasResolveRequest(kind: .pane, value: "current", contextPaneID: envPane)
    )

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == peerPane.raw)
  }

  @Test
  func unattributedCallerFallsBackToContextPaneID() async throws {
    let envPane = PaneID()
    let handlers = Self.makeHandlers { _ in nil }
    let params = try JSONValue.encoded(
      IPC.AliasResolveRequest(kind: .pane, value: "current", contextPaneID: envPane)
    )

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == envPane.raw)
  }

  @Test
  func unattributableCurrentPaneIsNotFound() async throws {
    let handlers = Self.makeHandlers { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "current"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)

    guard case .failed(let error) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    guard case .notFound = error else {
      Issue.record("expected .notFound, got \(error)")
      return
    }
  }

  @Test
  func currentContainersResolveFromTheCallingPane() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in fixture.pane }
    for (kind, expected) in [
      (IPC.AliasResolveRequest.Kind.tab, fixture.tab.raw),
      (.worktree, fixture.worktree.raw),
      (.project, fixture.project.raw),
    ] {
      let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: kind, value: "current"))
      let outcome = await handlers.resolveAlias(params, peerPID: 1)
      let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)
      #expect(result.kind == kind)
      #expect(result.id == expected)
    }
  }

  @Test
  func currentContainerOutsideAnyPaneIsNotFound() async throws {
    let handlers = Self.makeHandlers(catalog: Self.makeCatalog().catalog) { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "current"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)

    guard case .failed(.notFound(let kind, let id)) = outcome else {
      Issue.record("expected .notFound, got \(outcome)")
      return
    }
    #expect(kind == "project")
    #expect(id == "current")
  }

  @Test
  func projectResolvesByNameCaseInsensitively() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "API"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == fixture.project.raw)
  }

  @Test
  func worktreeResolvesByBranchWithinTheCallingPanesProject() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in fixture.pane }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .worktree, value: "main"))

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    // Both projects have a `main`; the calling pane's project wins.
    #expect(result.id == fixture.mainWorktree.raw)
  }

  @Test
  func worktreeNameAmbiguousAcrossProjectsIsConflict() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .worktree, value: "main"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)

    guard case .failed(.conflict) = outcome else {
      Issue.record("expected .conflict, got \(outcome)")
      return
    }
  }

  @Test
  func tabResolvesByTitle() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .tab, value: "dev server"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == fixture.tab.raw)
  }

  @Test
  func unknownNameIsNotFound() async throws {
    let handlers = Self.makeHandlers(catalog: Self.makeCatalog().catalog) { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "nope"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)

    guard case .failed(.notFound) = outcome else {
      Issue.record("expected .notFound, got \(outcome)")
      return
    }
  }

  @Test
  func bareWordForPaneIsAUsageError() async throws {
    let handlers = Self.makeHandlers(catalog: Self.makeCatalog().catalog) { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "echo"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)

    guard case .failed(.invalidParams(let message, _)) = outcome else {
      Issue.record("expected .invalidParams, got \(outcome)")
      return
    }
    #expect(message.contains("echo"))
  }

  /// A worktree path target is a path on This Mac, so a Remote Project's
  /// worktree with a deeper matching path string never wins (ADR 0006).
  @Test
  func worktreePathTargetIgnoresRemoteProjects() {
    let localMain = Worktree(name: "main", path: "/srv/repo", branch: "main")
    let local = Project(name: "repo", rootPath: "/srv/repo", gitRoot: "/srv/repo", worktrees: [localMain])
    let remoteFeature = Worktree(name: "feature", path: "/srv/repo/feature", branch: "feature")
    let remote = Project(
      name: "repo", rootPath: "/srv/repo/feature", remoteHost: RemoteHost(alias: "mini"),
      worktrees: [remoteFeature])
    let catalog = Catalog(projects: [remote, local])

    #expect(HierarchyHandlers.worktreesMatchingPath("/srv/repo/feature/src", in: catalog) == [localMain.id.raw])
    #expect(HierarchyHandlers.worktreesMatchingPath("/srv/repo/feature", in: Catalog(projects: [remote])).isEmpty)
  }

  // MARK: - Host filter (ADR 0006)

  @Test
  func projectNameOnTwoHostsIsAConflictListingEachHost() async throws {
    let fixture = Self.makeTwoHostCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }

    let outcome = await handlers.resolveAlias(
      try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "agents")), peerPID: nil)

    guard case .failed(.conflict(let reason)) = outcome else {
      Issue.record("expected .conflict, got \(outcome)")
      return
    }
    #expect(reason.contains("\(fixture.local) host=0"))
    #expect(reason.contains("\(fixture.remote) host=\(fixture.host.id)"))
  }

  @Test
  func hostFilterSelectsTheProjectOnThatHost() async throws {
    let fixture = Self.makeTwoHostCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }

    let onThisMac: IPC.AliasResolveResult = try Self.decodeUnary(
      await handlers.resolveAlias(
        try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "agents", hostID: "0")), peerPID: nil))
    let onMini: IPC.AliasResolveResult = try Self.decodeUnary(
      await handlers.resolveAlias(
        try JSONValue.encoded(
          IPC.AliasResolveRequest(kind: .project, value: "agents", hostID: fixture.host.id.description.lowercased())),
        peerPID: nil))

    #expect(onThisMac.id == fixture.local.raw)
    #expect(onMini.id == fixture.remote.raw)
  }

  @Test
  func projectIDMustBeOnTheGivenHost() async throws {
    let fixture = Self.makeTwoHostCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }
    func resolve(_ id: ProjectID, host: String) async throws -> RouterOutcome {
      await handlers.resolveAlias(
        try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: id.description, hostID: host)),
        peerPID: nil)
    }

    let matching: IPC.AliasResolveResult = try Self.decodeUnary(
      try await resolve(fixture.remote, host: fixture.host.id.description))
    #expect(matching.id == fixture.remote.raw)

    guard case .failed(.conflict(let reason)) = try await resolve(fixture.local, host: fixture.host.id.description)
    else {
      Issue.record("expected .conflict for a Project on another Host")
      return
    }
    #expect(reason.contains("host=0"))
    guard case .failed(.notFound) = try await resolve(ProjectID(), host: "0") else {
      Issue.record("expected .notFound for an unknown Project id")
      return
    }
  }

  @Test
  func currentProjectMustBeOnTheGivenHost() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in fixture.pane }
    func resolve(host: String) async throws -> RouterOutcome {
      await handlers.resolveAlias(
        try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "current", hostID: host)), peerPID: 1)
    }

    let result: IPC.AliasResolveResult = try Self.decodeUnary(try await resolve(host: "0"))
    #expect(result.id == fixture.project.raw)
  }

  @Test
  func invalidHostIsInvalidParamsAndUnknownHostIsNotFound() async throws {
    let fixture = Self.makeTwoHostCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }
    func resolve(host: String) async throws -> RouterOutcome {
      await handlers.resolveAlias(
        try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "agents", hostID: host)), peerPID: nil)
    }

    for invalid in ["", "mini", "1", " 0"] {
      guard case .failed(.invalidParams(_, let path)) = try await resolve(host: invalid) else {
        Issue.record("expected .invalidParams for host \"\(invalid)\"")
        continue
      }
      #expect(path == ["hostID"])
    }
    let unknown = UUID().uuidString
    guard case .failed(.notFound(let kind, let id)) = try await resolve(host: unknown) else {
      Issue.record("expected .notFound for an unknown Host")
      return
    }
    #expect(kind == "host")
    #expect(id == unknown)
  }

  @Test
  func hostFilterDoesNotApplyToOtherKinds() async throws {
    let fixture = Self.makeCatalog()
    let handlers = Self.makeHandlers(catalog: fixture.catalog) { _ in nil }

    let result: IPC.AliasResolveResult = try Self.decodeUnary(
      await handlers.resolveAlias(
        try JSONValue.encoded(IPC.AliasResolveRequest(kind: .tab, value: "dev server", hostID: "not-a-host")),
        peerPID: nil))

    #expect(result.id == fixture.tab.raw)
  }

  // MARK: - Helpers

  private struct TwoHostFixture {
    let catalog: Catalog
    let host: HostRecord
    let local: ProjectID
    let remote: ProjectID
  }

  /// `agents` on This Mac and on the Host `mini`, at the same path.
  private static func makeTwoHostCatalog() -> TwoHostFixture {
    let mini = HostRecord(address: "mini.local", username: "me", name: "mini")
    let local = Project(name: "agents", rootPath: "/Users/me/agents")
    let remote = Project(name: "agents", rootPath: "/Users/me/agents", hostID: mini.id, remoteHost: mini.endpoint)
    return TwoHostFixture(
      catalog: Catalog(projects: [local, remote], hosts: [mini]), host: mini, local: local.id, remote: remote.id)
  }

  private static func makeHandlers(
    catalog: Catalog = Catalog(projects: []),
    callerPaneResolver: @escaping @MainActor (pid_t) -> PaneID?
  ) -> HierarchyHandlers {
    let manager = HierarchyManager(
      catalog: catalog,
      store: CatalogStore(fileURL: Self.tempURL()),
      runtime: FakeHierarchyRuntime()
    )
    return HierarchyHandlers(
      manager: manager,
      callerPaneResolver: callerPaneResolver
    )
  }

  private struct CatalogFixture {
    let catalog: Catalog
    let project: ProjectID
    let worktree: WorktreeID
    let mainWorktree: WorktreeID
    let tab: TabID
    let pane: PaneID
  }

  /// Two projects that both own a `main` worktree; the calling pane sits
  /// in project "api", worktree "feature", tab "dev server".
  private static func makeCatalog() -> CatalogFixture {
    let pane = Pane(workingDirectory: "/api/feature")
    let tab = Tab(name: "dev server", panes: [pane])
    let feature = Worktree(name: "feature", path: "/api/feature", branch: "feat/x", tabs: [tab])
    let apiMain = Worktree(name: "main", path: "/api", branch: "main")
    let api = Project(
      name: "api", rootPath: "/api", gitRoot: "/api", worktrees: [apiMain, feature])
    let webMain = Worktree(name: "main", path: "/web", branch: "main")
    let web = Project(name: "web", rootPath: "/web", gitRoot: "/web", worktrees: [webMain])
    return CatalogFixture(
      catalog: Catalog(projects: [api, web]),
      project: api.id,
      worktree: feature.id,
      mainWorktree: apiMain.id,
      tab: tab.id,
      pane: pane.id
    )
  }

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  private static func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-resolve-alias-tests-\(UUID().uuidString).json")
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
