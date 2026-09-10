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

  // MARK: - Helpers

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
