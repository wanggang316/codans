import ComposableArchitecture
import Foundation
import CodansCore

/// Reducer backing the Settings → Global Commands pane. The global counterpart
/// to `ProjectSettingsFeature`'s scripts path, minus everything project-scoped:
/// global commands have no `ProjectID`, no lifecycle scripts, and no built-in
/// Run invariant. The pane owns selection in the view; this reducer owns the
/// single TCA write path so test stores can spy on individual writes.
@Reducer
struct GlobalCommandsFeature {
  @ObservableState
  struct State: Equatable {
    var lastWriteFailure: String?
  }

  enum Action: Equatable {
    /// Replace the entire `general.globalScripts` array. The pane writes after
    /// every edit / reorder / delete; full-array semantics match
    /// `ForEach.onMove` and `SettingsWriter.setGlobalScripts`.
    case setGlobalScripts([ScriptDefinition])
    case writeFailed(String)
  }

  @Dependency(SettingsWriter.self) var settingsWriter

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setGlobalScripts(let scripts):
        let writer = settingsWriter.setGlobalScripts
        return .run { send in
          await writer(scripts)
          await send(.writeFailed(""))  // Clear the error on success
        }

      case .writeFailed(let message):
        state.lastWriteFailure = message.isEmpty ? nil : message
        return .none
      }
    }
  }
}
