import CodansCore
import ComposableArchitecture
import Foundation

/// The editor a file inside `projectID` opens in: per-project override →
/// global default → installed priority walk, plus the SSH host for Server
/// projects. Shared by every "open this file" entry point (diff viewer,
/// terminal links) so they agree on which editor wins.
nonisolated struct ProjectEditorContext: Sendable {
  let service: LiveEditorService
  let preferred: EditorID?
  let host: RemoteHost?

  @MainActor
  static func resolve(_ projectID: ProjectID?) async -> Self {
    @Dependency(SettingsWriter.self) var settingsWriter
    @Dependency(HierarchyClient.self) var hierarchyClient
    let settings = await settingsWriter.readSnapshot()
    let host = projectID.flatMap { id in
      hierarchyClient.snapshot().projects.first(where: { $0.id == id })?.remoteHost
    }
    let service = LiveEditorService(globalDefault: { settings.general.defaultEditorID })
    let descriptors = await service.describe()
    let preferred = EditorFeature.resolveInstalledPreference(
      projectOverride: projectID.flatMap { settings.projects[$0]?.defaultEditor },
      globalDefault: settings.general.defaultEditorID,
      descriptors: descriptors
    )
    return Self(service: service, preferred: preferred, host: host)
  }
}
