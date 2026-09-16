import Foundation
import Testing

@testable import CodansCore

struct WorkspaceManifestTests {
  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-workspace-manifest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - Layout

  @Test
  func manifestLivesInTheSharedStateDirectory() {
    #expect(WorkspaceLayout.stateDirectoryName == HandoffLayout.stateDirectoryName)
    #expect(WorkspaceLayout.rootRelativeManifestPath == ".codans/workspace.json")
    #expect(
      WorkspaceLayout.manifestURL(rootPath: "/tmp/ws").path(percentEncoded: false)
        == "/tmp/ws/.codans/workspace.json")
  }

  @Test
  func folderNameSlugifiesTheTitle() {
    #expect(WorkspaceLayout.folderName(forTitle: "Checkout Flow") == "checkout-flow")
    #expect(WorkspaceLayout.folderName(forTitle: "  API v2 / rewrite!  ") == "api-v2-rewrite")
    #expect(WorkspaceLayout.folderName(forTitle: "???") == "workspace")
  }

  @Test
  func defaultWorkspacesDirectoryMirrorsTheWorktreeBase() {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    let directory = WorkspaceLayout.defaultWorkspacesDirectory(home: home)
    #expect(directory.hasDirectoryPath)
    #expect(directory.path == "/Users/me/.codans/workspaces")
    #expect(WorkspaceLayout.defaultSourcesDirectory(home: home).path == "/Users/me/.codans/sources")
  }

  @Test
  func uniquePathSuffixesTakenFolders() {
    let base = URL(fileURLWithPath: "/Users/me/.codans/sources", isDirectory: true)
    let taken: Set<String> = [
      "/Users/me/.codans/sources/lib", "/Users/me/.codans/sources/lib-2",
    ]
    #expect(
      WorkspaceLayout.uniquePath(base: base, folder: "app") { taken.contains($0) } == "/Users/me/.codans/sources/app")
    #expect(
      WorkspaceLayout.uniquePath(base: base, folder: "lib") { taken.contains($0) } == "/Users/me/.codans/sources/lib-3")
  }

  @Test
  func repositoryNameComesFromTheLastURLComponent() {
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: "https://github.com/org/lib.git") == "lib")
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: "git@github.com:org/lib.git") == "lib")
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: "git@github.com:lib") == "lib")
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: "ssh://git@host/team/Repo/") == "Repo")
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: "file:///tmp/bare.git") == "bare")
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: "  ") == nil)
    #expect(WorkspaceLayout.repositoryName(fromRemoteURL: ".git") == nil)
  }

  // MARK: - Codable

  @Test
  func decodeToleratesMissingAndUnknownKeys() throws {
    let json = """
      {
        "title": "Checkout Flow",
        "future": true,
        "repositories": [
          { "name": "app", "checkoutMode": "teleport", "extra": 1 },
          { "path": "api" }
        ]
      }
      """
    let manifest = try JSONDecoder().decode(WorkspaceManifest.self, from: Data(json.utf8))
    #expect(manifest.schemaVersion == WorkspaceManifest.currentSchemaVersion)
    #expect(manifest.repositories[0].remoteURL == nil)
    #expect(manifest.title == "Checkout Flow")
    #expect(manifest.taskLinks.isEmpty)
    #expect(manifest.repositories.count == 2)
    // An unknown checkout mode reads as "not recorded", not as a failure.
    #expect(manifest.repositories[0].checkoutMode == nil)
    #expect(manifest.repositories[0].path == "app")
    // `name` defaults to `path` and vice versa.
    #expect(manifest.repositories[1].name == "")
    #expect(manifest.repositories[1].normalizedName == "api")
  }

  @Test
  func roundTripPreservesEveryField() throws {
    let manifest = WorkspaceManifest(
      title: "T",
      description: "d",
      taskLinks: ["https://example.com/1"],
      repositories: [
        WorkspaceManifest.Entry(
          name: "app", role: "macOS app", sourceGitRoot: "/src/app",
          checkoutMode: .newBranch, branch: "feat/x", baseRef: "origin/main"),
        WorkspaceManifest.Entry(
          name: "lib", sourceGitRoot: "/src/lib", remoteURL: "git@github.com:org/lib.git",
          checkoutMode: .remoteTrackingRef, branch: "main", baseRef: "origin/main"),
      ]
    )
    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(WorkspaceManifest.self, from: data)
    #expect(decoded.repositories[1].remoteURL == "git@github.com:org/lib.git")
    #expect(decoded.repositories[1].checkoutMode == .remoteTrackingRef)
    let localEntry = String(bytes: try JSONEncoder().encode(manifest.repositories[0]), encoding: .utf8) ?? ""
    #expect(!localEntry.contains("remoteURL"))
    #expect(decoded == manifest)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["schemaVersion"] as? Int == 1)
    // Sparse encode: nil / empty optionals stay off disk.
    let entry = (object?["repositories"] as? [[String: Any]])?.first
    #expect(entry?["role"] as? String == "macOS app")
    #expect(entry?["checkoutMode"] as? String == "newBranch")
  }

  @Test
  func encodeOmitsEmptyTaskLinksAndNilDescription() throws {
    let data = try JSONEncoder().encode(WorkspaceManifest(title: "T"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["taskLinks"] == nil)
    #expect(object?["description"] == nil)
  }

  // MARK: - Normalize / validate

  @Test
  func normalizedFillsTitleFromFolderAndTrims() {
    let manifest = WorkspaceManifest(
      title: "  ",
      description: "  ",
      taskLinks: [" a ", ""],
      repositories: [
        WorkspaceManifest.Entry(name: " app ", role: " ", path: nil),
        WorkspaceManifest.Entry(name: "", path: "api"),
        WorkspaceManifest.Entry(name: "", path: ""),
      ]
    )
    let normalized = manifest.normalized(rootPath: "/tmp/checkout-flow")
    #expect(normalized.title == "checkout-flow")
    #expect(normalized.description == nil)
    #expect(normalized.taskLinks == ["a"])
    #expect(normalized.repositories.map(\.name) == ["app", "api"])
    #expect(normalized.repositories.map(\.path) == ["app", "api"])
    #expect(normalized.repositories[0].role == nil)
    // Idempotent.
    #expect(normalized.normalized(rootPath: "/tmp/checkout-flow") == normalized)
  }

  @Test
  func validateRejectsEscapingPathsAndDuplicates() {
    let manifest = WorkspaceManifest(
      title: "T",
      repositories: [
        WorkspaceManifest.Entry(name: "a", path: "../a"),
        WorkspaceManifest.Entry(name: "b", path: "/abs"),
        WorkspaceManifest.Entry(name: "c", path: "nested/c"),
        WorkspaceManifest.Entry(name: "d", path: "d"),
        WorkspaceManifest.Entry(name: "d", path: "e"),
        WorkspaceManifest.Entry(name: "f", path: "d"),
      ]
    )
    let issues = manifest.validate()
    #expect(issues.contains(.invalidPath(name: "a", path: "../a")))
    #expect(issues.contains(.invalidPath(name: "b", path: "/abs")))
    #expect(issues.contains(.invalidPath(name: "c", path: "nested/c")))
    #expect(issues.contains(.duplicateName("d")))
    #expect(issues.contains(.duplicatePath("d")))
    #expect(issues.count == 5)
  }

  @Test
  func entryResolvesUnderTheRoot() {
    let entry = WorkspaceManifest.Entry(name: "app")
    #expect(entry.resolvedPath(rootPath: "/tmp/ws") == "/tmp/ws/app")
  }

  // MARK: - Store

  @Test
  func storeRoundTripsThroughDiskAndStampsTimestamps() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = root.path(percentEncoded: false)
    #expect(!WorkspaceManifestStore.hasManifest(rootPath: rootPath))

    let manifest = WorkspaceManifest(
      title: "T", repositories: [WorkspaceManifest.Entry(name: "app")])
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let saved = try WorkspaceManifestStore.save(manifest, rootPath: rootPath, now: now)
    #expect(saved.createdAt == now)
    #expect(saved.updatedAt == now)
    #expect(WorkspaceManifestStore.hasManifest(rootPath: rootPath))

    let loaded = try WorkspaceManifestStore.load(rootPath: rootPath)
    #expect(loaded == saved)

    // A later save keeps createdAt and bumps updatedAt.
    let later = now.addingTimeInterval(60)
    let resaved = try WorkspaceManifestStore.save(loaded, rootPath: rootPath, now: later)
    #expect(resaved.createdAt == now)
    #expect(resaved.updatedAt == later)
  }

  @Test
  func storeReportsMissingMalformedAndInvalid() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = root.path(percentEncoded: false)

    #expect(throws: WorkspaceManifestStore.Failure.self) {
      try WorkspaceManifestStore.load(rootPath: rootPath)
    }

    let url = WorkspaceLayout.manifestURL(rootPath: rootPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    do {
      _ = try WorkspaceManifestStore.load(rootPath: rootPath)
      Issue.record("expected malformed")
    } catch let failure as WorkspaceManifestStore.Failure {
      guard case .malformed = failure else {
        Issue.record("expected malformed, got \(failure)")
        return
      }
    }

    try Data(#"{"repositories":[{"name":"a","path":"../a"}]}"#.utf8).write(to: url)
    do {
      _ = try WorkspaceManifestStore.load(rootPath: rootPath)
      Issue.record("expected invalid")
    } catch let failure as WorkspaceManifestStore.Failure {
      guard case .invalid(_, let issues) = failure else {
        Issue.record("expected invalid, got \(failure)")
        return
      }
      #expect(issues == [.invalidPath(name: "a", path: "../a")])
    }
  }
}

extension WorkspaceManifest.Entry {
  /// Test helper: the name a normalize pass would assign.
  fileprivate var normalizedName: String {
    name.isEmpty ? path : name
  }
}
