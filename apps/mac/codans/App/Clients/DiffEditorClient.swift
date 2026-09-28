import CodansCore
import ComposableArchitecture
import Foundation

nonisolated struct DiffEditorClient: Sendable {
  /// Opens a current worktree file; line navigation is best effort for editors
  /// without a supported line-addressing mechanism.
  var openFile: @MainActor @Sendable (URL, String, Int?, ProjectID?) async throws -> Void
}

extension DiffEditorClient: DependencyKey {
  static let liveValue = Self { worktree, relativePath, line, projectID in
    let context = await ProjectEditorContext.resolve(projectID)
    try await context.service.openFile(
      worktree: worktree, relativePath: relativePath, line: line, preferred: context.preferred,
      host: context.host
    )
  }

  static let testValue = Self(openFile: unimplemented("DiffEditorClient.openFile"))
}

extension DependencyValues {
  var diffEditorClient: DiffEditorClient {
    get { self[DiffEditorClient.self] }
    set { self[DiffEditorClient.self] = newValue }
  }
}
