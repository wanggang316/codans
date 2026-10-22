import Darwin
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Launch-time adoption of the daemons an earlier build left under the
/// cache directory (`SessionReaper.migrateLegacySocketDirectory`). The
/// property that matters is that a listening AF_UNIX socket, once renamed
/// into the runtime directory, is still the daemon the probe reaches —
/// otherwise every pane would respawn once on upgrade, which is the very
/// recycle the move exists to stop.
@MainActor
struct SessionReaperLegacyDirectoryTests {
  private struct Fixture {
    let coordinator: SessionCoordinator
    let legacy: URL
    let runtime: URL
    let cleanup: () -> Void
  }

  /// Socket paths must fit AF_UNIX's 104-byte `sun_path`, so the socket
  /// directories are short siblings under /tmp rather than a deep
  /// NSTemporaryDirectory()-based path.
  private func makeFixture() throws -> Fixture {
    let tag = UUID().uuidString.prefix(8)
    let legacy = URL(fileURLWithPath: "/tmp/cdr-\(tag)-cache", isDirectory: true)
    let runtime = URL(fileURLWithPath: "/tmp/cdr-\(tag)-run", isDirectory: true)
    let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-reaper-\(tag)", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    try fm.createDirectory(at: state, withIntermediateDirectories: true)
    let store = try SessionStore(fileURL: state.appendingPathComponent("sessions.json"))
    let coordinator = SessionCoordinator(store: store, initial: .empty)
    return Fixture(coordinator: coordinator, legacy: legacy, runtime: runtime) {
      store.release()
      for dir in [legacy, runtime, state] { try? fm.removeItem(at: dir) }
    }
  }

  private func row(_ contentID: ContentID, socketPath: String, at date: Date) -> Session {
    Session(
      contentID: contentID, socketPath: socketPath, pid: 0,
      createdAt: date, lastAttachedAt: date,
      command: [], cwd: "/tmp", zmxVersion: "", sessionEpoch: "1"
    )
  }

  private func makeReaper(_ fixture: Fixture, now: Date) -> SessionReaper {
    SessionReaper(
      coordinator: fixture.coordinator,
      socketDirectory: fixture.runtime,
      clock: { now },
      currentSessionEpoch: { "1" }
    )
  }

  /// The socket moves, the catalog row follows it, and the sweep's probe
  /// reaches the still-listening daemon at the new path.
  @Test
  func liveLegacyDaemonIsReachedAtItsNewPath() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let pane = ContentID()
    let legacyPath = fixture.legacy.appendingPathComponent(pane.raw.uuidString).path
    let runtimePath = fixture.runtime.appendingPathComponent(pane.raw.uuidString).path
    let fd = ListeningUnixSocket.bind(at: legacyPath)
    defer { _ = Darwin.close(fd) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    fixture.coordinator.recordLive(row(pane, socketPath: legacyPath, at: now))

    let reaper = makeReaper(fixture, now: now)
    reaper.migrateLegacySocketDirectory(from: fixture.legacy)

    #expect(FileManager.default.fileExists(atPath: runtimePath))
    #expect(!FileManager.default.fileExists(atPath: legacyPath))
    #expect(fixture.coordinator.catalog.sessions[pane.raw.uuidString]?.socketPath == runtimePath)

    let states = try reaper.sweep(liveContentIDs: [pane])
    guard case .alive(let session) = states[pane] else {
      Issue.record("expected the moved daemon to probe alive, got \(String(describing: states[pane]))")
      return
    }
    #expect(session.socketPath == runtimePath)
  }

  /// A quit-time snapshot written under the legacy tree is offered for
  /// restore from the runtime tree.
  @Test
  func legacySnapshotIsAdoptedByTheRuntimeDirectory() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let pane = ContentID()
    let legacySnapshots = fixture.legacy.appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: legacySnapshots, withIntermediateDirectories: true)
    let name = "\(pane.raw.uuidString).snap"
    try Data("snap".utf8).write(to: legacySnapshots.appendingPathComponent(name))
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let reaper = makeReaper(fixture, now: now)
    reaper.migrateLegacySocketDirectory(from: fixture.legacy)
    let states = try reaper.sweep(liveContentIDs: [pane])

    let expected = fixture.runtime
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(name)
    guard case .snapshot(let url) = states[pane] else {
      Issue.record("expected the moved snapshot to be offered for restore, got \(String(describing: states[pane]))")
      return
    }
    #expect(url.standardizedFileURL.path == expected.standardizedFileURL.path)
    #expect(!FileManager.default.fileExists(atPath: legacySnapshots.appendingPathComponent(name).path))
  }

  /// When the pane already has a daemon in the runtime directory, the
  /// legacy socket is an older duplicate: it is dropped and the runtime
  /// daemon is the one the sweep keeps.
  @Test
  func supersededLegacySocketIsDroppedAndTheRuntimeDaemonKept() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.runtime, withIntermediateDirectories: true)
    let pane = ContentID()
    let legacyPath = fixture.legacy.appendingPathComponent(pane.raw.uuidString).path
    let runtimePath = fixture.runtime.appendingPathComponent(pane.raw.uuidString).path
    let legacyFD = ListeningUnixSocket.bind(at: legacyPath)
    defer { _ = Darwin.close(legacyFD) }
    let runtimeFD = ListeningUnixSocket.bind(at: runtimePath)
    defer { _ = Darwin.close(runtimeFD) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    fixture.coordinator.recordLive(row(pane, socketPath: runtimePath, at: now))

    let reaper = makeReaper(fixture, now: now)
    reaper.migrateLegacySocketDirectory(from: fixture.legacy)

    #expect(!FileManager.default.fileExists(atPath: legacyPath))
    #expect(FileManager.default.fileExists(atPath: runtimePath))
    let states = try reaper.sweep(liveContentIDs: [pane])
    guard case .alive = states[pane] else {
      Issue.record("expected the runtime daemon to be kept, got \(String(describing: states[pane]))")
      return
    }
  }

  /// A machine that never ran an earlier build has no legacy directory;
  /// nothing is created or touched.
  @Test
  func missingLegacyDirectoryIsANoOp() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.legacy)
    let reaper = makeReaper(fixture, now: Date())
    reaper.migrateLegacySocketDirectory(from: fixture.legacy)
    #expect(!FileManager.default.fileExists(atPath: fixture.runtime.path))
  }
}
