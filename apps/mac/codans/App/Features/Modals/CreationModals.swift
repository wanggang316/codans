import ComposableArchitecture
import Foundation
import CodansCore

/// Lightweight sheet reducer for the new-tab creation flow.
/// Holds a draft name, validates on submit, dispatches the matching
/// `HierarchyClient.createTab`, and dismisses.

@Reducer
struct NewTabFeature {
  @ObservableState
  struct State: Equatable {
    let projectID: ProjectID
    let worktreeID: WorktreeID
    var draftName: String = ""
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case submitButtonTapped
    case cancelButtonTapped
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .submitButtonTapped:
        let trimmed = state.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = trimmed.isEmpty ? nil : trimmed
        _ = try? hierarchyClient.createTab(state.worktreeID, state.projectID, name)
        return .run { _ in await dismiss() }
      case .cancelButtonTapped:
        return .run { _ in await dismiss() }
      }
    }
  }
}
