import ComposableArchitecture
import Foundation
import CodansCore

/// Lightweight sheet reducer for the new-tab creation flow.
/// Holds a draft name, validates on submit, dispatches the matching
/// `HierarchyClient.newTab`, and dismisses.

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
        let catalog = hierarchyClient.snapshot()
        let worktree = catalog.projects.first { $0.id == state.projectID }?
          .worktrees.first { $0.id == state.worktreeID }
        let address = worktree.flatMap { worktree in
          try? hierarchyClient.newTab(
            nil, state.worktreeID, state.projectID,
            .terminal(workingDirectory: worktree.path), name, nil, true)
        }
        return .run { _ in
          // `newTab` is catalog-only; the session comes up here so the
          // new Tab is live before the sheet is gone.
          if let address { try? await hierarchyClient.ensureSurface(address.contentID) }
          await dismiss()
        }
      case .cancelButtonTapped:
        return .run { _ in await dismiss() }
      }
    }
  }
}
