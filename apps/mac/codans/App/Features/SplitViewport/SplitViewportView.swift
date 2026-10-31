import CodansCore
import ComposableArchitecture
import SwiftUI

/// Recursively renders the active Tab's `SplitTree<PaneID>`. Leaves scope
/// a child `StoreOf<PaneHostFeature>` off the parent store and hand it
/// to `LazyPaneHost`; splits become `HSplitView` / `VSplitView` per
/// `SplitTree.Direction`. Surface lifecycle is owned entirely by
/// `PaneHostFeature`; this view only bridges catalog changes into the
/// reducer via `.panesInActiveTabChanged(_:)`.
///
/// Empty-Tab UX: centered "No panes" placeholder with a "New Pane" button,
/// held back for `emptyStateGrace` so a Tab that is still seeding its first
/// Pane shows `warmingPlaceholder` instead. The Tab is never auto-closed by
/// this view.
struct SplitViewportView: View {
  @Bindable var store: StoreOf<SplitViewportFeature>
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  @Environment(HierarchyManager.self) private var hierarchyManager
  /// Shared drop-highlight state for the pane-move gesture, scoped to this
  /// viewport. A single shared value (vs per-leaf state) so the highlight
  /// follows the cursor across panes and always clears on drop — see
  /// `PaneDropHighlight`.
  @State private var dropHighlight = PaneDropHighlight()
  /// The Tab whose `emptyStateGrace` has already elapsed, or nil before any
  /// has. It is compared against `tabID` *inside* the render pass, so a Tab
  /// the view has just been pointed at fails the check on its very first
  /// frame. A Bool re-armed from `.task` cannot do that: `.task` runs after
  /// that frame is already on screen, so the previous Tab's settled `true`
  /// leaks the "New Pane" call to action through for ~100ms. A Tab that
  /// empties out *later* (the user closed its last Pane) still matches and
  /// shows the affordance immediately, which is the settled state the
  /// placeholder is actually for.
  @State private var settledTabID: TabID?

  /// How long a just-shown Tab is allowed to look empty before the
  /// actionable "No panes" affordance appears. Warm bringup of a Tab's first
  /// Pane measures ~350ms end to end, so this leaves headroom for a cold zmx
  /// daemon without stranding a genuinely Pane-less Tab behind a spinner.
  private static let emptyStateGrace: Duration = .milliseconds(1500)

