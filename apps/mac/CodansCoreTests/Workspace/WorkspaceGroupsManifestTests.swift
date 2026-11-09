import Foundation
import Testing

@testable import CodansCore

/// Group manifest (schema 2): codec, validation, version 1 migration, and
/// the store's load-or-migrate path.
struct WorkspaceGroupsManifestTests {
  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-groups-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private let rootPath = "/tmp/ws"

  private var legacy: WorkspaceManifest {
    WorkspaceManifest(
      title: "Checkout Flow",
      description: "task",
      repositories: [
        .init(
          name: "app", role: "frontend", sourceGitRoot: "/src/app", checkoutMode: .newBranch,
          branch: "feat/checkout", baseRef: "origin/main"),
        .init(name: "api", sourceGitRoot: "/work/app", checkoutMode: .existingBranch, branch: "fix/api"),
        .init(name: "lib", sourceGitRoot: "/src/lib", remoteURL: "git@github.com:org/lib.git"),
      ])
  }

  private func validManifest() -> WorkspaceGroupsManifest {
    let groupID = WorkspaceGroupID()
    return WorkspaceGroupsManifest(
      title: "ws",
      projects: [.init(name: "app", sourceGitRoot: "/src/app")],
      groups: [
        .init(id: WorkspaceGroupID(), name: "default", kind: .default, path: "default"),
        .init(
          id: groupID, name: "fix-login", kind: .named, path: "fix-login", branch: "fix/login",
          members: [
            .init(
              id: WorkspaceMemberID(), name: "app", path: "fix-login/app", sourceGitRoot: "/src/app",
              checkoutMode: .newBranch, branch: "fix/login", baseRef: "origin/main", createdBranch: true)
          ]),
      ])
  }

  // MARK: - Migration

  @Test
  func migrationKeepsEveryMemberAndItsBranchUnderExisting() {
    let migrated = WorkspaceManifestMigration.migrate(legacy, rootPath: rootPath) { _ in false }

    #expect(migrated.schemaVersion == 2)
    #expect(migrated.title == "Checkout Flow")
    #expect(migrated.description == "task")
    #expect(migrated.groups.map(\.name) == ["default", "existing"])
    #expect(migrated.groups[0].kind == .default)
    #expect(migrated.groups[0].path == "default")
    #expect(migrated.groups[0].members.isEmpty)
    let existing = migrated.groups[1]
    #expect(existing.kind == .named)
    #expect(existing.path == ".")
    #expect(existing.origin == .migrated)
    #expect(existing.members.map(\.path) == ["app", "api", "lib"])
    #expect(existing.members.map(\.branch) == ["feat/checkout", "fix/api", nil])
    #expect(existing.members.map(\.sourceGitRoot) == ["/src/app", "/work/app", "/src/lib"])
    #expect(existing.members[0].role == "frontend")
    #expect(existing.members[0].baseRef == "origin/main")
    #expect(existing.members.allSatisfy { $0.createdBranch == nil })
    #expect(migrated.groups[0].id == WorkspaceGroupID.derived(rootPath: rootPath, key: "default"))
    #expect(existing.id == WorkspaceGroupID.derived(rootPath: rootPath, key: "existing"))
    #expect(existing.members[0].id == WorkspaceMemberID.derived(rootPath: rootPath, path: "app"))
    #expect(migrated.validate().isEmpty)
  }

