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

    init() {
      let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
      let manager = HierarchyManager(
        catalog: .default, store: CatalogStore(fileURL: tempURL), runtime: fakeRuntime)
      self.manager = manager
      projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
      // swiftlint:disable:next force_try
      worktreeID = try! manager.createWorktree(in: projectID, name: "main", path: "/tmp", branch: "main")
      let box = ContentBox()
      runtime = ContentRuntime(hierarchy: manager) { snapshot in
        let content = FakeTabContent(id: snapshot.id)
        box.made.append(snapshot.id)
        box.contents[snapshot.id] = content
        return content
      }
      self.box = box
    }

    private let box: ContentBox

    final class ContentBox {
      var contents: [ContentID: FakeTabContent] = [:]
      /// Every factory call in order, including teardown-only instances.
      var made: [ContentID] = []
    }

    func content(_ id: ContentID) -> FakeTabContent? { box.contents[id] }
    var made: [ContentID] { box.made }

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
    #expect(fixture.made.isEmpty)

    try await fixture.ensure(address, geometry: ContentGeometry(size: CGSize(width: 800, height: 600), scale: 2))
    let content = try #require(fixture.content(address.contentID))
    #expect(content.calls == ["create"])
    #expect(content.lastAddress == address)
    #expect(content.lastEnv == ["K": "v"])
    #expect(content.lastGeometry?.size == CGSize(width: 800, height: 600))
    #expect(content.isLive)

    // A second ensure reuses the instance; the content decides it is a
    // re-attach.
    try await fixture.ensure(address)
    #expect(fixture.content(address.contentID) === content)
    #expect(content.calls == ["create", "create"])
    #expect(fixture.made == [address.contentID])
  }

  /// A bring-up without a slot (an IPC ensure, a re-attach after reclaim)
  /// starts at the slot the Content was last mounted in.
  @Test
  func ensureWithoutGeometryUsesTheMountedSlot() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    try await fixture.ensure(address)
    let content = try #require(fixture.content(address.contentID))
    let slot = ContentGeometry(size: CGSize(width: 1_200, height: 700), scale: 2)

    fixture.runtime.mount(address.contentID, geometry: slot)
    try await fixture.ensure(address)
    #expect(content.calls == ["create", "mount", "create"])
    #expect(content.lastGeometry == slot)

    // An explicit slot wins over the remembered one.
    let explicit = ContentGeometry(size: CGSize(width: 300, height: 200), scale: 1)
    try await fixture.ensure(address, geometry: explicit)
    #expect(content.lastGeometry == explicit)
  }

  @Test
  func mountCloseOrdering() async throws {
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
    // The instance is gone: a later focus does not reach it.
    fixture.runtime.acceptFocus(address.contentID)
    #expect(content.calls.count == 5)
  }

  /// A Content not brought up this launch still has a daemon to kill:
  /// close and suspend build an instance from the catalog just for the
  /// teardown, and drive it.
  @Test
  func closeAndSuspendReachAContentNeverBroughtUp() throws {
    let fixture = Fixture()
    let closed = try fixture.newTab()
    let suspended = try fixture.newTab()

    fixture.runtime.close(closed.contentID)
    fixture.runtime.suspend(suspended.contentID)

    #expect(fixture.made == [closed.contentID, suspended.contentID])
    #expect(fixture.content(closed.contentID)?.calls == ["close"])
    #expect(fixture.content(suspended.contentID)?.calls == ["suspend"])
  }

  /// An id the catalog does not know has nothing to tear down.
  @Test
  func closeOfAnUnknownContentDoesNothing() {
    let fixture = Fixture()
    fixture.runtime.close(ContentID())
    #expect(fixture.made.isEmpty)
  }

  @Test
  func suspendDropsTheInstanceWithoutClose() async throws {
    let fixture = Fixture()
    let address = try fixture.newTab()
    try await fixture.ensure(address)
    let content = try #require(fixture.content(address.contentID))

    fixture.runtime.suspend(address.contentID)
    #expect(content.calls == ["create", "suspend"])
    #expect(fixture.made == [address.contentID])
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
    let chrome = try #require(fixture.content(address.contentID)?.chrome)
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
}
