import CodansCore
import Foundation
import Testing

@testable import Codans

/// A `TabContent` that records its lifecycle calls instead of touching a
/// terminal. `isLive` flips on `create` and off on `close` / `suspend`,
/// the way a surface registers and unregisters.
@MainActor
final class FakeTabContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal
  let chrome = TabChrome()
  private(set) var isLive = false
  var currentWorkingDirectory: String?
  /// Every call in order: `create`, `mount`, `unmount`, `close`, `suspend`,
  /// `focus`.
  private(set) var calls: [String] = []
  private(set) var lastAddress: TabAddress?
  private(set) var lastEnv: [String: String] = [:]
  private(set) var lastGeometry: ContentGeometry?
  var createError: Error?

  init(id: ContentID) {
    self.id = id
  }

  deinit {}

  // swiftlint:disable async_without_await
  func create(
    snapshot: ContentSnapshot, at address: TabAddress, in worktree: Worktree,
    env: [String: String], geometry: ContentGeometry?
  ) async throws {
    // swiftlint:enable async_without_await
    calls.append("create")
    lastAddress = address
    lastEnv = env
    lastGeometry = geometry
    if let createError { throw createError }
    isLive = true
  }

  func mount(geometry: ContentGeometry) {
    calls.append("mount")
    lastGeometry = geometry
  }

  func unmount() { calls.append("unmount") }

  func close() {
    calls.append("close")
    isLive = false
  }

  func suspend() {
    calls.append("suspend")
    isLive = false
  }

  func acceptFocus() { calls.append("focus") }
}

@MainActor
struct ContentRuntimeTests {
  @MainActor
  private struct Fixture {
    let manager: HierarchyManager
    let fakeRuntime = FakeHierarchyRuntime()
    let runtime: ContentRuntime
    let projectID: ProjectID
    let worktreeID: WorktreeID

    init(loadReport: CatalogLoadReport = .clean) {
      let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
      let manager = HierarchyManager(
        catalog: .default, store: CatalogStore(fileURL: tempURL), runtime: fakeRuntime)
      self.manager = manager
      projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
      // swiftlint:disable:next force_try
      worktreeID = try! manager.createWorktree(in: projectID, name: "main", path: "/tmp", branch: "main")
      let box = ContentBox()
      runtime = ContentRuntime(hierarchy: manager, loadReport: loadReport) { snapshot in
        let content = FakeTabContent(id: snapshot.id)
        box.contents[snapshot.id] = content
        return content
      }
      self.box = box
    }

    private let box: ContentBox

    final class ContentBox {
      var contents: [ContentID: FakeTabContent] = [:]
    }

    func content(_ id: ContentID) -> FakeTabContent? { box.contents[id] }

    func newTab(cwd: String = "/tmp") throws -> TabAddress {
      try manager.newTab(
        in: nil, worktreeID: worktreeID, projectID: projectID, content: .terminal(workingDirectory: cwd))
    }

    func worktree() -> Worktree {
      manager.catalog.projects[0].worktrees[0]
    }

    func ensure(_ address: TabAddress, geometry: ContentGeometry? = nil) async throws {
      let snapshot = try #require(manager.catalog.content(address.contentID))
      _ = try await runtime.ensure(snapshot, in: address, worktree: worktree(), env: ["K": "v"], geometry: geometry)
    }
  }

  @Test
  func ensureCreatesOneInstanceThenReattaches() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    #expect(fixture.runtime.content(for: address.contentID) == nil)

    try await fixture.ensure(address, geometry: ContentGeometry(size: CGSize(width: 800, height: 600), scale: 2))
    let content = try #require(fixture.content(address.contentID))
    #expect(content.calls == ["create"])
    #expect(content.lastAddress == address)
    #expect(content.lastEnv == ["K": "v"])
    #expect(content.lastGeometry?.size == CGSize(width: 800, height: 600))
    #expect(fixture.runtime.liveContentIDs == [address.contentID])

