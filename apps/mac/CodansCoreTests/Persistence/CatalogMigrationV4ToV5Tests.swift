import Foundation
import Testing

@testable import CodansCore

/// Catalog version 5 moves host fields from Server projects into the Host
/// list (ADR 0003). Version 4 files decode with the fields on each Project
/// and migrate in memory.
struct CatalogMigrationV4ToV5Tests {
  private let buildA = "11111111-1111-1111-1111-111111111111"
  private let buildB = "22222222-2222-2222-2222-222222222222"
  private let deployRoot = "33333333-3333-3333-3333-333333333333"
  private let gpuBox = "44444444-4444-4444-4444-444444444444"
  private let local = "55555555-5555-5555-5555-555555555555"
  private let buildPort22 = "66666666-6666-6666-6666-666666666666"

  /// Server projects on two machines: `build.example.com` reached as `ci`
  /// (three Projects, one of them with an explicit port 22) and as `root`,
  /// and `gpu-box` (an SSH config alias without a username). One local
  /// Project.
  private var v4Fixture: Data {
    Data(
      """
      {
        "version": 4,
        "tags": [],
        "projects": [
          { "id": { "raw": "\(buildA)" }, "name": "a", "rootPath": "/srv/a", "worktrees": [],
            "remoteHost": { "alias": "build.example.com", "username": "ci" } },
          { "id": { "raw": "\(local)" }, "name": "app", "rootPath": "/src/app", "worktrees": [] },
          { "id": { "raw": "\(gpuBox)" }, "name": "train", "rootPath": "/home/me/train", "worktrees": [],
            "remoteHost": { "alias": "gpu-box" } },
          { "id": { "raw": "\(deployRoot)" }, "name": "etc", "rootPath": "/etc/app", "worktrees": [],
            "remoteHost": { "alias": "build.example.com", "username": "root" } },
          { "id": { "raw": "\(buildB)" }, "name": "b", "rootPath": "/srv/b", "worktrees": [],
            "remoteHost": { "alias": "build.example.com", "username": "ci" } },
          { "id": { "raw": "\(buildPort22)" }, "name": "c", "rootPath": "/srv/c", "worktrees": [],
            "remoteHost": { "alias": "build.example.com", "username": "ci", "port": 22 } }
        ]
      }
      """.utf8)
  }

  private func project(_ raw: String, in catalog: Catalog) throws -> Project {
    try #require(catalog.projects.first { $0.id.raw.uuidString == raw })
  }

  @Test
  func versionFourDecodesWithHostFieldsOnProjects() throws {
    let catalog = try JSONDecoder().decode(Catalog.self, from: v4Fixture)
    #expect(catalog.version == 4)
    #expect(catalog.hosts.isEmpty)
    #expect(try project(buildA, in: catalog).remoteHost == RemoteHost(alias: "build.example.com", username: "ci"))
    #expect(try project(buildA, in: catalog).hostID == nil)
  }

  @Test
  func eachDistinctHostUsernamePortBecomesOneRecord() throws {
    let migrated = CatalogMigrationV4ToV5.migrate(try JSONDecoder().decode(Catalog.self, from: v4Fixture))

    #expect(migrated.version == 5)
    // Two machines, one of them with two usernames: three records, in
    // Project order. Port 22 equals no port.
    #expect(
      migrated.hosts.map(\.endpoint) == [
        RemoteHost(alias: "build.example.com", username: "ci"),
        RemoteHost(alias: "gpu-box"),
        RemoteHost(alias: "build.example.com", username: "root"),
      ])
    let ci = migrated.hosts[0].id
    #expect(try project(buildA, in: migrated).hostID == ci)
    #expect(try project(buildB, in: migrated).hostID == ci)
    #expect(try project(buildPort22, in: migrated).hostID == ci)
    #expect(try project(gpuBox, in: migrated).hostID == migrated.hosts[1].id)
    #expect(try project(deployRoot, in: migrated).hostID == migrated.hosts[2].id)
    // Each Project still resolves to a working endpoint.
    #expect(try project(deployRoot, in: migrated).remoteHost == RemoteHost(alias: "build.example.com", username: "root"))
    #expect(try project(gpuBox, in: migrated).remoteHost == RemoteHost(alias: "gpu-box"))
    // The local Project stays on This Mac.
    #expect(try project(local, in: migrated).hostID == nil)
    #expect(try project(local, in: migrated).remoteHost == nil)
  }

  @Test
  func reloadAfterSaveGivesTheSameCatalog() throws {
    let migrated = CatalogMigrationV4ToV5.migrate(try JSONDecoder().decode(Catalog.self, from: v4Fixture))
    let data = try JSONEncoder().encode(migrated)
    let reloaded = try JSONDecoder().decode(Catalog.self, from: data)

    #expect(reloaded == migrated)
    #expect(reloaded.version == 5)
    #expect(reloaded.hosts.count == 3)
    // Projects store only the Host id on disk.
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(object["projects"] as? [[String: Any]])
    #expect(projects.allSatisfy { $0["remoteHost"] == nil })
    #expect(projects.filter { $0["hostID"] != nil }.count == 5)
    // A second migration pass changes nothing.
    #expect(CatalogMigrationV4ToV5.migrate(reloaded) == reloaded)
  }

  @Test
  func onlyLocalProjectsMigrateToAnEmptyHostList() throws {
    let catalog = Catalog(
      version: 4,
      projects: [Project(name: "app", rootPath: "/src/app"), Project(name: "lib", rootPath: "/src/lib")])
    let migrated = CatalogMigrationV4ToV5.migrate(catalog)
    #expect(migrated.version == 5)
    #expect(migrated.hosts.isEmpty)
    #expect(migrated.projects.allSatisfy { $0.hostID == nil && $0.remoteHost == nil })

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
    #expect((object["hosts"] as? [Any])?.isEmpty == true)
  }

  @Test
  func versionThreeRunsBothMigrations() throws {
    let v3 = Catalog(
      version: 3,
      projects: [Project(name: "srv", rootPath: "/srv", remoteHost: RemoteHost(alias: "box", username: "me"))])
    let migrated = CatalogMigrationV4ToV5.migrate(CatalogMigrationV3ToV4.migrate(v3))
    #expect(migrated.version == 5)
    #expect(migrated.hosts.map(\.endpoint) == [RemoteHost(alias: "box", username: "me")])
    #expect(migrated.projects[0].hostID == migrated.hosts[0].id)
  }
}