  var body: some View {
    Group {
      if let tab = currentTab(), !tab.splitTree.isEmpty, let root = tab.splitTree.root {
        SubtreeView(
          node: root,
          path: SplitTree<PaneID>.Path(),
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No top gap: the toolbar already leaves one under its controls, and
        // the tab bar adds its own when it shows. The leading gap depends on
        // the sidebar; `WorktreeDetailView` owns it.
        .padding([.trailing, .bottom], PaneCardMetrics.gap)
        .environment(dropHighlight)
      } else if settledTabID == tabID {
        emptyPlaceholder
      } else {
        warmingPlaceholder
      }
    }
    .task(id: currentPaneSeedsKey()) {
      syncPaneHosts()
    }
    .task(id: tabID) {
      let graced = tabID
      try? await Task.sleep(for: Self.emptyStateGrace)
      guard !Task.isCancelled else { return }
      settledTabID = graced
    }
  }

  /// Neutral stand-in for a Tab whose first Pane row has not landed yet.
  /// Opening a Tab is two steps — the Tab row is inserted synchronously,
  /// its first Pane follows once the async zmx bringup path reaches
  /// `createPaneRow` — so a brand-new (or just-switched-to) Tab renders
  /// with an empty split tree for a frame or two. Showing `emptyPlaceholder`
  /// in that window flashes a prominent "New Pane" call to action the user
  /// never needs to press.
  ///
  /// Deliberately bare: nothing but Ghostty's terminal background. A warm
  /// Tab lands its first Pane in ~350ms, and a spinner that appears and
  /// disappears inside that window reads as a flash rather than as
  /// progress. The one indicator worth showing belongs to a spawn slow
  /// enough to need explaining, and `LazyPaneHost.loadingPlaceholder`
  /// owns it behind its own delay. Sharing the terminal tone with
  /// `LeafView`'s cold-pane branch keeps the whole empty → live
  /// progression on a single flat colour.
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
        Text("No panes in this Tab")
          .font(.title3)
          .foregroundStyle(.secondary)
        Button("New Pane") {
          store.send(
            .newPaneButtonTapped(
              inTab: tabID, inWorktree: worktreeID,
              inProject: projectID,
              workingDirectory: currentWorktreePath() ?? NSHomeDirectory(),
            ))
        }
        .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Shown instead of "New Pane" when the Worktree folder is gone: a pane
  /// cannot start there, so the button would silently do nothing.
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
  /// fallback "New Pane" button spawns a terminal rooted at the Worktree
  /// directory. Returns nil if the Worktree has been pruned between render
  /// and tap — the caller falls back to `$HOME`.
  private func currentWorktreePath() -> String? {
    hierarchyManager.catalog
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })?
      .path
  }

  private func currentTab() -> CodansCore.Tab? {
    hierarchyManager.catalog
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })?
      .tabs.first(where: { $0.id == tabID })
  }

  /// Stable identity for `.task(id:)`: if the pane set (in order) is the
  /// same, SwiftUI won't re-fire the sync. Using the id collection directly
  /// is cheap — tabs hold ≤ ~32 panes.
  private func currentPaneSeedsKey() -> [PaneID] {
    currentTab()?.panes.map(\.id) ?? []
  }

  private func syncPaneHosts() {
    guard let tab = currentTab() else {
      store.send(.panesInActiveTabChanged([]))
      return
    }
    let seeds = tab.panes.map { pane in
      PaneHostFeature.State(
        paneID: pane.id,
        tabID: tabID,
        worktreeID: worktreeID,
        projectID: projectID,
      )
    }
    store.send(.panesInActiveTabChanged(seeds))
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
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID

  var body: some View {
    switch node {
    case .leaf(let paneID):
      LeafView(
        paneID: paneID,
        store: store,
        tabID: tabID,
        worktreeID: worktreeID,
        projectID: projectID,
        isSplit: !path.components.isEmpty,
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
              inTab: tabID,
              inWorktree: worktreeID,
              inProject: projectID,
            ))
        },
      ),
      // The gap between two cards is the divider: the window backdrop shows
      // through. The resize target also covers the card margins on both
      // sides of the gap, up to the terminal edge.
      dividerColor: .clear,
      dividerThickness: PaneCardMetrics.gap,
      dividerHitOverhang: PaneCardMetrics.surfaceInset * 2,
      left: {
        SubtreeView(
          node: split.left,
          path: leftPath,
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
        )
      },
      right: {
        SubtreeView(
          node: split.right,
          path: rightPath,
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
        )
      },
      onEqualize: {
        store.send(
          .resizeSplitRequested(
            capturedPath,
            ratio: 0.5,
            inTab: tabID,
            inWorktree: worktreeID,
            inProject: projectID,
          ))
      },
    )
  }
}

