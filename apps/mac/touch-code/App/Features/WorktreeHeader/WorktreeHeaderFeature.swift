import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer backing the Worktree Header row: branch label + Open-in split
/// button.
///
/// User-facing side effects stay in the reducer so TestStore can prove
/// them. Editor opens are emitted as `.delegate(.openEditor(...))` rather
/// than dispatched through `EditorClient` directly; `RootFeature` forwards
/// them into `EditorFeature.openRequested` (resolving `editorID: nil` via
/// `EditorFeature.resolveDefault` first). The Git Viewer no longer has a
/// dedicated header button — invocations land on the ⌘⌥G chord / menu /
/// palette entry, which RootFeature dispatches against
/// `settings.general.defaultGitViewerID`.
@Reducer
struct WorktreeHeaderFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case onAppear
    case openDefaultEditorTapped(worktreePath: String, projectID: ProjectID?)
    case openEditorTapped(editorID: EditorID, worktreePath: String, projectID: ProjectID?)
    /// Dropdown menu item tapped. Resolves the worktree path and projectID
    /// from the current selection at action-handle time so the open targets
    /// the live selection rather than the path captured when the Menu's
    /// NSMenuItems were first built (SwiftUI bridges Menu content to
    /// NSMenuItem actions that don't always refresh on view rebuild — the
    /// outer `primaryAction` doesn't suffer this since it's evaluated
    /// inline). Also persists the pick as the per-Project default.
    case pickEditorFromMenuTapped(EditorID)
    case customEditorsTapped
    case setProjectDefaultEditorTapped(projectID: ProjectID, editorID: EditorID?)
    /// Run script split-button — primary or menu activation. Phase 2.
    ///
    /// Carries only `scriptID`; `RootFeature` resolves the target Project +
    /// Worktree from `state.selection` at handle-time. Mirrors the
    /// `pickEditorFromMenuTapped` pattern: SwiftUI bridges Menu content to
    /// NSMenuItem actions whose closure captures don't always refresh on
    /// view rebuild, and the `.keyboardShortcut` chord routes through that
    /// same path — so a worktree switch could previously fire the script
    /// against a stale worktreeID. Inline `primaryAction` callers were
    /// unaffected, but the menu / chord paths were.
    case runScriptTapped(scriptID: UUID)
    /// "Manage Scripts…" menu footer or primary click on an empty script list.
    /// Carries the source `projectID` so the parent can deep-link into
    /// the Settings window's Project Scripts pane for that project.
    case manageScriptsTapped(projectID: ProjectID)
    case delegate(Delegate)

    /// Parent-consumed delegate. `RootFeature` routes these into the existing
    /// `EditorFeature` / settings-sheet presentation paths.
    enum Delegate: Equatable {
      /// Request to open a Worktree. `editorID == nil` asks the parent to
      /// resolve the default via `EditorFeature.resolveDefault` and
      /// dispatch `.editor(.openRequested(...))` with the resolved id.
      case openEditor(editorID: EditorID?, worktreePath: String, projectID: ProjectID?)
      /// Present the Settings sheet on the editors tab (`"+ Custom editors…"`).
      case showCustomEditorsSettings
      /// Mirror of today's "Set default for this Project" sub-menu.
      case setProjectOverride(projectID: ProjectID, editorID: EditorID?)
      /// Dropdown menu pick: parent resolves the current Worktree's path
      /// from `state.selection` (avoids stale closure captures in NSMenuItem
      /// actions), persists `editorID` as the per-Project default, and opens
      /// the worktree with that editor.
      case pickEditorFromMenu(EditorID)
      /// Run a user-defined Project script. RootFeature resolves the
      /// target Project + Worktree from `state.selection` at handle-time
      /// (see `runScriptTapped` for the staleness rationale) and dispatches
      /// to `HierarchyClient.runScript`.
      case runScriptRequested(scriptID: UUID)
      /// User asked to manage scripts — open the Settings window AND
      /// deep-link into the Project Scripts pane for the given project.
      /// (Earlier shipped a no-deep-link variant; restored after the
      /// scripts pane redesign so the footer button lands users where
      /// they expect.)
      case manageScriptsRequested(projectID: ProjectID)
    }
  }

  @Dependency(HierarchyClient.self) var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .onAppear:
        return .none

      case .openDefaultEditorTapped(let path, let pid):
        return .send(.delegate(.openEditor(editorID: nil, worktreePath: path, projectID: pid)))

      case .openEditorTapped(let id, let path, let pid):
        return .send(.delegate(.openEditor(editorID: id, worktreePath: path, projectID: pid)))

      case .pickEditorFromMenuTapped(let id):
        return .send(.delegate(.pickEditorFromMenu(id)))

      case .customEditorsTapped:
        return .send(.delegate(.showCustomEditorsSettings))

      case .setProjectDefaultEditorTapped(let projectID, let editorID):
        return .send(
          .delegate(
            .setProjectOverride(
              projectID: projectID,
              editorID: editorID
            )))

      case .runScriptTapped(let scriptID):
        return .send(.delegate(.runScriptRequested(scriptID: scriptID)))

      case .manageScriptsTapped(let projectID):
        return .send(.delegate(.manageScriptsRequested(projectID: projectID)))

      case .delegate:
        // Consumed by the parent; reducer has no local state change.
        return .none
      }
    }
  }
}
