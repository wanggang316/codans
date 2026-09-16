import CodansCore
import SwiftUI

/// Composition for Settings → Workflows. Runtime state stays app-owned.
struct WorkflowSettingsHostViewV2: View {
  let appState: AppState
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    WorkflowLibraryViewV2(
      catalog: appState.workflowCatalogV2,
      profiles: appState.settingsStore.settings.agents.enabledProfiles,
      panes: appState.workflowAgentPanesV2,
      workspaces: appState.workflowWorkspaces,
      creationRequest: appState.workflowCreationRequest,
      onStart: {
        try appState.startWorkflowV2(
          definition: $0, source: $1, title: $2, inputs: $3, selections: $4)
      },
      onRunStarted: { id in
        appState.workflowPresentedRunID = id
        openWindow(id: CodansApp.mainWindowID)
      },
      onCreationRequestHandled: { appState.workflowCreationRequest = nil }
    )
  }
}
