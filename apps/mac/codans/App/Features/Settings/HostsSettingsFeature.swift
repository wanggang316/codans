import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer backing Settings › Hosts (ADR 0003, decisions 3 and 5). The pane
/// reads the Host list and Project counts live from `HierarchyManager`; this
/// reducer owns the add / edit form and every write, which goes through
/// `HierarchyClient` so the catalog keeps its single writer and its
/// validation.
@Reducer
struct HostsSettingsFeature {
  @ObservableState
  struct State: Equatable {
    /// The open add / edit form, or `nil` when no form shows.
    var editor: Editor?
    /// Why the last delete failed, shown above the list.
    var deleteError: String?
  }

  struct Editor: Equatable {
    enum Mode: Equatable {
      case add
      case edit(HostID)
    }

    var mode: Mode
    var draft: HostDraft
    /// Validation failure, shown in the form.
    var errorMessage: String?

    var isEditing: Bool {
      if case .edit = mode { return true }
      return false
    }
  }

  enum Action: Equatable {
    case addButtonTapped
    case editButtonTapped(HostRecord)
    case deleteButtonTapped(HostID)
    case editor(EditorAction)
  }

  enum EditorAction: Equatable {
    case addressChanged(String)
    case usernameChanged(String)
    case portChanged(String)
    case nameChanged(String)
    case saveButtonTapped
    case cancelButtonTapped
  }

  @Dependency(HierarchyClient.self) var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .addButtonTapped:
        state.editor = Editor(mode: .add, draft: HostDraft())
        return .none

      case .editButtonTapped(let record):
        state.editor = Editor(mode: .edit(record.id), draft: HostDraft(record: record))
        return .none

      case .deleteButtonTapped(let id):
        do {
          try hierarchyClient.removeHost(id)
          state.deleteError = nil
        } catch {
          state.deleteError = error.localizedDescription
        }
        return .none

      case .editor(let action):
        guard state.editor != nil else { return .none }
        reduceEditor(&state, action)
        return .none
      }
    }
  }

  private func reduceEditor(_ state: inout State, _ action: EditorAction) {
    switch action {
    case .addressChanged(let value):
      state.editor?.draft.address = value
    case .usernameChanged(let value):
      state.editor?.draft.username = value
    case .portChanged(let value):
      state.editor?.draft.port = HostDraft.sanitizedPort(value)
    case .nameChanged(let value):
      state.editor?.draft.name = value
    case .cancelButtonTapped:
      state.editor = nil
    case .saveButtonTapped:
      guard let editor = state.editor else { return }
      do {
        switch editor.mode {
        case .add:
          try hierarchyClient.addHost(editor.draft.record())
        case .edit(let id):
          try hierarchyClient.updateHost(editor.draft.record(id: id))
        }
        state.editor = nil
      } catch {
        state.editor?.errorMessage = error.localizedDescription
      }
    }
  }
}
