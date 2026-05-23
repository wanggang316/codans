import Foundation
import Testing

@testable import TouchCodeCore

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
    // touch-code build can still own it.
    #expect(FileManager.default.fileExists(atPath: ctx.fileURL.path))
  }

  // MARK: - Helpers

  private struct TempContext {
    let directory: URL
    let fileURL: URL

    init() {
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("touch-code-session-store-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      self.directory = base
      self.fileURL = base.appendingPathComponent("sessions.json")
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
