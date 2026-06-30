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
  /// `ContentView`, so this view no longer accepts a callback (0005 M6c).
  let editorStore: StoreOf<EditorFeature>
  /// AgentState registry (optional). Threaded down to `TabBarView` so a tab
  /// chip lights while a bound agent in that tab is `.working` — the same
  /// registry `ContentView` hands the sidebar, kept in sync by construction.
  var agentStateStore: AgentStateStore?
  /// T2 Header feature — scoped by `ContentView` from the root. Drives the bell
  /// badge and the Open-in split button's delegate routing.
  let headerStore: StoreOf<WorktreeHeaderFeature>
  /// 0014: titlebar-center Worktree Status Bar store. Owns the toast slot; PR /
  /// motivational forms are view-level projections of other scopes (added in M4/M5).
  let statusBarStore: StoreOf<StatusBarFeature>
  /// 0014 M4: scoped GitHub feature store; read for the PR form's
  /// `snapshots[worktreeID]` lookup. Same store the sidebar badge reads so
  /// the two surfaces stay in sync by construction.
  let gitHubStore: StoreOf<GitHubFeature>
  /// T10: branch popover + switch state. Threaded through to the leading
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

  /// HAN-63: window-toolbar chrome is hidden window-wide (see the
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
    if let pending = activePendingWorktree {
      // During creation the content body is JUST the live streaming output
      // (the slimmed `WorktreeLoadingView`). The window toolbar STAYS
      // VISIBLE via `pendingSkeletonToolbarContent`, rendering shimmering
      // skeleton placeholders in the LEFT (branch) and MIDDLE (status)
      // slots — exactly where the real branch label + status pill land on
      // completion — and NOTHING in the trailing/right slot (no actions for
      // a not-yet-created worktree). Mirrors the normal branch's chrome
      // wiring (`SuppressTitleModifier` so default-placement items flow
      // leading-to-trailing; `.toolbarBackground` gated on fullscreen).
      //
      // The skeleton is suppressed once the row settles into `.failed`: a
      // shimmering "still loading" cue would contradict the settled-error
      // reading (VAL-DETAIL-004), so the failure sub-case shows no toolbar
      // items — matching the chrome the failed state had before this view
      // took over the toolbar.
      let info = loadingInfo(for: pending)
      WorktreeLoadingView(info: info)
        .modifier(SuppressTitleModifier())
        .toolbar { pendingSkeletonToolbarContent(isFailure: info.isFailure) }
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
    } else if let address = resolveAddress() {
      let info = worktreeInfo(for: address)
      VStack(spacing: 0) {
        // T10: inline branch-switch error banner. Renders itself only
        // when `branchSwitcherStore.switchError` is non-nil, so it stays
        // a zero-height no-op on the happy path. Placed at the top of
        // the detail body — directly under the window toolbar — so the
        // banner reads as a "drop-down notification strip" regardless
        // of which tab / pane is foreground.
        BranchSwitcherErrorBannerView(store: branchSwitcherStore)
        tabBarRow(address: address)
        terminalRegion(address: address)
      }
      .animation(.easeInOut(duration: 0.18), value: branchSwitcherStore.switchError)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Mount project-script shortcut bindings as a 0-sized background of
      // the detail body. The toolbar's run-script Menu can only register
      // its in-menu `.keyboardShortcut` after the dropdown has been opened
      // (Menu content is lazy) — and even then SwiftUI drops the binding
      // on the next `.id(_:)`-driven rebuild. Mounting hidden Buttons on
      // the regular view tree keeps every chord live the whole time the
      // worktree is on screen.
      .background(alignment: .topLeading) {
        ProjectScriptsShortcutBindings(
          store: headerStore,
          projectID: address.project,
          worktreeID: address.worktree
        )
      }
      // On macOS 15+ remove the title slot entirely so default-placement
      // toolbar items can flow leading-to-trailing with `ToolbarSpacer`
      // controlling the layout.
      // `.navigationTitle("")` still reserves a leading region and would
      // push default-placement items toward the trailing edge — which is
      // why earlier centering attempts collapsed onto the right side.
      // macOS 14 keeps `.navigationTitle("")` + the older `.principal`
      // zoning since `.toolbar(removing:)` is 15+.
      .modifier(SuppressTitleModifier())
      .toolbar { worktreeToolbarContent(address: address, info: info) }
      // Drop the system-painted window-toolbar chrome so the macOS 26
      // floating-sidebar overlay only blends against the detail body
      // underneath it. Without this, the toolbar's full-window glass
      // repaints on every toolbar-state change (tab switch rebuilds
      // `worktreeToolbarContent`) and flickers across the area covered
      // by the translucent sidebar.
      //
      // HAN-63: re-show the chrome when fullscreen — without it, the
      // sidebar `+` button and detail toolbar render over the terminal
      // pane with nothing behind them (the title bar normally provides
      // the visual backing).
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

  /// Window-titlebar toolbar content for the active Worktree. Branch label
  /// on the leading edge (`.navigation` placement), bell / open-in on the
  /// trailing edge (`.primaryAction`). Mirrors the
  /// layout that used to live as the right cluster of the content-region
  /// header; moving it into `.toolbar {}` reclaims vertical pixels above
  /// the tab bar and matches macOS native chrome (Xcode, Finder).
  ///
  /// `ContentView` contributes one additional trailing `ToolbarItem`
  /// (Settings gear) — SwiftUI merges both sources, with Settings rendered
  /// after the items declared here.
  @ToolbarContentBuilder
  private func worktreeToolbarContent(
    address: Address,
    info: WorktreeInfo?
  ) -> some ToolbarContent {
    if let info {
      // macOS 26 layout: every item in default placement, ordering
      // plus ToolbarSpacer(.flexible) splits
      // horizontal space evenly so the status capsule sits visually
      // equidistant between the branch label and the trailing buttons.
      // Pre-26 keeps the older `.navigation` / `.principal` /
      // `.primaryAction` zoning since ToolbarSpacer is macOS 26+.
      if #available(macOS 26.0, *) {
        // Always render the identity cluster, even for non-git Projects —
        // the sidebar shows the synthetic folder row in that case, and
        // `WorktreeHeaderInfoLabel` falls through to the same folder
        // glyph + name rendering via `isSynthetic`. Keeps the header and
        // sidebar consistent (HAN-60).
        branchToolbarItemDefault(info: info)
        ToolbarSpacer(.flexible)
        centeredStatusBarToolbarItem(address: address, info: info)
        // Bell is intentionally placed *immediately* after the status
        // capsule with no flexible spacer between them — keeps the
        // status / bell pair visually grouped at the window's
        // optical center.
        inboxBellToolbarItem()
        ToolbarSpacer(.flexible)
        trailingButtonsDefault(address: address, info: info)
      } else {
        branchToolbarItem(info: info)
        statusBarToolbarItem(address: address, info: info)
        // Same as the modern path: bell sits adjacent to the principal
        // status item so the user reads "[status] [bell]" as one
        // cluster rather than seeing the bell in the trailing button
        // group with the action buttons.
        inboxBellToolbarItem()
        ToolbarItemGroup(placement: .primaryAction) {
          // Order: RunScript, Open. `ToolbarItemGroup` renders children
          // leading-to-trailing in declaration order.
          HeaderRunScriptSplitButton(
            store: headerStore,
            projectID: address.project,
            worktreeID: address.worktree
          )
          .buttonStyle(.plain)
          HeaderOpenSplitButton(
            store: headerStore,
            editorStore: editorStore,
            projectID: address.project,
            worktreePath: info.worktree.path
          )
          .buttonStyle(.plain)
        }
      }
    }
  }

  /// Window-titlebar toolbar content for the *creating* state. Parallels
  /// `worktreeToolbarContent`'s placement structure across both OS paths so
  /// the toolbar reads as the same chrome — only the LEFT (branch) and MIDDLE
  /// (status) slots are swapped for shimmering `SkeletonBlock` placeholders
  /// (the branch + status aren't known until the worktree exists), and the
  /// trailing/right slot renders NOTHING (a not-yet-created worktree has no
  /// Run / editor actions). The placeholders carry the `skeleton-left` /
  /// `skeleton-middle` accessibility ids — the same contract keys that used
  /// to ride the loading-view body — so a probe finds them on the toolbar
  /// (VAL-DETAIL-001 / VAL-DETAIL-003).
  ///
  /// macOS 26 uses default placement with a flanking `ToolbarSpacer(.flexible)`
  /// pair (mirroring `branchToolbarItemDefault` + `centeredStatusBarToolbarItem`);
  /// pre-26 falls back to `.navigation` / `.principal` zoning (mirroring
  /// `branchToolbarItem` + `statusBarToolbarItem`).
  ///
  /// `isFailure` suppresses every item: a settled `.failed` creation is not
  /// "still loading", so the shimmering placeholders are dropped and the
  /// toolbar renders empty (VAL-DETAIL-004).
  @ToolbarContentBuilder
  private func pendingSkeletonToolbarContent(isFailure: Bool) -> some ToolbarContent {
    // `if !isFailure { … }` with no else is the optional form `@ToolbarContentBuilder`
    // supports (`buildOptional`) — it renders nothing for a settled failure.
    // An empty `if`/`else` *branch* is NOT valid toolbar content (unlike
    // `@ViewBuilder`, there is no zero-component `buildBlock`), so the
    // suppression has to be the outer guard.
    if !isFailure {
      if #available(macOS 26.0, *) {
        // Leading branch-identity placeholder. `.sharedBackgroundVisibility(.hidden)`
        // matches the real `branchToolbarItemDefault` so the slot reads as plain
        // content, not a glass capsule.
        ToolbarItem {
          SkeletonBlock(width: 120, height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(WorktreeLoadingView.AccessibilityID.skeletonLeft)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        // Centered status placeholder — wider than the branch block to stand in
        // for the status pill. Default placement so the flanking flexible
        // spacers center it, mirroring `centeredStatusBarToolbarItem`.
        ToolbarItem {
          SkeletonBlock(width: 140, height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(WorktreeLoadingView.AccessibilityID.skeletonMiddle)
        }
        ToolbarSpacer(.flexible)
        // No trailing item: a not-yet-created worktree has no Run / editor
        // actions, so the right slot stays empty during creation.
      } else {
        // Pre-26 fallback: branch placeholder in the leading `.navigation`
        // slot, status placeholder in the centered `.principal` slot — the same
        // zoning the real `branchToolbarItem` / `statusBarToolbarItem` use.
        ToolbarItem(placement: .navigation) {
          SkeletonBlock(width: 120, height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(WorktreeLoadingView.AccessibilityID.skeletonLeft)
        }
        ToolbarItem(placement: .principal) {
          SkeletonBlock(width: 140, height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(WorktreeLoadingView.AccessibilityID.skeletonMiddle)
        }
        // No `.primaryAction` group: the trailing slot stays empty during
        // creation.
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

  /// macOS 26 leading identity item. Default placement so it sits before
  /// the leading `ToolbarSpacer(.flexible)` and reads as the leftmost
  /// chip. `.sharedBackgroundVisibility(.hidden)` opts the cluster out
  /// of the toolbar's glass capsule so the icon + name + branch + PR
  /// stats read as plain content alongside the trailing action chips,
  /// matching the sidebar row (HAN-60).
  @available(macOS 26.0, *)
  @ToolbarContentBuilder
  private func branchToolbarItemDefault(info: WorktreeInfo) -> some ToolbarContent {
    ToolbarItem {
      WorktreeHeaderInfoLabel(
        worktree: info.worktree,
        project: info.project,
        gitHubStore: gitHubStore,
        branchSwitcherStore: branchSwitcherStore
      )
    }
    .sharedBackgroundVisibility(.hidden)
  }

  /// macOS 26 trailing buttons. Each lives in its own `ToolbarItem` so
  /// the system wraps it in a separate glass capsule — two discrete
  /// chips instead of one shared cluster background. `ToolbarSpacer(.fixed)`
  /// between siblings keeps them visually distinct without collapsing
  /// the gap. Default placement; ordering after the trailing flexible
  /// spacer pins the row to the right edge.
  @available(macOS 26.0, *)
  @ToolbarContentBuilder
  private func trailingButtonsDefault(
    address: Address, info: WorktreeInfo
  ) -> some ToolbarContent {
    // No `.buttonStyle` / no manual padding — each ToolbarItem gets
    // the toolbar's native glass capsule + hover state.
    //
    // Order: RunScript, Open.
    ToolbarItem {
      HeaderRunScriptSplitButton(
        store: headerStore,
        projectID: address.project,
        worktreeID: address.worktree
      )
    }
    ToolbarSpacer(.fixed)
    ToolbarItem {
      HeaderOpenSplitButton(
        store: headerStore,
        editorStore: editorStore,
        projectID: address.project,
        worktreePath: info.worktree.path
      )
    }
  }

  @ToolbarContentBuilder
  private func branchToolbarItem(info: WorktreeInfo) -> some ToolbarContent {
    let item = ToolbarItem(placement: .navigation) {
      WorktreeHeaderInfoLabel(
        worktree: info.worktree,
        project: info.project,
        gitHubStore: gitHubStore,
        branchSwitcherStore: branchSwitcherStore
      )
    }
    if #available(macOS 26.0, *) {
      item.sharedBackgroundVisibility(.hidden)
    } else {
      item
    }
  }

  @ToolbarContentBuilder
  private func statusBarToolbarItem(address: Address, info: WorktreeInfo) -> some ToolbarContent {
    // No `.sharedBackgroundVisibility(.hidden)` — let macOS 26's toolbar
    // provide the standard glass capsule so the status slot reads as a
    // peer of the trailing button cluster instead of a hand-rolled chip.
    // Used as the pre-26 fallback when `ToolbarSpacer` is unavailable.
    ToolbarItem(placement: .principal) {
      StatusBarView(
        store: statusBarStore,
        gitHubStore: gitHubStore,
        worktreeID: address.worktree,
        worktreePath: URL(fileURLWithPath: info.worktree.path),
        branch: info.worktree.branch
      )
    }
  }

  /// macOS 26+ variant. Uses default placement so the surrounding
  /// `ToolbarSpacer(.flexible)` pair distributes free horizontal space
  /// equally on both sides — making the status capsule visually
  /// equidistant from the branch label and the trailing button cluster
  /// (instead of pinned to the title-bar's geometric center).
  @available(macOS 26.0, *)
  @ToolbarContentBuilder
  private func centeredStatusBarToolbarItem(
    address: Address, info: WorktreeInfo
  ) -> some ToolbarContent {
    ToolbarItem {
      StatusBarView(
        store: statusBarStore,
        gitHubStore: gitHubStore,
        worktreeID: address.worktree,
        worktreePath: URL(fileURLWithPath: info.worktree.path),
        branch: info.worktree.branch
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

  /// HAN-65: keep the empty-project state visually blank. Suppress the
  /// window title (otherwise the app's bundle name — "codans" —
  /// surfaces in the title bar) and hide the window-toolbar background so
  /// no chrome divider paints over the detail pane.
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
