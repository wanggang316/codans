import ComposableArchitecture
import SwiftUI
import CodansCore

/// Pure model for the pane right-click context menu. Side effects (reading
/// labels, flipping mute, closing the pane) go through closures so the
/// menu's logic stays testable without spinning up a SwiftUI view tree.
struct PaneContextMenuModel {
  let paneID: PaneID
  let snapshot: () -> Catalog
  let setLabel: (PaneID, String, Bool) -> Void
  /// Tears down the pane through `HierarchyClient.closePane`. The full
  /// pane address is captured by the view at the call site, so the model
  /// only needs to fire the closure. Defaults to a no-op so label-only
  /// tests can construct the model without wiring close.
  var closePane: () -> Void = {}

  var isMuted: Bool {
    snapshot().pane(paneID)?.labels.contains(InboxLabels.muted) ?? false
  }

  func toggleMute() {
    setLabel(paneID, InboxLabels.muted, !isMuted)
  }

  func close() {
    closePane()
  }
}

/// Right-click menu for a pane. Hosts the "Mute notifications" toggle
/// and a "Close" item that tears the pane down; future menu items can be
/// added here without churning `LazyPaneHost`.
///
/// The menu reads `HierarchyClient.snapshot()` lazily inside
/// `PaneContextMenuModel.isMuted` on every render so the checkmark
/// reflects the latest label state when the user re-opens the menu —
/// the per-pane mute label flips elsewhere are picked up without an
/// explicit observer.
struct PaneContextMenu: View {
  let paneID: PaneID
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID
  @Dependency(HierarchyClient.self) private var hierarchy

  private var model: PaneContextMenuModel {
    PaneContextMenuModel(
      paneID: paneID,
      snapshot: hierarchy.snapshot,
      setLabel: hierarchy.setPaneLabel,
      // Mirrors the ⌘W focused-pane path (RootFeature) and the prepared
      // `SplitViewportFeature.closePaneButtonTapped`: a plain pane
      // teardown. Closing the tab's last pane leaves an empty tab, which
      // `SplitViewportView` renders as its "No panes" placeholder.
      closePane: { try? hierarchy.closePane(paneID, tabID, worktreeID, projectID) }
    )
  }

  var body: some View {
    Button {
      model.toggleMute()
    } label: {
      Label(
        "Mute notifications",
        systemImage: model.isMuted ? "checkmark" : "bell.slash"
      )
    }
    Divider()
    Button {
      model.close()
    } label: {
      Label("Close", systemImage: "xmark")
    }
  }
}