  @Test
  func migrationListsDistinctSourcesWithUniqueNames() {
    var manifest = legacy
    manifest.repositories.append(.init(name: "app-2", sourceGitRoot: "/src/app"))
    manifest.repositories.append(.init(name: "handmade"))
    let migrated = WorkspaceManifestMigration.migrate(manifest, rootPath: rootPath) { _ in false }

    #expect(
      migrated.projects == [
        .init(name: "app", sourceGitRoot: "/src/app"),
        .init(name: "app-2", sourceGitRoot: "/work/app"),
        .init(name: "lib", sourceGitRoot: "/src/lib", remoteURL: "git@github.com:org/lib.git"),
      ])
  }

  @Test
  func migrationAvoidsDefaultFolderCollisions() {
    var manifest = legacy
    manifest.repositories.append(.init(name: "default", sourceGitRoot: "/src/other"))
    let taken: Set<String> = ["/tmp/ws/default-2"]
    let migrated = WorkspaceManifestMigration.migrate(manifest, rootPath: rootPath) { taken.contains($0) }
    #expect(migrated.groups[0].name == "default")
    #expect(migrated.groups[0].path == "default-3")
    #expect(migrated.validate().isEmpty)
  }

  @Test
  func migrationOfAnEmptyManifestStillYieldsExisting() {
    let migrated = WorkspaceManifestMigration.migrate(WorkspaceManifest(title: "ws"), rootPath: rootPath) { _ in
      false
    }
    #expect(migrated.groups.map(\.name) == ["default", "existing"])
    #expect(migrated.groups[1].members.isEmpty)
    #expect(migrated.projects.isEmpty)
  }

  @Test
  func migrationIsDeterministic() {
    let first = WorkspaceManifestMigration.migrate(legacy, rootPath: rootPath) { _ in false }
    let second = WorkspaceManifestMigration.migrate(legacy, rootPath: rootPath) { _ in false }
    #expect(first == second)
  }

  // MARK: - Validation

  @Test
  func validManifestHasNoIssues() {
    #expect(validManifest().validate().isEmpty)
  }

  @Test
  func validateRequiresExactlyOneDefaultWithoutMembers() {
    var none = validManifest()
    none.groups.removeFirst()
    #expect(none.validate().contains(.missingDefaultGroup))

    var two = validManifest()
    two.groups.append(.init(id: WorkspaceGroupID(), name: "default-b", kind: .default, path: "default-b"))
    #expect(two.validate().contains(.multipleDefaultGroups))

    var withMembers = validManifest()
    withMembers.groups[0].members = [.init(id: WorkspaceMemberID(), name: "x", path: "default/x")]
    #expect(withMembers.validate().contains(.defaultGroupHasMembers))
  }

  @Test
  func validateReservesDefaultAndRejectsDuplicateNames() {
    var reserved = validManifest()
    reserved.groups[1].name = "default"
    #expect(reserved.validate().contains(.reservedGroupName("default")))

    var duplicate = validManifest()
    duplicate.groups.append(.init(id: WorkspaceGroupID(), name: "fix-login", kind: .named, path: "other"))
    #expect(duplicate.validate().contains(.duplicateGroupName("fix-login")))
  }

  @Test
  func validateRejectsEscapingAndUnnormalizedPaths() {
    for bad in ["", "/abs", "../out", "a/../b", "a//b", "a/", "./a"] {
      var manifest = validManifest()
      manifest.groups[1].path = bad
      #expect(manifest.validate().contains(.invalidPath(bad)), "group path \(bad)")
    }
    var member = validManifest()
    member.groups[1].members[0].path = "fix-login/../../x"
    #expect(member.validate().contains(.invalidPath("fix-login/../../x")))
  }

  @Test
  func validateAllowsDotOnlyForAMigratedGroup() {
    var created = validManifest()
    created.groups[1].path = "."
    created.groups[1].members[0].path = "app"
    #expect(created.validate().contains(.invalidPath(".")))

    created.groups[1].origin = .migrated
    #expect(created.validate().isEmpty)

    var defaultAtRoot = validManifest()
    defaultAtRoot.groups[0].path = "."
    defaultAtRoot.groups[0].origin = .migrated
    #expect(defaultAtRoot.validate().contains(.invalidPath(".")))
  }

  @Test
  func validateRejectsOverlappingPaths() {
    var sameAsGroup = validManifest()
    sameAsGroup.groups[1].members[0].path = "default"
    #expect(sameAsGroup.validate().contains(.overlappingPaths("default", "default")))

    var insideOtherGroup = validManifest()
    insideOtherGroup.groups[1].members[0].path = "default/app"
    #expect(insideOtherGroup.validate().contains(.overlappingPaths("default", "default/app")))

    var nestedMembers = validManifest()
    nestedMembers.groups[1].members.append(
      .init(id: WorkspaceMemberID(), name: "lib", path: "fix-login/app/lib"))
    #expect(nestedMembers.validate().contains(.overlappingPaths("fix-login/app", "fix-login/app/lib")))
  }

  @Test
  func validateChecksSources() {
    var manifest = validManifest()
    manifest.projects = [
      .init(name: "app", sourceGitRoot: "/src/app"),
      .init(name: "app", sourceGitRoot: "/src/app"),
      .init(name: "a/b", sourceGitRoot: "relative"),
    ]
    let issues = manifest.validate()
    #expect(issues.contains(.duplicateSourceName("app")))
    #expect(issues.contains(.duplicateSource("/src/app")))
    #expect(issues.contains(.invalidSourceName("a/b")))
    #expect(issues.contains(.relativeSourcePath("relative")))
  }

  // MARK: - Codec

  @Test
  func roundTripPreservesEveryField() throws {
    var manifest = validManifest()
    manifest.groups[1].deletion = GroupDeletionState(deleteBranches: true, startedAt: Date(timeIntervalSince1970: 0))
    manifest.groups[1].createdAt = Date(timeIntervalSince1970: 10)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkspaceGroupsManifest.self, from: encoder.encode(manifest))
    #expect(decoded == manifest)
  }

  @Test
  func decodeIsStrictOnStructure() {
    let missingGroups = Data(#"{"schemaVersion": 2, "title": "ws", "projects": []}"#.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(WorkspaceGroupsManifest.self, from: missingGroups)
    }
    let unknownKind = Data(
      #"""
      {"schemaVersion": 2, "projects": [], "groups": [
        {"id": "00000000-0000-0000-0000-000000000001", "name": "x", "kind": "shared", "path": "x"}]}
      """#.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(WorkspaceGroupsManifest.self, from: unknownKind)
    }
  }

  @Test
  func newerSchemaFailsBeforeTheStructureIsRead() {
    #expect(throws: WorkspaceGroupsManifest.DecodingIssue.newerSchema(3)) {
      _ = try JSONDecoder().decode(WorkspaceGroupsManifest.self, from: Data(#"{"schemaVersion": 3}"#.utf8))
    }
  }

  // MARK: - Store

  @Test
  func hasManifestSeesEitherFile() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    #expect(!WorkspaceManifestStore.hasManifest(rootPath: path))

    try WorkspaceManifestStore.saveGroups(validManifest(), rootPath: path)
    #expect(WorkspaceManifestStore.hasManifest(rootPath: path))
    #expect(!FileManager.default.fileExists(atPath: WorkspaceLayout.manifestURL(rootPath: path).path))
  }

  @Test
  func loadOrMigrateWritesTheGroupManifestAndLeavesVersionOneAlone() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    try WorkspaceManifestStore.save(legacy, rootPath: path)
    let v1URL = WorkspaceLayout.manifestURL(rootPath: path)
    let v1Bytes = try Data(contentsOf: v1URL)

    let migrated = try WorkspaceManifestStore.loadOrMigrate(rootPath: path)

    #expect(migrated.groups.map(\.name) == ["default", "existing"])
    #expect(migrated.groups[1].members.map(\.branch) == ["feat/checkout", "fix/api", nil])
    #expect(try Data(contentsOf: v1URL) == v1Bytes)
    let groupsURL = WorkspaceLayout.groupsManifestURL(rootPath: path)
    let written = try Data(contentsOf: groupsURL)
    #expect(try WorkspaceManifestStore.loadGroups(rootPath: path) == migrated)

    // Second run reads the group manifest and writes nothing.
    #expect(try WorkspaceManifestStore.loadOrMigrate(rootPath: path) == migrated)
    #expect(try Data(contentsOf: groupsURL) == written)
    #expect(try Data(contentsOf: v1URL) == v1Bytes)
  }

  @Test
  func newerGroupSchemaFailsWithoutFallingBackToVersionOne() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    try WorkspaceManifestStore.save(legacy, rootPath: path)
    let groupsURL = WorkspaceLayout.groupsManifestURL(rootPath: path)
    let future = Data(#"{"schemaVersion": 3, "groups": "new shape"}"#.utf8)
    try future.write(to: groupsURL)

    #expect(throws: WorkspaceManifestStore.Failure.newerSchema(path: groupsURL.path, version: 3)) {
      _ = try WorkspaceManifestStore.loadOrMigrate(rootPath: path)
    }
    #expect(try Data(contentsOf: groupsURL) == future)
  }

  @Test
  func invalidGroupManifestFailsWithoutFallingBackToVersionOne() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    try WorkspaceManifestStore.save(legacy, rootPath: path)
    var invalid = validManifest()
    invalid.groups.removeFirst()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let groupsURL = WorkspaceLayout.groupsManifestURL(rootPath: path)
    try encoder.encode(invalid).write(to: groupsURL)

    #expect(throws: WorkspaceManifestStore.Failure.invalidGroups(path: groupsURL.path, issues: [.missingDefaultGroup]))
    {
      _ = try WorkspaceManifestStore.loadOrMigrate(rootPath: path)
    }

    try Data("{".utf8).write(to: groupsURL)
    #expect {
      _ = try WorkspaceManifestStore.loadOrMigrate(rootPath: path)
    } throws: { error in
      guard case WorkspaceManifestStore.Failure.malformed = error else { return false }
      return true
    }
  }

  @Test
  func saveGroupsRejectsAnInvalidManifest() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var invalid = validManifest()
    invalid.groups[1].path = "../escape"
    #expect(throws: WorkspaceManifestStore.Failure.self) {
      try WorkspaceManifestStore.saveGroups(invalid, rootPath: root.path(percentEncoded: false))
    }
  }
}
