import CodansCore
import Foundation

// The stubs keep the final async signatures the live wiring calls.
// swiftlint:disable async_without_await

// Group deletion and Workspace removal. Not implemented yet: the check
// reports a failure (which blocks deletion) and the actions fail with
// `notImplemented` until this part lands.
extension WorkspaceClient {
  @MainActor
  static func checkGroupDeletion(
    projectID: ProjectID, groupID: WorkspaceGroupID, context: Context
  ) async -> GroupDeletionCheck {
    GroupDeletionCheck(
      projectID: projectID, groupID: groupID, groupName: "",
      groupCheckFailures: [WorkspaceError.notImplemented("Deleting a group").localizedDescription])
  }

  @MainActor
  static func deleteGroup(
    projectID: ProjectID, groupID: WorkspaceGroupID, request: GroupDeletionRequest, context: Context
  ) async throws -> GroupDeletionOutcome {
    throw WorkspaceError.notImplemented("Deleting a group")
  }

  @MainActor
  static func removeWorkspace(
    projectID: ProjectID, request: WorkspaceRemovalRequest, context: Context
  ) async throws -> WorkspaceRemovalOutcome {
    throw WorkspaceError.notImplemented("Removing a workspace")
  }
}
// swiftlint:enable async_without_await
