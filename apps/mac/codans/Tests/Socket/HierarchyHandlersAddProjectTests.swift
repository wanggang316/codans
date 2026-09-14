import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// `codans project add` reaches `HierarchyHandlers.addProject`, which
/// validates the directory, refuses a second registration of the same
/// path, and discovers the git root the way the sidebar's Add Project does.
@MainActor
struct HierarchyHandlersAddProjectTests {
  @Test
  func addProjectDiscoversGitRootAndReconciles() async throws {
    let directory = Self.tempDirectory()
    var reconciled: [ProjectID] = []
    let fixture = Fixture(
      gitRootDiscovery: { path in path == HierarchyManager.canonicalPath(directory.path) ? "/discovered" : nil },
      reconcileWorktrees: { reconciled.append($0) }
    )
    let params = try JSONValue.encoded(
      AddProjectRequest(name: "repo", rootPath: directory.path, gitRoot: nil))

    let outcome = await fixture.handlers.addProject(params)
    let result: HierarchyHandlers.AddProjectResult = try Self.decodeUnary(outcome)

    #expect(result.gitRoot == "/discovered")
    #expect(result.rootPath == HierarchyManager.canonicalPath(directory.path))
    #expect(fixture.manager.catalog.projects.first?.gitRoot == "/discovered")
    #expect(reconciled == [result.id])
  }

  @Test
  func addProjectKeepsASuppliedGitRoot() async throws {
    let directory = Self.tempDirectory()
    let fixture = Fixture(gitRootDiscovery: { _ in "/discovered" })
    let params = try JSONValue.encoded(
      AddProjectRequest(name: "repo", rootPath: directory.path, gitRoot: "/supplied"))

    let outcome = await fixture.handlers.addProject(params)
    let result: HierarchyHandlers.AddProjectResult = try Self.decodeUnary(outcome)

    #expect(result.gitRoot == "/supplied")
  }

  @Test
  func addProjectRejectsAMissingDirectory() async throws {
    let fixture = Fixture()
    let params = try JSONValue.encoded(
      AddProjectRequest(name: "nope", rootPath: "/definitely/not/here", gitRoot: nil))

    let outcome = await fixture.handlers.addProject(params)

    guard case .failed(.invalidParams) = outcome else {
      Issue.record("expected .invalidParams, got \(outcome)")
      return
    }
    #expect(fixture.manager.catalog.projects.isEmpty)
  }

  @Test
  func addProjectRejectsAnAlreadyRegisteredPath() async throws {
    let directory = Self.tempDirectory()
    let fixture = Fixture()
    let first = try JSONValue.encoded(
      AddProjectRequest(name: "repo", rootPath: directory.path, gitRoot: nil))
    _ = await fixture.handlers.addProject(first)

    let second = try JSONValue.encoded(
      AddProjectRequest(name: "again", rootPath: directory.path + "/", gitRoot: nil))
    let outcome = await fixture.handlers.addProject(second)

    guard case .failed(.conflict) = outcome else {
      Issue.record("expected .conflict, got \(outcome)")
      return
    }
    #expect(fixture.manager.catalog.projects.count == 1)
  }

  /// Mirrors `HierarchyHandlers.AddProjectParams`.
  private struct AddProjectRequest: Encodable {
    let name: String
    let rootPath: String
    let gitRoot: String?
  }

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  private static func tempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-add-project-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @MainActor
  private struct Fixture {
    let manager: HierarchyManager
    let handlers: HierarchyHandlers

    init(
      gitRootDiscovery: @escaping @MainActor (String) async -> String? = { _ in nil },
      reconcileWorktrees: @escaping @MainActor (ProjectID) async -> Void = { _ in }
    ) {
      let manager = HierarchyManager(
        catalog: Catalog(projects: []),
        store: CatalogStore(
          fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codans-add-project-\(UUID().uuidString).json")
        ),
        runtime: FakeHierarchyRuntime()
      )
      self.manager = manager
      self.handlers = HierarchyHandlers(
        manager: manager,
        gitRootDiscovery: gitRootDiscovery,
        reconcileWorktrees: reconcileWorktrees
      )
    }
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
