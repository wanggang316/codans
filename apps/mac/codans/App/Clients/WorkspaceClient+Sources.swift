import CodansCore
import Foundation

// The stubs keep the final async signatures the live wiring calls.
// swiftlint:disable async_without_await

// Workspace creation and the source project list. Not implemented yet: the
// live closures fail with `notImplemented` until this part lands.
extension WorkspaceClient {
  @MainActor
  static func createWorkspace(_ plan: WorkspaceSourcePlan, context: Context) async throws -> ProjectID {
    throw WorkspaceError.notImplemented("Creating a workspace")
  }

  @MainActor
  static func preflightWorkspace(_ plan: WorkspaceSourcePlan, context: Context) async -> WorkspacePreflight {
    WorkspacePreflight()
  }

  @MainActor
  static func addSource(
    projectID: ProjectID, source: WorkspaceSource, context: Context
  ) async throws -> WorktreeID {
    throw WorkspaceError.notImplemented("Adding a project to a workspace")
  }

  @MainActor
  static func removeSource(projectID: ProjectID, sourceGitRoot: String, context: Context) async throws {
    throw WorkspaceError.notImplemented("Removing a project from a workspace")
  }
}
// swiftlint:enable async_without_await
