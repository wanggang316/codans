import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// Renders the detail column for the selected Worktree: tab bar on top,
/// split viewport underneath. Both reach into the environment
/// `HierarchyManager` for catalog reads; neither duplicates state.
///
/// If `selection` does not resolve to a live Worktree (nil IDs, or IDs
/// that no longer exist after a prune), renders a neutral "Select a
/// Worktree" prompt.
struct WorktreeDetailView: View {
  @Bindable var store: StoreOf<WorktreeDetailFeature>
  let selection: HierarchySelection
  /// Scoped editor-feature store; passed in by `ContentView` so the Worktree-header
  /// dropdown shares a single editor-state source of truth with the Settings sheet.
  /// Open-result toasts are driven by `editorStore.state.lastOpenResult` directly from
  /// `ContentView`, so this view does not accept a callback.
  let editorStore: StoreOf<EditorFeature>
  /// AgentState registry (optional). Threaded down to `TabBarView` so a tab
  /// chip lights while a bound agent in that tab is `.working` — the same
  /// registry `ContentView` hands the sidebar, kept in sync by construction.
  var agentStateStore: AgentStateStore?
  /// Header feature — scoped by `ContentView` from the root. Drives the bell
  /// badge and the Open-in split button's delegate routing.
  let headerStore: StoreOf<WorktreeHeaderFeature>
  /// Titlebar-center Worktree Status Bar store. Owns the toast slot; PR /
  /// motivational forms are view-level projections of other scopes.
  let statusBarStore: StoreOf<StatusBarFeature>
  /// Scoped GitHub feature store; read for the PR form's
  /// `snapshots[worktreeID]` lookup. Same store the sidebar badge reads so
  /// the two surfaces stay in sync by construction.
  let gitHubStore: StoreOf<GitHubFeature>
  /// Branch popover + switch state. Threaded through to the leading
  /// toolbar `WorktreeHeaderInfoLabel` (popover anchor) and to the inline
  /// `BranchSwitcherErrorBannerView` rendered under the toolbar.
  let branchSwitcherStore: StoreOf<BranchSwitcherFeature>
  /// Invoked from the empty-state Add Project button. Wired by `ContentView`
  /// so the detail view doesn't need to hold the sidebar's TCA scope just
  /// to fire `toolbarAddProjectTapped` — same pattern as the editor toast
  /// that surfaces sidebar outcomes without a back-channel store.
  let onAddProject: () -> Void
  /// v1 notifications: dispatches `RootFeature.focusHierarchyPath` from
  /// the InboxBellView's row-tap. Wired by `ContentView` so this view
  /// doesn't need to hold the root TCA scope just to fire one action.
  let onFocusHierarchyPath: (InboxEntry.SourcePath) -> Void
  /// Bumped by `RootFeature` when the user invokes ⌘U / the "Show Unread
  /// Notifications" menu item. Threaded down to `InboxBellView` whose
  /// `.onChange` opens the popover — same UUID-trigger pattern as
  /// `revealSelectionTrigger` for the sidebar.
  let inboxBellPopoverTrigger: UUID
  /// `RootFeature.activePendingWorktreeID` resolved to its row in
  /// `sidebar.pendingWorktrees`, plus the parent Project's display
  /// name. Non-nil → the detail pane shows `WorktreeLoadingView`
  /// regardless of `selection`; the resolver in `ContentView` already
  /// drops back to nil when the pending row leaves the array (success
  /// / cancel / discard), so this view doesn't have to track state
  /// transitions itself. Failure mode keeps the row in the array with
  /// `.failed` status and is surfaced as the `failed(message:)` kind.
  let activePendingWorktree: PendingWorktreeBinding?
  @Environment(HierarchyManager.self) private var hierarchyManager

  /// Window-toolbar chrome is hidden window-wide (see the
  /// `.toolbarBackground(.hidden, ...)` modifier below) to stop tab-switch
  /// repaints from flickering across the translucent sidebar. In fullscreen
  /// the title bar disappears entirely, so the hidden chrome leaves the
  /// sidebar's `+` button and the detail toolbar items floating over the
  /// terminal panes with no backing. Tracking the main window's fullscreen
  /// state lets us re-enable the system chrome while fullscreen — the
  /// flicker concern doesn't apply in fullscreen because there is no
  /// floating-sidebar overlay to repaint behind.
  @State private var isWindowFullscreen: Bool = false

