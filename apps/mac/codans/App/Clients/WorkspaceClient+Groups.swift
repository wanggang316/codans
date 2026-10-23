import CodansCore
import Foundation

// The stubs keep the final async signatures the live wiring calls.
// swiftlint:disable async_without_await

// Named group creation. Not implemented yet: the live closures fail with
// `notImplemented` (or answer empty) until this part lands.
extension WorkspaceClient {
  @MainActor
  static func groupCreationDefaults(projectID: ProjectID, context: Context) async -> [MemberCreationOptions] {
    []
  }

  @MainActor
  static func preflightGroup(_ plan: WorkspaceGroupPlan, context: Context) async -> WorkspacePreflight {
    WorkspacePreflight()
  }

  @MainActor
  static func performCreateGroup(
    _ plan: WorkspaceGroupPlan,
    context: Context,
    yield: @escaping @Sendable (WorkspaceCreationEvent) -> Void
  ) async throws {
    throw WorkspaceError.notImplemented("Creating a group")
  }
}
// swiftlint:enable async_without_await
