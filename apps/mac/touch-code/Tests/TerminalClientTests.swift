import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct TerminalClientTests {
  private func makeLiveEngine() -> (TerminalClient, TerminalEngine) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    // ghosttyRuntime = nil: we exercise events() and closure wiring, not
    // actual surface creation (requires a real GhosttyRuntime + window).
    let engine = TerminalEngine(store: store, hierarchy: manager)
    return (TerminalClient.live(engine: engine), engine)
  }

  @Test
  func liveEventsStreamBroadcastsEmittedEvents() async {
    let (client, engine) = makeLiveEngine()
    let stream = client.events()
    let paneID = PaneID()
    let tabID = TabID()

    engine.emit(.paneReady(paneID))
    engine.emit(.tabActivated(tabID))

    var iterator = stream.makeAsyncIterator()
    if case .paneReady(let pid) = await iterator.next() {
      #expect(pid == paneID)
    } else {
      Issue.record("expected paneReady first")
    }
    if case .tabActivated(let tid) = await iterator.next() {
      #expect(tid == tabID)
    } else {
      Issue.record("expected tabActivated second")
    }
  }

  @Test
  func liveEnsureSurfaceThrowsWhenAddressUnknown() async {
    let (client, _) = makeLiveEngine()
    do {
      try await client.ensureSurface(
        PaneID(), TabID(), WorktreeID(), ProjectID()
      )
      Issue.record("ensureSurface should throw for unknown address")
    } catch TerminalClient.Error.worktreeNotFound {
      // expected
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}
