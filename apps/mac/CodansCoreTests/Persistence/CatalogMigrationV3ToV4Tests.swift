import Foundation
import Testing

@testable import CodansCore

/// Version 3 files have no Workspace groups. The loader lifts their layout
/// (`CatalogMigrationV4ToV5`), then `CatalogMigrationV3ToV4` places every
/// Workspace row into a group.
struct CatalogMigrationV3ToV4Tests {
  private let rootID = "11111111-1111-1111-1111-111111111111"
  private let childID = "22222222-2222-2222-2222-222222222222"
  private let archivedID = "33333333-3333-3333-3333-333333333333"
  private let repoRowID = "44444444-4444-4444-4444-444444444444"
  private let paneID = "55555555-5555-5555-5555-555555555555"
  private let tabID = "66666666-6666-6666-6666-666666666666"
  private let workspaceID = "77777777-7777-7777-7777-777777777777"

  /// A version 3 catalog as written by the previous build: one ordinary
  /// repository and one Workspace whose root row holds a live terminal.
  private var legacyFixture: Data {
    Data(
      """
      {
        "version": 3,
        "selectedProjectID": { "raw": "\(workspaceID)" },
        "tags": [],
        "projects": [
          {
            "id": { "raw": "88888888-8888-8888-8888-888888888888" },
            "name": "app", "rootPath": "/src/app", "gitRoot": "/src/app",
            "worktrees": [
              { "id": { "raw": "\(repoRowID)" }, "name": "main", "path": "/src/app", "branch": "main", "tabs": [] }
            ]
          },
          {
            "id": { "raw": "\(workspaceID)" },
            "name": "ws", "rootPath": "/tmp/ws", "isWorkspace": true,
            "selectedWorktreeID": { "raw": "\(childID)" },
            "worktrees": [
              {
                "id": { "raw": "\(rootID)" }, "name": "ws", "path": "/tmp/ws",
                "selectedTabID": { "raw": "\(tabID)" },
                "tabs": [
                  {
                    "id": { "raw": "\(tabID)" },
                    "splitTree": { "root": { "leaf": { "_0": { "raw": "\(paneID)" } } } },
                    "panes": [ { "id": { "raw": "\(paneID)" }, "workingDirectory": "/tmp/ws" } ]
                  }
                ]
              },
              { "id": { "raw": "\(childID)" }, "name": "app", "path": "/tmp/ws/app", "branch": "feat/x", "sourceGitRoot": "/src/app", "tabs": [] },
              { "id": { "raw": "\(archivedID)" }, "name": "lib", "path": "/tmp/ws/lib", "branch": "fix/y", "archived": true, "tabs": [] }
            ]
          }
        ]
      }
      """.utf8)
  }

  /// The fixture with its layout lifted, as the loader hands it over.
  private func decodeLegacy() throws -> Catalog {
    try CatalogMigrationV4ToV5.migrate(legacyFixture)
  }

  @Test
  func newerVersionIsReportedSeparatelyFromRetiredVersions() {
    #expect(throws: Catalog.DecodingIssue.newerVersion(6)) {
      _ = try JSONDecoder().decode(Catalog.self, from: Data(#"{"version": 6}"#.utf8))
    }
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(2)) {
      _ = try JSONDecoder().decode(Catalog.self, from: Data(#"{"version": 2}"#.utf8))
    }
  }

  @Test
  func migrationKeepsIdentityPathsBranchesSessionsAndSelection() throws {
    let legacy = try decodeLegacy()
    let migrated = CatalogMigrationV3ToV4.migrate(legacy)

    #expect(migrated.version == Catalog.currentVersion)
    #expect(migrated.selectedProjectID == legacy.selectedProjectID)
    let before = try #require(legacy.projects.last)
    let after = try #require(migrated.projects.last)
    #expect(after.id == before.id)
    #expect(after.selectedWorktreeID == before.selectedWorktreeID)
    #expect(after.worktrees.map(\.id) == before.worktrees.map(\.id))
    #expect(after.worktrees.map(\.path) == before.worktrees.map(\.path))
    #expect(after.worktrees.map(\.branch) == before.worktrees.map(\.branch))
    #expect(after.worktrees.map(\.archived) == before.worktrees.map(\.archived))
    #expect(after.worktrees[0].panes == before.worktrees[0].panes)
    #expect(after.worktrees[0].focusedPaneID == before.worktrees[0].focusedPaneID)
    #expect(after.worktrees[0].contentIDs.map(\.raw.uuidString) == [paneID])
    // The ordinary repository is untouched.
    #expect(migrated.projects[0] == legacy.projects[0])
  }

  @Test
  func migrationGroupsEveryWorkspaceRowUnderExisting() throws {
    let migrated = CatalogMigrationV3ToV4.migrate(try decodeLegacy())
    let workspace = try #require(migrated.projects.last)

    let defaultID = WorkspaceGroupID.derived(rootPath: "/tmp/ws", key: "default")
    let existingID = WorkspaceGroupID.derived(rootPath: "/tmp/ws", key: "existing")
    #expect(
      workspace.workspaceGroups == [
        WorkspaceGroupRecord(id: defaultID, name: "default", kind: .default),
        WorkspaceGroupRecord(id: existingID, name: "existing", kind: .named),
      ])
    #expect(workspace.workspaceGroups.allSatisfy { !$0.isExpanded })
    #expect(
      workspace.worktrees.map(\.workspaceSlot) == [
        WorkspaceSlot(groupID: existingID, role: .groupTerminal),
        WorkspaceSlot(groupID: existingID, role: .member),
        WorkspaceSlot(groupID: existingID, role: .member),
      ])
    #expect(migrated.projects[0].workspaceGroups.isEmpty)
    #expect(migrated.projects[0].worktrees.allSatisfy { $0.workspaceSlot == nil })
  }

