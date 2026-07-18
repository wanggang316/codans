import CodansCore
import ComposableArchitecture
import SwiftUI

/// Root SwiftUI host for the TCA shell. Holds the `StoreOf<RootFeature>`
/// that composes sidebar + detail sub-features and presents a two-column
/// `NavigationSplitView`. The `HierarchyManager` is injected through
/// `@Environment` so descendant views can read `@Observable` state
/// directly — TCA state stays focused on selection + transient UI.
struct ContentView: View {
  @Bindable var store: StoreOf<RootFeature>
  let hierarchyManager: HierarchyManager
  let settingsStore: SettingsStore
  /// Per-Worktree dirty-tree cache threaded into the sidebar so each row can decide
  /// whether to paint a pending-work dot without owning its own `git status` fetch.
  let worktreeStatusMonitor: WorktreeStatusMonitor
  /// Per-Worktree uncommitted-edits diff cache. Drives the `+N −M` chip on
  /// every worktree row, not just rows with a matched PR.
  let worktreeLocalDiffMonitor: WorktreeLocalDiffMonitor
  /// Notifications roll-up. Threaded via `.environment` so sidebar
  /// rows / tab bar / pane chrome can read per-level unread indicators
  /// without each site owning its own derivation.
  let notificationRollup: RollupIndexProvider?
  /// Inbox owner. Threaded so the InboxBellView's popover can read
  /// `entries`, mark rows read, and trigger a "Mark all read".
  let notificationStore: NotificationStore?
  /// Banner adapter. Threaded so the Settings → Notifications pane
  /// reuses the long-lived instance instead of spawning a fresh one
  /// (each spawn re-runs `setNotificationCategories` on the shared
  /// UN center).
  let osNotifier: UserNotificationsOSNotifier?
  /// Registry that backs the worktree-toolbar badge + popover. Optional
  /// because `AppState.bringUp` constructs it lazily; nil renders no badge.
  let agentStateStore: AgentStateStore?
  /// Transient toast for editor-open outcomes (success + failure). Non-nil = visible;
  /// auto-clears after a short window via `.task(id:)`.
  @State private var lastEditorToast: EditorToast?

  /// Live Sparkle seam (the global value, shared with the Updates pane) so an
  /// in-process settings change can re-sync the running `SPUUpdater`.
  @Dependency(UpdatesClient.self) private var updatesClient