  /// View-only projection of the in-flight pending row plus the
  /// repository-side context the loading view needs. Built by
  /// `ContentView` so this struct doesn't depend on TCA state shapes.
  struct PendingWorktreeBinding: Equatable {
    let pending: PendingWorktree
    let repositoryName: String?
  }

  var body: some View {
    detailBody
      // Paint a low-alpha Ghostty-terminal-background band into the
      // detail's top + leading safe-area insets. The unified toolbar
      // (`.toolbarBackground(.hidden)` below) and the macOS 26
      // floating-sidebar overlay both render their glass material over
      // the detail content, so painting in those insets is the surface
      // the chrome actually samples. Without this the chrome is the
      // neutral system tone regardless of which terminal palette is
      // active. Skipped in fullscreen because the unified toolbar
      // collapses and the system reserves no top inset to fill.
      .ghosttyChromeTint(edges: chromeTintEdges)
  }

  /// Chrome-tint edges for the current detail state. Empty in the
  /// no-project placeholder: with no terminal on screen there is nothing
  /// to blend the chrome against, and the active Ghostty palette can be a
  /// dark-only theme that would clash with the system-appearance sidebar
  /// and the neutral empty body (gray/dark chrome framing a light window).
  /// Painting no band keeps the whole no-project window on the system tone.
  private var chromeTintEdges: Edge.Set {
    let isPlaceholder = activePendingWorktree == nil && resolveAddress() == nil
    if isPlaceholder { return [] }
    return isWindowFullscreen ? [.leading] : [.top, .leading]
  }

  @ViewBuilder
  private var detailBody: some View {
    if let mode = resolveDetailMode() {
      detailContent(mode)
        // On macOS 15+ remove the title slot entirely so default-placement
        // toolbar items can flow leading-to-trailing with `ToolbarSpacer`
        // controlling the layout.
        // `.navigationTitle("")` still reserves a leading region and would
        // push default-placement items toward the trailing edge — which is
        // why earlier centering attempts collapsed onto the right side.
        // macOS 14 keeps `.navigationTitle("")` + the older `.principal`
        // zoning since `.toolbar(removing:)` is 15+.
        .modifier(SuppressTitleModifier())
        // ONE toolbar declaration for both modes — see
        // `worktreeToolbarContent(mode:)` for why the creating and settled
        // states must not each bring their own.
        .toolbar { worktreeToolbarContent(mode: mode) }
        // Drop the system-painted window-toolbar chrome so the macOS 26
        // floating-sidebar overlay only blends against the detail body
        // underneath it. Without this, the toolbar's full-window glass
        // repaints on every toolbar-state change (tab switch rebuilds
        // `worktreeToolbarContent`) and flickers across the area covered
        // by the translucent sidebar.
        //
        // Re-show the chrome when fullscreen — without it, the sidebar `+`
        // button and detail toolbar render over the terminal pane with
        // nothing behind them (the title bar normally provides the visual
        // backing).
        .toolbarBackground(isWindowFullscreen ? .visible : .hidden, for: .windowToolbar)
        .onAppear { isWindowFullscreen = Self.detectMainWindowFullscreen() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) { _ in
          isWindowFullscreen = Self.detectMainWindowFullscreen()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in
          isWindowFullscreen = Self.detectMainWindowFullscreen()
        }
    } else {
      placeholder
    }
  }

  /// Which worktree surface the detail column renders. Resolved once per
  /// body evaluation and shared by the content region and the toolbar so
  /// the two can never disagree about which state they are drawing.
  private enum DetailMode {
    /// A creation is streaming: the content body is JUST the live output
    /// (the slimmed `WorktreeLoadingView`) and the toolbar slots hold
    /// shimmering stand-ins.
    case creating(WorktreeLoadingInfo)
    /// A real Worktree is selected. `info` is nil only in the sliver
    /// between a selection and the catalog rows it names being pruned out
    /// from under it, where the toolbar renders no items.
    case worktree(Address, WorktreeInfo?)
  }

  /// A pending creation wins over the selection: the user stays on the row
  /// being created until it settles. The resolver in `ContentView` already
  /// drops `activePendingWorktree` back to nil when the pending row leaves
  /// the array (success / cancel / discard), so this view doesn't have to
  /// track the transition itself.
  private func resolveDetailMode() -> DetailMode? {
    if let pending = activePendingWorktree {
      return .creating(loadingInfo(for: pending))
    }
    guard let address = resolveAddress() else { return nil }
    return .worktree(address, worktreeInfo(for: address))
  }

