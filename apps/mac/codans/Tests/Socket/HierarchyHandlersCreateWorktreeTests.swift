import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct HierarchyHandlersCreateWorktreeTests {
  @Test
  func explicitPathIsUsedVerbatim() async throws {
    let fixture = Self.makeFixture()
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "feature",
        path: "/explicit/path",
        branch: "feature",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    #expect(result.path == HierarchyManager.canonicalPath("/explicit/path"))
  }

  @Test
  func defaultPathFallsBackToSystemDefaultWhenNoGlobalOrOverride() async throws {
    let fixture = Self.makeFixture()
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "feature/login",
        path: nil,
        branch: "feature/login",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    let expected = HierarchyManager.canonicalPath(
      NSHomeDirectory() + "/.codans/repos/repo/feature/login"
    )
    #expect(result.path == expected)
  }

  @Test
  func defaultPathHonoursGlobalDefault() async throws {
    let fixture = Self.makeFixture(globalWorktreesDirectory: "/global/wt-base")
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "feature",
        path: nil,
        branch: "feature",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    // Global base appends `<projectName>/<sanitizedBranch>`.
    let expected = HierarchyManager.canonicalPath("/global/wt-base/repo/feature")
    #expect(result.path == expected)
  }

  @Test
  func projectOverrideWinsOverGlobalDefault() async throws {
    let fixture = Self.makeFixture(
      globalWorktreesDirectory: "/global/wt-base",
      worktreesDirectoryOverride: "/custom/wt-base"
    )
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "feature",
        path: nil,
        branch: "feature",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    // Project override is verbatim — projectName is NOT re-appended on top.
    #expect(result.path == HierarchyManager.canonicalPath("/custom/wt-base/feature"))
  }

  @Test
  func defaultPathHonoursProjectOverride() async throws {
    let fixture = Self.makeFixture(worktreesDirectoryOverride: "/custom/wt-base")
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "feature",
        path: nil,
        branch: "feature",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    let expected = HierarchyManager.canonicalPath("/custom/wt-base/feature")
    #expect(result.path == expected)
  }

  @Test
  func defaultPathSanitizesBranchName() async throws {
    let fixture = Self.makeFixture(worktreesDirectoryOverride: "/wt")
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "weird name",
        path: nil,
        branch: "weird:name",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    #expect(result.path == HierarchyManager.canonicalPath("/wt/weirdname"))
  }

  @Test
  func defaultPathRequiresBranchWhenPathIsNil() async throws {
    let fixture = Self.makeFixture()
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "headless",
        path: nil,
        branch: nil,
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    guard case .failed(let err) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    if case .invalidParams = err {
    } else {
      Issue.record("expected invalidParams, got \(err)")
    }
  }

  @Test
  func missingPathOnAGitProjectIsMaterialisedThroughTheCreator() async throws {
    let spy = CreatorSpy()
    let base = Self.tempDirectory()
    let fixture = Self.makeFixture(globalWorktreesDirectory: base.path, creator: spy)
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "feat/login",
        path: nil,
        branch: "feat/login",
        reuseExisting: nil,
        baseRef: "origin/main"
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    let spec = try #require(spy.specs.first)
    #expect(spec.repoRoot.path == "/repo")
    #expect(spec.name == "feat/login")
    #expect(spec.baseRef == "origin/main")
    #expect(spec.pathOverride?.path == base.appending(path: "repo/feat/login").path)
    #expect(spec.baseDirectory.path == base.appending(path: "repo/feat").path)
    #expect(result.created)
    #expect(result.path == HierarchyManager.canonicalPath(base.appending(path: "repo/feat/login").path))
  }

  @Test
  func existingPathIsRegisteredWithoutTouchingGit() async throws {
    let spy = CreatorSpy()
    let existing = Self.tempDirectory()
    let fixture = Self.makeFixture(creator: spy)
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "adopted",
        path: existing.path,
        branch: "adopted",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    #expect(spy.specs.isEmpty)
    #expect(!result.created)
  }

  @Test
  func folderProjectStaysCatalogOnly() async throws {
    let spy = CreatorSpy()
    let fixture = Self.makeFixture(gitRoot: nil, creator: spy)
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "notes",
        path: "/nowhere/notes",
        branch: "notes",
        reuseExisting: nil
      )
    )

    let outcome = await fixture.handlers.createWorktree(params)
    let result: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(outcome)

    #expect(spy.specs.isEmpty)
    #expect(!result.created)
  }

  @Test
  func baseRefFallsBackToTheRepoDefault() async throws {
    let spy = CreatorSpy()
    let fixture = Self.makeFixture(
      globalWorktreesDirectory: Self.tempDirectory().path,
      creator: spy,
      defaultBaseRef: "origin/develop"
    )
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID,
        name: "x",
        path: nil,
        branch: "x",
        reuseExisting: nil
      )
    )

    _ = await fixture.handlers.createWorktree(params)

    #expect(spy.specs.first?.baseRef == "origin/develop")
  }

  @Test
  func gitFailureMapsToTheMatchingIPCError() async throws {
    let spy = CreatorSpy(failure: .branchExists("x"))
    let fixture = Self.makeFixture(globalWorktreesDirectory: Self.tempDirectory().path, creator: spy)
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID, name: "x", path: nil, branch: "x", reuseExisting: nil))

    let outcome = await fixture.handlers.createWorktree(params)

    guard case .failed(.conflict) = outcome else {
      Issue.record("expected .conflict, got \(outcome)")
      return
    }
  }

  @Test
  func removeWorktreeDeleteFromDiskRoutesThroughTheRemover() async throws {
    let fixture = Self.makeFixture(removerWarning: "branch kept")
    let created = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: fixture.projectID, name: "x", path: "/x", branch: "x", reuseExisting: nil))
    let row: HierarchyHandlers.CreateWorktreeResult = try Self.decodeUnary(
      await fixture.handlers.createWorktree(created))
    let params = try JSONValue.encoded(
      HierarchyHandlers.RemoveWorktreeParams(
        id: row.id, projectID: fixture.projectID, deleteFromDisk: true))

    let outcome = await fixture.handlers.removeWorktree(params)
    let result: HierarchyHandlers.RemoveWorktreeResult = try Self.decodeUnary(outcome)

    #expect(result.deleted)
    #expect(result.warning == "branch kept")
    #expect(fixture.removed == [row.id])
  }

  @Test
  func removeWorktreeDeleteFromDiskIsUnsupportedWithoutARemover() async throws {
    let fixture = Self.makeFixture()
    let params = try JSONValue.encoded(
      HierarchyHandlers.RemoveWorktreeParams(
        id: WorktreeID(), projectID: fixture.projectID, deleteFromDisk: true))

    let outcome = await fixture.handlers.removeWorktree(params)

    guard case .failed(.unsupported) = outcome else {
      Issue.record("expected .unsupported, got \(outcome)")
      return
    }
  }

  /// Records every spec the handler hands to the creator and answers with
  /// the requested path (or throws the configured failure).
  @MainActor
  private final class CreatorSpy {
    var specs: [CreateWorktreeSpec] = []
    let failure: GitWorktreeError?
    init(failure: GitWorktreeError? = nil) { self.failure = failure }
    func create(_ spec: CreateWorktreeSpec) throws -> URL {
      specs.append(spec)
      if let failure { throw failure }
      return spec.pathOverride ?? spec.baseDirectory.appending(path: spec.name)
    }
  }

  private static func tempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-create-worktree-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func makeFixture(
    globalWorktreesDirectory: String? = nil,
    worktreesDirectoryOverride: String? = nil,
    gitRoot: String? = "/repo",
    creator: CreatorSpy? = nil,
    defaultBaseRef: String? = nil,
    removerWarning: String? = nil
  ) -> Fixture {
    let projectID = ProjectID()
    let project = Project(
      id: projectID,
      name: "repo",
      rootPath: "/repo",
      gitRoot: gitRoot,
      worktrees: [],
      selectedWorktreeID: nil
    )
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]),
      store: CatalogStore(fileURL: Self.tempURL()),
      runtime: FakeHierarchyRuntime()
    )
    var settings = Settings()
    settings.worktree.defaultWorktreesDirectory = globalWorktreesDirectory
    if let override = worktreesDirectoryOverride {
      settings.projects[projectID] = ProjectSettings(worktreesDirectory: override)
    }
    let removed = RemovedBox()
    let handlers = HierarchyHandlers(
      manager: manager,
      settingsProvider: { settings },
      worktreeCreator: creator.map { spy in { @MainActor @Sendable spec in try spy.create(spec) } },
      defaultBaseRef: { _ in defaultBaseRef },
      worktreeRemover: removerWarning.map { warning in
        { @MainActor @Sendable worktreeID, projectID in
          removed.ids.append(worktreeID)
          try manager.removeWorktree(worktreeID, from: projectID)
          return warning
        }
      }
    )
    return Fixture(handlers: handlers, projectID: projectID, removedBox: removed)
  }

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  private static func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-create-worktree-tests-\(UUID().uuidString).json")
  }

  @MainActor
  private final class RemovedBox {
    var ids: [WorktreeID] = []
  }

  private struct Fixture {
    let handlers: HierarchyHandlers
    let projectID: ProjectID
    var removedBox: RemovedBox?
    var removed: [WorktreeID] { removedBox?.ids ?? [] }
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