  /// Bridges `RootFeature.State.sidebarVisible` (a Bool) to
  /// `NavigationSplitViewVisibility` so the chord, the system disclosure
  /// chevron, and the bound state stay in lockstep.
  private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { store.sidebarVisible ? .all : .detailOnly },
      set: { newValue in
        let visible = (newValue != .detailOnly)
        if visible != store.sidebarVisible {
          // Wrap the store dispatch in withAnimation so the sidebar
          // slides instead of snapping. The native `.sidebarToggle`
          // click animates the binding update internally, but routing
          // through `store.send` lands the reducer mutation outside
          // that transaction — explicit withAnimation here restores it.
          _ = withAnimation(.easeOut(duration: 0.2)) {
            store.send(.toggleSidebarRequested)
          }
        }
      }
    )
  }

  enum EditorToast: Equatable {
    case opened(String)
    case failed(String)
  }

  var body: some View {
    GhosttyColorSchemeSyncView {
      ZStack {
        mainSplit
        if let paletteStore = store.scope(
          state: \.commandPalette, action: \.commandPalette.presented
        ) {
          CommandPaletteView(
            store: paletteStore,
            onDismiss: { store.send(.commandPaletteToggle(nil)) }
          )
          .zIndex(100)
        }
      }
    }
  }

  private var mainSplit: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      HierarchySidebarView(
        store: store.scope(state: \.sidebar, action: \.sidebar),
        currentSelection: store.selection,
        activePendingWorktreeID: store.activePendingWorktreeID,
        revealTrigger: store.revealSelectionTrigger,
        gitHubStore: store.scope(state: \.gitHub, action: \.gitHub),
        editorStore: store.scope(state: \.editor, action: \.editor),
        agentStateStore: agentStateStore,
        onAgentStateRowTapped: { paneID in store.send(.agentState(.rowTapped(paneID))) }
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      WorktreeDetailView(
        store: store.scope(state: \.detail, action: \.detail),
        selection: store.selection,
        editorStore: store.scope(state: \.editor, action: \.editor),
        agentStateStore: agentStateStore,
        headerStore: store.scope(state: \.worktreeHeader, action: \.worktreeHeader),
        statusBarStore: store.scope(state: \.statusBar, action: \.statusBar),
        gitHubStore: store.scope(state: \.gitHub, action: \.gitHub),
        branchSwitcherStore: store.scope(state: \.branchSwitcher, action: \.branchSwitcher),
        onAddProject: { store.send(.sidebar(.toolbarAddProjectTapped)) },
        onFocusHierarchyPath: { source in store.send(.focusHierarchyPath(source)) },
        inboxBellPopoverTrigger: store.inboxBellPopoverTrigger,
        // Resolve the root-level focus id to its sidebar row each render. The
        // pending row is the source of truth for streaming output; when it
        // leaves `pendingWorktrees` (cancel / discard), this resolves to nil
        // and the detail pane falls back to the regular selection-driven
        // render without a dedicated reducer transition.
        activePendingWorktree: resolveActivePendingWorktree()
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) { editorToastOverlay }
      .sheet(
        item: $store.scope(state: \.tagManagerSheet, action: \.tagManagerSheet)
      ) { tagStore in
        TagManagerSheet(store: tagStore)
      }
    }
    .environment(hierarchyManager)
    .environment(settingsStore)
    .environment(UpdatesEnvironment.model)
    .environment(worktreeStatusMonitor)
    .environment(worktreeLocalDiffMonitor)
    .environment(notificationRollup)
    .environment(notificationStore)
    .environment(osNotifier)
    .task {
      store.send(.onLaunch)
      store.send(.worktreeHeader(.onAppear))
      store.send(.gitHub(.onAppear))
    }
    .onChange(of: store.editor.lastOpenResult) { _, new in
      guard let new else { return }
      switch new {
      case .opened(_, let displayName):
        lastEditorToast = .opened(displayName)
      case .failed(let reason):
        lastEditorToast = .failed(reason)
      }
    }
    .onChange(of: store.editor.lastProjectOverrideFailure) { _, new in
      if let reason = new {
        lastEditorToast = .failed("Override failed: \(reason)")
      }
    }
    // When the Settings window writes `defaultEditorID`, refresh the main-window
    // EditorFeature so the Header split-button dropdown rebuilds its cached
    // descriptors + globalDefault.
    .onChange(of: settingsStore.settings.general.defaultEditorID) { _, _ in
      store.send(.editor(.onAppear))
    }
    // Re-sync the live SPUUpdater whenever the Updates prefs change in-process,
    // not only through the Updates-pane picker bindings. Any other write path
    // (or a future settings entry point) would otherwise update settings.json
    // but leave the running updater on its launch-time cadence — the "set 3h,
    // app still polls daily" drift. `triggerBackgroundCheck: false` so a
    // settings edit never itself hits the network; the picker opts into an
    // immediate probe on its own.
    .onChange(of: settingsStore.settings.general) { old, new in
      guard old.updateChannel != new.updateChannel
        || old.updateCheckInterval != new.updateCheckInterval
        || old.updatesAutomaticallyCheckForUpdates != new.updatesAutomaticallyCheckForUpdates
        || old.updatesAutomaticallyDownloadUpdates != new.updatesAutomaticallyDownloadUpdates
      else { return }
      updatesClient.applyPreferences(
        new.updateChannel,
        new.updateCheckInterval,
        new.updatesAutomaticallyCheckForUpdates,
        new.updatesAutomaticallyDownloadUpdates,
        false
      )
    }
    .onDisappear {
      store.send(.onQuit)
    }
    // Project expansion is persisted on `Project.isExpanded` and pruned
    // implicitly when the Project leaves the catalog; no sidebar-side
    // expansion set to maintain.
  }

}

extension ContentView {
  /// Resolves `RootFeature.activePendingWorktreeID` to the sidebar row it
  /// references plus the parent project's display name. The Project lookup
  /// goes through the live `HierarchyManager.catalog` rather than the
  /// reducer state so the view picks up renames without a reducer round-trip.
  fileprivate func resolveActivePendingWorktree() -> WorktreeDetailView.PendingWorktreeBinding? {
    guard
      let id = store.activePendingWorktreeID,
      let pending = store.sidebar.pendingWorktrees[id: id]
    else { return nil }
    let repositoryName = hierarchyManager.catalog
      .projects.first(where: { $0.id == pending.projectID })?.name
    return WorktreeDetailView.PendingWorktreeBinding(
      pending: pending,
      repositoryName: repositoryName
    )
  }

  @ViewBuilder
  fileprivate var editorToastOverlay: some View {
    if let toast = lastEditorToast {
      toastPill(toast)
        .padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: lastEditorToast) {
          // Auto-dismiss after 2.5 s. `.task(id:)` cancels on re-entry so a second open
          // (or navigation away) doesn't get clobbered.
          try? await Task.sleep(for: .seconds(2.5))
          if !Task.isCancelled {
            await MainActor.run { lastEditorToast = nil }
          }
        }
    }
  }

  @ViewBuilder
  fileprivate func toastPill(_ toast: EditorToast) -> some View {
    switch toast {
    case .opened(let displayName):
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .accessibilityHidden(true)
          .foregroundStyle(.tint)
        Text("Opened in \(displayName)").font(.callout)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.ultraThickMaterial, in: .rect(cornerRadius: 8))
      .shadow(radius: 4, y: 2)
    case .failed(let message):
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
          .foregroundStyle(.orange)
        Text(message).font(.callout)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.ultraThickMaterial, in: .rect(cornerRadius: 8))
      .shadow(radius: 4, y: 2)
    }
  }

  // EditorError → user-facing reason mapping now lives in
  // `EditorFeature.editorErrorDescription` so TestStore observes the same string the UI
  // sees. ContentView just reads `store.editor.lastOpenResult` and renders.
}