  @ViewBuilder
  private func detailContent(_ mode: DetailMode) -> some View {
    switch mode {
    case .creating(let info):
      WorktreeLoadingView(info: info)
    case .worktree(let address, _):
      VStack(spacing: 0) {
        // Inline branch-switch error banner. Renders itself only when
        // `branchSwitcherStore.switchError` is non-nil, so it stays a
        // zero-height no-op on the happy path. Placed at the top of
        // the detail body — directly under the window toolbar — so the
        // banner reads as a "drop-down notification strip" regardless
        // of which tab / pane is foreground.
        BranchSwitcherErrorBannerView(store: branchSwitcherStore)
        tabBarRow(address: address)
        terminalRegion(address: address)
      }
      .animation(.easeInOut(duration: 0.18), value: branchSwitcherStore.switchError)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// True iff any visible app window (other than Settings) is currently in
  /// macOS fullscreen. Used to gate `.toolbarBackground` so the sidebar's
  /// `+` button keeps a backing once the title bar collapses.
  private static func detectMainWindowFullscreen() -> Bool {
    NSApp.windows.contains { window in
      window.isVisible
        && window.styleMask.contains(.fullScreen)
        && !SettingsWindowTagger.matches(window)
    }
  }

  private struct WorktreeInfo {
    let worktree: Worktree
    let project: Project
  }

  private func worktreeInfo(for address: Address) -> WorktreeInfo? {
    guard
      let project = hierarchyManager.catalog
        .projects.first(where: { $0.id == address.project }),
      let worktree = project.worktrees.first(where: { $0.id == address.worktree })
    else { return nil }
    return WorktreeInfo(worktree: worktree, project: project)
  }

  /// Tab bar row above the terminal region. Branch label + bell / open-in
  /// chips used to live to the right of the tabs (old `unifiedHeader`); they
  /// moved into the window titlebar via `worktreeToolbarContent(address:)`
  /// so the content region gets its vertical space back.
  @ViewBuilder
  private func tabBarRow(address: Address) -> some View {
    TabBarView(
      store: store.scope(state: \.tabBar, action: \.tabBar),
      projectID: address.project,
      worktreeID: address.worktree,
      activeTabID: address.activeTab,
      agentStateStore: agentStateStore
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    // No solid `.windowBackgroundColor` fill: with the toolbar chrome
    // hidden, the bar reads as a continuation of the titlebar region
    // (the NSWindow's natural backdrop). A solid fill across the full
    // detail width — including the area covered by the floating
    // sidebar — turns any repaint into a visible flash.
  }

  @ViewBuilder
  private func terminalRegion(address: Address) -> some View {
    if let tabID = address.activeTab {
      SplitViewportView(
        store: store.scope(state: \.splitViewport, action: \.splitViewport),
        projectID: address.project,
        worktreeID: address.worktree,
        tabID: tabID
      )
    } else {
      emptyTab
    }
  }

  /// Window-titlebar toolbar content — ONE declaration serving both the
  /// creating and the settled state. Branch label on the leading edge,
  /// status pill + bell at the optical center, Run / Open on the trailing
  /// edge. Mirrors the layout that used to live as the right cluster of the
  /// content-region header; moving it into `.toolbar {}` reclaims vertical
  /// pixels above the tab bar and matches macOS native chrome.
  ///
  /// macOS 26 layout: every item in default placement, ordering plus
  /// `ToolbarSpacer(.flexible)` splits horizontal space evenly so the
  /// status capsule sits visually equidistant between the branch label and
  /// the trailing buttons. Pre-26 keeps the older `.navigation` /
  /// `.principal` / `.primaryAction` zoning since `ToolbarSpacer` is 26+.
  ///
  /// Both modes MUST flow through this single `.toolbar { }` with an
  /// identical item structure. When each mode declared its own toolbar,
  /// SwiftUI handed AppKit a completely different item set the moment a
  /// creation started or finished; NSToolbar tore every item down and
  /// re-inserted it, and the freshly built hosting views visibly slid in
  /// from the window's leading edge — growing into place over a second or
  /// more before settling. Switching only the *content* of each slot keeps
  /// the toolbar items themselves alive, so the swap is an in-place repaint.
  ///
  /// Slot-for-slot the creating state mirrors the settled one, so the
  /// flexible-spacer math resolves identically and nothing shifts when the
  /// real content takes over:
  ///   - LEFT: `SkeletonBranchClusterView`, sized from the pending
  ///     worktree's REAL name + project name.
  ///   - MIDDLE: `SkeletonStatusPillView` carrying the motivational form's
  ///     footprint. The bell beside it stays LIVE and interactive — it is
  ///     window-level chrome (global unread count), not worktree data.
  ///   - RIGHT: ghost Run / Open chips holding the real buttons' footprint,
  ///     so the trailing flexible spacer weighs the same in both modes.
  /// The left / middle stand-ins carry the `skeleton-left` /
  /// `skeleton-middle` accessibility ids (VAL-DETAIL-001 / VAL-DETAIL-003).
  ///
  /// `ContentView` contributes one additional trailing `ToolbarItem`
  /// (Settings gear) — SwiftUI merges both sources, with Settings rendered
  /// after the items declared here.
  @ToolbarContentBuilder
  private func worktreeToolbarContent(mode: DetailMode) -> some ToolbarContent {
    // `if … { }` with no else is the optional form `@ToolbarContentBuilder`
    // supports (`buildOptional`). An empty `if`/`else` *branch* is NOT valid
    // toolbar content (unlike `@ViewBuilder`, there is no zero-component
    // `buildBlock`), so the suppression has to be the outer guard.
    if hasToolbarItems(mode) {
      if #available(macOS 26.0, *) {
        // `.sharedBackgroundVisibility(.hidden)` opts the identity cluster
        // out of the toolbar's glass capsule so the icon + name + branch +
        // PR stats read as plain content alongside the trailing action
        // chips, matching the sidebar row.
        ToolbarItem { identitySlot(mode) }
          .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        // No `.sharedBackgroundVisibility(.hidden)` here — the status slot
        // keeps macOS 26's standard glass capsule so it reads as a peer of
        // the trailing button cluster instead of a hand-rolled chip.
        ToolbarItem { statusSlot(mode) }
        // Bell is intentionally placed *immediately* after the status
        // capsule with no flexible spacer between them — keeps the
        // status / bell pair visually grouped at the window's
        // optical center.
        inboxBellToolbarItem()
        ToolbarSpacer(.flexible)
        // Each trailing chip lives in its own `ToolbarItem` so the system
        // wraps it in a separate glass capsule — two discrete chips instead
        // of one shared cluster background. `ToolbarSpacer(.fixed)` keeps
        // them visually distinct without collapsing the gap. No
        // `.buttonStyle` / no manual padding: each item gets the toolbar's
        // native glass capsule + hover state. Order: RunScript, Open.
        ToolbarItem { runSlot(mode) }
        ToolbarSpacer(.fixed)
        ToolbarItem { openSlot(mode) }
      } else {
        ToolbarItem(placement: .navigation) { identitySlot(mode) }
        ToolbarItem(placement: .principal) { statusSlot(mode) }
        // Same as the modern path: bell sits adjacent to the principal
        // status item so the user reads "[status] [bell]" as one
        // cluster rather than seeing the bell in the trailing button
        // group with the action buttons.
        inboxBellToolbarItem()
        ToolbarItemGroup(placement: .primaryAction) {
          // Order: RunScript, Open. `ToolbarItemGroup` renders children
          // leading-to-trailing in declaration order.
          runSlot(mode).buttonStyle(.plain)
          openSlot(mode).buttonStyle(.plain)
        }
      }
    }
  }

  /// Toolbar items are suppressed in exactly two states: a settled creation
  /// failure — a shimmering "still loading" cue would contradict the
  /// settled-error reading (VAL-DETAIL-004), so the failed state renders
  /// the same empty chrome it had before this view owned the toolbar — and
  /// a selection whose catalog rows were pruned out from under it.
  private func hasToolbarItems(_ mode: DetailMode) -> Bool {
    switch mode {
    case .creating(let loading): return !loading.isFailure
    case .worktree(_, let info): return info != nil
    }
  }

  @ViewBuilder
  private func identitySlot(_ mode: DetailMode) -> some View {
    switch mode {
    case .creating(let loading):
      SkeletonBranchClusterView(name: loading.name, projectName: loading.repositoryName)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(WorktreeLoadingView.AccessibilityID.skeletonLeft)
    case .worktree(_, let info):
      // Always render the identity cluster, even for non-git Projects —
      // the sidebar shows the synthetic folder row in that case, and
      // `WorktreeHeaderInfoLabel` falls through to the same folder glyph +
      // name rendering via `isSynthetic`. Keeps header and sidebar
      // consistent.
      if let info {
        WorktreeHeaderInfoLabel(
          worktree: info.worktree,
          project: info.project,
          gitHubStore: gitHubStore,
          branchSwitcherStore: branchSwitcherStore
        )
      }
    }
  }

  @ViewBuilder
  private func statusSlot(_ mode: DetailMode) -> some View {
    switch mode {
    case .creating:
      SkeletonStatusPillView()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(WorktreeLoadingView.AccessibilityID.skeletonMiddle)
    case .worktree(let address, let info):
      if let info {
        StatusBarView(
          store: statusBarStore,
          gitHubStore: gitHubStore,
          worktreeID: address.worktree,
          worktreePath: URL(fileURLWithPath: info.worktree.path),
          branch: info.worktree.branch
        )
      }
    }
  }

  @ViewBuilder
  private func runSlot(_ mode: DetailMode) -> some View {
    switch mode {
    case .creating:
      SkeletonActionChipView(labelText: "Run")
    case .worktree(let address, let info):
      if info != nil {
        HeaderRunScriptSplitButton(
          store: headerStore,
          projectID: address.project,
          worktreeID: address.worktree
        )
      }
    }
  }

  @ViewBuilder
  private func openSlot(_ mode: DetailMode) -> some View {
    switch mode {
    case .creating:
      SkeletonActionChipView(labelText: "Finder")
    case .worktree(let address, let info):
      if let info {
        HeaderOpenSplitButton(
          store: headerStore,
          editorStore: editorStore,
          projectID: address.project,
          worktreePath: info.worktree.path
        )
      }
    }
  }

  @ToolbarContentBuilder
  private func inboxBellToolbarItem() -> some ToolbarContent {
    ToolbarItem {
      InboxBellView(
        onFocusHierarchyPath: onFocusHierarchyPath,
        popoverTrigger: inboxBellPopoverTrigger
      )
    }
  }

  private struct Address {
    let project: ProjectID
    let worktree: WorktreeID
    let activeTab: TabID?
  }

  private func resolveAddress() -> Address? {
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let project = hierarchyManager.catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else {
      return nil
    }
    return Address(
      project: projectID,
      worktree: worktreeID,
      activeTab: worktree.selectedTabID
    )
  }

  private var emptyTab: some View {
    EmptyTerminalPaneView(message: "No terminals open")
  }

  /// Keep the empty-project state visually blank. Suppress the window
  /// title (otherwise the app's bundle name — "codans" — surfaces in the
  /// title bar) and hide the window-toolbar background so no chrome
  /// divider paints over the detail pane.
  private var placeholder: some View {
    EmptyProjectStateView(onAddProject: onAddProject)
      .modifier(SuppressTitleModifier())
      .toolbarBackground(.hidden, for: .windowToolbar)
  }

  /// Maps a `PendingWorktree` row to the view-layer struct the loading
  /// view consumes. Running rows surface the streaming git tail; failed
  /// rows surface `humanReadable(_:)` of the wrapped error so the
  /// detail view shows the same copy the sidebar tooltip already uses.
  private func loadingInfo(for binding: PendingWorktreeBinding) -> WorktreeLoadingInfo {
    let pending = binding.pending
    let kind: WorktreeLoadingInfo.Kind
    switch pending.status {
    case .running:
      // Drive the operation label from the live creation phase (not a
      // hardcoded "git worktree add") so the detail chip agrees with the
      // sidebar stage: git-add while `.creatingWorktree`, the configured
      // setup command while `.runningSetupScript` (VAL-DETAIL-007,
      // VAL-CROSS-001).
      kind = .creating(
        WorktreeLoadingInfo.Progress(
          statusCommand: WorktreeLoadingInfo.Progress.operationLabel(
            for: pending.phase,
            setupCommand: pending.spec.setupCommand
          ),
          statusLines: pending.progressLines
        )
      )
    case .failed(let err):
      kind = .failed(message: humanReadable(err))
    }
    return WorktreeLoadingInfo(
      name: pending.displayName,
      repositoryName: binding.repositoryName,
      kind: kind
    )
  }
}

/// Wraps `.toolbar(removing: .title)` (macOS 15+) with a
/// `.navigationTitle("")` fallback for macOS 14. Both suppress the
/// bundle-name title; only the modern API also frees the leading slot
/// so default-placement items + ToolbarSpacers lay out predictably.
private struct SuppressTitleModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbar(removing: .title)
    } else {
      content.navigationTitle("")
    }
  }
}
