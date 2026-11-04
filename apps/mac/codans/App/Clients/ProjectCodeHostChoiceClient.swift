import CodansCore
import ComposableArchitecture
import Foundation

/// Reads the Project "Code Host" choice (Auto / GitHub / GitLab) that applies to one Pull
/// Request fetch unit. The resolver uses it after the `gh` / `glab` steps (ADR 0004
/// item 2).
///
/// A git Project's unit is keyed by the Project id, so its own setting applies. A
/// Workspace unit is keyed by a derived id; the setting of the registered Project whose
/// repository is the unit's repository applies, so each Workspace member keeps the Code
/// Host of its own Project (ADR 0004 item 16).
///
/// Read at fetch time, so a changed choice applies to the next fetch without new action
/// payloads.
nonisolated struct ProjectCodeHostChoiceClient: Sendable {
  /// The choice for the fetch unit `unitID` with repository root `gitRoot`; `nil` is Auto.
  var choice: @Sendable (_ unitID: ProjectID, _ gitRoot: URL) async -> CodeHostKind?
}

extension ProjectCodeHostChoiceClient {
  @MainActor
  static func live(hierarchy: HierarchyClient, settings: SettingsStore) -> ProjectCodeHostChoiceClient {
    ProjectCodeHostChoiceClient { [weak settings] unitID, gitRoot in
      await MainActor.run {
        guard let settings else { return nil }
        return choice(unitID: unitID, gitRoot: gitRoot, catalog: hierarchy.snapshot(), settings: settings.settings)
      }
    }
  }

  /// Pure lookup behind `live`.
  nonisolated static func choice(
    unitID: ProjectID, gitRoot: URL, catalog: Catalog, settings: Settings
  ) -> CodeHostKind? {
    if catalog.projects.contains(where: { $0.id == unitID }) {
      return settings.projects[unitID]?.git?.codeHost
    }
    // Workspace members are local repositories (workspaces never route through SSH).
    let root = HierarchyManager.canonicalPath(gitRoot.path)
    let owner = catalog.projects.first { project in
      guard !project.isWorkspace, !project.isRemote, let projectRoot = project.gitRoot else { return false }
      return HierarchyManager.canonicalPath(projectRoot) == root
    }
    return owner.flatMap { settings.projects[$0.id]?.git?.codeHost }
  }
}

extension ProjectCodeHostChoiceClient: DependencyKey {
  /// Auto everywhere until the app wires the live client.
  static let liveValue = ProjectCodeHostChoiceClient { _, _ in nil }
  static let testValue = ProjectCodeHostChoiceClient { _, _ in nil }
}
