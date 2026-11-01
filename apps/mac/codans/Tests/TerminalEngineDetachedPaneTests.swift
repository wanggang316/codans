import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct TerminalEngineDetachedPaneTests {
  private final class FakeWatcher: DetachedPaneWatching, @unchecked Sendable {
    let paneID: PaneID
    let onEvent: @Sendable (ZmxPassiveWatcher.Event) -> Void
    private(set) var started = false
    private(set) var stopped = false

    init(paneID: PaneID, onEvent: @escaping @Sendable (ZmxPassiveWatcher.Event) -> Void) {
      self.paneID = paneID
      self.onEvent = onEvent
    }

    func start() { started = true }
    func stop() { stopped = true }
  }

  @MainActor
  private final class Harness {
    let engine: TerminalEngine
    let tempURL: URL
    var watchers: [FakeWatcher] = []
    var changes: [(PaneID, TerminalEngine.DetachedPaneChange)] = []

    init() {
      tempURL = FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString + ".json")
      let store = CatalogStore(fileURL: tempURL)
      let manager = HierarchyManager(catalog: .default, store: store, runtime: FakeHierarchyRuntime())
      engine = TerminalEngine(store: store, hierarchy: manager)
      engine.makeDetachedPaneWatcher = { [unowned self] paneID, onEvent in
        let watcher = FakeWatcher(paneID: paneID, onEvent: onEvent)
        self.watchers.append(watcher)
        return watcher
      }
      engine.onDetachedPaneChange = { [unowned self] paneID, change in
        self.changes.append((paneID, change))
      }
    }

    deinit { try? FileManager.default.removeItem(at: tempURL) }

    func changeKinds(for paneID: PaneID) -> [TerminalEngine.DetachedPaneChange] {
      changes.filter { $0.0 == paneID }.map(\.1)
    }
  }

  /// Watcher events hop to the main actor through a `Task`.
  private func settle() async {
    for _ in 0..<10 { await Task.yield() }
  }

  @Test
  func watchesEachDetachedPaneOnce() {
    let harness = Harness()
    let first = PaneID()
    let second = PaneID()

    harness.engine.watchDetachedPanes([first, second, first])
    harness.engine.watchDetachedPanes([first])

    #expect(harness.watchers.map(\.paneID) == [first, second])
    #expect(harness.watchers.allSatisfy { $0.started })
    #expect(harness.engine.isWatchingDetachedPane(first))
    #expect(harness.changeKinds(for: first) == [.detached])
  }

  @Test
  func routesSignalsIntoTheSurfacePipeline() async {
    let harness = Harness()
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])

    harness.watchers[0].onEvent(
      .signals([
        .title("agent"),
        .desktopNotification(title: "", body: "done"),
        .programStatus(ProgramStatusReport(state: .working, app: "claude-code")),
      ]))
    await settle()
    harness.engine.finishEventStream()

    var titles: [String?] = []
    var notifications: [String] = []
    var programStates: [ProgramStatusState?] = []
    for await event in stream {
      switch event {
      case .paneInfoChanged(paneID, .title(let title)): titles.append(title)
      case .paneInfoChanged(paneID, .desktopNotification(_, let body)): notifications.append(body)
      case .paneProgramStatusChanged(paneID, let summary): programStates.append(summary?.root?.state)
      default: break
      }
    }
    #expect(titles == ["agent"])
    #expect(notifications == ["done"])
    #expect(programStates == [.working])
  }

  @Test
  func killStopsTheWatcherFirstAndIgnoresItsLateEvents() async {
    let harness = Harness()
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    let watcher = harness.watchers[0]

    harness.engine.closeSurface(for: paneID)
    #expect(watcher.stopped)
    #expect(!harness.engine.isWatchingDetachedPane(paneID))

    watcher.onEvent(.signals([.title("late")]))
    watcher.onEvent(.daemonGone)
    await settle()
    harness.engine.finishEventStream()

    var sawLateTitle = false
    for await event in stream {
      if case .paneInfoChanged(paneID, .title) = event { sawLateTitle = true }
    }
    #expect(!sawLateTitle)
    #expect(harness.changeKinds(for: paneID) == [.detached, .observationEnded])
  }

  @Test
  func daemonExitEndsObservationAndReportsIt() async {
    let harness = Harness()
    let paneID = PaneID()
    harness.engine.watchDetachedPanes([paneID])
    harness.watchers[0].onEvent(.signals([.programStatus(ProgramStatusReport(state: .working, app: "claude-code"))]))
    await settle()

    harness.watchers[0].onEvent(.daemonGone)
    await settle()

    #expect(!harness.engine.isWatchingDetachedPane(paneID))
    #expect(harness.changeKinds(for: paneID) == [.detached, .daemonExited])
    // A later watch is a fresh watcher, not the gone one.
    harness.engine.watchDetachedPanes([paneID])
    #expect(harness.watchers.count == 2)
  }

  /// Lets a test decide when the surface counts as attached.
  private final class AttachGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      await withCheckedContinuation { continuation in
        let resumeNow = lock.withLock {
          if opened { return true }
          waiters.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }

    func open() {
      let pending = lock.withLock {
        opened = true
        defer { waiters.removeAll() }
        return waiters
      }
      pending.forEach { $0.resume() }
    }
  }

  private let working = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .working, app: "claude-code"))
  private let done = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .done, app: "claude-code"))

  @Test
  func reattachKeepsTheWatcherUntilTheSurfaceIsAttached() async {
    let harness = Harness()
    let gate = AttachGate()
    harness.engine.awaitSurfaceAttached = { _ in await gate.wait() }
    harness.engine.detachedHandoffGrace = .milliseconds(50)
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    let watcher = harness.watchers[0]

    #expect(harness.engine.beginDetachedHandoff(paneID))
    harness.engine.finishDetachedHandoffWhenAttached(paneID)
    // Output before the surface connects reaches only the watcher.
    watcher.onEvent(.signals([working]))
    await settle()
    #expect(!watcher.stopped)
    // Overlap: both report `done`, in either order.
    #expect(!harness.engine.admitSurfaceSignal(working, for: paneID))
    #expect(harness.engine.admitSurfaceSignal(done, for: paneID))
    watcher.onEvent(.signals([done, .desktopNotification(title: "", body: "ready")]))
    await settle()
    #expect(!harness.engine.admitSurfaceSignal(.desktopNotification(title: "", body: "ready"), for: paneID))
    // The daemon cannot be reported gone while a surface takes over.
    watcher.onEvent(.daemonGone)
    await settle()

    gate.open()
    await settle()
    #expect(watcher.stopped)
    #expect(harness.changeKinds(for: paneID) == [.detached, .observationEnded])
    try? await Task.sleep(for: .milliseconds(150))
    // After the grace period the surface is the only source.
    #expect(harness.engine.admitSurfaceSignal(done, for: paneID))
    watcher.onEvent(.signals([.title("stale")]))
    await settle()
    harness.engine.finishEventStream()

    var states: [ProgramStatusState?] = []
    var notifications = 0
    var titles = 0
    for await event in stream {
      switch event {
      case .paneProgramStatusChanged(paneID, let summary): states.append(summary?.root?.state)
      case .paneInfoChanged(paneID, .desktopNotification): notifications += 1
      case .paneInfoChanged(paneID, .title): titles += 1
      default: break
      }
    }
    // `working` from the watcher only; `done` came from the surface, whose
    // ingest this test does not run, so the watcher's copy was dropped.
    #expect(states == [.working])
    #expect(notifications == 1)
    #expect(titles == 0)
  }

  @Test
  func closeEndsTheWatcherAndTheHandoff() async {
    let harness = Harness()
    let paneID = PaneID()
    harness.engine.watchDetachedPanes([paneID])
    #expect(harness.engine.beginDetachedHandoff(paneID))
    harness.watchers[0].onEvent(.signals([working]))
    await settle()

    harness.engine.closeSurface(for: paneID)
    #expect(harness.watchers[0].stopped)
    // No ledger left to drop a later surface's copy of `working`.
    #expect(harness.engine.admitSurfaceSignal(working, for: paneID))
  }

  @Test
  func explicitStopEndsObservationOnce() {
    let harness = Harness()
    let paneID = PaneID()
    harness.engine.watchDetachedPanes([paneID])

    #expect(harness.engine.stopWatchingDetachedPane(paneID))
    #expect(!harness.engine.stopWatchingDetachedPane(paneID))
    #expect(harness.watchers[0].stopped)
    #expect(harness.changeKinds(for: paneID) == [.detached, .observationEnded])
  }

  @Test
  func finishingTheEngineStopsEveryWatcher() {
    let harness = Harness()
    harness.engine.watchDetachedPanes([PaneID(), PaneID()])

    harness.engine.finishEventStream()
    harness.engine.watchDetachedPanes([PaneID()])

    #expect(harness.watchers.count == 2)
    #expect(harness.watchers.allSatisfy { $0.stopped })
  }
}
