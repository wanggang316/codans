import ComposableArchitecture
import SwiftUI
import CodansCore

/// Recursively renders the active Tab's `SplitTree<PaneID>`. Leaves scope
/// a child `StoreOf<PaneHostFeature>` off the parent store and hand it
/// to `LazyPaneHost`; splits become `HSplitView` / `VSplitView` per
/// `SplitTree.Direction`. Surface lifecycle is owned entirely by
/// `PaneHostFeature`; this view only bridges catalog changes into the
/// reducer via `.panesInActiveTabChanged(_:)`.
///
/// Empty-Tab UX: centered "No panes" placeholder with a "New Pane" button.
/// The Tab is never auto-closed by this view.
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

  var body: some View {
    Group {
      if let tab = currentTab(), !tab.splitTree.isEmpty, let root = tab.splitTree.root {
        SubtreeView(
          node: root,
          path: SplitTree<PaneID>.Path(),
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(dropHighlight)
      } else {
        emptyPlaceholder
      }
    }
    .task(id: currentPaneSeedsKey()) {
      syncPaneHosts()
    }
  }

  private var emptyPlaceholder: some View {
    VStack(spacing: 12) {
      Text("No panes in this Tab")
        .font(.title3)
        .foregroundStyle(.secondary)
      Button("New Pane") {
        store.send(
          .newPaneButtonTapped(
            inTab: tabID, inWorktree: worktreeID,
            inProject: projectID,
            workingDirectory: currentWorktreePath() ?? NSHomeDirectory()
          ))
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        projectID: projectID
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
              inTab: tabID,
              inWorktree: worktreeID,
              inProject: projectID
            ))
        }
      ),
      dividerColor: Color(nsColor: .separatorColor),
      left: {
        SubtreeView(
          node: split.left,
          path: leftPath,
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID
        )
      },
      right: {
        SubtreeView(
          node: split.right,
          path: rightPath,
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID
        )
      },
      onEqualize: {
        store.send(
          .resizeSplitRequested(
            capturedPath,
            ratio: 0.5,
            inTab: tabID,
            inWorktree: worktreeID,
            inProject: projectID
          ))
      }
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
  /// active Tab has more than one pane. Single-pane Tabs skip the dim
  /// overlay and the drag handle since there is nothing to re-arrange
  /// against.
  let isSplit: Bool
  /// Shared drop-highlight state (one per viewport). This leaf renders the
  /// edge overlay only while it is the active target — see `PaneDropHighlight`.
  @Environment(PaneDropHighlight.self) private var dropHighlight
  @Environment(HierarchyManager.self) private var hierarchyManager
  /// Pulled in so the dim overlay re-evaluates when the user flips Appearance
  /// (or the OS auto-switches). `unfocusedSplitFill()` resolves against the
  /// active ghostty palette, but without an observable dependency here SwiftUI
  /// keeps the previous frame's overlay color until something else (focus
  /// change, layout) forces a rebuild — which is what produced the stale
  /// light/dark wash on unfocused panes after a theme switch.
  @Environment(\.colorScheme) private var colorScheme
  /// Bumped on `.ghosttyRuntimeConfigApplied` so the overlay re-resolves when
  /// the user picks a new ghostty theme (Settings → Terminal, or by editing
  /// `~/.config/ghostty/config`). `colorScheme` only covers the appearance
  /// flip path; without this tick the overlay stays on the previous theme's
  /// fill colour until the user re-focuses the pane or triggers a layout pass.
  @State private var configReloadTick: Int = 0
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
    return GeometryReader { geo in
      paneContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Grab affordance — only meaningful when there is somewhere to move to.
        .overlay(alignment: .top) {
          if isSplit {
            PaneDragHandle(paneID: paneID)
          }
        }
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
                      inProject: projectID
                    ))
                }
              )
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

  @ViewBuilder
  private var paneContent: some View {
    if let childStore = store.scope(
      state: \.paneHosts[id: paneID],
      action: \.paneHosts[id: paneID]
    ) {
      // `.id(paneID)` forces SwiftUI to rebuild the LazyPaneHost subtree when
      // the pane changes. Without it, two leaves at the same split-tree
      // position across worktree switches diff as "same view, new props", and
      // `PaneHostView.updateNSView` (intentionally a no-op — ghostty owns its
      // own rendering) never swaps the underlying `GhosttySurfaceView`, so the
      // terminal visually stays on the previously-shown worktree.
      LazyPaneHost(store: childStore)
        .id(paneID)
        .overlay { unfocusedDimOverlay }
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
          configReloadTick &+= 1
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
        .overlay { unfocusedDimOverlay }
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
          configReloadTick &+= 1
        }
    } else {
      // Truly cold pane: surface hasn't been spawned yet (first render
      // after creation). Background tracks Ghostty's terminal color so
      // the hand-off to `LazyPaneHost.loadingPlaceholder` and then the
      // live surface stays on a single tone — earlier we used
      // `underPageBackgroundColor` here, which produced a visible grey
      // flash before the terminal theme settled in.
      let terminalBackground = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: terminalBackground))
    }
  }

  private var isFocused: Bool {
    hierarchyManager.lastFocusedPane(in: tabID) == paneID
  }

  /// Wash on unfocused panes inside a multi-pane Tab. Matches ghostty's
  /// `unfocused-split` exactly: a hit-test-disabled `Rectangle` filled with
  /// `unfocused-split-fill` (defaults to terminal `background`) at
  /// `1 - unfocused-split-opacity` (default 0.15). Single-pane Tabs and the
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
