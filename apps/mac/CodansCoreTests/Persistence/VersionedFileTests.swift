import Foundation
import Testing

@testable import CodansCore

struct VersionedFileTests {
  private func makeURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("versioned-file-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("hosts.json")
  }

  private func load(_ url: URL, unreadable: VersionedFile.Unreadable = .backUp) -> VersionedFile.LoadResult<[String]> {
    VersionedFile.load(
      [String].self, at: url, currentVersion: 1, empty: [], unreadable: unreadable,
      legacy: { try JSONDecoder().decode([String].self, from: $0) }
    )
  }

  private func entries(_ result: VersionedFile.LoadResult<[String]>) -> [String]? {
    if case .loaded(let entries) = result { return entries }
    return nil
  }

  @Test
  func missingFileLoadsEmpty() throws {
    let url = try makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(entries(load(url)) == [])
  }

  @Test
  func writeProducesVersionedEnvelopeAndRoundTrips() throws {
    let url = try makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try VersionedFile.write(["a", "b"], to: url, version: 1)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(object?["version"] as? Int == 1)
    #expect(entries(load(url)) == ["a", "b"])
  }

  @Test
  func legacyBareShapeIsRead() throws {
    let url = try makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try Data(#"["legacy"]"#.utf8).write(to: url)
    #expect(entries(load(url)) == ["legacy"])
  }

  @Test
  func newerVersionIsBackedUpEvenWithAChangedShape() throws {
    let url = try makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try Data(#"{"version": 2, "entries": {"changed": true}}"#.utf8).write(to: url)
    #expect(entries(load(url)) == [])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let backups = try FileManager.default.contentsOfDirectory(atPath: StoreBackup.directory(for: url).path)
    #expect(backups.contains { $0.hasPrefix("hosts.unsupported-v2-") })
  }

  @Test
  func corruptCacheIsDiscarded() throws {
    let url = try makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try Data("{nope".utf8).write(to: url)
    #expect(entries(load(url, unreadable: .discard)) == [])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: StoreBackup.directory(for: url).path))
  }
}
