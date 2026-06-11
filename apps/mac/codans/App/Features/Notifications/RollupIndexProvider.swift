import Foundation
import Observation
import CodansCore

/// `@Observable` owner of the current `RollupIndex`. Recomputes whenever
/// either input changes — the inbox or the hierarchy / focus snapshot —
/// using a re-arming `withObservationTracking` loop. Views observe
/// `current` and re-render automatically.
@MainActor
@Observable
public final class RollupIndexProvider {
  public private(set) var current: RollupIndex = .empty

  @ObservationIgnored private let store: NotificationStore
  @ObservationIgnored private let focus: @MainActor () -> RollupFocusState
  /// Drives the `withObservationTracking` re-arm. Called inside the
  /// tracking block so observation captures every dependency the
  /// closure reads — typically `store.entries` plus a few `manager.catalog`
  /// reads inside the focus closure.
  @ObservationIgnored private let observe: @MainActor () -> Void
  @ObservationIgnored private var task: Task<Void, Never>?

  public init(
    store: NotificationStore,
    focus: @escaping @MainActor () -> RollupFocusState,
    observe: @escaping @MainActor () -> Void
  ) {
    self.store = store
    self.focus = focus
    self.observe = observe
    recompute()
    armObservation()
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  // MARK: - Internals

  /// Re-arming Observation pump: every loop iteration recomputes
  /// unconditionally and then re-registers a fresh tracking block.
  /// Recomputing *before* re-arming is load-bearing — `withObservationTracking`
  /// only fires `onChange` once per registration, and there is a small
  /// window between the previous fire and the next arm during which any
  /// further mutation would otherwise be missed. Recomputing in the loop
  /// body collapses that gap so a burst (e.g. five OSC 9 notifications in
  /// a few ms) is observed as the final settled state, not a stale one.
  private func armObservation() {
    let store = store
    let observe = observe
    task?.cancel()
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.recompute()
        let stream = AsyncStream<Void> { continuation in
          withObservationTracking {
            _ = store.entries
            observe()
          } onChange: {
            Task { @MainActor [continuation] in
              continuation.yield(())
            }
          }
        }
        for await _ in stream {
          break
        }
      }
    }
  }

  private func recompute() {
    let unread = store.entries.filter(\.isUnread)
    current = RollupIndex.compute(unread: unread, focus: focus())
  }
}
