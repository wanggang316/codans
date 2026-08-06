import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct TargetHandleRegistryTests {
  @Test
  func assignsHandlesInHierarchyOrder() {
    let registry = TargetHandleRegistry()
    let ids = FixtureIDs()
    registry.sync(with: Self.catalog(ids, tabs: [.first, .second]))

    #expect(registry.tab(forHandle: 1) == ids.firstTabID)
    #expect(registry.tab(forHandle: 2) == ids.secondTabID)
    #expect(registry.pane(forHandle: 1) == ids.firstPaneID)
    #expect(registry.pane(forHandle: 2) == ids.secondPaneID)
  }

  @Test
  func handlesStayStableAcrossRepeatedSyncs() {
    let registry = TargetHandleRegistry()
    let ids = FixtureIDs()
    registry.sync(with: Self.catalog(ids, tabs: [.first, .second]))
    registry.sync(with: Self.catalog(ids, tabs: [.first, .second]))

    #expect(registry.tab(forHandle: 2) == ids.secondTabID)
    #expect(registry.pane(forHandle: 2) == ids.secondPaneID)
  }

  @Test
  func releasedHandlesAreNeverReused() {
    let registry = TargetHandleRegistry()
    let ids = FixtureIDs()
    registry.sync(with: Self.catalog(ids, tabs: [.first, .second]))
    // Close the second tab (and its pane): handles t2 / p2 are released.
    registry.sync(with: Self.catalog(ids, tabs: [.first]))

    #expect(registry.tab(forHandle: 2) == nil)
    #expect(registry.pane(forHandle: 2) == nil)

    // A newly opened tab/pane must get fresh handles, not the released ones.
    registry.sync(with: Self.catalog(ids, tabs: [.first, .third]))

    #expect(registry.tab(forHandle: 2) == nil)
    #expect(registry.tab(forHandle: 3) == ids.thirdTabID)
    #expect(registry.pane(forHandle: 2) == nil)
    #expect(registry.pane(forHandle: 3) == ids.thirdPaneID)
  }

  @Test
  func parseAcceptsStrictHandleShapesOnly() {
    #expect(TargetHandleRegistry.parse("t12", prefix: "t") == 12)
    #expect(TargetHandleRegistry.parse("p3", prefix: "p") == 3)
    #expect(TargetHandleRegistry.parse("t", prefix: "t") == nil)
    #expect(TargetHandleRegistry.parse("T1", prefix: "t") == nil)
    #expect(TargetHandleRegistry.parse("t1x", prefix: "t") == nil)
    #expect(TargetHandleRegistry.parse("p-1", prefix: "p") == nil)
    #expect(TargetHandleRegistry.parse("1", prefix: "t") == nil)
    #expect(TargetHandleRegistry.parse("t1", prefix: "p") == nil)
  }

  enum FixtureTab { case first, second, third }

  struct FixtureIDs {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let firstTabID = TabID()
    let secondTabID = TabID()
    let thirdTabID = TabID()
    let firstPaneID = PaneID()
    let secondPaneID = PaneID()
    let thirdPaneID = PaneID()
  }

  static func catalog(_ ids: FixtureIDs, tabs included: [FixtureTab]) -> Catalog {
    let tabs = included.map { which -> Tab in
      let (tabID, paneID, name): (TabID, PaneID, String)
      switch which {
      case .first: (tabID, paneID, name) = (ids.firstTabID, ids.firstPaneID, "one")
      case .second: (tabID, paneID, name) = (ids.secondTabID, ids.secondPaneID, "two")
      case .third: (tabID, paneID, name) = (ids.thirdTabID, ids.thirdPaneID, "three")
      }
      let pane = Pane(id: paneID, workingDirectory: "/repo", initialCommand: nil)
      return Tab(id: tabID, name: name, splitTree: SplitTree(leaf: paneID), panes: [pane])
    }
    let worktree = Worktree(
      id: ids.worktreeID,
      name: "main",
      path: "/repo",
      branch: "main",
      tabs: tabs,
      selectedTabID: tabs.first?.id
    )
    let project = Project(
      id: ids.projectID,
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [worktree],
      selectedWorktreeID: ids.worktreeID
    )
    return Catalog(projects: [project])
  }
}

@MainActor
struct HierarchyHandlersHandleTests {
  @Test
  func resolveAliasResolvesHandlesWithoutPriorListing() async throws {
    let fixture = Self.makeFixture()

    let tabOutcome = await fixture.handlers.resolveAlias(
      try JSONValue.encoded(IPC.AliasResolveRequest(kind: .tab, value: "t1"))
    )
    let tabResult: IPC.AliasResolveResult = try Self.decodeUnary(tabOutcome)
    #expect(tabResult.id == fixture.ids.firstTabID.raw)

    let paneOutcome = await fixture.handlers.resolveAlias(
      try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "p2"))
    )
    let paneResult: IPC.AliasResolveResult = try Self.decodeUnary(paneOutcome)
    #expect(paneResult.id == fixture.ids.secondPaneID.raw)
  }

  @Test
  func resolveAliasUnknownHandleIsNotFound() async throws {
    let fixture = Self.makeFixture()

    let outcome = await fixture.handlers.resolveAlias(
      try JSONValue.encoded(IPC.AliasResolveRequest(kind: .tab, value: "t99"))
    )
    guard case .failed(let error) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(error == .notFound(kind: "tab", id: "t99"))
  }

  @Test
  func resolveAliasKeepsHandleNamespacePerKind() async throws {
    let fixture = Self.makeFixture()

    // A tab-shaped handle under a non-tab kind must not resolve.
    let outcome = await fixture.handlers.resolveAlias(
      try JSONValue.encoded(IPC.AliasResolveRequest(kind: .project, value: "t1"))
    )
    guard case .failed(let error) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(error.code == "unsupported")
  }

  @Test
  func listProjectsCarriesStableHandles() async throws {
    let fixture = Self.makeFixture()

    let first: ListProjectsPayload = try Self.decodeUnary(
      await fixture.handlers.listProjects(.object([:]))
    )
    let second: ListProjectsPayload = try Self.decodeUnary(
      await fixture.handlers.listProjects(.object([:]))
    )

    let handles = try #require(first.handles)
    #expect(handles.tabs[fixture.ids.firstTabID.raw.uuidString] == 1)
    #expect(handles.tabs[fixture.ids.secondTabID.raw.uuidString] == 2)
    #expect(handles.panes[fixture.ids.firstPaneID.raw.uuidString] == 1)
    #expect(handles.panes[fixture.ids.secondPaneID.raw.uuidString] == 2)
    #expect(second.handles == handles)
  }

  private static func makeFixture() -> Fixture {
    let ids = TargetHandleRegistryTests.FixtureIDs()
    let catalog = TargetHandleRegistryTests.catalog(ids, tabs: [.first, .second])
    let manager = HierarchyManager(
      catalog: catalog,
      store: CatalogStore(fileURL: Self.tempURL()),
      runtime: FakeHierarchyRuntime()
    )
    return Fixture(handlers: HierarchyHandlers(manager: manager), ids: ids)
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
      .appendingPathComponent("codans-handle-tests-\(UUID().uuidString).json")
  }

  private struct Fixture {
    let handlers: HierarchyHandlers
    let ids: TargetHandleRegistryTests.FixtureIDs
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
