import AppKit
import ComposableArchitecture
import OSLog
import SwiftUI
import TouchCodeCore

private let autoOpenLogger = Logger(
  subsystem: "com.touch-code.activeagents", category: "autoOpen"
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
  /// Optional editor store. Drives the worktree context menu's "Open in
  /// <Editor>" entry (resolved default) and "Open in" submenu (every
  /// installed editor). Nil in previews — the submenu falls back to the
  /// shared "Open in Editor" entry alone.
  var editorStore: StoreOf<EditorFeature>?
  /// ActiveAgents registry. Drives the bottom expandable panel + the
  /// 🤖-style toggle button in the footer. Optional so previews / tests
  /// without `AppState.bringUp` wiring omit the panel and the button.
  var activeAgentsRegistry: AgentRegistry?
  /// Row-tap dispatcher for the ActiveAgents panel — routes to
  /// `RootFeature.activeAgents(.rowTapped)`. Closure (rather than direct
  /// store write) keeps Sidebar decoupled from Root.
  var onActiveAgentsRowTapped: (PaneID) -> Void = { _ in }
  /// Whether the ActiveAgents bottom panel is currently expanded.
  /// Persisted so the footer toggle's last state survives a relaunch —
  /// users who keep the panel open during long sessions should not
  /// re-toggle it after every restart. The auto-open path in
  /// `onChange(anyAgentNeedsAttention)` still re-opens a closed panel
  /// when a fresh agent demands attention.
  @AppStorage("activeAgents.panel.open") private var activeAgentsPanelOpen = false
  /// Persisted panel height. The drag handle in
  /// `ActiveAgentsSidebarPanel` writes to this; the host clamps the
  /// rendered height to `[minHeight, 0.5 * sidebarHeight]`.
  @AppStorage("activeAgents.panel.height") private var activeAgentsPanelHeight: Double = 200
  /// Live sidebar height, captured via a background GeometryReader on
  /// `treeBody`. Used to clamp the ActiveAgents panel to at most half
  /// the sidebar so the worktree list always retains the other half.
  /// Defaults to a sensible value so the first render before the
  /// background measure lands doesn't pop a too-tall panel.
  @State private var sidebarHeightObservation: Double = 600

  /// Min / max height bounds for the ActiveAgents panel. Kept as a
  /// type-level constant so both `ActiveAgentsSidebarPanel`'s own clamp
  /// and the List's bottom spacer-row height share one source.
  private static let activeAgentsPanelMinHeight: Double = 140

  /// Effective panel height after clamping to `[minHeight, 0.5 *
  /// sidebarHeight]`. Mirrors the clamp inside
  /// `ActiveAgentsSidebarPanel.clampedHeight` so the spacer row inside
  /// the List can reserve exactly the height the panel occupies. Note:
  /// `.contentMargins(.bottom, _, for: .scrollContent)` is the
  /// ScrollView-native modifier for this purpose but `List(.sidebar)`
  /// on macOS 26 ignores it — see commit 6c1c3631. The invisible
  /// `Color.clear` row inside `treeBody`'s List is the workaround.
  private var clampedActiveAgentsPanelHeight: Double {
    let minH = Self.activeAgentsPanelMinHeight
    let maxH = max(minH, sidebarHeightObservation * 0.5)
    return min(max(activeAgentsPanelHeight, minH), maxH)
  }
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(WorktreeStatusMonitor.self) private var worktreeStatusMonitor
  @Environment(WorktreeLocalDiffMonitor.self) private var worktreeLocalDiffMonitor
  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?

  /// Tracks whether the `.command` modifier is currently pressed. When held the sidebar
  /// reveals per-row `⌃N` hotkey hints (and the matching `⌃1`–`⌃9` / `⌃0` bindings).
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

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

  /// Flips to true once `_UnclampedClipView` has been swapped in. Until then
  /// the List renders at `opacity(0)` so the user never sees the unshifted
  /// (x=0) frames the AppKit introspection retries paper over.
  @State private var sidebarIndentReady = false

  /// Heterogeneous sidebar rows in render order: main → pinned → pending →
  /// unpinned. Per-segment rules and rationale live in
  /// docs/design-docs/worktree-sidebar-ordering.md §渲染合并. `pendings`
  /// is filtered to the given project (caller passes the full sidebar-wide
  /// list). Used by ordering tests + the hotkey enumeration shim; the
  /// production view splits the segments across separate ForEach blocks
  /// so each can own its own .onMove.
  static func orderedSidebarRows(
    project: Project,
    pendings: [PendingWorktree]
  ) -> [SidebarRow] {
    let visible = project.worktrees.filter { !$0.archived }
    let main = visible.filter { $0.path == project.rootPath }
    let pinned = visible.filter { $0.isPinned && $0.path != project.rootPath }
    let rest = visible.filter { !$0.isPinned && $0.path != project.rootPath }
    let projectPending = pendings.filter { $0.projectID == project.id }
    return main.map(SidebarRow.worktree)
      + pinned.map(SidebarRow.worktree)
      + projectPending.map(SidebarRow.pending)
      + rest.map(SidebarRow.worktree)
  }

  /// Compat shim for the hotkey-enumeration path (`treeBody.hotkeyIndex`),
  /// which only assigns slots to real worktrees. Derived from
  /// `orderedSidebarRows` so the segment ordering stays in one place; the
  /// `pendings: []` argument is correct for hotkey purposes — pending rows
  /// never claim a `⌃N` slot per design doc §pending 段 用户操作.
  static func orderedVisibleWorktrees(in project: Project) -> [Worktree] {
    orderedSidebarRows(project: project, pendings: []).compactMap { row in
      if case .worktree(let w) = row { return w } else { return nil }
    }
  }

  var body: some View {
    let catalog = hierarchyManager.catalog
    // Force `@Observable` subscription to `agentRegistry.entries` even
    // while the panel is closed and `registry` is never unwrapped in
    // the conditional below. Without this top-level read the body
    // never re-evaluates on entry mutations, and the `.onChange(of:
    // anyAgentNeedsAttention)` modifier below never fires the auto-open
    // transition (the rising edge into "any agent is loading").
    let _ = anyAgentNeedsAttention

    // Filter the project list by the catalog's active tag filter (M4).
    // OR semantics on `.tags(set)`; `.untagged` shows projects with no
    // tags; `.all` is the no-op default.
    let visibleProjects = catalog.sorted(filteredProjects(catalog: catalog))
    let untaggedExists = catalog.projects.contains { $0.tagIDs.isEmpty }
    // Display-name index used by the manual-sort sheet; built from the
    // authoritative array (not `visibleProjects`) so a hidden / filtered
    // project still resolves to its real name in the dialog.
    let projectNames: [ProjectID: String] = Dictionary(
      uniqueKeysWithValues: catalog.projects.map { ($0.id, $0.name) }
    )

    // Sidebar body: the upper ZStack is the only area the
    // ActiveAgents panel may draw into. Clipping this region is
    // essential on macOS 26: List overlays can paint past their
    // allocated frame while a bottom move transition is entering, so
    // an unclipped panel visually covers the footer sibling below.
    // With the panel mounted inside this clipped slot, its bottom
    // transition is cut at the footer's top edge and reads as sliding
    // up from beneath the fixed footer.
    VStack(spacing: 0) {
      ZStack(alignment: .bottom) {
        treeBody(
          projects: visibleProjects,
          bottomInsetHeight: activeAgentsPanelOpen ? clampedActiveAgentsPanelHeight : 0
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

        if activeAgentsPanelOpen, let registry = activeAgentsRegistry {
          ActiveAgentsSidebarPanel(
            registry: registry,
            resolveSourcePath: { paneID in
              resolveActiveAgentsSourcePath(
                paneID: paneID,
                catalog: hierarchyManager.catalog
              )
            },
            focusedPaneID: currentlyFocusedPaneID(),
            onTapRow: { paneID in
              // Panel stays open after a row tap — the user often
              // fan-jumps between agents and re-opening the panel
              // each time is friction.
              onActiveAgentsRowTapped(paneID)
            },
            onClose: {
              withAnimation(.easeOut(duration: 0.18)) {
                activeAgentsPanelOpen = false
              }
            },
            height: $activeAgentsPanelHeight,
            minHeight: Self.activeAgentsPanelMinHeight,
            maxHeight: max(Self.activeAgentsPanelMinHeight, sidebarHeightObservation * 0.5)
          )
          .zIndex(1)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .clipped()
      // `activeAgentsPanelOpen` is backed by `@AppStorage`, whose
      // change notification is delivered through `UserDefaults` and
      // does not preserve the SwiftUI Transaction set up by
      // `withAnimation { ... }` at the mutation site. Attaching an
      // explicit `.animation(_:value:)` here re-establishes the
      // transition so the panel slides in/out instead of popping.
      .animation(.easeOut(duration: 0.18), value: activeAgentsPanelOpen)

      TagFilterPopoverFooter(
        tags: catalog.tags,
        activeFilter: catalog.activeTagFilter,
        showUntaggedChip: untaggedExists,
        onAllTapped: { store.send(.allChipTapped) },
        onTagTapped: { store.send(.tagChipTapped($0)) },
        onUntaggedTapped: { store.send(.untaggedChipTapped) },
        onEditTagsTapped: { store.send(.delegate(.openTagManager)) },
        onRefreshTapped: { store.send(.refreshAllProjectsTapped) },
        sortMode: catalog.projectSortMode,
        onSortModeChanged: { store.send(.projectSortModeChanged($0)) },
        onManualSortRequested: { store.send(.manualSortSheetRequested) },
        onActiveAgentsTapped: activeAgentsRegistry == nil
          ? nil
          : {
            withAnimation(.easeOut(duration: 0.18)) {
              activeAgentsPanelOpen.toggle()
            }
          },
        activeAgentsPanelOpen: activeAgentsPanelOpen
      )
      .zIndex(2)
    }
    // Auto-open the Agents View panel on the rising edge into "any
    // bound agent is loading" — but only when the user has the
    // Settings → General toggle on. We do NOT auto-close when the
    // signal falls back to false; the user keeps the panel open
    // until they explicitly close it via the footer toggle. The
    // observed value is a Bool so SwiftUI's `.onChange` fires only
    // on real transitions (not every dict mutation).
    .onChange(of: anyAgentNeedsAttention) { oldValue, newValue in
      autoOpenLogger.debug(
        "anyAgentNeedsAttention transition \(oldValue, privacy: .public)->\(newValue, privacy: .public) autoOpen=\(self.settingsStore.settings.general.agentsViewAutoOpen, privacy: .public) panelOpen=\(self.activeAgentsPanelOpen, privacy: .public)"
      )
      guard newValue,
        settingsStore.settings.general.agentsViewAutoOpen,
        !activeAgentsPanelOpen
      else { return }
      autoOpenLogger.info("auto-opening Agents View panel")
      withAnimation(.easeOut(duration: 0.18)) {
        activeAgentsPanelOpen = true
      }
    }
    .sheet(
      isPresented: Binding(
        get: { store.manualSortSheet != nil },
        set: { isPresented in
          if !isPresented {
            store.send(.manualSortCancelled)
          }
        }
      )
    ) {
      ManualProjectSortSheetView(projectNames: projectNames, store: store)
    }
    .toolbar { sidebarToolbarContent }
    .sheet(
      isPresented: Binding(
        get: { store.createWorktreeSheet != nil },
        set: { isPresented in
          if !isPresented {
            store.send(.createWorktreeSheet(.cancelButtonTapped))
          }
        }
      )
    ) {
      if let childStore = store.scope(
        state: \.createWorktreeSheet,
        action: \.createWorktreeSheet
      ) {
        CreateWorktreeSheet(store: childStore)
      }
    }
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
      Text(
        "Closes all panes and deletes the Worktree directory, including any uncommitted changes. This cannot be undone."
      )
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
      Text("Removes the Project and closes all its panes. Files on disk are not affected.")
    }
    // Archived Worktrees sheet (opened from Project ⋯ menu).
    .sheet(
      isPresented: Binding(
        get: { store.archivedWorktreesSheet != nil },
        set: { if !$0 { store.send(.archivedWorktreesSheetDismissed) } }
      )
    ) {
      if let childStore = store.scope(
        state: \.archivedWorktreesSheet,
        action: \.archivedWorktreesSheet
      ) {
        ArchivedWorktreesSheet(store: childStore)
      }
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
      Text("Files and branch are kept. Find it later under “Archived Worktrees” in the Project menu.")
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
    ToolbarItem(placement: .primaryAction) {
      Button {
        store.send(.toolbarAddProjectTapped)
      } label: {
        Label("Add Project", systemImage: "plus")
          .commandKeyHint(.addProject)
      }
      .helpWithShortcut("Add Project", .addProject)
    }
  }

  // MARK: - Tag filter (M4)

  /// Apply `Catalog.activeTagFilter` to `catalog.projects`. Linear scan;
  /// project counts are small enough (<200) that a per-render filter is
  /// sub-millisecond.
  private func filteredProjects(catalog: Catalog) -> [Project] {
    switch catalog.activeTagFilter {
    case .all:
      return catalog.projects
    case .tags(let set) where set.isEmpty:
      // Empty `.tags` is normalized to `.all` by the manager but defend
      // here too — a corrupted catalog shouldn't hide every project.
      return catalog.projects
    case .tags(let set):
      return catalog.projects.filter { !$0.tagIDs.isDisjoint(with: set) }
    case .untagged:
      return catalog.projects.filter { $0.tagIDs.isEmpty }
    }
  }

  // MARK: - Tree

  @ViewBuilder
  private func treeBody(projects: [Project], bottomInsetHeight: Double) -> some View {
    if projects.isEmpty {
      emptyState
    } else {
      // Top-down flat enumeration of visible worktrees across projects, following the
      // same main → pinned → others partition the rows themselves render in. Used to
      // assign `⌃1`…`⌃9` plus `⌃0` (10th slot) and reveal matching hints while ⌘ is
      // held. Archived rows live in a separate sheet and never claim a hotkey slot.
      let hotkeyIndex: [WorktreeID: Int] = {
        var map: [WorktreeID: Int] = [:]
        var slot = 0
        for project in projects {
          for worktree in Self.orderedVisibleWorktrees(in: project) {
            if slot >= 10 { return map }
            map[worktree.id] = slot
            slot += 1
          }
        }
        return map
      }()
      // List + .listStyle(.sidebar) with NO `.scrollIndicators(.*)` modifier.
      // On macOS 26 / NavigationSplitView sidebar columns, both `.hidden` and
      // `.never` silently collapse the List's top titlebar safe area — the
      // first row then draws at y=0, overlapping with the traffic lights.
      // Accepting the scroller-when-needed trade-off; the default indicator
      // posture is fine for source-list-style sidebars.
      ScrollViewReader { proxy in
        List(selection: nativeSelectionBinding) {
          ForEach(projects) { project in
            projectSection(project, hotkeyIndex: hotkeyIndex)
          }
        }
        .listStyle(.sidebar)
        // Bottom safe-area-inset sized to the live ActiveAgents panel
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
          guard let worktreeID = currentSelection.worktreeID else { return }
          withAnimation { proxy.scrollTo(worktreeID, anchor: .center) }
        }
      }
    }
  }

  /// HAN-65: empty-state copy is English and reflects the actual
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
      Button {
        store.send(.toolbarAddProjectTapped)
      } label: {
        Label("Open Project", systemImage: "plus")
          .commandKeyHint(.addProject)
      }
      .buttonStyle(.borderedProminent)
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
    if let resolved = resolvedShortcuts[.addProject], resolved.isEnabled, let binding = resolved.binding {
      return ShortcutDisplay.chord(for: binding)
    }
    if let fallback = ShortcutSchema.app.entry(for: .addProject)?.defaultBinding {
      return ShortcutDisplay.chord(for: fallback)
    }
    return nil
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
      case .loading, .ready:
        // Header is its own List row. DisclosureGroup used to nest the worktree rows
        // inside the header row — that made AppKit animate the single wrapping row's
        // height on every expand / collapse, visibly jittering the Project name.
        // Emitting header + each worktree as SIBLING rows lets NSTableView handle
        // expansion as plain row insert / remove instead.
        Button {
          var txn = Transaction()
          txn.disablesAnimations = true
          withTransaction(txn) {
            store.send(.toggleProjectExpansion(project.id))
          }
        } label: {
          ProjectHeaderRow(
            project: project,
            isExpanded: isExpanded,
            store: store
          )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        if isExpanded {
          // Render the four segments individually so pinned and unpinned
          // each own their own ForEach + .onMove (per design doc §渲染合并
          // / 拖拽). Pending rows render in source order between pinned
          // and unpinned; main and pending segments do not admit reorder.
          let visible = project.worktrees.filter { !$0.archived }
          let mainRows = visible.filter { $0.path == project.rootPath }
          let pinnedRows = visible.filter { $0.isPinned && $0.path != project.rootPath }
          let unpinnedRows = visible.filter { !$0.isPinned && $0.path != project.rootPath }
          let pendingRows = store.pendingWorktrees.filter { $0.projectID == project.id }
          ForEach(mainRows) { worktree in
            worktreeRow(worktree, in: project, hotkeySlot: hotkeyIndex[worktree.id])
          }
          ForEach(pinnedRows) { worktree in
            worktreeRow(worktree, in: project, hotkeySlot: hotkeyIndex[worktree.id])
          }
          .onMove { source, destination in
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
          }
          .onMove { source, destination in
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

  // MARK: - Pending row

  /// Wires task03's `PendingWorktreeRow` into the segment ForEach with
  /// Cancel / Retry / Discard handlers dispatched to the lifecycle reducer.
  @ViewBuilder
  private func pendingRow(_ pending: PendingWorktree) -> some View {
    PendingWorktreeRow(
      pending: pending,
      onCancel: { store.send(.pendingWorktreeCancelTapped(pending.id)) },
      onRetry: { store.send(.pendingWorktreeRetryTapped(pending.id)) },
      onDiscard: { store.send(.pendingWorktreeDiscardTapped(pending.id)) }
    )
    // Match the worktree row's `listRowInsets` so the spinner + name line up
    // with sibling worktree rows. Without this the row renders flush-left
    // because the clip-view shift compensated by `leading: 14` (see
    // `worktreeRow`) is not applied.
    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 0))
    .listRowSeparator(.hidden)
  }

  // MARK: - Worktree row

  private func worktreeRow(
    _ worktree: Worktree,
    in project: Project,
    hotkeySlot: Int?
  ) -> some View {
    let isSelected = currentSelection.worktreeID == worktree.id
    let snapshot = gitHubStore?.snapshots[worktree.id]
    let rollup: PullRequestBadge.CheckRollup = {
      // 0013 M5: rollup data travels with the snapshot now (filled by the batched
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
    return HStack(spacing: 6) {
      rowSelectionButton(
        worktree: worktree, project: project,
        snapshot: snapshot, rollup: rollup,
        hotkeyNumber: hotkeyNumber,
        isSelected: isSelected
      )
      diffStatsChip(for: worktree, in: project, snapshot: snapshot)
      gitHubBadge(for: worktree, in: project)
      // Trailing chord hint, after both the row content and the optional PR pill so it
      // always pins to the right edge of the row instead of being shoved leftwards by
      // the pill's intrinsic width. Visible only while ⌘ is held.
      if let hotkeyNumber, commandKeyObserver.isCommandHeld {
        Text("⌃\(hotkeyNumber == 10 ? "0" : String(hotkeyNumber))")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .overlay(
            RoundedRectangle(cornerRadius: 3)
              .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
          )
          .accessibilityHidden(true)
      }
    }
    // Worktree rows are real List children. Selection chrome is owned by
    // SwiftUI's native `List(selection:)` (see `nativeSelectionBinding`):
    // `.tag(worktree.id)` makes the row a selectable target so AppKit's
    // sourceList renderer paints the focus-aware highlight (emphasized blue
    // when sidebar holds first-responder, unemphasized grey when focus
    // moves to a terminal pane), with the matching white / dark text.
    // Leading 14 compensates the +6pt clip-view shift in
    // `_UnclampedClipView` and adds a +8pt visual indent so worktree content
    // reads as a child level under the (left-aligned) project header.
    .tag(worktree.id)
    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 0))
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
    }
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
    let isMainCheckout = worktree.path == project.rootPath
    // Dir-kind Projects auto-inject a single Worktree pointing at `rootPath`
    // (HierarchyManager.addProject). Detect it locally rather than via a
    // shared computed property — `gitRoot == nil` + path match is the same
    // pair already used to suppress git affordances elsewhere in this view.
    let isSyntheticWorktree = isMainCheckout && project.gitRoot == nil
    // Plain content (no Button wrapping). With native `List(selection:)`,
    // the row's tap is owned by AppKit's NSTableView so the click also
    // promotes the table to first responder — that's what flips the
    // selection chrome from unemphasized grey to emphasized blue. A
    // SwiftUI Button at the row's leading area would intercept the
    // click, leave the table off-responder, and the row would stay grey
    // even though state moved.
    let isLifecycleInProgress = store.lifecycleInProgressWorktrees.contains(worktree.id)
    // Aggregated "any pane in this worktree is executing" signal. Reads through
    // `HierarchyManager.worktreeIsDirty(_:)`, an `@Observable` getter, so the
    // spinner appears/disappears automatically as OSC 9;4 progress reports flip
    // `runningPanes`. Rendered at the leading icon slot (replacing
    // WorktreeRowIcon) so the row's running indicator lives in the same place
    // as the lifecycle spinner — one consistent "this row is busy" affordance.
    let isExecuting = hierarchyManager.worktreeIsDirty(worktree.id)
    let content = HStack(spacing: 6) {
      Group {
        if isLifecycleInProgress {
          // Archive / delete is mid-flight (lifecycle script running in
          // a pane, then the catalog mutation). Swap the row icon for a
          // spinner so the click feels acknowledged; the row vanishes
          // once the wrapper completes (archive → archived list, delete
          // → gone).
          ProgressView()
            .controlSize(.small)
            .frame(width: 14, height: 14)
            .accessibilityLabel("Working")
        } else if isExecuting {
          ProgressView()
            .controlSize(.small)
            .frame(width: 14, height: 14)
            .accessibilityLabel("Worktree has a running command")
        } else {
          WorktreeRowIcon(
            snapshot: snapshot, rollup: rollup, isSelected: isSelected,
            isSynthetic: isSyntheticWorktree,
            hasUnreadNotification: notificationRollup?.current.unreadWorktrees.contains(worktree.id) == true
              && settingsStore.settings.notifications.worktreeBellEnabled,
            isDefaultBranch: isMainCheckout && !isSyntheticWorktree
          )
        }
      }
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Text(worktree.name)
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
        // Suppress the secondary branch line when it restates the worktree name —
        // the common case (main/main, test0003/test0003) otherwise doubles every
        // row height for zero information.
        if let branch = worktree.branch, branch != worktree.name {
          Text(branch)
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

    // The per-row hotkey still requires a Button to bind to. Mount a
    // 0×0 invisible Button via `.background` so the shortcut lives in
    // the responder chain without painting pixels or competing with
    // List's hit-test for clicks (zero frame == zero hit area). The
    // chord itself comes from the shortcut registry — defaults are
    // ⌃1..⌃9 / ⌃0 but a user rebind takes effect here without restart.
    if let hotkeyNumber, let commandID = CommandID.selectWorktreeAt(index: hotkeyNumber) {
      content.background(alignment: .topLeading) {
        Button {
          store.send(.worktreeRowTapped(worktree.id, inProject: project.id))
        } label: {
          EmptyView()
        }
        .appKeyboardShortcut(commandID, in: resolvedShortcuts)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
      }
    } else {
      content
    }
  }

  // Main-checkout guard: the row whose path is the Project's rootPath is the main checkout
  // and cannot be archived or removed from the app (spec W-Q3 guard). Extracted so the row
  // body stays under swiftlint's function_body_length limit.
  @ViewBuilder
  private func worktreeContextMenu(
    worktree: Worktree, project: Project
  ) -> some View {
    let isMainCheckout = worktree.path == project.rootPath

    // Group 1 — Open / Reveal. Top-level "Open in <Default>" surfaces
    // the resolved editor by name (project override → global default →
    // priority cascade); the "Open in" submenu lists every installed
    // editor for explicit overrides; "Reveal in Finder" rounds out the
    // navigation group.
    openInDefaultButton(worktree: worktree, project: project)
    openInSubmenu(worktree: worktree, project: project)
    Button {
      store.send(.worktreeRevealInFinderTapped(path: worktree.path))
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }
    .appKeyboardShortcut(.revealCurrentWorktreeInFinder, in: resolvedShortcuts)

    // Group 2 — Copy. Pathname + branch name onto the general pasteboard.
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

    // Group 3 — Worktree lifecycle. Hidden for the main checkout (W-Q3
    // guard: cannot pin / archive / remove the project's root worktree).
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
      if let descriptor = resolvedDefaultEditor(for: project.id) {
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

  /// Reads a 16×16 copy of the bundle's icon. The `NSWorkspace` cache
  /// returns a multi-representation image; we copy and rescale so
  /// neither our menu rendering nor any other consumer of the cached
  /// icon ends up with a one-off size mutation.
  private func appIcon(at appURL: URL) -> NSImage {
    let icon = NSWorkspace.shared.icon(
      forFile: appURL.path(percentEncoded: false)
    )
    let copy = (icon.copy() as? NSImage) ?? icon
    copy.size = NSSize(width: 16, height: 16)
    return copy
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

  // MARK: - Diff stats chip

  /// Compact `+N −M` chip rendered to the right of the row content. Counts
  /// come from `WorktreeLocalDiffMonitor` (`git diff HEAD --shortstat`) so
  /// every worktree — PR-matched or not — surfaces the same "uncommitted
  /// edits in this worktree" signal. Refresh on HEAD events is wired in
  /// `RootFeature.worktreeHeadChanged`; row-mount falls back to the
  /// monitor's freshness window. The titlebar `StatusPullRequestView` still
  /// shows the PR's pushed `+/−` for the active worktree if users want the
  /// at-base comparison.
  @ViewBuilder
  fileprivate func diffStatsChip(
    for worktree: Worktree, in project: Project, snapshot: PullRequestSnapshot?
  ) -> some View {
    if let local = worktreeLocalDiffMonitor.stats[worktree.id] ?? nil,
      local.additions > 0 || local.deletions > 0
    {
      DiffStatsChip(
        additions: local.additions,
        deletions: local.deletions,
        onTap: { [worktreeID = worktree.id, projectID = project.id] in
          store.send(.delegate(.openGitViewerRequested(projectID: projectID, worktreeID: worktreeID)))
        }
      )
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
        // 0013 M5: checks now travel inside the snapshot (see the comment on
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
            .mergeRequested(worktreeID, prNumber: pr.number, strategy: strategy, worktreePath: worktreePath)
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
          store.send(.markReadyRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
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
        store.send(.refreshRequested(worktreeID, branch: branch, worktreePath: worktreePath))
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
  /// ActiveAgents sidebar panel via `.onChange`, gated by Settings →
  /// General → `agentsViewAutoOpen`. Exposed as a `Bool` so `.onChange`
  /// fires only on real transitions, not on every entry mutation.
  private var anyAgentNeedsAttention: Bool {
    guard let entries = activeAgentsRegistry?.entries else { return false }
    return entries.values.contains { entry in
      entry.state == .working || entry.state == .blocked
    }
  }

  /// Walks the selection chain (project → worktree → tab) and returns
  /// the pane the user is currently focused on, or nil when the chain
  /// breaks (no project selected, archived worktree, etc.). Used by the
  /// ActiveAgents sidebar panel to highlight the row corresponding to
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
private struct ProjectHeaderRow: View {
  let project: Project
  /// Drives the leading disclosure chevron (`chevron.right` collapsed, `chevron.down`
  /// expanded). The parent Button still owns the tap, so this is display-only.
  var isExpanded: Bool = false
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  @Environment(RollupIndexProvider.self) private var rollup: RollupIndexProvider?
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts
  @State private var isHovering = false
  @State private var isPlusHovering = false
  @State private var isMenuHovering = false

  var body: some View {
    let hasUnread =
      rollup?.current.unreadProjects.contains(project.id) == true
      && settingsStore.settings.notifications.projectBellEnabled
    HStack(spacing: 6) {
      // L4 unread indicator. When the project is in `unreadProjects`
      // (rollup rule = project collapsed + unread inside), the leading
      // disclosure chevron swaps for a red bell glyph — same pattern as
      // the worktree row icon. Click target / disclosure semantics are
      // unchanged: the parent Button still owns the tap.
      if hasUnread {
        Image(systemName: "bell.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 10, height: 10, alignment: .center)
          .foregroundStyle(Color.orange)
          .accessibilityLabel("Has unread notifications")
      } else {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 10, alignment: .center)
          .accessibilityHidden(true)
      }
      Text(project.name)
        .font(.subheadline)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .lineLimit(1)
      Spacer(minLength: 4)
      // Keep the hover chrome from collapsing row width when hidden —
      // use opacity, not conditional rendering.
      HStack(spacing: 2) {
        // Non-git Projects (P-Q4 = a): suppress the Add Worktree affordance.
        // Worktrees are a git-only concept; a scratch folder renders with a
        // single synthetic Worktree and nothing to add.
        if project.supportsWorktrees {
          Button {
            store.send(.projectAddWorktreeTapped(projectID: project.id))
          } label: {
            iconLabel(systemName: "plus", isHovering: isPlusHovering)
              .accessibilityLabel("Add Worktree under this Project")
          }
          .buttonStyle(.plain)
          .onHover { isPlusHovering = $0 }
        }
        Menu {
          Button {
            store.send(.projectSettingsTapped(projectID: project.id))
          } label: {
            Label("Project Settings…", systemImage: "slider.horizontal.3")
          }
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
          Button {
            store.send(.projectPruneTapped(projectID: project.id))
          } label: {
            Label("Prune Stale Worktrees", systemImage: "wand.and.sparkles")
          }
          Divider()
          // M5 (project-tags): inline color palette + "Tags…" entry.
          // ControlGroup(.palette) gives the native NSMenu color row;
          // "Tags…" opens the global TagManager via the sidebar's
          // `.openTagManager` delegate.
          ProjectTagsMenu(project: project, store: store)
          Divider()
          Button(role: .destructive) {
            store.send(
              .projectRemoveTapped(projectID: project.id, name: project.name)
            )
          } label: {
            Label("Remove Project", systemImage: "trash")
          }
        } label: {
          iconLabel(systemName: "ellipsis", isHovering: isMenuHovering)
            .accessibilityLabel("Project options")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isMenuHovering = $0 }
      }
      .opacity(isHovering ? 1 : 0)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }

  /// 22×22 hit target with a subtle hover background. Used by the trailing
  /// "+" and "..." affordances so both share the same affordance footprint
  /// and so the click target is comfortably larger than the underlying SF
  /// Symbol glyph.
  @ViewBuilder
  private func iconLabel(systemName: String, isHovering: Bool) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(isHovering ? .primary : .secondary)
      .frame(width: 22, height: 22)
      .background(
        Circle().fill(Color.primary.opacity(isHovering ? 0.08 : 0))
      )
      .contentShape(Circle())
  }
}

/// Transparent helper that hunts down the AppKit `NSOutlineView` backing
/// `List(.sidebar)` and applies two leading-edge adjustments:
///
///   1. Zero `NSOutlineView`'s built-in indentation / intercell spacing, so
///      rows have no per-level offset on top of the scroll-view gutter.
///   2. Swap the scroll view's clip view for `_UnclampedClipView`, which pins
///      `bounds.origin.x` at a fixed offset — visually shifting all row
///      content leftward by that amount (defeats SwiftUI sidebar style's
///      internal leading padding without losing hit-testing).
///
/// Retries a few times because the List may not be attached when
/// `viewDidMoveToWindow` first fires. Fires `onReady` once any outline has
/// been patched so the SwiftUI parent can gate visibility on install — the
/// 6pt clip-view shift would otherwise visibly snap rows left mid-launch.
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
      installUnclampedClipView(for: outline, leadingOffset: 6)
    }
    if !outlines.isEmpty, !didFireReady {
      didFireReady = true
      onReady?()
    }
  }

  /// Replaces the scroll view's clip view with `_UnclampedClipView` (idempotent)
  /// and pins its `leadingOffset`. Preserves the original clip view's
  /// background / cursor / copy-on-scroll state so the visual stays identical
  /// apart from the horizontal shift.
  ///
  /// `constrainBoundsRect:` only fires on AppKit-initiated bounds proposals
  /// (scroll, resize, animation), so on first install we drive `setBoundsOrigin`
  /// + `tile()` ourselves — otherwise the leading shift only "kicks in" after
  /// the first user interaction.
  private func installUnclampedClipView(for outline: NSOutlineView, leadingOffset: CGFloat) {
    guard let scrollView = outline.enclosingScrollView else { return }
    // `bounds.origin.y` on the original clip view encodes the top
    // content-inset / safe-area offset AppKit sets during initial layout
    // (titlebar gutter on a sidebar column). A freshly allocated
    // _UnclampedClipView starts at y=0, so we must carry that y forward —
    // otherwise rows render visibly lower than the eventual steady-state.
    let preservedY = scrollView.contentView.bounds.origin.y
    if !(scrollView.contentView is _UnclampedClipView) {
      let oldClip = scrollView.contentView
      let newClip = _UnclampedClipView()
      newClip.drawsBackground = oldClip.drawsBackground
      newClip.backgroundColor = oldClip.backgroundColor
      newClip.copiesOnScroll = oldClip.copiesOnScroll
      newClip.documentCursor = oldClip.documentCursor
      scrollView.contentView = newClip
      if scrollView.documentView !== outline { scrollView.documentView = outline }
    }
    guard let clip = scrollView.contentView as? _UnclampedClipView else { return }
    clip.leadingOffset = leadingOffset
    clip.setBoundsOrigin(NSPoint(x: leadingOffset, y: preservedY))
    scrollView.tile()
    scrollView.reflectScrolledClipView(clip)
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

/// `NSClipView` subclass that pins horizontal `bounds.origin.x` to a fixed
/// offset (`leadingOffset`) so the documentView visually shifts left by that
/// amount — bypassing super's clamp that snaps `x` back to 0 for a non-
/// horizontally-scrollable clip view.
///
/// Why pin instead of returning the proposed rect verbatim: AppKit calls
/// `constrainBoundsRect:` during animation / momentum scroll with values
/// that include `±infinity` (legitimate intermediates that super would
/// normally sanitize). Returning identity for those crashes the geometry
/// pipeline (`Invalid view geometry: x is -infinity`). Calling super first
/// hands us a finite, sensible rect; we only override the axis we control.
///
/// Per the AppKit 10.9 release notes and WWDC 2013 §215, `constrainBoundsRect:`
/// is the sanctioned override point for custom positioning; this does NOT
/// disable responsive scrolling (that requires overriding `scrollWheel:`,
/// which we do not do) or elastic scrolling (governed by independent
/// `verticalScrollElasticity`/`horizontalScrollElasticity` properties).
private final class _UnclampedClipView: NSClipView {
  /// Target `bounds.origin.x` — positive shifts documentView visually left
  /// by that many points (we're "scrolling right" without horizontal scroll).
  var leadingOffset: CGFloat = 0

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    rect.origin.x = leadingOffset
    return rect
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

/// Captures the sidebar column's live height so the ActiveAgents bottom
/// panel can clamp to half of it. Updated each time SwiftUI re-measures
/// the sidebar background.
private struct SidebarHeightPreferenceKey: PreferenceKey {
  static let defaultValue: Double = 0
  static func reduce(value: inout Double, nextValue: () -> Double) {
    value = max(value, nextValue())
  }
}

/// Walks the catalog for a paneID and returns the (projectName,
/// worktreeName) pair the ActiveAgents row needs for its breadcrumb.
/// Returns nil when the pane has been torn down between event delivery
/// and the next popover render — the row renders an em-dash fallback.
private func resolveActiveAgentsSourcePath(
  paneID: PaneID,
  catalog: Catalog
) -> (project: String, worktree: String)? {
  for project in catalog.projects {
    for worktree in project.worktrees
    where worktree.tabs.contains(where: { tab in
      tab.panes.contains(where: { $0.id == paneID })
    }) {
      return (project.name, worktree.name)
    }
  }
  return nil
}
