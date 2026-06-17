import ComposableArchitecture
import Foundation
import CodansCore

/// Reducer for the standalone Settings window. Holds sidebar selection + the General pane's
/// `EditorFeature` state plus a per-`ProjectID` slice of `ProjectSettingsFeature.State` for
/// each Project pane the user has visited.
///
/// Selection is *not* persisted. Closing the window drops the selection and re-opening
/// defaults to General. `windowClosed` resets `selection` to `nil`; `SettingsWindowView`
/// treats `nil` as "render General".
@Reducer
struct SettingsWindowFeature {
  @ObservableState
  struct State: Equatable {
    var selection: SettingsSection?
    var general: EditorFeature.State = .init()
    var terminal: SettingsTerminalFeature.State = .init()
    var globalCommands: GlobalCommandsFeature.State = .init()
    var projectPanes: IdentifiedArrayOf<ProjectSettingsFeature.State> = []

    init(
      selection: SettingsSection? = nil,
      general: EditorFeature.State = .init(),
      terminal: SettingsTerminalFeature.State = .init(),
      globalCommands: GlobalCommandsFeature.State = .init(),
      projectPanes: IdentifiedArrayOf<ProjectSettingsFeature.State> = []
    ) {
      self.selection = selection
      self.general = general
      self.terminal = terminal
      self.globalCommands = globalCommands
      self.projectPanes = projectPanes
    }

    /// Section the detail column should render. Falls back to `.general` when nothing is
    /// selected — matches "re-open defaults to General" and prevents an empty-detail
    /// flash on first open.
    var effectiveSection: SettingsSection { selection ?? .general }
  }

  enum Action: Equatable {
    case selectionChanged(SettingsSection?)
    case general(EditorFeature.Action)
    case terminal(SettingsTerminalFeature.Action)
    case globalCommands(GlobalCommandsFeature.Action)
    case projectPanes(IdentifiedActionOf<ProjectSettingsFeature>)
    /// Fired by `SettingsWindowView`'s `.onDisappear`. Clears sidebar selection on close.
    case windowClosed
    /// Fired from the view on every `HierarchyManager.catalog` delta. Reducer prunes a
    /// Project-scoped selection whose backing Project has disappeared from the catalog,
    /// and re-seeds `kind` on surviving panes to pick up `git init` / `rm -rf .git` flips.
    case projectsChanged(Set<ProjectID>)
  }

  @Dependency(HierarchyClient.self) var hierarchyClient

  var body: some Reducer<State, Action> {
    Scope(state: \.general, action: \.general) {
      EditorFeature()
    }
    Scope(state: \.terminal, action: \.terminal) {
      SettingsTerminalFeature()
    }
    Scope(state: \.globalCommands, action: \.globalCommands) {
      GlobalCommandsFeature()
    }
    Reduce { state, action in
      switch action {
      case .selectionChanged(let next):
        state.selection = next
        // Selecting a Project-scoped row lazily materialises the per-ProjectID slice of
        // `projectPanes`. Without this the window's detail switch sees an empty
        // `projectPanes`, `store.scope(...)` returns nil, and the pane view can't dispatch
        // actions.
        if let pid = next?.projectID {
          ensureProjectPane(&state, for: pid)
        }
        return .none
      case .general:
        return .none
      case .terminal:
        return .none
      case .globalCommands:
        return .none
      case .projectPanes:
        return .none
      case .windowClosed:
        state.selection = nil
        return .none
      case .projectsChanged(let currentIDs):
        // Prune panes for projects that no longer exist.
        state.projectPanes.removeAll { !currentIDs.contains($0.id) }
        // Re-seed kind on surviving panes so `git init` / `rm -rf .git` flips propagate.
        for pid in currentIDs {
          if let index = state.projectPanes.index(id: pid),
            let freshKind = hierarchyClient.kind(pid),
            state.projectPanes[index].kind != freshKind
          {
            state.projectPanes[index].kind = freshKind
          }
        }
        // Clear selection if it points to a disappeared project OR to a sub-pane that the
        // project's current kind no longer exposes (e.g. the user was on Git & Worktree when
        // `.git` was removed and the Project flipped to dir). Falling back to
        // General keeps the pane consistent with the sidebar's kind-conditional row set.
        if let selection = state.selection, let pid = selection.projectID {
          if !currentIDs.contains(pid) {
            state.selection = nil
          } else if let pane = state.projectPanes[id: pid],
            !SettingsSection.subrows(for: pane.kind, projectID: pid).contains(selection)
          {
            state.selection = .projectGeneral(pid)
          }
        }
        return .none
      }
    }
    .forEach(\.projectPanes, action: \.projectPanes) {
      ProjectSettingsFeature()
    }
  }

  /// Insert a fresh `ProjectSettingsFeature.State(projectID:)` into `projectPanes` if no
  /// entry exists for `pid`. Seeds `kind` from `HierarchyClient.kind(of:)`; falls back to
  /// `.gitRepo` when the Project is absent (caller-requested but unavailable; the pane
  /// will be pruned on the next `.projectsChanged` tick).
  private func ensureProjectPane(_ state: inout State, for pid: ProjectID) {
    guard state.projectPanes[id: pid] == nil else { return }
    var entry = ProjectSettingsFeature.State(projectID: pid)
    if let kind = hierarchyClient.kind(pid) {
      entry.kind = kind
    }
    state.projectPanes.append(entry)
  }
}
