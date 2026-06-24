import Foundation
import Testing

@testable import CodansCore

@MainActor
struct SessionStoreTests {
  @Test
  func roundTrip() throws {
    let ctx = TempContext()
    defer { ctx.cleanup() }

    let storeA = try SessionStore(fileURL: ctx.fileURL)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session1 = Session(
      paneID: PaneID(),
      socketPath: "/tmp/zmx/pane-a.sock",
      pid: 1234,
      createdAt: now,
      lastAttachedAt: now,
      command: ["/bin/zsh", "-l"],
      cwd: "/Users/gump/code/a",
      zmxVersion: "0.1.0"
    )
    let session2 = Session(
      paneID: PaneID(),
      socketPath: "/tmp/zmx/pane-b.sock",
      pid: 5678,
      createdAt: now.addingTimeInterval(60),
      lastAttachedAt: now.addingTimeInterval(120),
      command: ["/bin/bash"],
      cwd: "/Users/gump/code/b",
      zmxVersion: "0.1.0"
    )
    let catalog = SessionCatalog(sessions: [
      session1.paneID.description: session1,
      session2.paneID.description: session2,
    ])

    try storeA.saveNow(catalog)
    // Release storeA's flock before opening storeB — `SessionStore.init`
    // takes `LOCK_EX|LOCK_NB` so a second concurrent owner
    // would throw `.alreadyHeld`. The "two stores against the same file"
    // shape models a relaunch, where the previous owner is already gone.
    storeA.release()

    let storeB = try SessionStore(fileURL: ctx.fileURL)
    let loaded = try storeB.load()

    #expect(loaded == catalog)
    #expect(loaded.version == SessionCatalog.currentVersion)
    #expect(loaded.sessions.count == 2)
  }

  @Test
  func corruptFileIsBackedUpAndLoadReturnsEmpty() throws {
    let ctx = TempContext()
    defer { ctx.cleanup() }

    try Data("{ this is not valid json".utf8).write(to: ctx.fileURL)

    let store = try SessionStore(fileURL: ctx.fileURL)
    let loaded = try store.load()
    #expect(loaded == .empty)

    let directory = ctx.fileURL.deletingLastPathComponent().path
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
    let backups = entries.filter {
      $0.hasPrefix("\(ctx.fileURL.lastPathComponent).corrupt-") && $0.hasSuffix(".bak")
    }
    #expect(backups.count == 1)
    #expect(FileManager.default.fileExists(atPath: ctx.fileURL.path) == false)
  }

  /// Guards the race fix: an explicit `saveNow(B)` after an
  /// earlier `scheduleSave(A)` must cancel the pending debounced task
  /// so that, when the 500 ms timer would have fired, it does NOT
  /// resurrect catalog A and overwrite catalog B.
  @Test
  func saveNowCancelsPendingDebounce() async throws {
    let ctx = TempContext()
    defer { ctx.cleanup() }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try SessionStore(fileURL: ctx.fileURL)
    let catalogA = Self.singleSessionCatalog(pid: 111, at: now)
    let catalogB = Self.singleSessionCatalog(pid: 222, at: now.addingTimeInterval(1))

    store.scheduleSave(catalogA)
    try store.saveNow(catalogB)

    // Wait past the 500 ms debounce — the cancelled task must not fire.
    try await Task.sleep(nanoseconds: 700_000_000)

    let loaded = try store.load()
    #expect(loaded == catalogB)
    #expect(loaded.sessions.values.first?.pid == 222)
  }

  @Test
  func forwardCompatibleVersionReturnsEmpty() throws {
    let ctx = TempContext()
    defer { ctx.cleanup() }

    let futurePayload = #"{"version": 999, "sessions": {}}"#
    try Data(futurePayload.utf8).write(to: ctx.fileURL)

    let store = try SessionStore(fileURL: ctx.fileURL)
    let loaded = try store.load()
    #expect(loaded == .empty)
    // The forward-compat file is intentionally left in place so a newer
    // codans build can still own it.
    #expect(FileManager.default.fileExists(atPath: ctx.fileURL.path))
  }

  // MARK: - Helpers

  /// Single-row catalog with a fixed pane id and configurable pid /
  /// timestamps — handy for tests that want to distinguish two writes
  /// by content without spelling out the full struct each time.
  private static func singleSessionCatalog(
    pid: Int32,
    at stamp: Date
  ) -> SessionCatalog {
    let session = Session(
      paneID: PaneID(),
      socketPath: "/tmp/zmx/test-\(pid).sock",
      pid: pid,
      createdAt: stamp,
      lastAttachedAt: stamp,
      command: ["/bin/zsh"],
      cwd: "/tmp",
      zmxVersion: "0.1.0"
    )
    return SessionCatalog(sessions: [session.paneID.description: session])
  }

  private struct TempContext {
    let directory: URL
    let fileURL: URL

    init() {
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("codans-session-store-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      self.directory = base
      self.fileURL = base.appendingPathComponent("sessions.json")
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
