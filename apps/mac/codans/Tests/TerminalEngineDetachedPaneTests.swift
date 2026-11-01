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
    var exited: [PaneID] = []

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
      engine.onDetachedDaemonExited = { [unowned self] paneID in
        self.exited.append(paneID)
      }
    }

    deinit { try? FileManager.default.removeItem(at: tempURL) }

    func exitCount(for paneID: PaneID) -> Int {
      exited.filter { $0 == paneID }.count
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
    #expect(harness.exitCount(for: first) == 0)
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
    #expect(harness.exitCount(for: paneID) == 0)
  }

  /// Re-attach stops the watcher before the surface exists; signals it
  /// read but the main actor has not handled yet are dropped, so they
  /// cannot overwrite what the surface reports.
  @Test
  func signalsOfAStoppedWatcherAreIgnored() async {
    let harness = Harness()
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    let watcher = harness.watchers[0]

    #expect(harness.engine.stopWatchingDetachedPane(paneID))
    watcher.onEvent(.signals([.programStatus(ProgramStatusReport(state: .working, app: "claude-code"))]))
    watcher.onEvent(.daemonGone)
    await settle()
    harness.engine.finishEventStream()

    var sawStatus = false
    for await event in stream {
      if case .paneProgramStatusChanged = event { sawStatus = true }
    }
    #expect(!sawStatus)
    #expect(harness.exitCount(for: paneID) == 0)
  }

  /// The re-attach race: the watcher read signals and queued their
  /// callbacks, `ensureSurface` stopped it and a surface now renders the
  /// pane, and only then do the callbacks run. The surface is the only
  /// source: no program status, title or notification from the watcher.
  @Test
  func queuedWatcherSignalsAreIgnoredOnceASurfaceIsAttached() async {
    let harness = Harness()
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    let watcher = harness.watchers[0]

    // Queued before the stop, handled on the main actor after it.
    watcher.onEvent(
      .signals([
        .programStatus(ProgramStatusReport(state: .working, app: "claude-code")),
        .title("old"),
        .desktopNotification(title: "", body: "again"),
      ]))
    watcher.onEvent(.daemonGone)
    #expect(harness.engine.stopWatchingDetachedPane(paneID))
    harness.engine.surfacePresenceOverride = { $0 == paneID }
    await settle()
    harness.engine.finishEventStream()

    var delivered = 0
    for await event in stream {
      switch event {
      case .paneProgramStatusChanged(paneID, _), .paneInfoChanged(paneID, _): delivered += 1
      default: break
      }
    }
    #expect(delivered == 0)
    #expect(harness.exitCount(for: paneID) == 0)
  }

  /// Even a watcher still registered is not a source while a surface
  /// renders the pane.
  @Test
  func aCurrentWatcherIsIgnoredWhileASurfaceExists() async {
    let harness = Harness()
    let paneID = PaneID()
    let stream = harness.engine.events()
    harness.engine.watchDetachedPanes([paneID])
    harness.engine.surfacePresenceOverride = { $0 == paneID }

    harness.watchers[0].onEvent(.signals([.title("old")]))
    harness.watchers[0].onEvent(.daemonGone)
    await settle()
    harness.engine.finishEventStream()

    var titles = 0
    for await event in stream {
      if case .paneInfoChanged(paneID, .title) = event { titles += 1 }
    }
    #expect(titles == 0)
    #expect(harness.exitCount(for: paneID) == 0)
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
    #expect(harness.exitCount(for: paneID) == 1)
    // A later watch is a fresh watcher, not the gone one.
    harness.engine.watchDetachedPanes([paneID])
    #expect(harness.watchers.count == 2)
  }

  @Test
  func explicitStopEndsObservationOnce() {
    let harness = Harness()
    let paneID = PaneID()
    harness.engine.watchDetachedPanes([paneID])

    #expect(harness.engine.stopWatchingDetachedPane(paneID))
    #expect(!harness.engine.stopWatchingDetachedPane(paneID))
    #expect(harness.watchers[0].stopped)
    #expect(harness.exitCount(for: paneID) == 0)
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
