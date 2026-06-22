import Foundation
import Testing

@testable import CodansCore

/// `recordLive` must treat `sessionEpoch` as birth identity: stamped once
/// when a daemon is first recorded and preserved across every live
/// re-record (reattach, focus, pid-learn). Overwriting it with the
/// current session on a reattach is the defect that let a pane survive a
/// WindowServer-restart session rotation undetected — the reaper compared
/// the (clobbered) current epoch against itself and never saw the strand.
/// See `SessionCoordinator.recordLive` and `SessionEpoch`.
@MainActor
struct SessionCoordinatorEpochTests {
  /// Spin up a coordinator backed by a throwaway on-disk store. Reads go
  /// through the in-memory `catalog`, so the debounced disk save is
  /// irrelevant to these assertions.
  private func makeCoordinator() throws -> (SessionCoordinator, () -> Void) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-coord-epoch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try SessionStore(fileURL: dir.appendingPathComponent("sessions.json"))
    let coordinator = SessionCoordinator(store: store, initial: .empty)
    let cleanup: () -> Void = {
      store.release()
      try? FileManager.default.removeItem(at: dir)
    }
    return (coordinator, cleanup)
  }

  private func makeSession(
    _ paneID: PaneID,
    epoch: String?,
    lastAttachedAt: Date
  ) -> Session {
    Session(
      paneID: paneID,
      socketPath: "/tmp/zmx/\(paneID.raw.uuidString)",
      pid: 0,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastAttachedAt: lastAttachedAt,
      command: [],
      cwd: "/tmp",
      zmxVersion: "",
      sessionEpoch: epoch
    )
  }

  /// A reattach in a new session refreshes `lastAttachedAt` but MUST keep
  /// the original birth epoch — otherwise the reaper can never recognise a
  /// stranded daemon.
  @Test
  func epochIsPreservedAcrossReattachInNewSession() throws {
    let (coordinator, cleanup) = try makeCoordinator()
    defer { cleanup() }
    let pane = PaneID()
    let born = Date(timeIntervalSince1970: 1_700_000_000)
    let reattached = born.addingTimeInterval(3600)

    coordinator.recordLive(makeSession(pane, epoch: "100022", lastAttachedAt: born))
    // Reattach: same pane, the live session is now "107395" and the
    // attach timestamp moves forward.
    coordinator.recordLive(makeSession(pane, epoch: "107395", lastAttachedAt: reattached))

    let row = coordinator.catalog.sessions[pane.raw.uuidString]
    #expect(row?.sessionEpoch == "100022")            // birth epoch pinned
    #expect(row?.lastAttachedAt == reattached)        // live state still refreshes
  }

  /// First record of a pane with no prior row stamps the incoming epoch —
  /// this is the genuine fresh-spawn path (also the path taken right after
  /// the reaper recycles a stranded daemon and removes its row).
  @Test
  func epochIsStampedWhenNoPriorRow() throws {
    let (coordinator, cleanup) = try makeCoordinator()
    defer { cleanup() }
    let pane = PaneID()

    coordinator.recordLive(makeSession(pane, epoch: "107395", lastAttachedAt: Date()))

    #expect(coordinator.catalog.sessions[pane.raw.uuidString]?.sessionEpoch == "107395")
  }

  /// A legacy row written before the epoch field existed carries `nil`; the
  /// first re-record that knows a real epoch is allowed to fill it in, so
  /// the field can heal forward rather than staying unknown forever.
  @Test
  func nilPriorEpochIsAdoptable() throws {
    let (coordinator, cleanup) = try makeCoordinator()
    defer { cleanup() }
    let pane = PaneID()

    coordinator.recordLive(makeSession(pane, epoch: nil, lastAttachedAt: Date()))
    coordinator.recordLive(makeSession(pane, epoch: "107395", lastAttachedAt: Date()))

    #expect(coordinator.catalog.sessions[pane.raw.uuidString]?.sessionEpoch == "107395")
  }
}
