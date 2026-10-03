import Foundation
import Testing

@testable import CodansCore

struct AtomicFileStoreTests {
  @Test
  func sweepRemovesOnlyStaleTemporaries() throws {
    let directory = Self.temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    func make(_ name: String, age: TimeInterval) throws -> URL {
      let url = directory.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
      return url
    }
    let staleTemp = try make(".catalog.json.tmp-AAAA", age: 7200)
    let staleNew = try make(".settings.json.new-BBBB", age: 7200)
    let freshTemp = try make(".catalog.json.tmp-CCCC", age: 10)
    let live = try make("catalog.json", age: 7200)

    let removed = AtomicFileStore.sweepOrphanedTemporaries(in: directory, olderThan: 3600, now: now)

    #expect(Set(removed.map(\.lastPathComponent)) == [staleTemp.lastPathComponent, staleNew.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: freshTemp.path))
    #expect(FileManager.default.fileExists(atPath: live.path))
  }

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

  // MARK: - Symlink preservation

  @Test
  func writePreservesSymlinkedDestination() throws {
    let fm = FileManager.default
    let targetDir = Self.temporaryDirectory()
    let linkDir = Self.temporaryDirectory()
    defer {
      try? fm.removeItem(at: targetDir)
      try? fm.removeItem(at: linkDir)
    }
    let target = targetDir.appendingPathComponent("settings.json")
    try AtomicFileStore.write(Payload(name: "original", count: 1), to: target)
    let link = linkDir.appendingPathComponent("settings.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)

    try AtomicFileStore.write(Payload(name: "updated", count: 2), to: link)

    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
    let viaLink = try AtomicFileStore.read(Payload.self, at: link)
    let viaTarget = try AtomicFileStore.read(Payload.self, at: target)
    #expect(viaLink?.name == "updated")
    #expect(viaTarget?.name == "updated")
  }

  @Test
  func writePreservesRelativeSymlink() throws {
    let fm = FileManager.default
    let base = Self.temporaryDirectory()
    defer { try? fm.removeItem(at: base) }
    let targetDir = base.appendingPathComponent("dotfiles", isDirectory: true)
    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    let target = targetDir.appendingPathComponent("settings.json")
    try AtomicFileStore.write(Payload(name: "original", count: 1), to: target)
    let link = base.appendingPathComponent("settings.json")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")

    try AtomicFileStore.write(Payload(name: "updated", count: 2), to: link)

    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "dotfiles/settings.json")
    #expect(try AtomicFileStore.read(Payload.self, at: target)?.name == "updated")
  }

  @Test
  func writeFollowsSymlinkChain() throws {
    let fm = FileManager.default
    let dir = Self.temporaryDirectory()
    defer { try? fm.removeItem(at: dir) }
    let target = dir.appendingPathComponent("real.json")
    try AtomicFileStore.write(Payload(name: "original", count: 1), to: target)
    let middle = dir.appendingPathComponent("middle.json")
    let outer = dir.appendingPathComponent("outer.json")
    try fm.createSymbolicLink(at: middle, withDestinationURL: target)
    try fm.createSymbolicLink(at: outer, withDestinationURL: middle)

    try AtomicFileStore.write(Payload(name: "updated", count: 2), to: outer)

    #expect(try fm.destinationOfSymbolicLink(atPath: outer.path) == middle.path)
    #expect(try fm.destinationOfSymbolicLink(atPath: middle.path) == target.path)
    #expect(try AtomicFileStore.read(Payload.self, at: target)?.name == "updated")
  }

  @Test
  func writeThroughDanglingSymlinkCreatesTarget() throws {
    let fm = FileManager.default
    let dir = Self.temporaryDirectory()
    defer { try? fm.removeItem(at: dir) }
    // Target's directory does not exist yet — a fresh dotfiles checkout.
    let target = dir.appendingPathComponent("dotfiles", isDirectory: true)
      .appendingPathComponent("settings.json")
    let link = dir.appendingPathComponent("settings.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)

    try AtomicFileStore.write(Payload(name: "seeded", count: 1), to: link)

    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try AtomicFileStore.read(Payload.self, at: target)?.name == "seeded")
  }

  @Test
  func writeThrowsOnSymlinkLoop() throws {
    let fm = FileManager.default
    let dir = Self.temporaryDirectory()
    defer { try? fm.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.json")
    let b = dir.appendingPathComponent("b.json")
    try fm.createSymbolicLink(at: a, withDestinationURL: b)
    try fm.createSymbolicLink(at: b, withDestinationURL: a)

    #expect(throws: AtomicFileStore.Failure.tooManySymlinks(path: a.path)) {
      try AtomicFileStore.write(Payload(name: "loop", count: 1), to: a)
    }
  }

  @Test
  func writeThroughSymlinkLeavesNoTempFilesBehind() throws {
    let fm = FileManager.default
    let targetDir = Self.temporaryDirectory()
    let linkDir = Self.temporaryDirectory()
    defer {
      try? fm.removeItem(at: targetDir)
      try? fm.removeItem(at: linkDir)
    }
    let target = targetDir.appendingPathComponent("settings.json")
    try AtomicFileStore.write(Payload(name: "original", count: 1), to: target)
    let link = linkDir.appendingPathComponent("settings.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)

    try AtomicFileStore.write(Payload(name: "updated", count: 2), to: link)

    #expect(try fm.contentsOfDirectory(atPath: targetDir.path) == ["settings.json"])
    #expect(try fm.contentsOfDirectory(atPath: linkDir.path) == ["settings.json"])
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
