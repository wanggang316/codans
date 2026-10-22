import Foundation
import Testing
import CodansCore

@testable import Codans

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
    let contents = ContentRuntime(hierarchy: manager) { TerminalContent(id: $0.id, engine: engine) }
    return (TerminalClient.live(engine: engine, contents: contents), engine)
  }

  @Test
  func liveEventsStreamBroadcastsEmittedEvents() async {
    let (client, engine) = makeLiveEngine()
    let stream = client.events()
    let contentID = ContentID()
    let tabID = TabID()

    engine.emit(.paneReady(contentID))
    engine.emit(.tabActivated(tabID))

    var iterator = stream.makeAsyncIterator()
    if case .paneReady(let pid) = await iterator.next() {
      #expect(pid == contentID)
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
  func liveEnsureSurfaceThrowsWhenContentUnknown() async {
    let (client, _) = makeLiveEngine()
    do {
      try await client.ensureSurface(ContentID(), nil)
      Issue.record("ensureSurface should throw for an unknown Content")
    } catch TerminalClient.Error.contentNotFound {
      // expected
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}
