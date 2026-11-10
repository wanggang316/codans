import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// A pane that leaves the screen must let its store go: the store's
/// effects, the pane's stream among them, end only when it is freed, and
/// the Mac allows a device four streams at a time.
@MainActor
struct TerminalStoreCacheTests {
  @Test
  func aDroppedPaneFreesItsStore() {
    let cache = TerminalStoreCache()
    weak var dropped: StoreOf<TerminalStreamFeature>?
    do {
      let store = cache.store(for: "A", permission: .interactive, isConnected: false, supportsSeats: true)
      _ = cache.store(for: "B", permission: .interactive, isConnected: false, supportsSeats: true)
      // Wires the screen's seat reports to the store, as on screen.
      store.screen.reportSeatSize(cols: 60, rows: 40)
      dropped = store
    }
    #expect(dropped != nil)
    cache.retain(only: ["B"])
    #expect(dropped == nil)
    #expect(cache.all.count == 1)
  }
}
