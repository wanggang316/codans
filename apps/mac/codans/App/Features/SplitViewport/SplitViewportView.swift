import CodansCore
import ComposableArchitecture
import SwiftUI

/// Recursively renders the Worktree's `SplitTree<PaneID>`. Each leaf is a
/// `PaneView`: that Pane's tab strip stacked over the content host of its
/// selected Tab. Splits become `SplitView`s per `SplitTree.Direction`. A
/// zoomed Pane renders alone, strip included. Surface lifecycle is owned
/// entirely by `PaneHostFeature`; this view only bridges catalog changes
/// into the reducer via `.hostsChanged(_:)`.
///
/// Empty-Worktree UX: centered "press ⌘T" placeholder with a "New Tab"
/// button, held back for `emptyStateGrace` so a Worktree that is still
/// seeding its first Pane shows `warmingPlaceholder` instead.
struct SplitViewportView: View {
  @Bindable var store: StoreOf<SplitViewportFeature>
  /// Shared by every strip of the Worktree (one reducer, sheet state in
  /// one place).
  let tabBarStore: StoreOf<TabBarFeature>
  let projectID: ProjectID
  let worktreeID: WorktreeID
  var agentStateStore: AgentStateStore?
  @Environment(HierarchyManager.self) private var hierarchyManager
  /// The tab-chip drag across this viewport's Panes. One shared value (vs
  /// per-leaf state) so exactly one drop target lights up and it always
  /// clears on drop.
  @State private var tabDrag = TabDragSession()
  /// The Worktree whose `emptyStateGrace` has already elapsed, or nil before
  /// any has. It is compared against `worktreeID` *inside* the render pass,
  /// so a Worktree the view has just been pointed at fails the check on its
  /// very first frame. A Bool re-armed from `.task` cannot do that: `.task`
  /// runs after that frame is already on screen, so the previous Worktree's
  /// settled `true` leaks the "New Tab" call to action through for ~100ms.
  /// A Worktree that empties out *later* (the user closed its last Pane)
  /// still matches and shows the affordance immediately, which is the
  /// settled state the placeholder is actually for.
  @State private var settledWorktreeID: WorktreeID?

  /// How long a just-shown Worktree is allowed to look empty before the
  /// actionable placeholder appears. Warm bringup of a first Pane measures
  /// ~350ms end to end, so this leaves headroom for a cold zmx daemon
  /// without stranding a genuinely empty Worktree behind a blank.
  private static let emptyStateGrace: Duration = .milliseconds(1500)

