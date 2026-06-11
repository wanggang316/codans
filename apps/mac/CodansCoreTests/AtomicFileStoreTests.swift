import Foundation
import Testing

@testable import CodansCore

struct AtomicFileStoreTests {
  @Test
  func readReturnsNilForMissingFile() throws {
    let url = Self.temporaryURL()
    let decoded = try AtomicFileStore.read(Payload.self, at: url)
    #expect(decoded == nil)
  }

  @Test
  func writeThenReadRoundTrip() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let value = Payload(name: "Gump", count: 42)
    try AtomicFileStore.write(value, to: url)
    let decoded = try AtomicFileStore.read(Payload.self, at: url)
    #expect(decoded == value)
  }

  @Test
  func writeOverwritesPreviousFile() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try AtomicFileStore.write(Payload(name: "first", count: 1), to: url)
    try AtomicFileStore.write(Payload(name: "second", count: 2), to: url)

    let decoded = try AtomicFileStore.read(Payload.self, at: url)
    #expect(decoded?.name == "second")
    #expect(decoded?.count == 2)
  }

  @Test
  func writeCreatesMissingDirectories() throws {
    let tempDir = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let nested = tempDir
      .appendingPathComponent("a", isDirectory: true)
      .appendingPathComponent("b", isDirectory: true)
      .appendingPathComponent("payload.json")

    try AtomicFileStore.write(Payload(name: "deep", count: 1), to: nested)
    let decoded = try AtomicFileStore.read(Payload.self, at: nested)
    #expect(decoded?.name == "deep")
  }

  @Test
  func writeLeavesNoTempFilesBehind() throws {
    let tempDir = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let url = tempDir.appendingPathComponent("payload.json")
    try AtomicFileStore.write(Payload(name: "clean", count: 3), to: url)

    let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(contents == ["payload.json"])
  }

  // MARK: - Helpers

  private struct Payload: Codable, Equatable, Sendable {
    let name: String
    let count: Int
  }

  private static func temporaryDirectory() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private static func temporaryURL() -> URL {
    temporaryDirectory().appendingPathComponent("payload.json")
  }
}
