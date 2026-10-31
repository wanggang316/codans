import AppKit
import CodansCore
import ComposableArchitecture
import OSLog
import SwiftUI

private let autoOpenLogger = Logger(
  subsystem: "com.gumpw.codans.agentstate", category: "autoOpen"
)

/// Renders the sidebar: a sticky toolbar with "+ Add Project" and a "⋯"
/// menu; the catalog's Projects as collapsible sections with hover-revealed
/// `+` / `⋯` chrome; Worktree rows with a leading `●`/`○` selection dot;
/// a Tag chip footer pinned at the bottom safe area for filtering by Tag;
/// and empty-state + confirmation / stub-sheet presentations.
///
/// Structural data is NOT held in reducer state — the view reads the active
/// `Catalog` from `HierarchyManager` through SwiftUI's environment, so row
/// lists update whenever the underlying `@Observable` stores mutate. The
/// TCA reducer owns only local view state (expansion sets, popover / sheet /
/// confirmation payloads) and dispatches side effects through
/// `HierarchyClient` (plus delegate actions for Finder / editor open that
/// `RootFeature` routes).
struct HierarchySidebarView: View {
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  let currentSelection: HierarchySelection
  /// The creation the detail pane is following (`RootFeature.
  /// activePendingWorktreeID`). The matching pending row paints a manual
  /// accent "selected" background — pending rows carry no `.tag`, so the
  /// native List selection can't highlight them, but the sidebar must
  /// still show WHERE the focus is while the loading view is up.
  /// Nil when no creation is being followed (previews / tests included).
  var activePendingWorktreeID: PendingWorktreeID?
  /// Bumped by `RootFeature.revealCurrentWorktreeInSidebarRequested` (⌘⇧J).
  /// `.onChange(of:)` on this UUID triggers a `proxy.scrollTo` so the
  /// selected row comes back into view even when the user has scrolled
  /// elsewhere. Defaults to a fixed UUID for previews so the no-op render
  /// path is deterministic.
  var revealTrigger: UUID = UUID()
  /// Optional GitHub integration store. When non-nil, each Worktree row renders a PR
  /// badge (silent when no PR is matched) and the row hosts the PR popover. Nil in
  /// previews / tests that don't exercise the integration.
  var gitHubStore: StoreOf<GitHubFeature>?
  /// Rows the notification filter lists (`RootFeature.State.notifiedWorktreeIDs`).
  var notifiedWorktreeIDs: Set<WorktreeID> = []
  /// Optional editor store. Drives the worktree context menu's "Open in
  /// <Editor>" entry (resolved default) and "Open in" submenu (every
  /// installed editor). Nil in previews — the submenu falls back to the
  /// shared "Open in Editor" entry alone.
  var editorStore: StoreOf<EditorFeature>?
  /// AgentState registry. Drives the bottom expandable panel + the
  /// 🤖-style toggle button in the footer. Optional so previews / tests
  /// without `AppState.bringUp` wiring omit the panel and the button.
  var agentStateStore: AgentStateStore?
  /// Active workflow runs for the panel's "Workflows" group. Optional for
  /// the same reason as `agentStateStore`.
  var workflowEngine: WorkflowEngine?
  /// Row-tap dispatcher for the AgentState panel — routes to
  /// `RootFeature.agentState(.rowTapped)`. Closure (rather than direct
  /// store write) keeps Sidebar decoupled from Root.
  var onAgentStateRowTapped: (PaneID) -> Void = { _ in }
  /// Row context-menu "Hand Off…" dispatcher — routes to
  /// `RootFeature.agentState(.handOffTapped)`.
  var onAgentStateRowHandOff: (PaneID) -> Void = { _ in }
  /// Row context-menu "Run Workflow" dispatcher — routes to
  /// `RootFeature.agentState(.runWorkflowTapped)`.
  var onAgentStateRowRunWorkflow: (PaneID, String) -> Void = { _, _ in }
  /// Whether the AgentState bottom panel is currently expanded.
  /// Persisted so the footer toggle's last state survives a relaunch —
  /// users who keep the panel open during long sessions should not
  /// re-toggle it after every restart. The auto-open path in
  /// `onChange(anyAgentNeedsAttention)` still re-opens a closed panel
  /// when a fresh agent demands attention.
  ///
  /// The `@AppStorage` key keeps the legacy `activeAgents.*` string after
  /// the module was renamed to AgentState, so users' remembered panel
  /// open/height survives the rename instead of silently resetting.
  @AppStorage("activeAgents.panel.open") private var agentStatePanelOpen = false
  /// Persisted panel height. The drag handle in
  /// `AgentStateSidebarPanel` writes to this; the host clamps the
  /// rendered height to `[minHeight, 0.5 * sidebarHeight]`.
  @AppStorage("activeAgents.panel.height") private var agentStatePanelHeight: Double = 200
  /// Live sidebar height, captured via a background GeometryReader on
  /// `treeBody`. Used to clamp the AgentState panel to at most half
  /// the sidebar so the worktree list always retains the other half.
  /// Defaults to a sensible value so the first render before the
  /// background measure lands doesn't pop a too-tall panel.
  @State private var sidebarHeightObservation: Double = 600

  /// Min / max height bounds for the AgentState panel. Kept as a
  /// type-level constant so both `AgentStateSidebarPanel`'s own clamp
  /// and the List's bottom spacer-row height share one source.
  private static let agentStatePanelMinHeight: Double = 140

  /// Effective panel height after clamping to `[minHeight, 0.5 *
  /// sidebarHeight]`. Mirrors the clamp inside
  /// `AgentStateSidebarPanel.clampedHeight` so the spacer row inside
  /// the List can reserve exactly the height the panel occupies. Note:
  /// `.contentMargins(.bottom, _, for: .scrollContent)` is the
  /// ScrollView-native modifier for this purpose but `List(.sidebar)`
  /// on macOS 26 ignores it — see commit 6c1c3631. The invisible
  /// `Color.clear` row inside `treeBody`'s List is the workaround.
  private var clampedAgentStatePanelHeight: Double {
    let minH = Self.agentStatePanelMinHeight
    let maxH = max(minH, sidebarHeightObservation * 0.5)
    return min(max(agentStatePanelHeight, minH), maxH)
  }
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(WorktreeStatusMonitor.self) private var worktreeStatusMonitor
  @Environment(WorktreeLocalDiffMonitor.self) private var worktreeLocalDiffMonitor
  @Environment(NotificationStore.self) private var inbox: NotificationStore?

  /// Tracks whether the `.command` modifier is currently pressed. When held the sidebar
  /// reveals per-row `⌃N` hotkey hints (and the matching `⌃1`–`⌃9` / `⌃0` bindings).
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts
  /// Gates the decorative name shimmer on mid-archive / mid-delete rows —
  /// the non-animated signals (phase icon, phase line + its stage value)
  /// carry the state on their own. Mirrors `PendingWorktreeRow`'s gating.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// App-wide "is a newer version available?" mirror, injected by
  /// `ContentView`. Drives the persistent update reminder in the sidebar
  /// toolbar. Survives "Skip This Version" because it is derived from
  /// appcast-vs-current version comparison rather than Sparkle's skip state.
  @Environment(UpdatesModel.self) private var updatesModel
  /// Sparkle seam. The reminder button triggers a manual check, which
  /// re-surfaces the update modal even for a version the user previously
  /// skipped ("...unless they initiate an update check themselves").
  @Dependency(UpdatesClient.self) private var updatesClient

  /// Bridges TCA-owned `currentSelection.worktreeID` ↔ SwiftUI's native
  /// `List(selection:)`. Native binding is what gets us Finder-/Mail-style
  /// selection chrome for free: emphasized blue + white text when the
  /// sidebar holds first-responder, unemphasized grey + dark text the
  /// instant focus moves to a terminal pane (or anywhere else inside or
  /// outside the window). `NSTableView.selectionHighlightStyle = .sourceList`
  /// owns that transition; we just have to feed it a selection binding
  /// instead of painting `.listRowBackground` ourselves. Setter dispatches
  /// the existing `worktreeRowTapped` action so all the side-effects
  /// (selectedProjectID propagation, hooks, etc.) fire identically to a tap.
  private var nativeSelectionBinding: Binding<WorktreeID?> {
    Binding(
      get: {
        // Read live from `hierarchyManager.catalog` rather than from the
        // `currentSelection` prop. The prop trails state by one render
        // cycle (parent feature observes a stream → re-renders → re-passes
        // the value), so cross-Project clicks see a one-frame revert: the
        // setter mutates the manager synchronously, but on the immediate
        // next render `currentSelection` is still the previous value.
        // NSTableView snaps the highlight back to the old row for one
        // frame before the prop catches up — visible as the flicker
        // (A.main → B.main → A.main → B.main) the user reported. Reading
        // the @Observable manager directly closes the gap; mutations from
        // `worktreeRowTapped` land in the same tick the binding's `get`
        // is re-evaluated.
        let catalog = hierarchyManager.catalog
        guard let pid = catalog.selectedProjectID,
          let project = catalog.projects.first(where: { $0.id == pid })
        else { return nil }
        return project.selectedWorktreeID
      },
      set: { newValue in
        guard let newValue else { return }
        guard
          let project = hierarchyManager.catalog.projects
            .first(where: { project in
              project.worktrees.contains(where: { $0.id == newValue })
            })
        else { return }
        // Drop the no-op guard. Cross-Project clicks where the same
        // WorktreeID happens to be selected in both Projects (rare but
        // possible after a copy / reattach) would otherwise be filtered
        // out and the active Project would never flip.
        store.send(.worktreeRowTapped(newValue, inProject: project.id))
      }
    )
  }

  /// Flips to true once the outline view's own indentation has been zeroed.
  /// Until then the List renders at `opacity(0)` so the user never sees the
  /// per-level indent the AppKit introspection retries paper over.
  @State private var sidebarIndentReady = false

  /// Heterogeneous rows under a Project row, in render order: main → pinned →
  /// pending → unpinned (`Project.childWorktrees` plus the Project's pending
  /// creations). `pendings` is filtered to the given project (caller passes
  /// the full sidebar-wide list). Used by ordering tests; the production view
  /// splits the segments across separate ForEach blocks so each can own its
  /// own .onMove.
  static func orderedSidebarRows(
    project: Project,
    pendings: [PendingWorktree]
  ) -> [SidebarRow] {
    let children = project.childWorktrees
    let main = children.filter { $0.path == project.rootPath }
    let pinned = children.filter { $0.isPinned && $0.path != project.rootPath }
    let rest = children.filter { !$0.isPinned && $0.path != project.rootPath }
    let projectPending = pendings.filter { $0.projectID == project.id }
    return main.map(SidebarRow.worktree)
      + pinned.map(SidebarRow.worktree)
      + projectPending.map(SidebarRow.pending)
      + rest.map(SidebarRow.worktree)
  }

  /// The selected row when it belongs to a Workspace, read live like
  /// `nativeSelectionBinding`.
  private var selectedWorkspaceRow: SidebarRowAddress? {
    let catalog = hierarchyManager.catalog
    guard let project = catalog.projects.first(where: { $0.id == catalog.selectedProjectID }),
      project.isWorkspace, let worktreeID = project.selectedWorktreeID
    else { return nil }
    return SidebarRowAddress(projectID: project.id, worktreeID: worktreeID)
  }

  private var pullRequestWorktreeIDs: Set<WorktreeID> {
    guard let gitHubStore else { return [] }
    return Set(gitHubStore.snapshots.keys)
  }

  var body: some View {
    let catalog = hierarchyManager.catalog
    // Use the full catalog so a tag filter with no matches does not hide
    // the panel. Availability never changes the persisted open preference.
    let agentStatePanelAvailable = !catalog.projects.isEmpty && agentStateStore != nil
    let agentStatePanelVisible = agentStatePanelAvailable && agentStatePanelOpen
    // Filter the project list by the catalog's active tag filter.
    // OR semantics on `.tags(set)`; `.untagged` shows projects with no
    // tags; `.all` is the no-op default.
    let visibleProjects = catalog.sidebarProjects(
      pullRequestWorktreeIDs: pullRequestWorktreeIDs, notifiedWorktreeIDs: notifiedWorktreeIDs)
    let untaggedExists = catalog.projects.contains { $0.tagIDs.isEmpty }

    let isReordering = store.isReorderingProjects
    // The reorder session always shows the full, unfiltered Project set:
    // a filtered subset would desync `ForEach.onMove`'s indices from the
    // `catalog.projects` array that `reorderProjects` mutates.
    let displayedProjects = isReordering ? catalog.sorted(catalog.projects) : visibleProjects

    // Sidebar body: the upper ZStack is the only area the
    // AgentState panel may draw into. Clipping this region is
    // essential on macOS 26: List overlays can paint past their
    // allocated frame while a bottom move transition is entering, so
    // an unclipped panel visually covers the footer sibling below.
    // With the panel mounted inside this clipped slot, its bottom
    // transition is cut at the footer's top edge and reads as sliding
    // up from beneath the fixed footer.
    VStack(spacing: 0) {
      if let block = store.gitEnvironment?.block {
        GitEnvironmentBanner(block: block) {
          store.send(.gitEnvironmentRecheckTapped)
        }
      }
      SidebarFilterBar(
        selection: catalog.sidebarFilter,
        hasUnreadNotifications: (inbox?.unreadCount ?? 0) > 0,
        onSelect: { store.send(.sidebarFilterSelected($0)) },
        onMarkAllNotificationsRead: { inbox?.markAllRead() }
      )
      .disabled(isReordering)
      if isReordering {
        reorderBanner
      }
      ZStack(alignment: .bottom) {
        treeBody(
          projects: displayedProjects,
          isReordering: isReordering,
          bottomInsetHeight: agentStatePanelVisible ? clampedAgentStatePanelHeight : 0
        )
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: SidebarHeightPreferenceKey.self,
              value: proxy.size.height
            )
          }
        )
        .onPreferenceChange(SidebarHeightPreferenceKey.self) { newHeight in
          sidebarHeightObservation = newHeight
        }
        // The panel card is a translucent well with gaps around it, so it
        // cannot hide the rows that scroll under it. Cut the list off at
        // the panel's top edge instead.
        .mask(alignment: .top) {
          Rectangle()
            .padding(.bottom, agentStatePanelVisible ? clampedAgentStatePanelHeight : 0)
        }

