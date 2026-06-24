import ComposableArchitecture
import Foundation
import CodansCore

/// Inline-rename payload. Non-nil means a single row is editing its name;
/// the View binds the TextField text to `text` via `renameDraftChanged`.
struct TagRenameDraft: Equatable {
  var tagID: TagID
  var text: String
}

/// Removal-confirmation payload. Captured at tap-time so the dialog
/// shows the correct count + name even if the catalog mutates before
/// the user confirms.
struct PendingTagRemoval: Equatable {
  var tagID: TagID
  var displayName: String
  var affectedProjectCount: Int
}

/// TCA reducer for the Tag CRUD sheet.
///
/// State is intentionally tiny — every authoritative tag value lives in
/// `HierarchyManager.catalog`; this reducer only owns the two transient
/// UI payloads (rename draft, pending removal). Mutations route through
/// `HierarchyClient` closures.
@Reducer
struct TagManagerFeature {
  @ObservableState
  struct State: Equatable {
    var renameDraft: TagRenameDraft?
    var pendingRemoval: PendingTagRemoval?
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case createTagTapped(name: String, color: TagColor)
    case renameRowTapped(TagID, currentName: String)
    case renameDraftChanged(String)
    case renameCommitted
    case renameCancelled
    case recolor(TagID, TagColor)
    case removeTapped(TagID, name: String)
    case removeConfirmed
    case removeCancelled
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .createTagTapped(let name, let color):
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        _ = hierarchyClient.createTag(trimmed, color)
        // Drop any in-flight rename draft — the user clearly switched
        // contexts to "create new tag" and the prior draft would be
        // visually orphaned.
        state.renameDraft = nil
        return .none

      case .renameRowTapped(let tagID, let currentName):
        state.renameDraft = TagRenameDraft(tagID: tagID, text: currentName)
        return .none

      case .renameDraftChanged(let text):
        state.renameDraft?.text = text
        return .none

      case .renameCommitted:
        guard let draft = state.renameDraft else { return .none }
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          // Empty trim is a no-op rename; leave the draft so the user
          // can correct or Esc out.
          return .none
        }
        hierarchyClient.renameTag(draft.tagID, trimmed)
        state.renameDraft = nil
        return .none

      case .renameCancelled:
        state.renameDraft = nil
        return .none

      case .recolor(let tagID, let color):
        hierarchyClient.recolorTag(tagID, color)
        return .none

      case .removeTapped(let tagID, let name):
        // Snapshot the project count at tap time so the dialog text is
        // stable even if a parallel writer mutates `catalog.projects`
        // before the user confirms. There is no last-tag protection —
        // Untagged is a valid catalog state.
        let catalog = hierarchyClient.snapshot()
        let count = catalog.projects.filter { $0.tagIDs.contains(tagID) }.count
        state.pendingRemoval = PendingTagRemoval(
          tagID: tagID,
          displayName: name,
          affectedProjectCount: count
        )
        return .none

      case .removeConfirmed:
        guard let pending = state.pendingRemoval else { return .none }
        hierarchyClient.removeTag(pending.tagID)
        state.pendingRemoval = nil
        return .none

      case .removeCancelled:
        state.pendingRemoval = nil
        return .none
      }
    }
  }
}
