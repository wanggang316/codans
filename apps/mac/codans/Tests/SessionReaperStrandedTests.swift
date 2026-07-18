import Darwin
import Foundation
import Testing
import CodansCore

@testable import Codans

/// End-to-end guard for the stranded-daemon recycle path — the launch-time
/// half of the WindowServer-restart fix. The unit-level companion
/// (`SessionCoordinatorEpochTests`) proves a daemon's birth epoch survives a
/// reattach; this proves the reaper then ACTS on a surviving daemon whose
/// stamp disagrees with the live session: it kills + prunes it so bring-up
/// respawns clean in the live session (the heal). Without the recordLive
/// fix the stamp would have been overwritten with the live epoch and this
/// branch could never fire.
///
/// Uses a real listening Unix socket so `SessionReaper.probe`'s `connect(2)`
/// reports the daemon as alive — the reaper only recycles daemons that are
/// alive on the wire but stranded by epoch.
@MainActor
struct SessionReaperStrandedTests {
  /// Bind + listen a throwaway AF_UNIX socket so the reaper's probe sees a
  /// live daemon. Returns the fd (caller closes) — the path is unlinked by
  /// the temp-dir cleanup.
  private func makeListeningSocket(at path: String) -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // Copy the path into a local buffer first, then memcpy into sun_path —
    // mirrors `SessionReaper.probe` and avoids overlapping exclusive access
    // to `addr` that a nested `withCString` + `withUnsafeMutablePointer`
    // would trigger under Swift's exclusivity checker.
    let pathBytes = Array(path.utf8CString)
    precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "socket path too long")
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    _ = Darwin.unlink(path)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    precondition(bound == 0, "bind() failed errno=\(errno)")
    precondition(Darwin.listen(fd, 1) == 0, "listen() failed")
    return fd
  }

  private func makeStack() throws -> (SessionCoordinator, URL, () -> Void) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-reaper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try SessionStore(fileURL: dir.appendingPathComponent("sessions.json"))
    let coordinator = SessionCoordinator(store: store, initial: .empty)
    return (coordinator, dir, { store.release(); try? FileManager.default.removeItem(at: dir) })
  }

  private func row(_ paneID: PaneID, socketPath: String, epoch: String?, lastAttachedAt: Date) -> Session {
    Session(
      paneID: paneID, socketPath: socketPath, pid: 0,
      createdAt: lastAttachedAt, lastAttachedAt: lastAttachedAt,
      command: [], cwd: "/tmp", zmxVersion: "", sessionEpoch: epoch
    )
  }

  /// A daemon alive on the wire but stamped with an epoch that differs from
  /// the live session is recycled: the reaper reports `.dead` and prunes the
  /// row so `ensureSurface` respawns a clean daemon in the live session.
  @Test
  func aliveDaemonWithStaleEpochIsRecycled() throws {
    let (coordinator, _, cleanup) = try makeStack()
    defer { cleanup() }
    let pane = PaneID()
    // Short path: AF_UNIX `sun_path` caps at ~104 bytes, far under a deep
    // NSTemporaryDirectory()-based path, so bind the listener directly in /tmp.
    let socketPath = "/tmp/cdr-\(UUID().uuidString.prefix(8)).sock"
    let fd = makeListeningSocket(at: socketPath)
    defer { _ = Darwin.close(fd); _ = Darwin.unlink(socketPath) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    coordinator.recordLive(row(pane, socketPath: socketPath, epoch: "100022", lastAttachedAt: now))

    let reaper = SessionReaper(
      coordinator: coordinator,
      clock: { now },
      currentSessionEpoch: { "107395" }   // live session rotated away from the stamp
    )
    let states = try reaper.sweep(livePaneIDs: [pane])

    guard case .dead = states[pane] else {
      Issue.record("expected stranded daemon to be recycled (.dead), got \(String(describing: states[pane]))")
      return
    }
    #expect(coordinator.catalog.sessions[pane.raw.uuidString] == nil)  // row pruned
  }

  /// Control: the same alive daemon whose stamp MATCHES the live session is
  /// kept (`.alive`, row retained) — proving the recycle is driven by the
  /// epoch mismatch, not merely by being alive.
  @Test
  func aliveDaemonWithMatchingEpochIsKept() throws {
    let (coordinator, _, cleanup) = try makeStack()
    defer { cleanup() }
    let pane = PaneID()
    // Short path: AF_UNIX `sun_path` caps at ~104 bytes, far under a deep
    // NSTemporaryDirectory()-based path, so bind the listener directly in /tmp.
    let socketPath = "/tmp/cdr-\(UUID().uuidString.prefix(8)).sock"
    let fd = makeListeningSocket(at: socketPath)
    defer { _ = Darwin.close(fd); _ = Darwin.unlink(socketPath) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    coordinator.recordLive(row(pane, socketPath: socketPath, epoch: "107395", lastAttachedAt: now))

    let reaper = SessionReaper(
      coordinator: coordinator,
      clock: { now },
      currentSessionEpoch: { "107395" }   // same session — not stranded
    )
    let states = try reaper.sweep(livePaneIDs: [pane])

    guard case .alive = states[pane] else {
      Issue.record("expected matching-epoch daemon to be kept (.alive), got \(String(describing: states[pane]))")
      return
    }
    #expect(coordinator.catalog.sessions[pane.raw.uuidString] != nil)  // row retained
  }
}