        if agentStatePanelVisible, let registry = agentStateStore {
          AgentStateSidebarPanel(
            registry: registry,
            resolveSourcePath: { paneID in
              resolveAgentStateSourcePath(
                paneID: paneID,
                catalog: hierarchyManager.catalog
              )
            },
            focusedPaneID: currentlyFocusedPaneID(),
            onTapRow: { paneID in
              // Panel stays open after a row tap — the user often
              // fan-jumps between agents and re-opening the panel
              // each time is friction.
              onAgentStateRowTapped(paneID)
            },
            onClose: {
              withAnimation(.easeOut(duration: 0.18)) {
                agentStatePanelOpen = false
              }
            },
            onHandOffRow: { paneID in onAgentStateRowHandOff(paneID) },
            onRunWorkflowRow: { paneID, workflowID in onAgentStateRowRunWorkflow(paneID, workflowID) },
            workflowEngine: workflowEngine,
            height: $agentStatePanelHeight,
            minHeight: Self.agentStatePanelMinHeight,
            maxHeight: max(Self.agentStatePanelMinHeight, sidebarHeightObservation * 0.5)
          )
          .zIndex(1)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .clipped()
      // `agentStatePanelOpen` is backed by `@AppStorage`, whose
      // change notification is delivered through `UserDefaults` and
      // does not preserve the SwiftUI Transaction set up by
      // `withAnimation { ... }` at the mutation site. Attaching an
      // explicit `.animation(_:value:)` here re-establishes the
      // transition so the panel slides in/out instead of popping.
      .animation(.easeOut(duration: 0.18), value: agentStatePanelVisible)

      TagFilterPopoverFooter(
        tags: catalog.tags,
        activeFilter: catalog.activeTagFilter,
        showUntaggedChip: untaggedExists,
        onAllTapped: { store.send(.allChipTapped) },
        onTagTapped: { store.send(.tagChipTapped($0)) },
        onUntaggedTapped: { store.send(.untaggedChipTapped) },
        onEditTagsTapped: { store.send(.delegate(.openTagManager)) },
        onRefreshTapped: { store.send(.refreshAllProjectsTapped) },
        onReorderToggle: {
          store.send(store.isReorderingProjects ? .endProjectReorder : .beginProjectReorder)
        },
        isReordering: isReordering,
        onAgentStateTapped: !agentStatePanelAvailable
          ? nil
          : {
            withAnimation(.easeOut(duration: 0.18)) {
              agentStatePanelOpen.toggle()
            }
          },
        agentStatePanelOpen: agentStatePanelVisible
      )
      .zIndex(2)
    }
    // One-shot `git --version` probe. The probe actor caches, so the repeated
    // `.task` firings a sidebar sees over a session collapse to a single
    // subprocess; only the banner's Recheck busts that cache.
    .task { store.send(.gitEnvironmentProbeRequested) }
    // A Workspace row selected from anywhere (CLI, palette, restored
    // selection, notification) inside a collapsed group opens that group.
    .onChange(of: selectedWorkspaceRow, initial: true) { _, address in
      guard let address else { return }
      store.send(.revealWorkspaceRow(address.worktreeID, inProject: address.projectID))
    }
    // Auto-open the Agents View panel on the rising edge into "any
    // bound agent is loading" — but only when the user has the
    // Settings → General toggle on. We do NOT auto-close when the
    // signal falls back to false; the user keeps the panel open
    // until they explicitly close it via the footer toggle. The
    // observed value is a Bool so SwiftUI's `.onChange` fires only
    // on real transitions (not every dict mutation).
    .onChange(of: agentStatePanelAvailable && anyAgentNeedsAttention) { oldValue, newValue in
      autoOpenLogger.debug(
        "anyAgentNeedsAttention transition \(oldValue, privacy: .public)->\(newValue, privacy: .public) autoOpen=\(self.settingsStore.settings.general.agentsViewAutoOpen, privacy: .public) panelOpen=\(self.agentStatePanelOpen, privacy: .public)"
      )
      guard newValue,
        settingsStore.settings.general.agentsViewAutoOpen,
        !agentStatePanelOpen
      else { return }
      autoOpenLogger.info("auto-opening Agents View panel")
      withAnimation(.easeOut(duration: 0.18)) {
        agentStatePanelOpen = true
      }
    }
    .toolbar { sidebarToolbarContent }
    .modifier(SidebarSheetPresenter(store: store))
    .modifier(RemoteConnectionSheetPresenter(store: store))
    .modifier(CreateWorkspaceSheetPresenter(store: store))
    .modifier(WorkspaceRemovalDialogs(store: store))
    .confirmationDialog(
      worktreeRemovalTitle,
      isPresented: Binding(
        get: { store.pendingWorktreeRemoval != nil },
        set: { if !$0 { store.send(.worktreeRemoveCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Worktree", role: .destructive) {
        store.send(.worktreeRemoveConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.worktreeRemoveCancelled)
      }
    } message: {
      Text(worktreeRemovalMessage)
    }
    .confirmationDialog(
      projectRemovalTitle,
      isPresented: Binding(
        get: { store.pendingProjectRemoval != nil },
        set: { if !$0 { store.send(.projectRemoveCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Project", role: .destructive) {
        store.send(.projectRemoveConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.projectRemoveCancelled)
      }
    } message: {
      Text(projectRemovalMessage)
    }
    // First-archive explainer (once per session).
    .confirmationDialog(
      "Archive this Worktree?",
      isPresented: Binding(
        get: { store.pendingArchiveExplainer != nil },
        set: { if !$0 { store.send(.worktreeArchiveCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Archive") {
        store.send(.worktreeArchiveConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.worktreeArchiveCancelled)
      }
    } message: {
      Text(
        "Files and branch are kept. Find it later under “Archived Worktrees” in the Project menu.")
    }
    // Batch "Archive All Merged Worktrees" confirmation (Project ⋯ menu).
    .confirmationDialog(
      archiveAllMergedTitle,
      isPresented: Binding(
        get: { store.pendingArchiveAllMerged != nil },
        set: { if !$0 { store.send(.projectArchiveAllMergedCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Archive") {
        store.send(.projectArchiveAllMergedConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.projectArchiveAllMergedCancelled)
      }
    } message: {
      Text(
        "Files and branches are kept. Find them later under “Archived Worktrees” in the Project menu."
      )
    }
    // Batch "Remove All Merged Worktrees" confirmation (Project ⋯ menu).
    .confirmationDialog(
      removeAllMergedTitle,
      isPresented: Binding(
        get: { store.pendingRemoveAllMerged != nil },
        set: { if !$0 { store.send(.projectRemoveAllMergedCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Worktrees", role: .destructive) {
        store.send(.projectRemoveAllMergedConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.projectRemoveAllMergedCancelled)
      }
    } message: {
      Text(
        "Closes all panes and deletes each Worktree directory, including any uncommitted changes. This cannot be undone."
      )
    }
    // Prune toast.
    .alert(
      "Prune complete",
      isPresented: Binding(
        get: { store.pruneToast != nil },
        set: { if !$0 { store.send(.pruneToastDismissed) } }
      )
    ) {
      Button("OK") { store.send(.pruneToastDismissed) }
    } message: {
      Text(store.pruneToast ?? "")
    }
    // Lifecycle wrapper failure (archive flag flip / delete teardown).
    .alert(
      "Worktree action failed",
      isPresented: Binding(
        get: { store.lifecycleErrorToast != nil },
        set: { if !$0 { store.send(.lifecycleErrorToastDismissed) } }
      )
    ) {
      Button("OK") { store.send(.lifecycleErrorToastDismissed) }
    } message: {
      Text(store.lifecycleErrorToast ?? "")
    }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var sidebarToolbarContent: some ToolbarContent {
    // Persistent update reminder, left of "Add Project". Visible whenever the
    // appcast advertises a newer build for the active channel — and kept
    // visible after "Skip This Version" — so the user always knows an update
    // is waiting. Clicking runs a manual check, which re-opens Sparkle's
    // update flow even for a previously skipped version.
    if let available = updatesModel.available {
      ToolbarItem(placement: .primaryAction) {
        Button {
          updatesClient.checkNow()
        } label: {
          // Plain blue download glyph at the toolbar's uniform size, with the
          // standard toolbar-button hover (same as `+` / toggle). The blue tint
          // is what sets the update reminder apart from the neutral glyphs.
          Label("Update \(available.displayVersion)", systemImage: "arrow.down.circle.fill")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.blue)
        .help("Update \(available.displayVersion)")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      Menu {
        addProjectMenuItems
      } label: {
        Label("Add Project", systemImage: "plus")
          // Pin the glyph to the scheme-derived label color instead of letting
          // it inherit the toolbar item's implicit content color: after a
          // dark→light appearance change the implicit one has been observed
          // staying on the dark-mode white, which renders the "+" invisible on
          // light chrome while every sibling already reads as light.
          .foregroundStyle(.primary)
      }
      .menuIndicator(.hidden)
      // No chord on the button: `+` only opens the menu. The `.addProject`
      // binding belongs to "Open Project…", the first item, which shows it
      // as its key equivalent.
      .help("Add Project")
    }
  }

  /// Shared Add Project menu: open an existing local folder (the current
  /// flow, also bound to the `.addProject` shortcut), clone a remote
  /// repository into a new local path, or connect to a server over SSH.
  @ViewBuilder
  private var addProjectMenuItems: some View {
    Button {
      store.send(.toolbarAddProjectTapped)
    } label: {
      Label("Open Project…", systemImage: "folder")
    }
    .appKeyboardShortcut(.addProject, in: resolvedShortcuts)
    Button {
      store.send(.cloneRepoTapped)
    } label: {
      Label("Clone Repository…", systemImage: "square.and.arrow.down.on.square")
    }
    Button {
      store.send(.connectServerTapped)
    } label: {
      Label("Connect to Server…", systemImage: "tv.badge.wifi")
    }
    Button {
      store.send(.newWorkspaceTapped)
    } label: {
      Label("New Workspace…", systemImage: "square.stack.3d.up")
    }
  }

  // MARK: - Tree

  @ViewBuilder
  private func treeBody(projects: [Project], isReordering: Bool, bottomInsetHeight: Double)
    -> some View
  {
    if projects.isEmpty && !hierarchyManager.catalog.projects.isEmpty {
      VStack(spacing: 8) {
        Text("No matching projects").font(.headline)
        Text("Choose another filter to see your projects.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if projects.isEmpty {
      emptyState
    } else {
      // `⌃1`…`⌃9` plus `⌃0` (10th slot) go to the first ten selectable rows on
      // screen, top-down (`Catalog.sidebarSelectionOrder`: Project rows that
      // stand for a folder, and the rows of expanded Projects); matching hints
      // show while ⌘ is held. Archived, pending, and collapsed rows claim none.
      let hotkeyIndex: [WorktreeID: Int] = Dictionary(
        hierarchyManager.catalog.sidebarSelectionOrder(
          pullRequestWorktreeIDs: pullRequestWorktreeIDs, notifiedWorktreeIDs: notifiedWorktreeIDs)
          .prefix(10).enumerated()
          .map { ($0.element.worktreeID, $0.offset) },
        uniquingKeysWith: { first, _ in first })
      // List + .listStyle(.sidebar) with NO `.scrollIndicators(.*)` modifier.
      // On macOS 26 / NavigationSplitView sidebar columns, both `.hidden` and
      // `.never` silently collapse the List's top titlebar safe area — the
      // first row then draws at y=0, overlapping with the traffic lights.
      // Accepting the scroller-when-needed trade-off; the default indicator
      // posture is fine for source-list-style sidebars.
      ScrollViewReader { proxy in
        List(selection: nativeSelectionBinding) {
          if isReordering {
            // Reorder session: one draggable header-only row per Project
            // (worktrees hidden). A single row per ForEach element is what
            // makes `.onMove` valid here — it forwards to `reorderProjects`,
            // which moves `catalog.projects` and restamps `manualOrder`.
            ForEach(projects) { project in
              reorderProjectRow(project)
            }
            .onMove { source, destination in
              store.send(.reorderProjects(from: source, to: destination))
            }
          } else {
            ForEach(projects) { project in
              projectSection(project, hotkeyIndex: hotkeyIndex)
            }
          }
        }
        .listStyle(.sidebar)
        // Bottom safe-area-inset sized to the live AgentState panel
        // height (when expanded). Unlike a spacer row, the inset
        // shrinks the List's underlying `NSScrollView` safe area — so
        // both the scrollable content AND the overlay scroller stop
        // above the panel. A spacer row would instead inflate
        // content-size and leave the scroller trailing behind the
        // panel (its drag range covers the spacer's blank tail and
        // the scroller's track is still the full List height).
        // `.contentMargins(.bottom, _, for: .scrollContent)` is the
        // ScrollView-native version but `List(.sidebar)` on macOS 26
        // ignores it — see 6c1c3631. We don't worry about
        // bleed-through here because the panel (a ZStack sibling) is
        // a translucent popover material; rows showing through the
        // inset region are exactly the behind-glass effect we want.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if bottomInsetHeight > 0 {
            Color.clear
              .frame(height: bottomInsetHeight)
              .accessibilityHidden(true)
          }
        }
        // Hide the List's own opaque content background so the sidebar
        // column's system glass overlay shows through — same surface
        // the floating sidebar samples, so the footer below (rendered
        // as a sibling in the outer VStack) reads as one continuous
        // material with the list above it.
        .scrollContentBackground(.hidden)
        .opacity(sidebarIndentReady ? 1 : 0)
        .background(SidebarIndentZeroer(onReady: { sidebarIndentReady = true }))
        .onChange(of: revealTrigger) { _, _ in
          // Resolve the reveal target from the *live* catalog, not the
          // `currentSelection` prop — the prop trails state by a render
          // cycle (see `nativeSelectionBinding`). Palette-driven reveals bump
          // this trigger in the same tick they switch worktrees (and may
          // expand a collapsed parent), so the prop still points at the
          // previous, already-visible row and `scrollTo` looks like a no-op.
          // Defer one runloop so the selection mutation and any just-expanded
          // rows have landed before we scroll.
          Task { @MainActor in
            let catalog = hierarchyManager.catalog
            guard
              let projectID = catalog.selectedProjectID,
              let worktreeID = catalog.projects
                .first(where: { $0.id == projectID })?.selectedWorktreeID
            else { return }
            withAnimation { proxy.scrollTo(worktreeID, anchor: .center) }
          }
        }
      }
    }
  }

  /// empty-state copy is English and reflects the actual
  /// affordances the user has — the `.addProject` chord (resolved live
  /// against `resolvedShortcuts` so a rebind keeps the hint accurate)
  /// and the toolbar `+` button. Button label uses "Open Project" to
  /// match the user-facing verb the picker presents.
  private var emptyState: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "tray")
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      emptyStateHint
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Menu {
        addProjectMenuItems
      } label: {
        Label("Open Project", systemImage: "plus")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.borderedProminent)
      .fixedSize()
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  /// Hint text above the Open Project button. Resolves `.addProject` from
  /// the live shortcut registry so the displayed chord follows any user
  /// rebinding; falls back to the schema default before the registry has
  /// loaded; drops the chord clause entirely if the user disabled the
  /// binding.
  @ViewBuilder
  private var emptyStateHint: some View {
    if let chord = addProjectChord {
      Text(
        "Press \(Text(chord).monospaced()) or click \(Text("+").bold()) to open a project (repository or folder)."
      )
    } else {
      Text("Click \(Text("+").bold()) to open a project (repository or folder).")
    }
  }

  private var addProjectChord: String? {
    if let resolved = resolvedShortcuts[.addProject], resolved.isEnabled,
      let binding = resolved.binding
    {
      return ShortcutDisplay.chord(for: binding)
    }
    if let fallback = ShortcutSchema.app.entry(for: .addProject)?.defaultBinding {
      return ShortcutDisplay.chord(for: fallback)
    }
    return nil
  }

  // MARK: - Project reorder session

  /// Inline edit-mode banner shown above the list while reordering. Tells
  /// the user how to act and carries the only way out of the session.
  private var reorderBanner: some View {
    HStack(spacing: 8) {
      Text("Drag to reorder projects")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button("Done") { store.send(.endProjectReorder) }
        .keyboardShortcut(.defaultAction)
        .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// Header-only Project row rendered during the reorder session: a
  /// leading drag handle plus the Project name. No disclosure chevron,
  /// hover chrome, or selection — the row exists only to be dragged.
  private func reorderProjectRow(_ project: Project) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      // The reorder sheet strips the row to a handle and a name; the icon
      // earns its place here because scanning a drag list is exactly when
      // recognizing a Project at a glance matters.
      ProjectIconView(icon: project.icon, color: project.color)
      Text(project.name)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .accessibilityLabel(project.name)
  }

  // MARK: - Project section

  private func projectSection(
    _ project: Project,
    hotkeyIndex: [WorktreeID: Int]
  ) -> some View {
    let isExpanded = project.isExpanded
    return Group {
      switch project.loadState {
      case .failed(let reason):
        FailedProjectRow(
          name: project.name,
          rootPath: project.rootPath,
          remoteAuthority: project.remoteHost?.displayAuthority,
          reason: reason,
          retry: {
            store.send(.retryProjectTapped(projectID: project.id))
          },
          remove: {
            store.send(
              .projectRemoveTapped(
                projectID: project.id,
                name: project.name
              ))
          }
        )
        // Same row metrics as the healthy Project header below — without
        // them the failed row falls back to the sidebar's default insets and
        // sits at a different indent than its siblings.
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      case .loading, .ready:
        projectRow(project, hotkeySlot: project.rowWorktree.flatMap { hotkeyIndex[$0.id] })
        if isExpanded, project.isWorkspace {
          workspaceRows(project, hotkeyIndex: hotkeyIndex)
        } else if isExpanded {
          // Render the four segments individually so pinned and unpinned
          // each own their own ForEach + .onMove (per design doc §渲染合并
          // / 拖拽). Pending rows render in source order between pinned
          // and unpinned; main and pending segments do not admit reorder.
          let children = project.childWorktrees
          let mainRows = children.filter { $0.path == project.rootPath }
          let pinnedRows = children.filter { $0.isPinned && $0.path != project.rootPath }
          let unpinnedRows = children.filter { !$0.isPinned && $0.path != project.rootPath }
          // The live-match filters show a subset of each segment, so its
          // indices cannot drive a reorder.
          let isLiveMatchFilter = [SidebarFilter.notifications, .pullRequests]
            .contains(hierarchyManager.catalog.sidebarFilter)
          let pendingRows = store.pendingWorktrees.filter {
            $0.projectID == project.id && !isLiveMatchFilter
          }
          ForEach(mainRows) { worktree in
            worktreeRow(worktree, in: project, hotkeySlot: hotkeyIndex[worktree.id])
          }
          ForEach(pinnedRows) { worktree in
            worktreeRow(worktree, in: project, hotkeySlot: hotkeyIndex[worktree.id])
              .moveDisabled(isLiveMatchFilter)
          }
          .onMove { source, destination in
            guard !isLiveMatchFilter else { return }
            store.send(
              .reorderWorktrees(
                projectID: project.id,
                segment: .pinned, from: source, to: destination
              )
            )
          }
          ForEach(pendingRows) { pending in
            pendingRow(pending)
          }
          ForEach(unpinnedRows) { worktree in
            worktreeRow(worktree, in: project, hotkeySlot: hotkeyIndex[worktree.id])
              .moveDisabled(isLiveMatchFilter)
          }
          .onMove { source, destination in
            guard !isLiveMatchFilter else { return }
            store.send(
              .reorderWorktrees(
                projectID: project.id,
                segment: .unpinned, from: source, to: destination
              )
            )
          }
        }
      }
    }
  }

  // MARK: - Project row

  /// A Project's own row. When the Project stands for a folder of its own
  /// (`Project.rowWorktree`: a plain folder, a remote folder, a workspace),
  /// the row is that folder: selecting it opens the folder the way a worktree
  /// row opens a worktree, and only the chevron opens and closes the rows
  /// under it. A git Project's row is not selectable: a click anywhere on it
  /// opens or closes its worktrees, as the chevron does.
  ///
  /// The row and the rows under it are separate sibling List rows.
  /// DisclosureGroup used to nest the worktree rows inside the Project row —
  /// that made AppKit animate the single wrapping row's height on every
  /// expand / collapse, visibly jittering the Project name. Siblings let
  /// NSTableView handle expansion as plain row insert / remove instead.
  @ViewBuilder
  private func projectRow(_ project: Project, hotkeySlot: Int?) -> some View {
    let toggleExpansion = {
      var txn = Transaction()
      txn.disablesAnimations = true
      _ = withTransaction(txn) {
        store.send(.toggleProjectExpansion(project.id))
      }
    }
    if let root = project.rowWorktree {
      let hotkeyNumber = hotkeySlot.map { $0 + 1 }
      ProjectHeaderRow(
        project: project,
        store: store,
        gitHubStore: gitHubStore,
        rowWorktree: root,
        isRowSelected: currentSelection.worktreeID == root.id,
        agentStateStore: agentStateStore,
        hotkeyHint: commandKeyObserver.isCommandHeld ? hotkeyNumber : nil,
        onToggleExpansion: toggleExpansion
      ) {
        runScriptPingAccessory(for: root, in: project)
      }
      .background(alignment: .topLeading) {
        hotkeyChord(hotkeyNumber, worktreeID: root.id, projectID: project.id)
      }
      // Tagged like a worktree row: the native List selection paints its
      // highlight and arrow keys stop on it. `.id` is what a reveal scrolls to.
      .tag(root.id)
      .id(root.id)
      .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0))
      .listRowSeparator(.hidden)
      .contextMenu { worktreeContextMenu(worktree: root, project: project) }
    } else {
      Button(action: toggleExpansion) {
        ProjectHeaderRow(
          project: project,
          store: store,
          gitHubStore: gitHubStore,
          onToggleExpansion: toggleExpansion
        ) {
          EmptyView()
        }
      }
      .buttonStyle(.plain)
      // The Workspace header's `+` and `⋯` show only on hover, which also
      // hides them from accessibility; the row offers their entries.
      .accessibilityActions {
        if project.isWorkspace {
          Button("New Group") { store.send(.workspaceNewGroupTapped(projectID: project.id)) }
          Button("Add Project") { store.send(.workspaceAddProjectTapped(projectID: project.id)) }
          Button("Workspace Settings") { store.send(.projectSettingsTapped(projectID: project.id)) }
          Button("Remove Workspace") {
            store.send(.workspaceRemoveTapped(projectID: project.id, name: project.name))
          }
        }
      }
      .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }

  // MARK: - Workspace rows

  /// The rows under an expanded Workspace header: each group, followed by
  /// the references or members of an open group. Flat sibling List rows,
  /// like a Project's worktree rows, so a group opens as plain row inserts.
  private func workspaceRows(_ project: Project, hotkeyIndex: [WorktreeID: Int]) -> some View {
    ForEach(project.workspaceSidebarRows, id: \.listID) { row in
      switch row {
      case .group(let group, let terminal):
        workspaceGroupRow(
          group, terminal: terminal, in: project, hotkeySlot: terminal.flatMap { hotkeyIndex[$0.id] })
      case .member(let worktree, _):
        worktreeRow(worktree, in: project, hotkeySlot: hotkeyIndex[worktree.id], indent: 28)
      }
    }
  }

  /// A group row. Selecting it selects the group directory's row (List tag
  /// = the terminal row), so the group opens a terminal like any row; only
  /// the chevron opens and closes the group.
  @ViewBuilder
  private func workspaceGroupRow(
    _ group: WorkspaceGroupRecord, terminal: Worktree?, in project: Project, hotkeySlot: Int?
  ) -> some View {
    let hotkeyNumber = hotkeySlot.map { $0 + 1 }
    let toggleExpansion = {
      var txn = Transaction()
      txn.disablesAnimations = true
      _ = withTransaction(txn) {
        store.send(.toggleWorkspaceGroupExpansion(projectID: project.id, groupID: group.id))
      }
    }
    let row = WorkspaceGroupRow(
      group: group,
      terminal: terminal,
      summary: project.workspaceGroupSummary(group.id),
      pullRequestSummary: pullRequestSummary(over: project.workspaceGroupMembers(group.id)),
      isSelected: terminal.map { currentSelection.worktreeID == $0.id } ?? false,
      agentStateStore: agentStateStore,
      hotkeyHint: commandKeyObserver.isCommandHeld ? hotkeyNumber : nil,
      deletionFailures: store.workspaceGroupDeletionFailures[group.id] ?? [],
      onToggleExpansion: toggleExpansion,
      onRetryDeletion: {
        store.send(.deleteGroupTapped(projectID: project.id, groupID: group.id))
      },
      accessory: {
        if let terminal {
          runScriptPingAccessory(for: terminal, in: project)
        }
      }
    )
    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 0))
    .listRowSeparator(.hidden)
    if let terminal {
      row
        .background(alignment: .topLeading) {
          hotkeyChord(hotkeyNumber, worktreeID: terminal.id, projectID: project.id)
        }
        .tag(terminal.id)
        .id(terminal.id)
        .contextMenu { worktreeContextMenu(worktree: terminal, project: project) }
    } else {
      // The reconcile has not added the group directory's row yet: nothing
      // to select or open.
      row.listRowBackground(Color.clear)
    }
  }

  /// Open and merged pull-request counts over `rows`, nil when nothing is
  /// known yet: "3 PRs · 1 merged".
  private func pullRequestSummary(over rows: [Worktree]) -> String? {
    guard let gitHubStore else { return nil }
    let snapshots = rows.compactMap { gitHubStore.snapshots[$0.id] }
    guard !snapshots.isEmpty else { return nil }
    let merged = snapshots.filter { $0.state == .merged }.count
    let open = snapshots.count - merged
    var parts: [String] = []
    if open > 0 { parts.append(open == 1 ? "1 PR" : "\(open) PRs") }
    if merged > 0 { parts.append("\(merged) merged") }
    return parts.joined(separator: " · ")
  }

  /// The per-row hotkey still requires a Button to bind to. Mounted as a 0×0
  /// invisible background so the shortcut lives in the responder chain
  /// without painting pixels or competing with List's hit-test for clicks
  /// (zero frame == zero hit area). The chord itself comes from the shortcut
  /// registry — defaults are ⌃1..⌃9 / ⌃0 but a user rebind takes effect here
  /// without restart.
  @ViewBuilder
  private func hotkeyChord(
    _ hotkeyNumber: Int?, worktreeID: WorktreeID, projectID: ProjectID
  ) -> some View {
    if let hotkeyNumber, let commandID = CommandID.selectWorktreeAt(index: hotkeyNumber) {
      Button {
        store.send(.worktreeRowTapped(worktreeID, inProject: projectID))
      } label: {
        EmptyView()
      }
      .appKeyboardShortcut(commandID, in: resolvedShortcuts)
      .frame(width: 0, height: 0)
      .opacity(0)
      .accessibilityHidden(true)
    }
  }

  // MARK: - Pending row

  /// Wires task03's `PendingWorktreeRow` into the segment ForEach with
  /// Cancel / Retry / Discard handlers dispatched to the lifecycle reducer.
  @ViewBuilder
  private func pendingRow(_ pending: PendingWorktree) -> some View {
    let isHighlighted = pending.id == activePendingWorktreeID
    PendingWorktreeRow(
      pending: pending,
      isHighlighted: isHighlighted,
      onCancel: { store.send(.pendingWorktreeCancelTapped(pending.id)) },
      onRetry: { store.send(.pendingWorktreeRetryTapped(pending.id)) },
      onDiscard: { store.send(.pendingWorktreeDiscardTapped(pending.id)) }
    )
    // Pending rows carry no `.tag`, so the native List selection can't
    // bring the user back to a creation they navigated away from — this
    // gesture is that way back (RootFeature re-arms the loading focus).
    // Right-click still opens the row's context menu. `.isButton` tells
    // assistive tech the row is activatable despite not being a Button.
    .onTapGesture { store.send(.pendingWorktreeRowTapped(pending.id)) }
    .accessibilityAddTraits(.isButton)
    // Match the worktree row's `listRowInsets` so the spinner + name line up
    // with sibling worktree rows. Without this the row renders flush-left:
    // the child indent lives in `leading: 14` (see `worktreeRow`), not in
    // the outline view, whose own indentation is zeroed.
    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 0))
    .listRowSeparator(.hidden)
    // Manual "selected" pill while the detail pane follows this creation.
    // Approximates the native source-list emphasized selection (accent
    // fill, rounded, inset from the row edges); `PendingWorktreeRow` flips
    // its content to the light selected-row tones via `isHighlighted`.
    .listRowBackground(
      Group {
        if isHighlighted {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor)
            .padding(.horizontal, 4)
        }
      }
    )
  }

  // MARK: - Worktree row

  /// `indent` is the row's leading inset: 14 under a Project, 28 under a
  /// Workspace group.
  private func worktreeRow(
    _ worktree: Worktree,
    in project: Project,
    hotkeySlot: Int?,
    indent: CGFloat = 14
  ) -> some View {
    let isSelected = currentSelection.worktreeID == worktree.id
    let snapshot = gitHubStore?.snapshots[worktree.id]
    let rollup: PullRequestBadge.CheckRollup = {
      // rollup data travels with the snapshot now (filled by the batched
      // `gh api graphql` path in `parseBatchedPullRequests`). The v1 per-PR
      // `state.checks[prNumber]` map is no longer populated on the fetch side —
      // reading `snapshot.checkRollup` keeps the overlay working without the
      // extra gh subprocess v1 used to spawn.
      guard let snapshot else { return .noChecks }
      return PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
    }()
    let hotkeyNumber = hotkeySlot.map { $0 + 1 }

    // Row and GitHub badge are siblings rather than nested, so the badge's own Button
    // doesn't live inside the row's Button.label. Tapping the badge opens the PR popover
    // without also firing the row-selection action. The leading portion of the row is
    // the Button; the trailing badge sits beside it.
    // `spacing: 0`, not 6: the trailing accessories own their own leading gap so the
    // row's rightmost *visible* element always sits flush at the trailing edge. With a
    // shared HStack spacing, the no-PR rows' 0-pt `WorktreeGitHubBadge` anchor still
    // claimed 6 pt of spacing after the diff-stats chip, pushing that chip 6 pt inside
    // the edge while PR-pill rows stayed flush — a ragged right margin. Each accessory
    // pads its own leading edge; the empty badge anchor pads nothing, so the chip (or
    // pill) it trails stays flush.
    return HStack(spacing: 0) {
      rowSelectionButton(
        worktree: worktree, project: project,
        snapshot: snapshot, rollup: rollup,
        hotkeyNumber: hotkeyNumber,
        isSelected: isSelected
      )
      newBadgePill(for: worktree)
      SidebarWorktreeDiffStats(worktreeID: worktree.id)
      gitHubBadge(for: worktree, in: project)
      runScriptPingAccessory(for: worktree, in: project)
      // Trailing chord hint, after both the row content and the optional PR pill so it
      // always pins to the right edge of the row instead of being shoved leftwards by
      // the pill's intrinsic width. Visible only while ⌘ is held.
      if let hotkeyNumber, commandKeyObserver.isCommandHeld {
        SidebarHotkeyHint(number: hotkeyNumber)
      }
    }
    // Worktree rows are real List children. Selection chrome is owned by
    // SwiftUI's native `List(selection:)` (see `nativeSelectionBinding`):
    // `.tag(worktree.id)` makes the row a selectable target so AppKit's
    // sourceList renderer paints the focus-aware highlight (emphasized blue
    // when sidebar holds first-responder, unemphasized grey when focus
    // moves to a terminal pane), with the matching white / dark text.
    // Leading 14 is the +8pt visual indent over the project row's own
    // leading inset, so worktree content reads as a child level under the
    // (left-aligned) project header.
    .tag(worktree.id)
    .listRowInsets(EdgeInsets(top: 2, leading: indent, bottom: 2, trailing: 0))
    .listRowSeparator(.hidden)
    .contextMenu { worktreeContextMenu(worktree: worktree, project: project) }
    .task(id: worktree.path) {
      // Refresh the "dirty" dot on mount / path change. The monitor enforces a 30 s
      // freshness window internally so list-rerenders don't spawn redundant fetches.
      let url = URL(fileURLWithPath: worktree.path)
      await worktreeStatusMonitor.refresh(worktreeID: worktree.id, path: url)
      // Uncommitted-edit line counts ride the same trigger so every row
      // (PR-matched or not) can surface `+N −M` without a separate poll loop.
      // HEAD-change refresh is wired separately in
      // `RootFeature.worktreeHeadChanged`.
      await worktreeLocalDiffMonitor.refresh(worktreeID: worktree.id, path: url)
      // Server (remote) worktrees have no local FS watchers — the HEAD /
      // working-tree watchers that keep local chips live never fire for them.
      // Poll while the row is visible instead (the task cancels on
      // disappear); each tick is one probe over the shared SSH ControlMaster,
      // so the steady-state cost is a few tens of milliseconds.
      guard project.isRemote else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled else { return }
        worktreeLocalDiffMonitor.invalidate(worktreeID: worktree.id)
        await worktreeLocalDiffMonitor.refresh(worktreeID: worktree.id, path: url)
        await worktreeStatusMonitor.refresh(worktreeID: worktree.id, path: url)
      }
    }
  }

  /// A reference or member row of a Workspace group.
  private func isWorkspaceCheckout(_ worktree: Worktree, in project: Project) -> Bool {
    project.isWorkspace && worktree.workspaceSlot.map { $0.role != .groupTerminal } == true
  }

  /// A row's name line and the caption under it. A worktree reads name over
  /// branch, and the branch line is dropped when it restates the name — the
  /// common case (main/main, test0003/test0003) would otherwise double every
  /// row's height for nothing. A workspace's checkout turns that around: it
  /// leads with its branch, the thing that tells checkouts apart, and its
  /// folder — named after its project — goes below.
  private func rowLabels(
    for worktree: Worktree, in project: Project
  ) -> (title: String, caption: String?) {
    guard let branch = worktree.branch, branch != worktree.name else {
      // No branch to speak of. A detached checkout (branch == nil, HEAD
      // commit known — Codex sandboxes, `git checkout <sha>`) captions the
      // commit so sibling detached worktrees sharing a directory basename
      // (five `~/.codex/worktrees/*/codans`) stay distinguishable; a
      // synthetic non-git worktree stays single-line.
      return (worktree.name, worktree.detachedHeadTitle)
    }
    return isWorkspaceCheckout(worktree, in: project) ? (branch, worktree.name) : (worktree.name, branch)
  }

  /// The selection-tappable portion of a Worktree row. Extracted so `worktreeRow` fits
  /// under swiftlint's `function_body_length` and so the hotkey-hint + keyboard shortcut
  /// wiring stays close to the button those bindings drive.
  @ViewBuilder
  private func rowSelectionButton(
    worktree: Worktree, project: Project,
    snapshot: PullRequestSnapshot?, rollup: PullRequestBadge.CheckRollup,
    hotkeyNumber: Int?,
    isSelected: Bool
  ) -> some View {
    let isMainCheckout = !project.isWorkspace && worktree.path == project.rootPath
    let isReference = project.isWorkspace && worktree.workspaceSlot?.role == .reference
    let isUnavailable = project.unavailableWorkspaceRows.contains(worktree.id)
    // Dir-kind Projects auto-inject a single Worktree pointing at `rootPath`
    // (HierarchyManager.addProject). Detect it locally rather than via a
    // shared computed property — `gitRoot == nil` + path match is the same
    // pair already used to suppress git affordances elsewhere in this view.
    let isSyntheticWorktree = isMainCheckout && project.gitRoot == nil
    let (rowTitle, rowCaption) = rowLabels(for: worktree, in: project)
    let leadingGlyph: WorktreeRowIcon.LeadingGlyph = isSyntheticWorktree ? .folder : .gitAnchor
    // Plain content (no Button wrapping). With native `List(selection:)`,
    // the row's tap is owned by AppKit's NSTableView so the click also
    // promotes the table to first responder — that's what flips the
    // selection chrome from unemphasized grey to emphasized blue. A
    // SwiftUI Button at the row's leading area would intercept the
    // click, leave the table off-responder, and the row would stay grey
    // even though state moved.
    let lifecycle = store.lifecycleProgress[worktree.id]
    let content = HStack(spacing: 6) {
      SidebarWorktreeActivityIcon(
        worktree: worktree, agentStateStore: agentStateStore,
        snapshot: snapshot, rollup: rollup, isSelected: isSelected,
        glyph: leadingGlyph, isDefaultBranch: isMainCheckout && !isSyntheticWorktree,
        hasLifecycle: lifecycle != nil
      )
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Text(rowTitle)
            // Decorative light-sweep while an archive / delete lifecycle
            // runs — the same in-progress affordance the pending-creation
            // row uses. The phase line's stage value below is the
            // probeable signal; the shimmer is purely cosmetic.
            .shimmer(isActive: lifecycle != nil && !reduceMotion)
          // Beside the name rather than at the row's trailing edge: it
          // qualifies *this* checkout, and the trailing corner belongs to
          // the accessories that report on it.
          workspaceMembershipBadge(for: worktree, in: project)
          // A reference is the source project's own checkout, linked into
          // the Workspace rather than owned by it.
          if isReference {
            Image(systemName: "arrow.up.right")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .help("Linked to the source project's checkout")
              .accessibilityLabel("Linked checkout")
          }
          // Default-branch marker now lives in WorktreeRowIcon's leading
          // slot (star.fill replaces git-branch for the main checkout),
          // so there's no longer an inline star next to the name.
          // Explicit pinned marker — keeps the "this row is pinned" signal visible
          // even when the row-icon's role tint is overridden by a PR-state color.
          if worktree.isPinned && !isMainCheckout {
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
              .accessibilityLabel("Pinned")
          }
        }
        if let lifecycle {
          // Mid-archive / mid-delete: the phase line replaces the branch
          // caption — mirroring the creation row's streaming second line —
          // so the row narrates the teardown instead of restating a branch
          // that is about to leave the list. Swept together with the name
          // so the whole row reads as one in-progress unit.
          LifecyclePhaseLineView(progress: lifecycle)
            .shimmer(isActive: !reduceMotion)
        } else if isUnavailable {
          Text("Source not found")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let rowCaption {
          Text(rowCaption)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      // The chord hint used to sit here, but the GitHub PR badge is a *sibling* HStack
      // member outside `rowSelectionButton` (so the badge's Button isn't a child of the
      // row Button); rendering the hint inline meant the trailing PR pill always pushed
      // the hint left of itself. Hint moved to the outer HStack — see
      // `worktreeRow(...)` in this file — so it sticks to the trailing edge regardless
      // of whether a PR pill is present.
    }
    .contentShape(Rectangle())

    content.background(alignment: .topLeading) {
      hotkeyChord(hotkeyNumber, worktreeID: worktree.id, projectID: project.id)
    }
  }

  // Main-checkout guard: the row whose path is the Project's rootPath is the main checkout
  // and cannot be archived or removed from the app (spec W-Q3 guard). Extracted so the row
  // body stays under swiftlint's function_body_length limit.
  @ViewBuilder
  private func worktreeContextMenu(
    worktree: Worktree, project: Project
  ) -> some View {
    // A Workspace has no main checkout: its root, when it is a row, is the
    // migrated group's directory.
    let isMainCheckout = !project.isWorkspace && worktree.path == project.rootPath

    // Group 1 — Open / Reveal. Top-level "Open in <Default>" surfaces
    // the resolved editor by name (project override → global default →
    // priority cascade); the "Open in" submenu lists every installed
    // editor for explicit overrides; "Reveal in Finder" rounds out the
    // navigation group. Server (remote) worktrees open through an editor's
    // SSH remoting CLI instead: the submenu narrows to SSH-capable editors
    // and Finder (local-only) stays hidden.
    if let host = project.remoteHost {
      if remoteResolvedDefaultEditor(for: project, host: host) != nil {
        openInDefaultButton(worktree: worktree, project: project)
        remoteOpenInSubmenu(worktree: worktree, project: project, host: host)
      }
    } else {
      openInDefaultButton(worktree: worktree, project: project)
      openInSubmenu(worktree: worktree, project: project)
      Button {
        store.send(.worktreeRevealInFinderTapped(path: worktree.path))
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }
      .appKeyboardShortcut(.revealCurrentWorktreeInFinder, in: resolvedShortcuts)
    }

    Divider()
    worktreeGitHubAndChangesItems(worktree: worktree, project: project)

    // Group 3 — Copy. Pathname + branch name onto the general pasteboard.
    // Branch entry hides when `worktree.branch` is nil (synthetic dir-kind
    // worktrees, detached HEAD) so the menu never offers an empty copy.
    Divider()
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(worktree.path, forType: .string)
    } label: {
      Label("Copy as Pathname", systemImage: "doc.on.doc")
    }
    if let branch = worktree.branch {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
      } label: {
        Label("Copy as Branch Name", systemImage: "doc.on.doc")
      }
    }

    // Group 4 — Worktree lifecycle. Hidden for the main checkout (W-Q3
    // guard: cannot pin / archive / remove the project's root worktree).
    // Workspace children keep Pin but not Archive / Remove: those act on a
    // worktree of *this* repository, and a child's repository is elsewhere —
    // membership changes go through the workspace flow.
    if !isMainCheckout {
      Divider()
      Button {
        store.send(.worktreePinToggleTapped(worktreeID: worktree.id, current: worktree.isPinned))
      } label: {
        Label(
          worktree.isPinned ? "Unpin Worktree" : "Pin Worktree",
          systemImage: worktree.isPinned ? "pin.slash" : "pin"
        )
      }
    }
    if project.isWorkspace {
      workspaceRowLifecycleItems(worktree: worktree, project: project)
    }
    // A source Project's row that a workspace lists as a child is likewise
    // the workspace's to archive or remove.
    let isWorkspaceMember =
      !project.isWorkspace && hierarchyManager.workspaceMemberships[worktree.id] != nil
    if !isMainCheckout, !project.isWorkspace, !isWorkspaceMember {
      if worktree.archived {
        Button {
          store.send(
            .worktreeUnarchiveTapped(
              worktreeID: worktree.id, inProject: project.id
            ))
        } label: {
          Label("Unarchive Worktree", systemImage: "tray.and.arrow.up")
        }
      } else {
        Button {
          store.send(
            .worktreeArchiveTapped(
              worktreeID: worktree.id, inProject: project.id, name: worktree.name
            ))
        } label: {
          Label("Archive Worktree", systemImage: "archivebox")
        }
        .appKeyboardShortcut(.archiveCurrentWorktree, in: resolvedShortcuts)
      }
      Button(role: .destructive) {
        store.send(
          .worktreeRemoveTapped(
            worktreeID: worktree.id, inProject: project.id, name: worktree.name
          ))
      } label: {
        Label("Remove Worktree", systemImage: "trash")
      }
      .appKeyboardShortcut(.deleteCurrentWorktree, in: resolvedShortcuts)
    }
  }

  /// The destructive entry of a Workspace row, if it has one. No row gets
  /// Archive or Remove: a group goes as a whole (Delete Group…, never for
  /// `default`), a member goes with its group, and a reference only leaves
  /// the Workspace — its checkout is the source project's.
  @ViewBuilder
  private func workspaceRowLifecycleItems(worktree: Worktree, project: Project) -> some View {
    if let slot = worktree.workspaceSlot {
      switch slot.role {
      case .groupTerminal:
        if let group = project.workspaceGroups.first(where: { $0.id == slot.groupID }), group.kind == .named {
          Divider()
          Button(role: .destructive) {
            store.send(.deleteGroupTapped(projectID: project.id, groupID: slot.groupID))
          } label: {
            Label(group.deletion == nil ? "Delete Group…" : "Retry Deletion…", systemImage: "trash")
          }
        }
      case .reference:
        Divider()
        Button(role: .destructive) {
          store.send(.removeSourceTapped(worktreeID: worktree.id, inProject: project.id))
        } label: {
          Label("Remove from Workspace…", systemImage: "minus.circle")
        }
      case .member:
        EmptyView()
      }
    }
  }

  /// Group 2 — GitHub + Changes. Every entry acts on the right-clicked row,
  /// not the selection; the shortcut hints mirror the selection-scoped
  /// Worktree-menu commands. "Open Pull Request" shows only once a PR
  /// snapshot exists for the row. The built-in diff window offers one entry
  /// per comparison scope; an external Git Viewer cannot take a scope, so it
  /// gets a single "Show Changes" entry.
  @ViewBuilder
  private func worktreeGitHubAndChangesItems(
    worktree: Worktree, project: Project
  ) -> some View {
    if project.repoRoot(for: worktree) != nil {
      Button {
        store.send(.delegate(.openOnGitHub(projectID: project.id, worktreeID: worktree.id)))
      } label: {
        Label("Open in GitHub", image: "github")
      }
      .appKeyboardShortcut(.openProjectOnGitHub, in: resolvedShortcuts)
    }
    if let gitHubStore, let pullRequest = gitHubStore.snapshots[worktree.id] {
      Button {
        gitHubStore.send(.delegate(.openURL(pullRequest.url)))
      } label: {
        // Same PR-state octicon the row leads with (WorktreeRowIcon).
        Label(
          "Open Pull Request",
          image: pullRequest.state.rowIconName(isDraft: pullRequest.isDraft))
      }
      .appKeyboardShortcut(.openCurrentPR, in: resolvedShortcuts)
    }
    if settingsStore.settings.general.externalGitViewerID != nil {
      showChangesButton("Show Changes", worktree: worktree, project: project, scope: .all)
        .appKeyboardShortcut(.toggleDiffInspector, in: resolvedShortcuts)
    } else {
      // A fresh diff window opens on the uncommitted scope, so the hint sits there.
      showChangesButton("Show Uncommitted", worktree: worktree, project: project, scope: .all)
        .appKeyboardShortcut(.toggleDiffInspector, in: resolvedShortcuts)
      showChangesButton("Show Outgoing", worktree: worktree, project: project, scope: .outgoing)
    }
  }

  private func showChangesButton(
    _ title: String, worktree: Worktree, project: Project, scope: GitComparisonScope
  ) -> some View {
    Button {
      store.send(
        .delegate(.showChanges(projectID: project.id, worktreeID: worktree.id, scope: scope)))
    } label: {
      Label(title, systemImage: "plusminus")
    }
  }

  /// "Open in <Resolved Editor>" entry. When the editor store is
  /// available and a default editor resolves (project override → global
  /// default → first installed in the priority cascade), the entry's
  /// title carries that editor's display name. Otherwise we fall back
  /// to "Open in Editor". Uses `arrow.up.forward.app` — the
  /// "open in external app" glyph — instead of the prior pencil-edit
  /// icon, which read as "edit / rename" rather than "launch".
  @ViewBuilder
  private func openInDefaultButton(
    worktree: Worktree, project: Project
  ) -> some View {
    let title: String = {
      let descriptor: EditorDescriptor? =
        if let host = project.remoteHost {
          remoteResolvedDefaultEditor(for: project, host: host)
        } else {
          resolvedDefaultEditor(for: project.id)
        }
      if let descriptor {
        return "Open in \(descriptor.displayName)"
      }
      return "Open in Editor"
    }()
    Button {
      store.send(
        .worktreeOpenInDefaultEditorTapped(
          worktreeID: worktree.id, projectID: project.id, path: worktree.path
        ))
    } label: {
      Label(title, systemImage: "arrow.up.forward.app")
    }
    .appKeyboardShortcut(.openInEditor, in: resolvedShortcuts)
  }

  /// "Open in" submenu listing every installed editor returned by the
  /// editor service's `describe()`. Each row carries the editor's real
  /// app icon (via `NSWorkspace.shared.icon(forFile:)` against the
  /// `EditorDescriptor.appURL`) — same glyph the user sees in the Dock
  /// or Spotlight, which is more recognisable than a generic SF Symbol.
  /// Tapping dispatches `worktreeOpenInEditorTapped` with the explicit
  /// ID so the service bypasses the priority cascade. Hidden when the
  /// editor store is nil (preview / test path) since there's nothing
  /// to enumerate.
  @ViewBuilder
  private func openInSubmenu(
    worktree: Worktree, project: Project
  ) -> some View {
    if let editorStore, !editorStore.descriptors.isEmpty {
      Menu {
        ForEach(editorStore.descriptors) { descriptor in
          Button {
            store.send(
              .worktreeOpenInEditorTapped(
                worktreeID: worktree.id,
                projectID: project.id,
                path: worktree.path,
                editorID: descriptor.id
              ))
          } label: {
            editorMenuLabel(for: descriptor)
          }
        }
      } label: {
        Text("Open in")
      }
    }
  }

  /// Remote variant of `openInSubmenu`: only editors with an SSH remoting
  /// CLI, with rows that cannot express this host (VS Code family on a
  /// non-default port) rendered disabled, the reason as their tooltip.
  @ViewBuilder
  private func remoteOpenInSubmenu(
    worktree: Worktree, project: Project, host: RemoteHost
  ) -> some View {
    if let editorStore {
      let capable = editorStore.descriptors.filter {
        RemoteEditorOpen.supportsRemote($0.id)
      }
      if !capable.isEmpty {
        Menu {
          ForEach(capable) { descriptor in
            let reason = RemoteEditorOpen.disabledReason(
              editorID: descriptor.id, host: host, displayName: descriptor.displayName
            )
            Button {
              store.send(
                .worktreeOpenInEditorTapped(
                  worktreeID: worktree.id,
                  projectID: project.id,
                  path: worktree.path,
                  editorID: descriptor.id
                ))
            } label: {
              editorMenuLabel(for: descriptor)
            }
            .disabled(reason != nil)
            .help(reason ?? descriptor.displayName)
          }
        } label: {
          Text("Open in")
        }
      }
    }
  }

  /// Mirror of `EditorFeature.resolveRemoteDefault` for the context-menu
  /// title, so "Open in <Editor>" names what the tap will actually launch.
  private func remoteResolvedDefaultEditor(
    for project: Project, host: RemoteHost
  ) -> EditorDescriptor? {
    guard let editorStore else { return nil }
    return EditorFeature.resolveRemoteDefault(
      projectOverride: settingsStore.settings.projects[project.id]?.defaultEditor,
      globalDefault: editorStore.globalDefault,
      descriptors: editorStore.descriptors,
      host: host
    )
  }

  /// Builds a `Label` for an `EditorDescriptor` whose icon is the
  /// editor's actual app icon when one is available (the descriptor
  /// resolved against an installed bundle), and a sensible SF Symbol
  /// fallback otherwise — `terminal` for `.shellEditor` (no bundle),
  /// `app.dashed` for descriptors whose Launch Services lookup didn't
  /// resolve. The icon is resized to 16×16 so NSMenu's rendering doesn't
  /// stretch the bundle's largest representation.
  @ViewBuilder
  private func editorMenuLabel(
    for descriptor: EditorDescriptor
  ) -> some View {
    if let appURL = descriptor.appURL {
      let icon = appIcon(at: appURL)
      Label {
        Text(descriptor.displayName)
      } icon: {
        Image(nsImage: icon)
      }
    } else if descriptor.launchMode == .shellEditor {
      Label(descriptor.displayName, systemImage: "terminal")
    } else {
      Label(descriptor.displayName, systemImage: "app.dashed")
    }
  }

  /// Reads a 16×16 copy of the bundle's icon through the `EditorAppIcons`
  /// process cache. The redraw gives the image an intrinsic 16×16 size so
  /// menu bridging never stretches the bundle's largest representation;
  /// caching keeps the eager per-row context-menu build off LaunchServices.
  private func appIcon(at appURL: URL) -> NSImage {
    EditorAppIcons.resizedIcon(
      atPath: appURL.path(percentEncoded: false), side: 16
    )
  }

  /// Resolves which editor would actually launch for the project today,
  /// matching the cascade in `RootFeature.sidebar(.delegate(.openInDefaultEditor))`:
  /// project override → global default → first installed in
  /// `EditorRegistry.defaultPriority`. Returns nil when nothing is
  /// installed at all (no descriptor to render the submenu) or when
  /// the editor store wasn't injected.
  private func resolvedDefaultEditor(
    for projectID: ProjectID
  ) -> EditorDescriptor? {
    guard let editorStore else { return nil }
    let descriptors = editorStore.descriptors
    let projectOverride = settingsStore.settings.projects[projectID]?.defaultEditor
    if let preferredID = EditorFeature.resolveInstalledPreference(
      projectOverride: projectOverride,
      globalDefault: editorStore.globalDefault,
      descriptors: descriptors
    ) {
      return descriptors.first(where: { $0.id == preferredID })
    }
    // Priority-cascade fallback — pick the first installed editor in
    // the registry's default order so the menu label matches what the
    // service would actually open.
    for id in EditorRegistry.defaultPriority {
      if let descriptor = descriptors.first(where: { $0.id == id }) {
        return descriptor
      }
    }
    return nil
  }

  // MARK: - Stub sheets

  private func stubSheet(
    title: String,
    body: String,
    dismiss: HierarchySidebarFeature.Action
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      Text(body)
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Done") { store.send(dismiss) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 360)
  }

  // MARK: - Confirmation titles

  private var worktreeRemovalTitle: String {
    if let name = store.pendingWorktreeRemoval?.displayName {
      return "Remove Worktree “\(name)”?"
    }
    return "Remove Worktree?"
  }

  private var projectRemovalTitle: String {
    if let name = store.pendingProjectRemoval?.displayName {
      return "Remove Project “\(name)”?"
    }
    return "Remove Project?"
  }

  /// The removal prompts already stand between the user and the delete, so
  /// a queue is mentioned there instead of in a second dialog.
  private var worktreeRemovalMessage: String {
    let base =
      "Closes all panes and deletes the Worktree directory, including any uncommitted changes. "
      + "This cannot be undone."
    guard
      let pending = store.pendingWorktreeRemoval,
      let count = hierarchyManager.catalog.projects
        .first(where: { $0.id == pending.projectID })?
        .worktrees.first(where: { $0.id == pending.worktreeID })?
        .queuedCommandCount,
      count > 0
    else { return base }
    return base + " " + QueuedCommandDiscard.discardNotice(count)
  }

  private var projectRemovalMessage: String {
    let base = "Removes the Project and closes all its panes. Files on disk are not affected."
    guard
      let pending = store.pendingProjectRemoval,
      let count = hierarchyManager.catalog.projects
        .first(where: { $0.id == pending.projectID })?
        .queuedCommandCount,
      count > 0
    else { return base }
    return base + " " + QueuedCommandDiscard.discardNotice(count)
  }

  // MARK: - New badge pill

  /// "New" pill — shown while `worktree.isNew == true` (cleared on first open by
  /// `RootFeature`). Mirrors the PR-number-pill stroke style (same corner radius, line
  /// weight, and padding) so the two read as one component family, but uses accent blue
  /// to signal "just created" rather than a PR lifecycle state. Placed as the first
  /// trailing accessory so the row reads: name · New · diff · PR.
  @ViewBuilder
  fileprivate func newBadgePill(for worktree: Worktree) -> some View {
    if worktree.isNew {
      Text("New")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.accentColor.opacity(0.75), lineWidth: 0.75)
        )
        // Own the leading gap from the row content (outer HStack is `spacing: 0`). Leading,
        // not trailing, so the pill's right edge stays flush when no other accessories follow.
        .padding(.leading, 6)
        .accessibilityLabel("New")
    }
  }

  /// On a source Project's row whose checkout a workspace lists as a child:
  /// marks the row and jumps to the workspace. Never shown inside the
  /// workspace itself, where every child row would carry it.
  ///
  /// The glyph alone, beside the name: a pill spelling the workspace out sat
  /// at the row's trailing edge, where it competed with the PR pill and the
  /// diff chip for the same corner and squeezed the name into an ellipsis.
  /// The name is one hover away instead.
  @ViewBuilder
  fileprivate func workspaceMembershipBadge(for worktree: Worktree, in project: Project) -> some View {
    if !project.isWorkspace,
      let membership = hierarchyManager.workspaceMemberships[worktree.id]
    {
      Button {
        store.send(.workspaceMembershipBadgeTapped(membership))
      } label: {
        Image(systemName: "square.stack.3d.up")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      // Names the workspace and how this row relates to it. What clicking
      // does is left to the pointer.
      .help("In workspace \(membership.workspaceName)")
      .accessibilityLabel("In workspace \(membership.workspaceName)")
    }
  }

  private var archiveAllMergedTitle: String {
    let count = store.pendingArchiveAllMerged?.worktreeIDs.count ?? 0
    return count == 1
      ? "Archive 1 merged Worktree?"
      : "Archive \(count) merged Worktrees?"
  }

  private var removeAllMergedTitle: String {
    let count = store.pendingRemoveAllMerged?.worktreeIDs.count ?? 0
    return count == 1
      ? "Remove 1 merged Worktree?"
      : "Remove \(count) merged Worktrees?"
  }

  fileprivate func runScriptPingAccessory(for worktree: Worktree, in project: Project) -> some View {
    SidebarRunScriptAccessory(worktreeID: worktree.id, projectID: project.id) {
      store.send(.worktreeStopRunScriptsTapped(worktreeID: worktree.id))
    }
  }

  // MARK: - GitHub badge + popover

  @ViewBuilder
  fileprivate func gitHubBadge(for worktree: Worktree, in project: Project) -> some View {
    if let gitHubStore, let branch = worktree.branch {
      let path = URL(fileURLWithPath: worktree.path)
      WorktreeGitHubBadge(
        store: gitHubStore,
        worktreeID: worktree.id,
        branch: branch,
        worktreePath: path,
        popoverContent: {
          gitHubPopoverContent(
            store: gitHubStore,
            worktreeID: worktree.id,
            branch: branch,
            worktreePath: path
          )
        }
      )
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private func gitHubPopoverContent(
    store: StoreOf<GitHubFeature>,
    worktreeID: WorktreeID,
    branch: String,
    worktreePath: URL
  ) -> some View {
    let snapshot = store.snapshots[worktreeID]
    let error = store.lastError[worktreeID]
    let isLoading = store.loading.contains(worktreeID)

    let content: PullRequestPopover.Content = {
      if let error { return .error(error) }
      if let snapshot {
        // checks now travel inside the snapshot (see the comment on
        // `snapshot.checkRollup`). `latestWorkflowRuns` remains a separately-fetched
        // lazy load on popover-open — the batched query does not include workflow-run
        // IDs yet (Open Question 4 in the design doc).
        let run = store.latestWorkflowRuns[snapshot.number]
        return .loaded(snapshot, checks: snapshot.checkRollup, workflowRun: run)
      }
      if isLoading { return .loading }
      return .noPullRequest(branch: branch)
    }()

    let defaultStrategy = settingsStore.settings.general.defaultMergeStrategy ?? .squash

    let isMutating = store.mutating.contains(worktreeID)

    PullRequestPopover(
      content: content,
      defaultMergeStrategy: defaultStrategy,
      canMerge: !isMutating
        && snapshot?.mergeable == .mergeable
        && snapshot?.state == .open
        && snapshot?.isDraft == false,
      mergeDisabledReason: isMutating
        ? "Another GitHub operation is in flight"
        : Self.mergeDisabledReason(for: snapshot),
      onMerge: { strategy in
        if let pr = snapshot {
          store.send(
            .mergeRequested(
              worktreeID, prNumber: pr.number, strategy: strategy, worktreePath: worktreePath)
          )
        }
      },
      onClose: {
        if let pr = snapshot {
          store.send(.closeRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
        }
      },
      onMarkReady: {
        if let pr = snapshot {
          store.send(
            .markReadyRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
        }
      },
      onRerunFailedJobs: {
        if let pr = snapshot, let run = store.latestWorkflowRuns[pr.number] {
          store.send(
            .rerunFailedJobsRequested(worktreeID, runID: run.databaseID, worktreePath: worktreePath)
          )
        }
      },
      onOpenOnWeb: {
        if let url = snapshot?.url {
          store.send(.delegate(.openURL(url)))
        }
      },
      onOpenCheckLog: { url in store.send(.delegate(.openURL(url))) },
      onSetProjectDefaultStrategy: { [settingsStore] strategy in
        // Per-Project override UI is deferred to a follow-up; writing to the *global*
        // default is a useful intermediate behavior — "Set as default" means "use this
        // strategy everywhere". When per-Project lands, this callback splits into two.
        settingsStore.mutateGeneral { $0.defaultMergeStrategy = strategy }
      },
      onRetry: {
        store.send(.worktreeRefreshRequested(worktreeID))
      }
    )
  }

  private static func mergeDisabledReason(for snapshot: PullRequestSnapshot?) -> String? {
    guard let snapshot else { return "No pull request for this Worktree" }
    if snapshot.state == .merged { return "Pull request already merged" }
    if snapshot.state == .closed { return "Pull request closed" }
    if snapshot.isDraft { return "Pull request is a draft" }
    // Prefer the richer `mergeStateStatus` reason when GitHub computed it; the legacy
    // `mergeable` only distinguishes mergeable/conflicting/unknown.
    switch snapshot.mergeStateStatus {
    case .dirty: return "Pull request has merge conflicts"
    case .blocked: return "Merge blocked by required checks or reviews"
    case .behind: return "Behind base branch — update required before merge"
    case .clean, .hasHooks, .unstable, .draft, .unknown: break
    }
    if snapshot.mergeable == .conflicting { return "Pull request has merge conflicts" }
    if snapshot.mergeable == .unknown { return "Merge status unknown — try refresh" }
    return nil
  }

  /// True iff any bound agent currently demands the user's attention —
  /// either it's actively working (`.working`) or it's blocked on a
  /// user response (`.blocked`). Drives the auto-open of the
  /// AgentState sidebar panel via `.onChange`, gated by Settings →
  /// General → `agentsViewAutoOpen`. Exposed as a `Bool` so `.onChange`
  /// fires only on real transitions, not on every entry mutation.
  private var anyAgentNeedsAttention: Bool {
    agentStateStore?.needsAttention == true
  }

  /// Walks the selection chain (project → worktree → tab) and returns
  /// the pane the user is currently focused on, or nil when the chain
  /// breaks (no project selected, archived worktree, etc.). Used by the
  /// AgentState sidebar panel to highlight the row corresponding to
  /// the pane already in view.
  private func currentlyFocusedPaneID() -> PaneID? {
    let catalog = hierarchyManager.catalog
    guard let projectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let worktreeID = project.selectedWorktreeID,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let tabID = worktree.selectedTabID
    else { return nil }
    return hierarchyManager.lastFocusedPane(in: tabID)
  }

}

// MARK: - Project header (hover chrome)

/// Dedicated subview so `@State var isHovering` is per-row. Hovering is a
/// view-local concern — not worth promoting to reducer state.
private struct ProjectHeaderRow<Accessory: View>: View {
  let project: Project
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  /// Read-only access to per-Worktree PR snapshots so the ⋯ menu can resolve
  /// the project's merged Worktrees for the "… All Merged Worktrees" items.
  /// Nil in previews — the items then render disabled.
  var gitHubStore: StoreOf<GitHubFeature>?
  /// The folder this row stands for (`Project.rowWorktree`), nil for a git
  /// Project. The row then carries that worktree's selection, busy state,
  /// unread bell, and ⌃N hint, the way a worktree row does.
  var rowWorktree: Worktree?
  var isRowSelected = false
  var agentStateStore: AgentStateStore?

  private var isRowBusy: Bool {
    guard let rowWorktree else { return false }
    return hierarchyManager.worktreeIsDirty(rowWorktree)
      || rowWorktree.tabs.contains { tab in
        tab.panes.contains { agentStateStore?.workingPaneIDs.contains($0.id) == true }
      }
  }
  /// The ⌃N number to show, while ⌘ is held.
  var hotkeyHint: Int?
  let onToggleExpansion: () -> Void
  /// Trailing indicators for `rowWorktree`, ahead of the hover controls.
  @ViewBuilder let accessory: () -> Accessory
  @Environment(RollupIndexProvider.self) private var rollup: RollupIndexProvider?
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts
  @State private var isHovering = false
  @State private var isPlusHovering = false
  @State private var isMenuHovering = false
  @State private var isChevronHovering = false

  /// Non-archived, non-main Worktrees in this project whose GitHub PR is
  /// merged. Drives the Project ⋯ menu's "Archive / Remove All Merged
  /// Worktrees" items (count + enablement). Empty when the GitHub store is
  /// absent or nothing is merged. "Merged" is the PR's GitHub state, matching
  /// `scripts/clean-merged-branches.sh` — squash-merge friendly, unlike
  /// `git branch --merged`. A checkout a workspace still lists as a child is
  /// left out: it is the workspace's to remove.
  private var mergedWorktreeIDs: [WorktreeID] {
    guard let gitHubStore else { return [] }
    return project.worktrees
      .filter { !$0.archived && $0.path != project.rootPath }
      .filter { hierarchyManager.workspaceMemberships[$0.id] == nil }
      .filter { gitHubStore.snapshots[$0.id]?.state == .merged }
      .map(\.id)
  }

  /// Project name tint — hover- and selection-driven. The Project color
  /// deliberately does *not* reach the name: the icon to its left already
  /// carries it, and tinting both painted the same signal twice and cost the
  /// name the primary/secondary hover contrast every other sidebar row keeps.
  private var projectNameColor: Color {
    isHovering || isRowSelected ? .primary : .secondary
  }

  /// L4 (the Project, collapsed, has unread inside) or, for a row that
  /// stands for a folder, L3 (that folder's worktree has unread).
  private var hasUnread: Bool {
    let notifications = settingsStore.settings.notifications
    let projectUnread =
      rollup?.current.unreadProjects.contains(project.id) == true && notifications.projectBellEnabled
    let rowUnread =
      rowWorktree.map { rollup?.current.unreadWorktrees.contains($0.id) == true } == true
      && notifications.worktreeBellEnabled
    return projectUnread || rowUnread
  }

  var body: some View {
    HStack(spacing: 6) {
      // The leading slot shows the Project icon; a running command in the
      // folder this row stands for swaps in a spinner, and unread swaps in a
      // bell — the same pattern as the worktree row icon.
      //
      // The icon does not change with expansion — the row carries the
      // Project's identity; the trailing chevron carries its disclosure state.
      Group {
        if isRowBusy {
          ProgressView()
            .controlSize(.small)
            .frame(width: 14, height: 14)
            .accessibilityLabel("Running a command")
        } else if hasUnread {
          Image(systemName: "bell.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 11, height: 11)
            .foregroundStyle(Color.orange)
            .accessibilityLabel("Has unread notifications")
        } else {
          ProjectIconView(
            icon: project.icon, color: project.color, size: 13,
            defaultSymbol: ProjectIconView.defaultSymbol(for: project.kind)
          )
        }
      }
      .frame(width: 14, alignment: .center)
      Text(project.name)
        // Semibold, though the row sits a size below its worktrees: the
        // Project is the heading of the rows under it, and at subheadline
        // size the regular weight let a child's name outweigh its parent.
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(projectNameColor)
        .lineLimit(1)
      // Server projects carry a small network glyph so a remote repo is
      // distinguishable from a local one at a glance; the tooltip names the
      // SSH destination.
      if let host = project.remoteHost {
        Image(systemName: "tv.badge.wifi")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .help(host.displayAuthority)
          .accessibilityLabel("Remote server \(host.displayAuthority)")
      }
      Spacer(minLength: 4)
      accessory()
      // Keep the hover chrome from collapsing row width when hidden —
      // use opacity, not conditional rendering.
      HStack(spacing: 2) {
        // Non-git Projects (P-Q4 = a): suppress the Add Worktree affordance.
        // Worktrees are a git-only concept; a scratch folder renders with a
        // single synthetic Worktree and nothing to add. Server (remote)
        // projects create over SSH (`git worktree add` on the host).
        if project.supportsWorktrees {
          Button {
            store.send(.projectAddWorktreeTapped(projectID: project.id))
          } label: {
            iconLabel(systemName: "plus", label: "Add Worktree under this Project", isHovering: isPlusHovering)
          }
          .buttonStyle(.plain)
          .onHover { isPlusHovering = $0 }
        } else if project.isWorkspace {
          // A workspace's `+` adds a group: one branch checked out in every
          // source project.
          Button {
            store.send(.workspaceNewGroupTapped(projectID: project.id))
          } label: {
            iconLabel(systemName: "plus", label: "New Group", isHovering: isPlusHovering)
          }
          .buttonStyle(.plain)
          .onHover { isPlusHovering = $0 }
          .help("New Group…")
        }
        Menu {
          if project.isWorkspace {
            workspaceMenuItems
          } else {
            projectMenuItems
          }
        } label: {
          iconLabel(
            systemName: "ellipsis", label: project.isWorkspace ? "Workspace options" : "Project options",
            isHovering: isMenuHovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isMenuHovering = $0 }
        // Opens and closes the rows under the Project. The only way to do so
        // on a row that stands for a folder, where a click selects instead.
        if project.hasChildRows {
          Button(action: onToggleExpansion) {
            iconLabel(
              systemName: "chevron.right",
              label: project.isExpanded ? "Collapse" : "Expand",
              isHovering: isChevronHovering
            )
            .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
          }
          .buttonStyle(.plain)
          .onHover { isChevronHovering = $0 }
          .help(project.isExpanded ? "Collapse" : "Expand")
        }
      }
      .opacity(isHovering ? 1 : 0)
      if let hotkeyHint {
        SidebarHotkeyHint(number: hotkeyHint)
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }

  /// The Workspace header's `⋯` menu. Group and checkout entries live on
  /// the group rows; the header manages the Workspace and its sources.
  @ViewBuilder
  private var workspaceMenuItems: some View {
    Button {
      store.send(.projectSettingsTapped(projectID: project.id))
    } label: {
      Label("Workspace Settings…", systemImage: "slider.horizontal.3")
    }
    Button {
      store.send(.workspaceAddProjectTapped(projectID: project.id))
    } label: {
      Label("Add Project…", systemImage: "plus.rectangle.on.folder")
    }
    Divider()
    Button(role: .destructive) {
      store.send(.workspaceRemoveTapped(projectID: project.id, name: project.name))
    } label: {
      Label("Remove Workspace…", systemImage: "trash")
    }
  }

  @ViewBuilder
  private var projectMenuItems: some View {
    Button {
      store.send(.projectSettingsTapped(projectID: project.id))
    } label: {
      Label("Project Settings…", systemImage: "slider.horizontal.3")
    }
    if project.isRemote {
      Button {
        store.send(.projectEditConnectionTapped(projectID: project.id))
      } label: {
        Label("Edit Connection…", systemImage: "tv.badge.wifi")
      }
    }
    Divider()
    // Worktree operations group: archived list, prune, and the
    // merged-batch actions — kept together between dividers.
    let archivedCount = project.worktrees.filter { $0.archived }.count
    Button {
      store.send(.projectShowArchivedTapped(projectID: project.id))
    } label: {
      Label(
        archivedCount > 0
          ? "Archived Worktrees (\(archivedCount))…"
          : "Archived Worktrees…",
        systemImage: "archivebox"
      )
    }
    .appKeyboardShortcut(.showArchivedWorktrees, in: resolvedShortcuts)
    // Prune and the merged batches act on one repository's worktree list.
    Button {
      store.send(.projectPruneTapped(projectID: project.id))
    } label: {
      Label("Prune Stale Worktrees", systemImage: "wand.and.sparkles")
    }
    let mergedIDs = mergedWorktreeIDs
    Button {
      store.send(
        .projectArchiveAllMergedTapped(
          projectID: project.id, worktreeIDs: mergedIDs
        )
      )
    } label: {
      Label(
        mergedIDs.isEmpty
          ? "Archive All Merged"
          : "Archive All Merged (\(mergedIDs.count))",
        systemImage: "archivebox"
      )
    }
    .disabled(mergedIDs.isEmpty)
    Button(role: .destructive) {
      store.send(
        .projectRemoveAllMergedTapped(
          projectID: project.id, worktreeIDs: mergedIDs
        )
      )
    } label: {
      Label(
        mergedIDs.isEmpty
          ? "Remove All Merged"
          : "Remove All Merged (\(mergedIDs.count))",
        systemImage: "trash"
      )
    }
    .disabled(mergedIDs.isEmpty)
    Divider()
    // Tags entry intentionally hidden for now. `ProjectTagsMenu` and
    // its tag-assignment logic (inline color palette + "Tags…"
    // → global TagManager via `.openTagManager`) are retained — only
    // the menu entry is suppressed. Re-add the line below to restore.
    // ProjectTagsMenu(project: project, store: store)
    Button(role: .destructive) {
      store.send(
        .projectRemoveTapped(projectID: project.id, name: project.name)
      )
    } label: {
      Label("Remove Project", systemImage: "trash")
    }
  }

  /// 22×22 hit target with a subtle hover background. Used by the trailing
  /// "+" and "..." affordances so both share the same affordance footprint
  /// and so the click target is comfortably larger than the underlying SF
  /// Symbol glyph.
  @ViewBuilder
  private func iconLabel(systemName: String, label: String, isHovering: Bool) -> some View {
    Image(systemName: systemName)
      .accessibilityLabel(label)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(isHovering ? .primary : .secondary)
      .frame(width: 22, height: 22)
      .background(
        Circle().fill(Color.primary.opacity(isHovering ? 0.08 : 0))
      )
      .contentShape(Circle())
  }
}

// MARK: - Workspace group row

extension WorkspaceSidebarRow {
  /// Stable List identity: a group by its id, a member by its row.
  fileprivate var listID: String {
    switch self {
    case .group(let group, _): "group:\(group.id.raw)"
    case .member(let worktree, _): "row:\(worktree.id.raw)"
    }
  }
}

/// One Workspace group: a star in the leading slot for `default` (a folder
/// for a named group), the name, and a caption with the member count, the
/// branch summary, and the group's pull requests. Own view so hover state is
/// per row.
private struct WorkspaceGroupRow<Accessory: View>: View {
  let group: WorkspaceGroupRecord
  /// The group directory's row; carries busy and unread state.
  let terminal: Worktree?
  let summary: WorkspaceGroupSummary
  let pullRequestSummary: String?
  let isSelected: Bool
  let agentStateStore: AgentStateStore?
  var hotkeyHint: Int?
  /// Items the last delete could not remove; known only until a restart.
  let deletionFailures: [GroupDeletionOutcome.Failure]
  let onToggleExpansion: () -> Void
  let onRetryDeletion: () -> Void
  @ViewBuilder let accessory: () -> Accessory
  @State private var isHovering = false
  @State private var isChevronHovering = false

  private var caption: String {
    if group.deletion != nil {
      switch deletionFailures.count {
      case 0: return "Deletion incomplete"
      case 1: return "Deletion incomplete · 1 item not removed"
      default: return "Deletion incomplete · \(deletionFailures.count) items not removed"
      }
    }
    var parts = [summary.memberCount == 1 ? "1 project" : "\(summary.memberCount) projects"]
    switch summary.branch {
    case .single(let branch): parts.append(branch)
    case .several(let count): parts.append("\(count) branches")
    case nil: break
    }
    if let pullRequestSummary { parts.append(pullRequestSummary) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 6) {
      leadingIcon
      VStack(alignment: .leading, spacing: 0) {
        Text(group.name)
          .lineLimit(1)
        Text(caption)
          .font(.caption)
          .foregroundStyle(group.deletion == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
          .lineLimit(1)
          .help(deletionHelp)
      }
      Spacer(minLength: 4)
      accessory()
      if group.deletion != nil {
        Button("Retry", action: onRetryDeletion)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .help("Check the group again and finish deleting it")
      }
      Button(action: onToggleExpansion) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isChevronHovering ? .primary : .secondary)
          .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
          .frame(width: 22, height: 22)
          .background(Circle().fill(Color.primary.opacity(isChevronHovering ? 0.08 : 0)))
          .contentShape(Circle())
          .accessibilityLabel(group.isExpanded ? "Collapse Group" : "Expand Group")
      }
      .buttonStyle(.plain)
      .onHover { isChevronHovering = $0 }
      .help(group.isExpanded ? "Collapse" : "Expand")
      // Opacity, not conditional rendering, so the row width stays put.
      .opacity(isHovering ? 1 : 0)
      if let hotkeyHint {
        SidebarHotkeyHint(number: hotkeyHint)
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(group.kind == .default ? "\(group.name), default group" : group.name)
    // The chevron is hidden until hover, which also hides it from
    // accessibility; the row itself must offer the toggle.
    .accessibilityAction(named: Text(group.isExpanded ? "Collapse Group" : "Expand Group"), onToggleExpansion)
  }

  /// The failed items with their reasons, or what Retry does after a
  /// restart, when the reasons are no longer known.
  private var deletionHelp: String {
    guard group.deletion != nil else { return "" }
    guard !deletionFailures.isEmpty else {
      return "Some items of this group were not removed. Retry checks the group again."
    }
    return deletionFailures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if let terminal {
      SidebarWorktreeActivityIcon(
        worktree: terminal, agentStateStore: agentStateStore,
        snapshot: nil, rollup: .noChecks, isSelected: isSelected,
        glyph: group.kind == .default ? .gitAnchor : .folder,
        isDefaultBranch: group.kind == .default,
        hasLifecycle: false
      )
    } else {
      WorktreeRowIcon(
        snapshot: nil, rollup: .noChecks, isSelected: isSelected,
        glyph: group.kind == .default ? .gitAnchor : .folder,
        isDefaultBranch: group.kind == .default
      )
    }
  }
}

/// The `⌃N` chord a sidebar row answers to, shown at its trailing edge while
/// ⌘ is held. Slot 10 reads `⌃0`.
private struct SidebarHotkeyHint: View {
  let number: Int

  var body: some View {
    Text("⌃\(number == 10 ? "0" : String(number))")
      .font(.caption2.monospaced())
      .foregroundStyle(.secondary)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
      )
      .padding(.leading, 6)
      .accessibilityHidden(true)
  }
}

/// Transparent helper that hunts down the AppKit `NSOutlineView` backing
/// `List(.sidebar)` and zeroes its built-in indentation / intercell spacing,
/// so rows carry no per-level offset on top of the scroll-view gutter and
/// the indent each row wants lives in its own `listRowInsets`.
///
/// Retries a few times because the List may not be attached when
/// `viewDidMoveToWindow` first fires. Fires `onReady` once any outline has
/// been patched so the SwiftUI parent can gate visibility on install — the
/// indent would otherwise visibly snap rows left mid-launch.
private struct SidebarIndentZeroer: NSViewRepresentable {
  var onReady: () -> Void = {}
  func makeNSView(context: Context) -> NSView {
    let view = _IndentZeroerView()
    view.onReady = onReady
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? _IndentZeroerView)?.onReady = onReady
  }
}

private final class _IndentZeroerView: NSView {
  var onReady: (() -> Void)?
  private var attempts = 0
  private var didFireReady = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attempts = 0
    patch()
  }

  private func patch() {
    guard let root = window?.contentView else { return }
    let outlines = findOutlineViews(in: root)
    if outlines.isEmpty, attempts < 60 {
      attempts += 1
      // First handful of retries fire next-runloop (≈1 frame) so the gate
      // flips before the user can perceive the unshifted rows; fall back
      // to 100ms after that in case the List takes longer than expected.
      let delay: DispatchTime = attempts < 10 ? .now() : .now() + 0.1
      DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
        self?.patch()
      }
      return
    }
    for outline in outlines {
      outline.indentationPerLevel = 0
      outline.intercellSpacing = NSSize(width: 0, height: outline.intercellSpacing.height)
      outline.outlineTableColumn?.minWidth = 0
    }
    if !outlines.isEmpty, !didFireReady {
      didFireReady = true
      onReady?()
    }
  }

  private func findOutlineViews(in root: NSView) -> [NSOutlineView] {
    var result: [NSOutlineView] = []
    var queue: [NSView] = [root]
    while let v = queue.first {
      queue.removeFirst()
      if let outline = v as? NSOutlineView { result.append(outline) }
      queue.append(contentsOf: v.subviews)
    }
    return result
  }
}

/// Tag controls for the project header ⋯ menu, rendered as a native
/// NSMenu submenu. Each row inside the submenu shows the tag's colored
/// circle plus its name; a `checkmark.circle.fill` variant indicates
/// the project already carries that tag. Color comes from `.tint(...)`
/// on the Button — NSMenu's renderer honours per-item tint (foreground
/// style on the inner Label is silently dropped). The trailing "Tags…"
/// entry opens the global TagManager via `.openTagManager`. When the
/// catalog has no tags, the submenu collapses to a single "Tags…"
/// entry so users can still discover the manager.
private struct ProjectTagsMenu: View {
  let project: Project
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    Menu {
      let tags = hierarchyManager.catalog.tags
      ForEach(tags) { tag in
        let isOn = project.tagIDs.contains(tag.id)
        Button {
          store.send(.toggleTagOnProject(project.id, tag.id))
        } label: {
          Label(
            tag.name,
            systemImage: isOn ? "checkmark.circle.fill" : "circle.fill"
          )
        }
        .tint(swiftUIColor(for: tag.color))
      }
      if !tags.isEmpty { Divider() }
      Button {
        store.send(.delegate(.openTagManager))
      } label: {
        Label("Tags…", systemImage: "tag")
      }
    } label: {
      Label("Tags", systemImage: "tag")
    }
  }
}

/// Captures the sidebar column's live height so the AgentState bottom
/// panel can clamp to half of it. Updated each time SwiftUI re-measures
/// the sidebar background.
private struct SidebarHeightPreferenceKey: PreferenceKey {
  static let defaultValue: Double = 0
  static func reduce(value: inout Double, nextValue: () -> Double) {
    value = max(value, nextValue())
  }
}

/// Walks the catalog for a paneID and returns the source tuple the
/// AgentState row needs: names + color for the breadcrumb, plus the
/// worktree path and remote host that key the hover summary card's
/// session scan (`remoteHost` non-nil routes the scan over SSH; its
/// `displayAuthority` also badges the row). `projectColor` mirrors the
/// project's configured color so the row's project name renders in the
/// same hue as the sidebar header and worktree-header label (`nil` =
/// No Color → caption secondary).
/// Returns nil when the pane has been torn down between event delivery
/// and the next popover render — the row renders an em-dash fallback.
private func resolveAgentStateSourcePath(
  paneID: PaneID,
  catalog: Catalog
) -> (
  project: String, worktree: String, projectColor: ProjectColor?,
  worktreePath: String, remoteHost: RemoteHost?
)? {
  for project in catalog.projects {
    for worktree in project.worktrees
    where worktree.tabs.contains(where: { tab in
      tab.panes.contains(where: { $0.id == paneID })
    }) {
      return (project.name, worktree.name, project.color, worktree.path, project.remoteHost)
    }
  }
  return nil
}

/// Second line of a worktree row mid-archive / mid-delete: the lifecycle
/// script's glyph (during the script phase) leading the phase text. Its
/// own view so `backgroundProminence` reads the ROW's environment — on an
/// emphasized (blue) selection an explicitly-tinted glyph must drop to
/// the light selected-row tone, the same adaptation `WorktreeRowIcon`
/// does for its glyphs. `.secondary` on the text adapts on its own.
private struct LifecyclePhaseLineView: View {
  let progress: WorktreeLifecycleProgress

  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    HStack(spacing: 3) {
      if progress.phase == .runningScript {
        // Same glyphs the Settings lifecycle sections use. The leading
        // icon slot keeps the spinner (motion = alive); this glyph
        // annotates WHICH script the second line is narrating.
        Image(systemName: progress.kind == .archive ? "archivebox" : "trash")
          .font(.caption2)
          .foregroundStyle(glyphColor)
          // Decorative — the stage value on the text leaf is the
          // probeable signal.
          .accessibilityHidden(true)
      }
      Text(progress.phaseLine)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityValue(progress.stageAccessibilityValue)
    }
  }

  private var glyphColor: Color {
    if backgroundProminence == .increased {
      return Color(nsColor: .alternateSelectedControlTextColor)
    }
    return progress.kind == .archive ? .orange : .red
  }
}

private struct SidebarFilterBar: View {
  let selection: SidebarFilter
  /// Tints the notification glyph while it is not selected, so unread
  /// notifications stay visible under any filter.
  let hasUnreadNotifications: Bool
  var onSelect: (SidebarFilter) -> Void
  var onMarkAllNotificationsRead: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var hoveredFilter: SidebarFilter?

  var body: some View {
    GeometryReader { geometry in
      let layout = SidebarFilterLayout(
        expansion: SidebarFilterExpansion(selection: selection),
        height: TabBarMetrics.trackHeight
      )
      let metrics = layout.metrics(width: geometry.size.width)
      layout {
        ForEach(SidebarFilter.allCases, id: \.self) { filter in
          filterButton(filter, metrics: metrics)
        }
      }
      .animation(
        reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32),
        value: selection
      )
    }
    .frame(height: TabBarMetrics.trackHeight)
    .padding(.horizontal, 8)
    .padding(.bottom, TabBarMetrics.trackBottomInset)
  }

  private func filterButton(_ filter: SidebarFilter, metrics: SidebarFilterLayout.Metrics) -> some View {
    let selected = selection == filter
    let title = title(for: filter)
    let titleWidth = ceil(
      (title as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: TabBarMetrics.titleFontSize, weight: .semibold)
      ]).width)
    // The label shrinks a little to fit; past that the title is dropped and
    // the selected capsule keeps only its icon.
    let titleScale = min(1, max(0, metrics.expanded - 12) / (14 + 5 + titleWidth))
    let showsTitle = selected && titleScale >= 0.8
    let labelScale = showsTitle ? titleScale : min(1, max(0, metrics.diameter - 8) / 14)

    return Button {
      onSelect(filter)
    } label: {
      Capsule()
        .fill(Color.primary.opacity(0.035))
        .overlay {
          Capsule()
            .fill(tint(for: filter))
            .opacity(selected ? 1 : hoveredFilter == filter ? 0.3 : 0)
        }
        .overlay {
          // The label keeps its full size and exits through the capsule edge.
          // Only the icon's position changes; text never squeezes its siblings.
          HStack(spacing: 5) {
            Image(systemName: symbol(for: filter))
              .frame(width: 14)
              .accessibilityHidden(true)
            Text(title)
              .fixedSize()
              .opacity(showsTitle ? 1 : 0)
              .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12).delay(showsTitle ? 0.1 : 0),
                value: showsTitle
              )
              .accessibilityHidden(true)
          }
          .font(.system(size: TabBarMetrics.titleFontSize, weight: .semibold))
          .foregroundStyle(
            selected
              ? Color.white
              : filter == .notifications && hasUnreadNotifications ? tint(for: filter) : Color.secondary)
          .fixedSize()
          .offset(x: showsTitle ? 0 : (titleWidth + 5) / 2)
          .animation(
            reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22).delay(showsTitle ? 0.06 : 0),
            value: showsTitle
          )
          .scaleEffect(labelScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .contextMenu {
      if filter == .notifications {
        Button("Mark All as Read", action: onMarkAllNotificationsRead)
          .disabled(!hasUnreadNotifications)
      }
    }
    .onHover { hoveredFilter = $0 ? filter : nil }
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func title(for filter: SidebarFilter) -> String {
    switch filter {
    case .all: "All"
    case .remote: "Remote"
    case .workspace: "Workspace"
    case .notifications: "Unread"
    case .pullRequests: "PR"
    }
  }

  private func symbol(for filter: SidebarFilter) -> String {
    switch filter {
    case .all: "square.grid.2x2.fill"
    case .remote: "wifi"
    case .workspace: "square.stack.3d.up.fill"
    case .notifications: "bell.fill"
    case .pullRequests: "arrow.triangle.pull"
    }
  }

  private func tint(for filter: SidebarFilter) -> Color {
    switch filter {
    case .all: .blue
    case .remote: .indigo
    case .workspace: .purple
    case .pullRequests: .green
    case .notifications: .orange
    }
  }
}

/// A single animated layout owns both edges of every capsule. Child frame and
/// offset animations cannot guarantee a fixed gap when a transition is interrupted.
nonisolated struct SidebarFilterLayout: Layout {
  var expansion: SidebarFilterExpansion
  var height: CGFloat
  var spacing: CGFloat = 6

  var animatableData: SidebarFilterExpansion {
    get { expansion }
    set { expansion = newValue }
  }

  /// Collapsed capsules never get narrower than they are tall; the selected
  /// capsule takes the rest. When even that leaves no room, every capsule
  /// becomes the same smaller circle.
  struct Metrics {
    var collapsed: CGFloat
    var expanded: CGFloat
    var diameter: CGFloat
  }

  func metrics(width: CGFloat) -> Metrics {
    let count = CGFloat(expansion.values.count)
    let available = max(0, width - spacing * (count - 1))
    let unit = available / (count + 2)
    let collapsed = max(unit, min(height, available / count))
    return Metrics(
      collapsed: collapsed,
      expanded: available - (count - 1) * collapsed,
      diameter: min(height, collapsed)
    )
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: proposal.width ?? 260, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (subview, frame) in zip(subviews, frames(width: bounds.width)) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height)
      )
    }
  }

  func frames(width: CGFloat) -> [CGRect] {
    let weights = expansion.values.map { max(0, $0) }
    let total = max(weights.reduce(0, +), 1e-9)
    let metrics = metrics(width: width)
    let y = (height - metrics.diameter) / 2
    var x: CGFloat = 0
    return weights.map { weight in
      let itemWidth = metrics.collapsed + (metrics.expanded - metrics.collapsed) * weight / total
      defer { x += itemWidth + spacing }
      return CGRect(x: x, y: y, width: itemWidth, height: metrics.diameter)
    }
  }
}

nonisolated struct SidebarFilterExpansion: VectorArithmetic {
  var values: [Double]

  init(selection: SidebarFilter) {
    values = SidebarFilter.allCases.map { $0 == selection ? 1 : 0 }
  }

  private init(values: [Double]) {
    self.values = values
  }

  static var zero: Self {
    Self(values: SidebarFilter.allCases.map { _ in 0 })
  }

  static func + (lhs: Self, rhs: Self) -> Self {
    Self(values: zip(lhs.values, rhs.values).map { $0 + $1 })
  }

  static func - (lhs: Self, rhs: Self) -> Self {
    Self(values: zip(lhs.values, rhs.values).map { $0 - $1 })
  }

  mutating func scale(by rhs: Double) {
    values = values.map { $0 * rhs }
  }

  var magnitudeSquared: Double {
    values.reduce(0) { $0 + $1 * $1 }
  }
}