  @Test
  func workspaceWithOnlyItsRootStillGetsExisting() {
    let root = Worktree(name: "ws", path: "/tmp/solo")
    let project = Project(name: "solo", rootPath: "/tmp/solo", worktrees: [root], isWorkspace: true)
    let migrated = CatalogMigrationV3ToV4.migrate(Catalog(projects: [project]))
    let groups = migrated.projects[0].workspaceGroups
    #expect(groups.map(\.name) == ["default", "existing"])
    #expect(migrated.projects[0].worktrees[0].workspaceSlot?.role == .groupTerminal)
  }

  @Test
  func migrationIsDeterministicAndRepeatable() throws {
    let legacy = try decodeLegacy()
    let first = CatalogMigrationV3ToV4.migrate(legacy)
    #expect(CatalogMigrationV3ToV4.migrate(legacy) == first)
    #expect(CatalogMigrationV3ToV4.migrate(first) == first)
  }

  @Test
  func migratedCatalogRoundTripsAtTheCurrentVersion() throws {
    let migrated = CatalogMigrationV3ToV4.migrate(try decodeLegacy())
    let data = try JSONEncoder().encode(migrated)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == migrated)
    #expect(decoded.version == Catalog.currentVersion)
  }

  // MARK: - Codec

  @Test
  func newFieldsAreOmittedAtTheirDefaults() throws {
    let project = Project(name: "p", rootPath: "/p", worktrees: [Worktree(name: "w", path: "/p")])
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    #expect(object["workspaceGroups"] == nil)
    let rows = try #require(object["worktrees"] as? [[String: Any]])
    #expect(rows[0]["workspaceSlot"] == nil)

    let record = WorkspaceGroupRecord(id: WorkspaceGroupID(), name: "g", kind: .named)
    let recordObject = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    #expect(recordObject["isExpanded"] == nil)
    #expect(recordObject["deletion"] == nil)
  }

  @Test
  func groupRecordsAndSlotsRoundTrip() throws {
    let groupID = WorkspaceGroupID()
    let record = WorkspaceGroupRecord(
      id: groupID, name: "fix-login", kind: .named, isExpanded: true,
      deletion: GroupDeletionState(deleteBranches: true, startedAt: Date(timeIntervalSince1970: 100)))
    let row = Worktree(
      name: "app", path: "/ws/fix-login/app",
      workspaceSlot: WorkspaceSlot(groupID: groupID, role: .member))
    let project = Project(
      name: "ws", rootPath: "/ws", worktrees: [row], isWorkspace: true, workspaceGroups: [record])
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(decoded.workspaceGroups == [record])
    #expect(decoded.worktrees[0].workspaceSlot == row.workspaceSlot)
  }

  @Test
  func derivedGroupIDsDependOnRootAndKey() {
    let a = WorkspaceGroupID.derived(rootPath: "/ws", key: "default")
    #expect(a == WorkspaceGroupID.derived(rootPath: "/ws", key: "default"))
    #expect(a != WorkspaceGroupID.derived(rootPath: "/ws", key: "existing"))
    #expect(a != WorkspaceGroupID.derived(rootPath: "/other", key: "default"))
    #expect(
      WorkspaceMemberID.derived(rootPath: "/ws", path: "app")
        == WorkspaceMemberID.derived(rootPath: "/ws", path: "app"))
    #expect(
      WorkspaceMemberID.derived(rootPath: "/ws", path: "app")
        != WorkspaceMemberID.derived(rootPath: "/ws", path: "lib"))
  }
}
