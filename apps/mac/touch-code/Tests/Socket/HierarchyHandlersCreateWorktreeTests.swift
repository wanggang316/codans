import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC
@testable import touch_code

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
      NSHomeDirectory() + "/.touch-code/repos/repo/feature/login"
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

  private static func makeFixture(
    globalWorktreesDirectory: String? = nil,
    worktreesDirectoryOverride: String? = nil
  ) -> Fixture {
    let projectID = ProjectID()
    let project = Project(
      id: projectID,
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
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
    let handlers = HierarchyHandlers(
      manager: manager,
      settingsProvider: { settings }
    )
    return Fixture(handlers: handlers, projectID: projectID)
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
      .appendingPathComponent("touch-code-create-worktree-tests-\(UUID().uuidString).json")
  }

  private struct Fixture {
    let handlers: HierarchyHandlers
    let projectID: ProjectID
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
