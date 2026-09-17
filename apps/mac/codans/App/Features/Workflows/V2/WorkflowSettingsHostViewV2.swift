import CodansCore
import SwiftUI

/// Composition for Settings → Workflows. Runtime state stays app-owned.
struct WorkflowSettingsHostViewV2: View {
  let appState: AppState

  var body: some View {
    WorkflowLibraryViewV2(
      catalog: appState.workflowCatalogV2,
      creationRequest: appState.workflowCreationRequest,
      onCreationRequestHandled: { appState.workflowCreationRequest = nil }
    )
  }
}
