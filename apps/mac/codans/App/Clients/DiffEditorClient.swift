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
    @Dependency(SettingsWriter.self) var settingsWriter
    @Dependency(HierarchyClient.self) var hierarchyClient
    let settings = await settingsWriter.readSnapshot()
    let host = await MainActor.run {
      projectID.flatMap { id in
        hierarchyClient.snapshot().projects.first(where: { $0.id == id })?.remoteHost
      }
    }
    let service = LiveEditorService(globalDefault: { settings.general.defaultEditorID })
    let descriptors = await service.describe()
    let preferred = EditorFeature.resolveInstalledPreference(
      projectOverride: projectID.flatMap { settings.projects[$0]?.defaultEditor },
      globalDefault: settings.general.defaultEditorID,
      descriptors: descriptors
    )
    try await service.openFile(
      worktree: worktree, relativePath: relativePath, line: line, preferred: preferred, host: host
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
