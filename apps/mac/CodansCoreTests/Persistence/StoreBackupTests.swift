import Foundation
import Testing

@testable import CodansCore

struct StoreBackupTests {
  private static let epoch = Date(timeIntervalSince1970: 0)

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("store-backup-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test
  func moveAsideLandsInBackupsWithReasonAndTimestamp() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    try Data("x".utf8).write(to: url)

    let backup = try StoreBackup.moveAside(url, reason: .migrated(fromVersion: 2), at: Self.epoch)

    #expect(backup.lastPathComponent == "settings.migrated-v2-19700101T000000Z.json")
    #expect(backup.deletingLastPathComponent().lastPathComponent == "backups")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: backup) == Data("x".utf8))
  }

  @Test
  func reasonLabels() {
    #expect(StoreBackup.Reason.corrupt.label == "corrupt")
    #expect(StoreBackup.Reason.unsupported(version: 7).label == "unsupported-v7")
    #expect(StoreBackup.Reason.migrated(fromVersion: 1).label == "migrated-v1")
  }

  @Test
  func sameSecondCollisionGetsACounter() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")

    try Data("a".utf8).write(to: url)
    let first = try StoreBackup.moveAside(url, reason: .corrupt, at: Self.epoch)
    try Data("b".utf8).write(to: url)
    let second = try StoreBackup.moveAside(url, reason: .corrupt, at: Self.epoch)

    #expect(first != second)
    #expect(second.lastPathComponent == "catalog.corrupt-19700101T000000Z-1.json")
  }

  @Test
  func pruneKeepsNewestPerReasonOnly() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sessions.json")

    for second in 0..<(StoreBackup.retainedPerReason + 2) {
      try Data("\(second)".utf8).write(to: url)
      try StoreBackup.moveAside(url, reason: .corrupt, at: Date(timeIntervalSince1970: TimeInterval(second)))
    }
    try Data("other".utf8).write(to: url)
    try StoreBackup.moveAside(url, reason: .unsupported(version: 9), at: Self.epoch)

    let names = try FileManager.default.contentsOfDirectory(atPath: StoreBackup.directory(for: url).path)
    let corrupt = names.filter { $0.hasPrefix("sessions.corrupt-") }.sorted()
    #expect(corrupt.count == StoreBackup.retainedPerReason)
    #expect(corrupt.first == "sessions.corrupt-19700101T000002Z.json")
    #expect(names.contains("sessions.unsupported-v9-19700101T000000Z.json"))
  }

  @Test
  func moveAsideThrowsWhenSourceIsMissing() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) {
      try StoreBackup.moveAside(directory.appendingPathComponent("absent.json"), reason: .corrupt)
    }
  }
}