private struct LeafView: View {
  let paneID: PaneID
  let store: StoreOf<SplitViewportFeature>
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID
  /// True when this leaf sits below at least one split node — i.e. the
  /// active Tab has more than one pane. Single-pane Tabs skip the
  /// unfocused fade and the header drag since there is nothing to
  /// re-arrange against.
  let isSplit: Bool
  /// Shared drop-highlight state (one per viewport). This leaf renders the
  /// edge overlay only while it is the active target — see `PaneDropHighlight`.
  @Environment(PaneDropHighlight.self) private var dropHighlight
  @Environment(HierarchyManager.self) private var hierarchyManager
  /// Fallback for `terminalColorScheme` when the terminal background has no
  /// perceived appearance.
  @Environment(\.colorScheme) private var colorScheme
  /// Bumped on `.ghosttyRuntimeConfigApplied` so the card re-reads the
  /// terminal background when the user picks a new ghostty theme.
  @State private var configReloadTick: Int = 0
  /// Pointer anywhere over the card: shows the header actions on an
  /// unfocused pane.
  @State private var isHoveringCard = false
  /// Used for the one-frame fallback on tab switch — see `paneContent`.
  /// Reducer state is the long-term source of truth; this lookup only fills
  /// the gap between catalog update and `.panesInActiveTabChanged` landing.
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some View {
    // Read the shared highlight in the body's OWN tracking scope (not only
    // inside the nested `.overlay`/`GeometryReader` closures). Observation only
    // re-renders this leaf for property reads it captured while evaluating
    // `body`; reading it solely inside a child closure means the overlay shows
    // during the drag (the active session forces re-renders) but never retracts
    // when `clear()` runs on drop — the stuck-highlight bug.
    let activeDropZone: PaneDropZone? = dropHighlight.target == paneID ? dropHighlight.zone : nil
    let shape = RoundedRectangle(cornerRadius: PaneCardMetrics.cornerRadius, style: .continuous)
    // A lone pane is the focused one by definition.
    let isFocusedCard = isFocused || !isSplit
    let showsActions = isFocusedCard || isHoveringCard
    return VStack(spacing: 0) {
      // The header is drawn as an overlay, above the terminal, so the
      // actions menu laid over it can unfold down across the terminal.
      Color.clear.frame(height: PaneCardMetrics.headerHeight)
      surfaceSlot(activeDropZone: activeDropZone)
        .padding([.horizontal, .bottom], PaneCardMetrics.surfaceInset)
    }
    .background(Color(nsColor: terminalBackground))
    .overlay(alignment: .top) {
      PaneCardHeader(
        paneID: paneID,
        tabID: tabID,
        isSplit: isSplit,
        isFocused: isFocusedCard,
        showsActions: showsActions,
        onFocus: focus,
        onSplit: split,
        onClose: {
          store.send(
            .closePaneButtonTapped(
              paneID, inTab: tabID, inWorktree: worktreeID, inProject: projectID))
        },
      )
      // The header sits on the terminal background, so its text follows the
      // terminal theme's tone rather than the app appearance.
      .environment(\.colorScheme, terminalColorScheme)
    }
    // Actions menu (hand off, command queue, the surface's own actions) in
    // the header's menu slot, and the command queue list under the header.
    .overlay(alignment: .topTrailing) {
      // Without a live surface yet, the surface's own rows show disabled.
      PaneCommandQueueChrome(
        paneID: paneID, surface: terminalClient.surface(paneID), showsMenu: showsActions,
        onMenuInteraction: focus,
      )
      .environment(\.colorScheme, terminalColorScheme)
    }
    .animation(.easeInOut(duration: 0.12), value: isHoveringCard)
    .clipShape(shape)
    .overlay {
      shape
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: PaneCardMetrics.borderWidth)
        .allowsHitTesting(false)
    }
    // An unfocused card lets the backdrop glass show through it, so it
    // reads as set back from the focused one.
    .opacity(isFocusedCard ? 1 : PaneCardMetrics.unfocusedOpacity)
    .animation(.easeInOut(duration: 0.12), value: isFocused)
    .onHover { isHoveringCard = $0 }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
      configReloadTick &+= 1
    }
  }

  /// The terminal under the card header, plus the pane-move drop target.
  private func surfaceSlot(activeDropZone: PaneDropZone?) -> some View {
    GeometryReader { geo in
      paneContent(slotSize: geo.size)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drop target. The custom `.touchCodePaneID` type (declared in the
        // app's Info.plist `UTExportedTypeDeclarations`) is what makes
        // `validateDrop` match the dragged item — without that declaration the
        // pasteboard type is a dynamic UTI that never conforms, so the drop is
        // silently rejected. `geo.size` feeds the edge-zone math.
        .background {
          Color.clear
            .contentShape(.rect)
            .onDrop(
              of: [.touchCodePaneID],
              delegate: PaneDropDelegate(
                anchorID: paneID,
                viewSize: geo.size,
                highlight: dropHighlight,
                commit: { sourceID, zone in
                  store.send(
                    .movePaneRequested(
                      sourceID,
                      anchor: paneID,
                      direction: zone.splitDirection,
                      inTab: tabID,
                      inWorktree: worktreeID,
                      inProject: projectID,
                    ))
                },
              ),
            )
        }
        // Drop-zone highlight, drawn above the surface but never hit-tested.
        // Shown only while this leaf is the active drop target.
        .overlay {
          if let activeDropZone {
            PaneDropOverlay(zone: activeDropZone)
          }
        }
    }
  }

  private func focus() {
    store.send(
      .focusPaneRequested(paneID, inTab: tabID, inWorktree: worktreeID, inProject: projectID))
    hierarchyManager.focusSurfaceView(for: paneID)
  }

  private func split(_ direction: SplitTree<PaneID>.NewDirection) {
    let workingDirectory =
      hierarchyManager.currentWorkingDirectory(for: paneID)
      ?? hierarchyManager.catalog.pane(paneID)?.workingDirectory
      ?? NSHomeDirectory()
    store.send(
      .splitButtonTapped(
        paneID, direction: direction,
        inTab: tabID, inWorktree: worktreeID, inProject: projectID,
        workingDirectory: workingDirectory))
  }

  /// Read after `configReloadTick` so a ghostty theme reload repaints the
  /// card.
  private var terminalBackground: NSColor {
    _ = configReloadTick
    return GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
  }

  private var terminalColorScheme: ColorScheme {
    let perceived = terminalBackground.perceivedAppearance?.bestMatch(from: [.darkAqua, .aqua])
    return perceived.map { $0 == .darkAqua ? .dark : .light } ?? colorScheme
  }

  @ViewBuilder
  private func paneContent(slotSize: CGSize) -> some View {
    if let childStore = store.scope(
      state: \.paneHosts[id: paneID],
      action: \.paneHosts[id: paneID],
    ) {
      // `.id(paneID)` forces SwiftUI to rebuild the LazyPaneHost subtree when
      // the pane changes. Without it, two leaves at the same split-tree
      // position across worktree switches diff as "same view, new props", and
      // `PaneHostView.updateNSView` (intentionally a no-op — ghostty owns its
      // own rendering) never swaps the underlying `GhosttySurfaceView`, so the
      // terminal visually stays on the previously-shown worktree.
      LazyPaneHost(store: childStore)
        .id(paneID)
        // Bringup trigger. Routed through the PARENT store with a
        // membership check instead of `childStore.send(.task)` inside
        // LazyPaneHost: the task body runs a beat after mount, and the
        // element can be gone by then — e.g. a transient archive/delete
        // script tab auto-closing the moment its instant script's child
        // exits. Sending an element action for a removed ID trips TCA's
        // missing-element runtime warning; the guard re-checks liveness
        // at send time (both run on MainActor, so no gap in between).
        .task(id: paneID) {
          guard store.paneHosts[id: paneID] != nil else { return }
          store.send(.paneHosts(.element(id: paneID, action: .task(slotSize: slotSize))))
        }
    } else if let warmSurface = terminalClient.surface(paneID) {
      // Tab-switch fast path: the catalog already points at this pane but
      // `SplitViewportView.task(id:)` hasn't run yet, so the reducer-scoped
      // store doesn't exist. Falling through to the loading placeholder
      // here is what produces the visible grey flash on every tab switch.
      // The surface itself is already warm in the engine registry, so we
      // render it directly until the scoped store materialises on the next
      // tick — same NSView the reducer would have given us.
      PaneHostView(surface: warmSurface)
        .id(paneID)
    } else {
      // Truly cold pane: surface hasn't been spawned yet (first render
      // after creation). Background tracks Ghostty's terminal color so
      // the hand-off to `LazyPaneHost.loadingPlaceholder` and then the
      // live surface stays on a single tone — earlier we used
      // `underPageBackgroundColor` here, which produced a visible grey
      // flash before the terminal theme settled in. No spinner either:
      // this phase is a handful of frames on the way to `LazyPaneHost`,
      // which owns the one bringup indicator and only reveals it once a
      // spawn is slow enough to be worth reporting.
      let terminalBackground = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
      Color(nsColor: terminalBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var isFocused: Bool {
    hierarchyManager.lastFocusedPane(in: tabID) == paneID
  }
}