    // A second ensure reuses the instance; the content decides it is a
    // re-attach.
    try await fixture.ensure(address)
    #expect(fixture.content(address.contentID) === content)
    #expect(content.calls == ["create", "create"])
    #expect(fixture.runtime.registeredContentIDs == [address.contentID])
  }

  @Test
  func mountCloseOrderingAndRelease() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    try await fixture.ensure(address)
    let content = try #require(fixture.content(address.contentID))

    fixture.runtime.mount(address.contentID, geometry: ContentGeometry(size: CGSize(width: 10, height: 10)))
    fixture.runtime.acceptFocus(address.contentID)
    fixture.runtime.unmount(address.contentID)
    fixture.runtime.close(address.contentID)

    #expect(content.calls == ["create", "mount", "focus", "unmount", "close"])
    #expect(!content.isLive)
    #expect(fixture.runtime.content(for: address.contentID) == nil)
    #expect(fixture.runtime.liveContentIDs.isEmpty)
    // Closing again is a no-op: the instance is gone.
    fixture.runtime.close(address.contentID)
    #expect(content.calls.count == 5)
  }

  @Test
  func suspendDropsTheInstanceWithoutClose() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    try await fixture.ensure(address)
    let content = try #require(fixture.content(address.contentID))

    fixture.runtime.suspend(address.contentID)
    #expect(content.calls == ["create", "suspend"])
    #expect(fixture.runtime.content(for: address.contentID) == nil)
  }

  @Test
  func failedCreateKeepsTheInstanceForRetry() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    struct Boom: Error {}
    let snapshot = try #require(fixture.manager.catalog.content(address.contentID))
    // The factory makes the instance before `create` runs, so arm the error
    // through a first failing call.
    await #expect(throws: Boom.self) {
      let content = FakeTabContent(id: address.contentID)
      content.createError = Boom()
      let runtime = ContentRuntime(hierarchy: fixture.manager) { _ in content }
      _ = try await runtime.ensure(snapshot, in: address, worktree: fixture.worktree())
      _ = runtime
    }
  }

  @Test
  func chromeFlowsIntoTheBusyPredicates() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    // Unregistered: every signal is quiet and the writers are dropped.
    #expect(!fixture.runtime.isTerminalBusy(address.contentID))
    fixture.runtime.setProgressBusy(address.contentID, true)
    #expect(!fixture.runtime.isTerminalBusy(address.contentID))
    #expect(!fixture.runtime.tabIsDirty(address.tabID))

    try await fixture.ensure(address)
    let chrome = try #require(fixture.runtime.chrome(for: address.contentID))
    #expect(!chrome.isTerminalBusy)

    fixture.runtime.setProgressBusy(address.contentID, true)
    #expect(chrome.isBusy)
    #expect(fixture.runtime.isTerminalBusy(address.contentID))
    #expect(fixture.runtime.tabIsDirty(address.tabID))
    #expect(fixture.runtime.worktreeIsDirty(fixture.worktreeID))

    // The two producers are independent: clearing one keeps the other.
    fixture.runtime.setCommandBusy(address.contentID, true)
    fixture.runtime.setProgressBusy(address.contentID, false)
    #expect(!chrome.isBusy)
    #expect(chrome.isCommandBusy)
    #expect(fixture.runtime.isTerminalBusy(address.contentID))

    fixture.runtime.setCommandBusy(address.contentID, false)
    #expect(!fixture.runtime.isTerminalBusy(address.contentID))
    #expect(!fixture.runtime.worktreeIsDirty(fixture.worktreeID))
  }

  @Test
  func runScriptContentIsExcludedFromDirtyButReportedAsRunning() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    let scriptID = UUID()
    fixture.manager.setRunScriptContent(
      worktreeID: fixture.worktreeID, scriptID: scriptID, contentID: address.contentID)
    try await fixture.ensure(address)

    fixture.runtime.setCommandBusy(address.contentID, true)
    #expect(!fixture.runtime.tabIsDirty(address.tabID))
    #expect(!fixture.runtime.worktreeIsDirty(fixture.worktreeID))
    #expect(fixture.runtime.isScriptRunning(worktreeID: fixture.worktreeID, scriptID: scriptID))
    #expect(fixture.runtime.runningScriptIDs(in: fixture.worktreeID) == [scriptID])

    fixture.runtime.setCommandBusy(address.contentID, false)
    #expect(!fixture.runtime.isScriptRunning(worktreeID: fixture.worktreeID, scriptID: scriptID))
    #expect(fixture.runtime.runningScriptIDs(in: fixture.worktreeID).isEmpty)
  }

  @Test
  func managerBusyPredicateCombinesQueueAndActivity() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    try await fixture.ensure(address)
    let runtime = fixture.runtime
    fixture.manager.contentActivity = { [weak runtime] id in runtime?.isTerminalBusy(id) ?? false }

    #expect(!fixture.manager.isBusy(address.contentID))
    runtime.setCommandBusy(address.contentID, true)
    #expect(fixture.manager.isBusy(address.contentID))
    runtime.setCommandBusy(address.contentID, false)
    #expect(!fixture.manager.isBusy(address.contentID))

    fixture.manager.setCommandQueue(
      [QueuedCommand(text: "make", timing: .afterCurrentTask, createdAt: Date())], for: address.contentID)
    #expect(fixture.manager.isBusy(address.contentID))
  }

  @Test
  func sessionSweepsAreGatedByTheLoadReport() {
    #expect(Fixture().runtime.sessionSweepsEnabled)
    var loss = CatalogLoadReport()
    loss.droppedTabs = 1
    #expect(!Fixture(loadReport: loss).runtime.sessionSweepsEnabled)
    var panes = CatalogLoadReport()
    panes.droppedPanes = 1
    #expect(!Fixture(loadReport: panes).runtime.sessionSweepsEnabled)
    var readOnly = CatalogLoadReport()
    readOnly.readOnlyVersion = 9
    #expect(!Fixture(loadReport: readOnly).runtime.sessionSweepsEnabled)
    var migrated = CatalogLoadReport()
    migrated.migratedFromVersion = 3
    #expect(Fixture(loadReport: migrated).runtime.sessionSweepsEnabled)
  }
}