  var body: some View {
    Group {
      if let worktree = currentWorktree(), let root = visibleRoot(of: worktree) {
        SubtreeView(
          node: root,
          path: SplitTree<PaneID>.Path(),
          store: store,
          tabBarStore: tabBarStore,
          worktreeID: worktreeID,
          projectID: projectID,
          agentStateStore: agentStateStore
        )
        // The toolbar already leaves a gap under its items, so a strip on
        // the top edge drops its own top inset: the track then sits as far
        // under the toolbar items as Safari's tab bar does.
        .padding(.top, -TabBarMetrics.trackTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(tabDrag)
        .overlay { TabDragPreview(session: tabDrag) }
      } else if settledWorktreeID == worktreeID {
        emptyPlaceholder
      } else {
        warmingPlaceholder
      }
    }
    .task(id: currentHostSeedsKey()) {
      syncPaneHosts()
    }
    .onAppear {
      tabDrag.onDrop = { [store] tabID, target in
        switch target {
        case .strip(let paneID, let index):
          store.send(.moveTabRequested(tabID, toPane: paneID, at: index))
        case .edge(let paneID, let zone):
          store.send(.splitTabRequested(tabID, anchor: paneID, direction: zone.splitDirection))
        case .sourceStrip:
          break
        }
      }
    }
    .task(id: worktreeID) {
      let graced = worktreeID
      try? await Task.sleep(for: Self.emptyStateGrace)
      guard !Task.isCancelled else { return }
      settledWorktreeID = graced
    }
    .onChange(of: worktreeID) {
      // Wait one turn so the previous Worktree's surface has left the
      // window before reading where the keyboard is.
      DispatchQueue.main.async { restoreKeyboardFocus() }
    }
  }

  /// Hands the keyboard back to the focused Pane's selected Tab after a
  /// Worktree switch — but only when the keyboard was in a terminal: the
  /// previous surface left the window (first responder fell back to the
  /// window) or another surface still holds it. A switch made from the
  /// sidebar keeps the keyboard there, so arrow-key navigation goes on.
  private func restoreKeyboardFocus() {
    guard let window = NSApp.keyWindow else { return }
    let responder = window.firstResponder
    guard responder == nil || responder === window || responder is GhosttySurfaceView,
      let contentID = currentWorktree()?.focusedPane?.selectedTab?.contentID
    else { return }
    hierarchyManager.focusSurfaceView(for: contentID)
  }

  /// The tree to draw: the zoomed Pane alone when one is zoomed, else the
  /// whole tree. A zoom that names a Pane no longer in the tree is ignored.
  private func visibleRoot(of worktree: Worktree) -> SplitTree<PaneID>.Node? {
    if let zoomed = worktree.splitTree.zoomed, worktree.splitTree.contains(zoomed) {
      return .leaf(zoomed)
    }
    return worktree.splitTree.root
  }

  /// Neutral stand-in for a Worktree whose first Pane has not landed yet.
  /// Deliberately bare: nothing but Ghostty's terminal background. A warm
  /// Worktree lands its first Pane in ~350ms, and a spinner that appears
  /// and disappears inside that window reads as a flash rather than as
  /// progress. The one indicator worth showing belongs to a spawn slow
  /// enough to need explaining, and `LazyPaneHost.loadingPlaceholder`
  /// owns it behind its own delay.
  private var warmingPlaceholder: some View {
    let terminalBackground = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
    return Color(nsColor: terminalBackground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var emptyPlaceholder: some View {
    if let missingPath = missingWorktreeFolder() {
      missingFolderPlaceholder(path: missingPath)
    } else {
      VStack(spacing: 12) {
        Text("No tabs open")
          .font(.title3)
          .foregroundStyle(.secondary)
        Button("New Tab") {
          store.send(
            .newTabButtonTapped(
              inPane: nil, inWorktree: worktreeID, inProject: projectID,
              workingDirectory: currentWorktreePath() ?? NSHomeDirectory()
            ))
        }
        .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Shown instead of "New Tab" when the Worktree folder is gone: a
  /// session cannot start there, so the button would silently do nothing.
  private func missingFolderPlaceholder(path: String) -> some View {
    VStack(spacing: 8) {
      Label("Folder not found", systemImage: "exclamationmark.triangle.fill")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text((path as NSString).abbreviatingWithTildeInPath)
        .font(.callout)
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
      Text("The folder was moved or deleted. Remove it from codans and add it again.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The Worktree path when its folder no longer exists locally, else `nil`.
  /// Server projects never qualify: their paths are remote.
  private func missingWorktreeFolder() -> String? {
    guard
      let project = hierarchyManager.catalog.projects.first(where: { $0.id == projectID }),
      !project.isRemote,
      let path = project.worktrees.first(where: { $0.id == worktreeID })?.path
    else { return nil }
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return exists && isDir.boolValue ? nil : path
  }

  /// Looks up the current Worktree's absolute path from the catalog so the
  /// fallback "New Tab" button spawns a terminal rooted at the Worktree
  /// directory. Returns nil if the Worktree has been pruned between render
  /// and tap — the caller falls back to `$HOME`.
  private func currentWorktreePath() -> String? {
    currentWorktree()?.path
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog.worktree(worktreeID, in: projectID)
  }

  /// Stable identity for `.task(id:)`: if the shown Contents (in Pane
  /// order) are the same, SwiftUI won't re-fire the sync.
  private func currentHostSeedsKey() -> [ContentID] {
    currentWorktree()?.panes.compactMap { $0.selectedTab?.contentID } ?? []
  }

  private func syncPaneHosts() {
    guard let worktree = currentWorktree() else {
      store.send(.hostsChanged([]))
      return
    }
    let seeds = worktree.panes.compactMap { pane -> PaneHostFeature.State? in
      guard let tab = pane.selectedTab else { return nil }
      return PaneHostFeature.State(
        contentID: tab.contentID,
        paneID: pane.id,
        tabID: tab.id,
        worktreeID: worktreeID,
        projectID: projectID
      )
    }
    store.send(.hostsChanged(seeds))
  }

}

/// Recursive subtree renderer. Implemented as a concrete `struct` (not an
/// `AnyView`-returning function) so SwiftUI can diff identity across re-renders
/// — otherwise every divider drag tears down and rebuilds every `PaneHostView`,
/// causing the ghostty surface to re-mount on each frame and visibly flicker.
/// Self-recursion through a named type collapses the view-type tree to a single
/// `SubtreeView` at each level, sidestepping the generic-inference explosion
/// that originally motivated `AnyView`.
///
/// Split nodes are rendered via `SplitView` — a `ZStack`-based splitter with a
/// draggable divider. We intentionally do NOT use `HSplitView`/`VSplitView`:
/// those wrap `NSSplitView`, which propagates Auto Layout constraint
/// invalidations through every nested `NSHostingView`, and with multiple ghostty
/// surfaces emitting `SurfaceInfo` changes on startup the reentrancy trips
/// macOS's "more Update Constraints passes than there are views" exception.
/// `SplitView` hard-sets frames and offsets on a `ZStack` instead — no Auto
/// Layout ping-pong, and it honors `SplitTree.split.ratio` directly.
///
/// `path` accumulates as we descend: `.left` for the first child, `.right` for
/// the second. That's what `resizeSplitRequested` needs to locate the split
/// node in the tree.
private struct SubtreeView: View {
  let node: SplitTree<PaneID>.Node
  let path: SplitTree<PaneID>.Path
  let store: StoreOf<SplitViewportFeature>
  let tabBarStore: StoreOf<TabBarFeature>
  let worktreeID: WorktreeID
  let projectID: ProjectID
  let agentStateStore: AgentStateStore?

  var body: some View {
    switch node {
    case .leaf(let paneID):
      PaneView(
        paneID: paneID,
        store: store,
        tabBarStore: tabBarStore,
        worktreeID: worktreeID,
        projectID: projectID,
        agentStateStore: agentStateStore,
        isSplit: !path.components.isEmpty
      )
    case .split(let split):
      splitBody(split)
    }
  }

  private func splitBody(_ split: SplitTree<PaneID>.Split) -> some View {
    let leftPath = SplitTree<PaneID>.Path(path.components + [.left])
    let rightPath = SplitTree<PaneID>.Path(path.components + [.right])
    let direction: SplitView<SubtreeView, SubtreeView>.Direction =
      split.direction == .horizontal ? .horizontal : .vertical
    let capturedPath = path
    return SplitView(
      direction,
      Binding<CGFloat>(
        get: { CGFloat(split.ratio) },
        set: { newRatio in
          store.send(
            .resizeSplitRequested(
              capturedPath,
              ratio: Double(newRatio),
              inWorktree: worktreeID,
              inProject: projectID
            ))
        }
      ),
      dividerColor: Color(nsColor: .separatorColor).opacity(0.6),
      dividerWidth: 1,
      left: {
        SubtreeView(
          node: split.left,
          path: leftPath,
          store: store,
          tabBarStore: tabBarStore,
          worktreeID: worktreeID,
          projectID: projectID,
          agentStateStore: agentStateStore
        )
      },
      right: {
        SubtreeView(
          node: split.right,
          path: rightPath,
          store: store,
          tabBarStore: tabBarStore,
          worktreeID: worktreeID,
          projectID: projectID,
          agentStateStore: agentStateStore
        )
      },
      onEqualize: {
        store.send(
          .resizeSplitRequested(
            capturedPath,
            ratio: 0.5,
            inWorktree: worktreeID,
            inProject: projectID
          ))
      }
    )
  }
}

/// One Pane: its tab strip over the content host of its selected Tab.
private struct PaneView: View {
  let paneID: PaneID
  let store: StoreOf<SplitViewportFeature>
  let tabBarStore: StoreOf<TabBarFeature>
  let worktreeID: WorktreeID
  let projectID: ProjectID
  let agentStateStore: AgentStateStore?
  /// True when this leaf sits below at least one split node — i.e. the
  /// Worktree has more than one Pane. A lone Pane skips the dim overlay.
  let isSplit: Bool
  /// The viewport's tab-chip drag. This leaf registers its strip and content
  /// frames and draws the edge overlay only while it is the drop target.
  @Environment(TabDragSession.self) private var tabDrag
  @Environment(HierarchyManager.self) private var hierarchyManager
  /// Pulled in so the dim overlay re-evaluates when the user flips Appearance
  /// (or the OS auto-switches). `unfocusedSplitFill()` resolves against the
  /// active ghostty palette, but without an observable dependency here SwiftUI
  /// keeps the previous frame's overlay color until something else (focus
  /// change, layout) forces a rebuild — which is what produced the stale
  /// light/dark wash on unfocused panes after a theme switch.
  @Environment(\.colorScheme) private var colorScheme
  /// Backing scale of the window the slot lives in, for the mount geometry.
  @Environment(\.displayScale) private var displayScale
  /// Bumped on `.ghosttyRuntimeConfigApplied` so the overlay re-resolves when
  /// the user picks a new ghostty theme (Settings → Terminal, or by editing
  /// `~/.config/ghostty/config`). `colorScheme` only covers the appearance
  /// flip path; without this tick the overlay stays on the previous theme's
  /// fill colour until the user re-focuses the pane or triggers a layout pass.
  @State private var configReloadTick: Int = 0
  /// Used for the one-frame fallback on a Tab switch — see `paneContent`.
  /// Reducer state is the long-term source of truth; this lookup only fills
  /// the gap between catalog update and `.hostsChanged` landing.
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some View {
    // Read the drop target in the body's OWN tracking scope (not only inside
    // the nested `.overlay`/`GeometryReader` closures). Observation only
    // re-renders this leaf for property reads it captured while evaluating
    // `body`; a read solely inside a child closure can leave the overlay up
    // after the drop clears the target.
    let activeDropZone: PaneDropZone? =
      if case .edge(paneID, let zone)? = tabDrag.target { zone } else { nil }
    return VStack(spacing: 0) {
      TabBarView(
        store: tabBarStore,
        projectID: projectID,
        worktreeID: worktreeID,
        paneID: paneID,
        isFocused: isFocused,
        agentStateStore: agentStateStore
      )
      .onGeometryChange(
        for: CGRect.self, of: { $0.frame(in: .global) },
        action: { tabDrag.setStripFrame($0, for: paneID) })
      GeometryReader { geo in
        TerminalMountDeferral(
          activeContentID: selectedContentID,
          contentIDs: hierarchyManager.catalog.pane(paneID)?.contentIDs ?? []
        ) {
          paneContent(slotSize: geo.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .onGeometryChange(
        for: CGRect.self, of: { $0.frame(in: .global) },
        action: { tabDrag.setContentFrame($0, for: paneID) })
    }
    // Drop-zone highlight over the whole Pane, strip included: the new Pane
    // takes that half of it, its own strip on top. Never hit-tested, and
    // shown only while this leaf is the active drop target.
    .overlay {
      if let activeDropZone {
        PaneDropOverlay(zone: activeDropZone)
      }
    }
    .onDisappear {
      tabDrag.setStripFrame(nil, for: paneID)
      tabDrag.setContentFrame(nil, for: paneID)
    }
    .id(paneID)
  }

  private var selectedContentID: ContentID? {
    hierarchyManager.catalog.pane(paneID)?.selectedTab?.contentID
  }

  @ViewBuilder
  private func paneContent(slotSize: CGSize) -> some View {
    if let contentID = selectedContentID,
      let childStore = store.scope(
        state: \.paneHosts[id: contentID],
        action: \.paneHosts[id: contentID]
      )
    {
      // `.id(contentID)` forces SwiftUI to rebuild the LazyPaneHost subtree
      // when the shown session changes. Without it, two leaves at the same
      // split-tree position across worktree switches diff as "same view, new
      // props", and `PaneHostView.updateNSView` (intentionally a no-op —
      // ghostty owns its own rendering) never swaps the underlying
      // `GhosttySurfaceView`, so the terminal visually stays on the
      // previously-shown session.
      LazyPaneHost(store: childStore)
        .id(contentID)
        // Bringup trigger. Routed through the PARENT store with a
        // membership check instead of `childStore.send(.task)` inside
        // LazyPaneHost: the task body runs a beat after mount, and the
        // element can be gone by then — e.g. a transient archive/delete
        // script tab auto-closing the moment its instant script's child
        // exits. Sending an element action for a removed ID trips TCA's
        // missing-element runtime warning; the guard re-checks liveness
        // at send time (both run on MainActor, so no gap in between).
        .task(id: contentID) {
          guard store.paneHosts[id: contentID] != nil else { return }
          let geometry = ContentGeometry(size: slotSize, scale: displayScale)
          store.send(.paneHosts(.element(id: contentID, action: .task(geometry: geometry))))
        }
        // Mount / unmount follow the host's place in the layout, through
        // the same membership check as the bring-up above.
        .onChange(of: ContentGeometry(size: slotSize, scale: displayScale)) { _, geometry in
          guard store.paneHosts[id: contentID] != nil else { return }
          store.send(.paneHosts(.element(id: contentID, action: .slotChanged(geometry))))
        }
        .onDisappear {
          guard store.paneHosts[id: contentID] != nil else { return }
          store.send(.paneHosts(.element(id: contentID, action: .disappeared)))
        }
        .overlay { unfocusedDimOverlay }
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
          configReloadTick &+= 1
        }
    } else if let contentID = selectedContentID, let warmSurface = terminalClient.surface(contentID) {
      // Tab-switch fast path: the catalog already points at this session but
      // `SplitViewportView.task(id:)` hasn't run yet, so the reducer-scoped
      // store doesn't exist. Falling through to the loading placeholder
      // here is what produces the visible grey flash on every tab switch.
      // The surface itself is already warm in the engine registry, so we
      // render it directly until the scoped store materialises on the next
      // tick — same NSView the reducer would have given us.
      PaneHostView(surface: warmSurface)
        .id(contentID)
        .overlay { unfocusedDimOverlay }
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
          configReloadTick &+= 1
        }
    } else {
      // Truly cold session: surface hasn't been spawned yet (first render
      // after creation). Background tracks Ghostty's terminal color so
      // the hand-off to `LazyPaneHost.loadingPlaceholder` and then the
      // live surface stays on a single tone. No spinner either: this phase
      // is a handful of frames on the way to `LazyPaneHost`, which owns the
      // one bringup indicator and only reveals it once a spawn is slow
      // enough to be worth reporting.
      let terminalBackground = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
      Color(nsColor: terminalBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var isFocused: Bool {
    hierarchyManager.catalog.worktree(worktreeID, in: projectID)?.focusedPaneID == paneID
  }

  /// Wash on unfocused Panes inside a multi-Pane Worktree. Matches ghostty's
  /// `unfocused-split` exactly: a hit-test-disabled `Rectangle` filled with
  /// `unfocused-split-fill` (defaults to terminal `background`) at
  /// `1 - unfocused-split-opacity` (default 0.15). A lone Pane and the
  /// focused leaf get nothing.
  @ViewBuilder
  private var unfocusedDimOverlay: some View {
    if shouldDimUnfocusedSplit {
      let runtime = GhosttyRuntime.shared
      let fill = runtime?.unfocusedSplitFill(colorScheme) ?? .windowBackgroundColor
      let opacity = runtime?.unfocusedSplitOpacity() ?? 0.15
      if opacity > 0 {
        Rectangle()
          .fill(Color(nsColor: fill))
          .allowsHitTesting(false)
          .opacity(opacity)
      }
    }
  }

  /// `isSplit && !isFocused`, evaluated after reading `configReloadTick` so
  /// the overlay rebuilds on ghostty config-file theme reloads (Settings →
  /// Terminal picker / manual config edit). `colorScheme` is read inside the
  /// overlay via `unfocusedSplitFill(colorScheme)`, covering OS / Appearance
  /// flips; this read covers the config-reload tick. Without it the overlay
  /// keeps the previous theme's wash colour until a focus change or layout
  /// pass forces a rebuild. Reading the tick in this plain computed Bool —
  /// rather than an inline `let _ =` inside the `@ViewBuilder` — keeps the
  /// discard out of the result builder (a bare `_ =` does not type-check as a
  /// builder statement) while still registering the SwiftUI dependency.
  private var shouldDimUnfocusedSplit: Bool {
    _ = configReloadTick
    return isSplit && !isFocused
  }
}
