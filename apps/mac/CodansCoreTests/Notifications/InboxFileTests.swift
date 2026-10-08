import Foundation
import Testing

@testable import CodansCore

struct InboxFileTests {
  // MARK: - Fixtures

  private func entry(
    title: String = "t",
    body: String = "b",
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> InboxEntry {
    InboxEntry(
      kind: .taskFinished,
      title: title,
      body: body,
      createdAt: createdAt,
      source: InboxEntry.SourcePath(
        projectID: ProjectID(),
        worktreeID: WorktreeID(),
        tabID: TabID(),
        paneID: PaneID()
      )
    )
  }

  private static func temporaryDirectory() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("inbox-file-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private static func temporaryURL(in directory: URL? = nil) -> URL {
    (directory ?? temporaryDirectory()).appendingPathComponent("notifications.json")
  }

  // MARK: - Tests

  /// (1) Envelope round-trip: save → load returns the same entries and the
  /// on-disk JSON has top-level `version` and `entries` keys.
  @Test
  func envelopeRoundTrip() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let original = [entry(title: "first"), entry(title: "second")]
    try InboxFile.save(original, to: url)

    let loaded = try InboxFile.load(from: url)
    #expect(loaded?.entries.map(\.title) == ["first", "second"])
    #expect(loaded?.quarantineBackupURL == nil)

    // Inspect raw JSON structure.
    let data = try Data(contentsOf: url)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["version"] as? Int == 1)
    #expect(json?["entries"] is [Any])
  }

  /// (2) Legacy bare-array decode: a hand-written top-level JSON array
  /// loads cleanly with no quarantine.
  @Test
  func legacyBareArrayDecodes() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let legacy = [entry(title: "legacy")]
    let bytes = try JSONEncoder.touchCodeDefault.encode(legacy)
    try bytes.write(to: url)

    let loaded = try InboxFile.load(from: url)
    #expect(loaded?.entries.count == 1)
    #expect(loaded?.entries.first?.title == "legacy")
    #expect(loaded?.quarantineBackupURL == nil)
  }

  /// (3) Legacy upgrade: load a bare-array file, then save the same
  /// entries — the file is now in envelope shape.
  @Test
  func legacyFileUpgradesOnNextSave() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let legacy = [entry(title: "legacy")]
    let bytes = try JSONEncoder.touchCodeDefault.encode(legacy)
    try bytes.write(to: url)

    let loaded = try #require(try InboxFile.load(from: url))
    try InboxFile.save(loaded.entries, to: url)

    let upgraded = try Data(contentsOf: url)
    let json = try JSONSerialization.jsonObject(with: upgraded) as? [String: Any]
    #expect(json?["version"] as? Int == 1)
    #expect(json?["entries"] is [Any])
  }

  /// (4) Forward-version quarantine: a file announcing version 99 is
  /// renamed aside and the loader returns an empty inbox plus the
  /// quarantine path; the original location is empty and the backup
  /// holds the seeded bytes.
  @Test
  func forwardVersionQuarantine() throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = Self.temporaryURL(in: directory)

    // Build a forward-version envelope by encoding a real entry, then
    // re-wrapping inside a version-99 envelope at the JSON-object level.
    let seeded = entry(title: "future")
    let entryBytes = try JSONEncoder.touchCodeDefault.encode(seeded)
    let entryObject = try JSONSerialization.jsonObject(with: entryBytes)
    let payload: [String: Any] = [
      "version": 99,
      "entries": [entryObject],
    ]
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [])
    try bytes.write(to: url)

    let pinnedNow = Date(timeIntervalSince1970: 0)
    let expectedBackup = StoreBackup.directory(for: url)
      .appendingPathComponent("notifications.unsupported-v99-19700101T000000Z.json")

    let loaded = try #require(try InboxFile.load(from: url, now: pinnedNow))
    #expect(loaded.entries.isEmpty)
    #expect(loaded.quarantineBackupURL?.standardizedFileURL == expectedBackup.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
    #expect(FileManager.default.fileExists(atPath: expectedBackup.path))

    let preservedBytes = try Data(contentsOf: expectedBackup)
    #expect(preservedBytes == bytes)
  }

  /// (6) Corrupt file returns empty after moving the bytes into `backups/`,
  /// so the next save cannot destroy them.
  @Test
  func corruptFileIsBackedUpAndReturnsEmpty() throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = Self.temporaryURL(in: directory)

    let garbage = Data("{garbage".utf8)
    try garbage.write(to: url)

    let loaded = try #require(try InboxFile.load(from: url))
    #expect(loaded.entries.isEmpty)
    #expect(loaded.quarantineBackupURL == nil)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
    let backups = try FileManager.default.contentsOfDirectory(at: StoreBackup.directory(for: url), includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == garbage)
  }

  /// (7) Absent file returns nil — the sentinel for "fresh install".
  @Test
  func absentFileReturnsNil() throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = Self.temporaryURL(in: directory)

    let loaded = try InboxFile.load(from: url)
    #expect(loaded == nil)
  }

  /// (8) Compile-time pin on the current version constant.
  @Test
  func currentVersionIsOne() {
    #expect(InboxFile.currentVersion == 1)
  }
}
