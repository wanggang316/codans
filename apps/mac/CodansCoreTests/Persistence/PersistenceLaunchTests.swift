import Foundation
import Testing

@testable import CodansCore

struct PersistenceLaunchTests {
  private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("persistence-launch-\(UUID().uuidString)", isDirectory: true)
    let legacy = AppDirectories.legacyConfigDirectory(home: home)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: legacy.appendingPathComponent("catalog.json"))
    return home
  }

  @Test
  func defaultRootsMigrateTheLegacyDirectory() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    PersistenceLaunch.prepare(environment: [:], home: home)

    let state = AppDirectories.stateDirectory(home: home, override: nil, configOverride: nil)
    #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("catalog.json").path))
  }

  @Test
  func overriddenRootsLeaveTheLegacyDirectoryAlone() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let isolated = home.appendingPathComponent("iso").path

    PersistenceLaunch.prepare(environment: [CodansEnvironment.Key.configDirectory.rawValue: isolated], home: home)

    let legacy = AppDirectories.legacyConfigDirectory(home: home)
    #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("catalog.json").path))
  }
}
