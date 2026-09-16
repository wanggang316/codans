import CodansCore
import SwiftUI

/// Composition for Settings → Agents → Workflows. Runtime state stays app-owned.
struct WorkflowSettingsHostViewV2: View {
  let appState: AppState
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    WorkflowLibraryViewV2(
      catalog: appState.workflowCatalogV2,
      service: appState.workflowServiceV2,
      profiles: appState.settingsStore.settings.agents.enabledProfiles,
      panes: appState.workflowAgentPanesV2,
      workspaces: appState.workflowWorkspaces,
      creationRequest: appState.workflowCreationRequest,
      onStart: {
        try appState.startWorkflowV2(definition: $0, source: $1, title: $2, inputs: $3, selections: $4)
      },
      onOpenPane: { value in
        guard let uuid = UUID(uuidString: value) else { return }
        openWindow(id: CodansApp.mainWindowID)
        appState.store?.send(.agentState(.rowTapped(PaneID(raw: uuid))))
      },
      onCreationRequestHandled: { appState.workflowCreationRequest = nil }
    )
  }
}
