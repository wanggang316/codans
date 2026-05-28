import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root view for the Settings window scene. Two-column `NavigationSplitView` with the
/// sidebar (global sections + Repositories disclosure) on the left and a per-section detail
/// pane on the right. The detail switch is frozen — T2/T3/T4 replace only the individual
/// placeholder view bodies, never the switch cases here.
struct SettingsWindowView: View {
  @Bindable var store: StoreOf<SettingsWindowFeature>
  /// Strong reference to the store so Appearance / future pane writes route through the
  /// single-writer SettingsStore without TCA scoping churn. Injected at scene construction.
  let settingsStore: SettingsStore
  /// Strong reference to the shortcuts store so the Shortcuts pane can mutate overrides.
  let shortcutsStore: ShortcutsStore
  /// Persisted-session catalog accessor, threaded into the General pane so
  /// the user can see and clear what would be resumed on the next launch.
  /// `nil` when the launch is running in no-resume mode.
  let sessionCoordinator: SessionCoordinator?
  /// Read for the sidebar's Repositories disclosure + the B8 pruning subscription below.
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let selection = Binding<SettingsSection?>(
      get: { store.state.selection },
      set: { store.send(.selectionChanged($0)) }
    )
    // Lock column visibility so SwiftUI stops auto-injecting the sidebar
    // collapse toggle; the remaining `.toolbar(removing: .sidebarToggle)` on the
    // sidebar column scrubs the placeholder, and the invisible principal item
    // below pins the toolbar height so the sidebar list does not slide down
    // when the toggle disappears.
    NavigationSplitView(columnVisibility: .constant(.all)) {
      SettingsSidebarView(selection: selection)
        .toolbar(removing: .sidebarToggle)
    } detail: {
      detailView(for: store.state.effectiveSection)
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Color.clear.frame(width: 0, height: 0)
      }
    }
    .frame(minWidth: 800, minHeight: 500)
    .navigationTitle(title(for: store.state.effectiveSection))
    .navigationSubtitle(subtitle(for: store.state.effectiveSection))
    .onChange(of: projectIDs, initial: true) { _, current in
      // B8: when the catalog drops a Project the user is viewing, fall back to General.
      store.send(.projectsChanged(current))
    }
    .onDisappear {
      store.send(.windowClosed)
    }
  }

  /// Stable snapshot of the current Project IDs. `@Observable` catalog access re-evaluates
  /// this on every mutation; `onChange(of:)` dedupes equal values.
  private var projectIDs: Set<ProjectID> {
    Set(hierarchyManager.catalog.projects.map(\.id))
  }

  /// Window-title binding. Global sections use `SettingsSection.globalTitle`; repository
  /// sections resolve the owning Project's name through the live `HierarchyManager`
  /// catalog and fall back to a bare section name when the project has been dropped
  /// mid-flight (B8 handoff — `onChange(of: projectIDs)` will swap the selection back
  /// to `.general` one frame later).
  private func title(for section: SettingsSection) -> String {
    if let globalTitle = section.globalTitle {
      return globalTitle
    }
    if let pid = section.projectID, let suffix = section.projectSubrowTitle {
      return projectTitle(for: pid, suffix: suffix)
    }
    return "Settings"
  }

  private func projectTitle(for projectID: ProjectID, suffix: String) -> String {
    let project = hierarchyManager.catalog.projects
      .first { $0.id == projectID }
    guard let project else { return suffix }
    return "\(project.name) — \(suffix)"
  }

  /// Window subtitle binding. Only project-scoped sections carry one — the
  /// owning Project's `rootPath` shows under the window title so the user
  /// can disambiguate two Projects that share a canonical name (e.g. two
  /// `worktrees/` checkouts of the same repo). Global panes return an
  /// empty string, which the AppKit title bar renders as no subtitle.
  private func subtitle(for section: SettingsSection) -> String {
    guard let pid = section.projectID,
      let project = hierarchyManager.catalog.projects.first(where: { $0.id == pid })
    else { return "" }
    return project.rootPath
  }

  @ViewBuilder
  private func detailView(for section: SettingsSection) -> some View {
    switch section {
    case .general:
      SettingsGeneralView(
        store: store.scope(state: \.general, action: \.general),
        settingsStore: settingsStore,
        onJumpToTerminal: { store.send(.selectionChanged(.terminal)) },
        sessionCoordinator: sessionCoordinator
      )
    case .github:
      GitHubSettingsView(settingsStore: settingsStore)
    case .worktree:
      SettingsWorktreeView(settingsStore: settingsStore)
    case .terminal:
      SettingsTerminalView(store: store.scope(state: \.terminal, action: \.terminal))
    case .notifications:
      NotificationsSettingsView()
    case .developer:
      DeveloperSettingsView()
    case .shortcuts:
      ShortcutsSettingsView(store: shortcutsStore)
    case .updates:
      UpdatesSettingsView()
    case .about:
      AboutSettingsView()
    case .projectGeneral(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectGeneralSettingsView(
          projectID: projectID,
          store: paneStore,
          descriptors: store.state.general.descriptors
        )
      } else {
        // State entry is lazily instantiated in `selectionChanged`; this arm is a
        // belt-and-suspenders placeholder for the single frame between a user click
        // landing and the reducer run finishing.
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .projectScripts(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectScriptsSettingsView(projectID: projectID, store: paneStore)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
