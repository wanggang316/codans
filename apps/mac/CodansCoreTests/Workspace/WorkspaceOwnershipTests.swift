import Foundation
import Testing

@testable import CodansCore

/// `WorkspaceOwnership` and `WorkspaceDefaultLinks` on a real temporary
/// directory with a real source folder behind the `default` links.
struct WorkspaceOwnershipTests {
  private struct Layout {
    let base: URL
    let root: String
    let source: String
    let manifest: WorkspaceGroupsManifest
  }

  /// `<base>/src/app` (source), `<base>/ws` (root) with `default/app` →
  /// source, named group `fix` with member `fix/app`, migrated `.` group
  /// with member `old`.
  private func makeLayout() throws -> Layout {
    let fileManager = FileManager.default
    let base = URL(
      fileURLWithPath: fileManager.temporaryDirectory
        .appendingPathComponent("codans-ws-own-\(UUID().uuidString)").path
    ).resolvingSymlinksInPath()
    let source = base.appendingPathComponent("src/app").path
    let root = base.appendingPathComponent("ws").path
    for directory in [source, root + "/fix/app", root + "/old"] {
      try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    try Data("keep".utf8).write(to: URL(fileURLWithPath: source + "/README"))
    let manifest = WorkspaceGroupsManifest(
      title: "ws",
      projects: [.init(name: "app", sourceGitRoot: source)],
      groups: [
        .init(id: WorkspaceGroupID(), name: "default", kind: .default, path: "default"),
        .init(
          id: WorkspaceGroupID(), name: "existing", kind: .named, path: ".", origin: .migrated,
          members: [.init(id: WorkspaceMemberID(), name: "old", path: "old")]),
        .init(
          id: WorkspaceGroupID(), name: "fix", kind: .named, path: "fix",
          members: [.init(id: WorkspaceMemberID(), name: "app", path: "fix/app", sourceGitRoot: source)]),
      ])
    try WorkspaceDefaultLinks.sync(rootPath: root, manifest: manifest)
    return Layout(base: base, root: root, source: source, manifest: manifest)
  }

  private func check(_ path: String, _ layout: Layout) -> WorkspaceOwnership.Verdict {
    WorkspaceOwnership.check(path: path, rootPath: layout.root, manifest: layout.manifest)
  }

  // MARK: - Ownership

  @Test
  func recordedGroupAndMemberPathsAreOwned() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    #expect(check(layout.root + "/fix", layout) == .owned)
    #expect(check(layout.root + "/fix/app", layout) == .owned)
    #expect(check(layout.root + "/old", layout) == .owned)
    #expect(check(layout.root + "/default", layout) == .owned)
  }

  @Test
  func theRootOfAMigratedGroupIsNeverOwned() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    #expect(check(layout.root, layout) == .notOwned(.workspaceRoot))
    #expect(check(layout.root + "/.", layout) == .notOwned(.workspaceRoot))
    #expect(check(layout.root + "/fix/..", layout) == .notOwned(.workspaceRoot))
  }

  @Test
  func pathsOutsideTheRootOrUnrecordedAreNotOwned() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    #expect(check(layout.source, layout) == .notOwned(.outsideRoot))
    #expect(check(layout.root + "/../src/app", layout) == .notOwned(.outsideRoot))
    #expect(check(layout.root + "/.codans", layout) == .notOwned(.notRecorded))
    #expect(check(layout.root + "/default/app", layout) == .notOwned(.notRecorded))
  }

  @Test
  func symbolicLinksOnThePathAreNotOwned() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    // A recorded member that is itself a link into the source.
    try FileManager.default.removeItem(atPath: layout.root + "/fix/app")
    try FileManager.default.createSymbolicLink(atPath: layout.root + "/fix/app", withDestinationPath: layout.source)
    #expect(check(layout.root + "/fix/app", layout) == .notOwned(.symbolicLink(layout.root + "/fix/app")))

    // A recorded group directory that is a link.
    try FileManager.default.removeItem(atPath: layout.root + "/default")
    try FileManager.default.createSymbolicLink(atPath: layout.root + "/default", withDestinationPath: layout.base.path)
    #expect(check(layout.root + "/default", layout) == .notOwned(.symbolicLink(layout.root + "/default")))
  }

  @Test
  func pathsInsideASourceProjectAreNotOwned() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    // A source checkout that lives inside the Workspace root.
    var manifest = layout.manifest
    manifest.projects.append(.init(name: "vendored", sourceGitRoot: layout.root + "/fix"))
    #expect(
      WorkspaceOwnership.check(path: layout.root + "/fix/app", rootPath: layout.root, manifest: manifest)
        == .notOwned(.insideSource(layout.root + "/fix")))
  }

  // MARK: - Default links

  @Test
  func syncCreatesLinksToEverySource() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let link = layout.root + "/default/app"
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == layout.source)
    #expect(FileManager.default.fileExists(atPath: link + "/README"))
  }

  @Test
  func syncReplacesStaleLinksRemovesUnlistedLinksAndKeepsOtherEntries() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let fileManager = FileManager.default
    let directory = layout.root + "/default"
    let other = layout.base.appendingPathComponent("src/lib").path
    try fileManager.createDirectory(atPath: other, withIntermediateDirectories: true)
    try fileManager.removeItem(atPath: directory + "/app")
    try fileManager.createSymbolicLink(atPath: directory + "/app", withDestinationPath: other)
    try fileManager.createSymbolicLink(atPath: directory + "/gone", withDestinationPath: other)
    try fileManager.createDirectory(atPath: directory + "/notes", withIntermediateDirectories: true)

    var manifest = layout.manifest
    manifest.projects.append(.init(name: "notes", sourceGitRoot: other))
    let report = try WorkspaceDefaultLinks.sync(rootPath: layout.root, manifest: manifest)

    #expect(report.replaced == [directory + "/app"])
    #expect(report.removed == [directory + "/gone"])
    #expect(report.notes == [.notALink(path: directory + "/notes")])
    #expect(try fileManager.destinationOfSymbolicLink(atPath: directory + "/app") == layout.source)
    #expect(!fileManager.fileExists(atPath: directory + "/gone"))
    // Removing a link never touches its target.
    #expect(fileManager.fileExists(atPath: other))
    #expect(fileManager.fileExists(atPath: layout.source + "/README"))
    // A second run changes nothing.
    let again = try WorkspaceDefaultLinks.sync(rootPath: layout.root, manifest: manifest)
    #expect(again.created.isEmpty && again.replaced.isEmpty && again.removed.isEmpty)
  }

  @Test
  func removingASourceUnlinksItAndKeepsTheSource() throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    var manifest = layout.manifest
    manifest.projects = []
    let report = try WorkspaceDefaultLinks.sync(rootPath: layout.root, manifest: manifest)
    #expect(report.removed == [layout.root + "/default/app"])
    #expect(FileManager.default.fileExists(atPath: layout.source + "/README"))
  }
}
