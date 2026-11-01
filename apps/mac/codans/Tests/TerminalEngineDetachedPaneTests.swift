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

  private let working = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .working, app: "claude-code"))
  private let done = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .done, app: "claude-code"))

  /// Records the fences the engine sends, decoded as both clients see them.
  private final class FenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [DetachedPaneSignal] = []
    func append(_ bytes: Data) {
      var scanner = ZmxOutputScanner()
      let signals = scanner.scan(bytes)
      lock.withLock { sent += signals }
    }
    var all: [DetachedPaneSignal] { lock.withLock { sent } }
  }

  private func waitForFences(_ log: FenceLog, count: Int) async {
    for _ in 0..<200 where log.all.count < count {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test
  func reattachHandsOverAtTheSurfacesFirstFence() async {
    let harness = Harness()
    let fences = FenceLog()
    harness.engine.sendHandoffFence = { _, bytes in fences.append(bytes) }
    harness.engine.handoffFenceInterval = .milliseconds(10)
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    let watcher = harness.watchers[0]

    #expect(harness.engine.beginDetachedHandoff(paneID))
    harness.engine.sendHandoffFences(paneID)
    await waitForFences(fences, count: 2)
    let f0 = fences.all[0]
    let f1 = fences.all[1]

    // Stream: [working] f0 [done] f1 [done]. The surface connected after
    // the first `done`, so its first fence is f1.
    watcher.onEvent(.signals([working, f0, done]))
    await settle()
    #expect(!watcher.stopped)
    #expect(!harness.engine.admitSurfaceSignal(f1, for: paneID))
    #expect(harness.engine.admitSurfaceSignal(done, for: paneID))
    watcher.onEvent(.signals([f1, done]))
    await settle()
    #expect(watcher.stopped)
    #expect(harness.changeKinds(for: paneID) == [.detached, .observationEnded])
    // No more fences once the split is known.
    let sentAtSplit = fences.all.count
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fences.all.count == sentAtSplit)
    // Late events of the stopped watcher are stale.
    watcher.onEvent(.signals([.title("stale")]))
    await settle()
    harness.engine.finishEventStream()

    var states: [ProgramStatusState?] = []
    var titles = 0
    for await event in stream {
      switch event {
      case .paneProgramStatusChanged(paneID, let summary): states.append(summary?.root?.state)
      case .paneInfoChanged(paneID, .title): titles += 1
      default: break
      }
    }
    // From the watcher: `working`, then the held `done` before f1. The
    // surface's own `done` after f1 is admitted to its decoder, which this
    // test does not run; the watcher's copy after f1 is dropped.
    #expect(states == [.working, .done])
    #expect(titles == 0)
  }

  @Test
  func handoffGivesUpWhenTheSurfaceNeverReadsAFence() async {
    let harness = Harness()
    harness.engine.sendHandoffFence = { _, _ in }
    harness.engine.handoffFenceInterval = .milliseconds(5)
    harness.engine.handoffTimeout = .milliseconds(40)
    let paneID = PaneID()
    harness.engine.watchDetachedPanes([paneID])
    #expect(harness.engine.beginDetachedHandoff(paneID))
    #expect(!harness.engine.admitSurfaceSignal(working, for: paneID))

    harness.engine.sendHandoffFences(paneID)
    try? await Task.sleep(for: .milliseconds(150))

    #expect(harness.watchers[0].stopped)
    #expect(harness.engine.admitSurfaceSignal(working, for: paneID))
  }

  @Test
  func fencesAreNeverDeliveredAsProgramStatus() async {
    let harness = Harness()
    let paneID = PaneID()
    var scanner = ZmxOutputScanner()
    let stray = scanner.scan(DetachedHandoff.fenceBytes(DetachedHandoff.fencePrefix + "1"))[0]
    #expect(!harness.engine.admitSurfaceSignal(stray, for: paneID))
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    harness.watchers[0].onEvent(.signals([stray]))
    await settle()
    harness.engine.finishEventStream()
    var sawStatus = false
    for await event in stream {
      if case .paneProgramStatusChanged = event { sawStatus = true }
    }
    #expect(!sawStatus)
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
    // No handoff left that would hold back a later surface.
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
