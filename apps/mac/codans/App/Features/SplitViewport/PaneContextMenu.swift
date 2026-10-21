import ComposableArchitecture
import SwiftUI
import CodansCore

/// Pure model for the content-area right-click menu. Side effects (reading
/// labels, flipping mute, closing) go through closures so the menu's logic
/// stays testable without spinning up a SwiftUI view tree.
struct PaneContextMenuModel {
  let contentID: ContentID
  let snapshot: () -> Catalog
  let setLabel: (ContentID, String, Bool) -> Void
  /// Closes the Tab holding the Content through `HierarchyClient.closeTab`.
  /// Defaults to a no-op so label-only tests can construct the model
  /// without wiring close.
  var closeTab: () -> Void = {}
  /// Closes the whole Pane the Tab sits in.
  var closePane: () -> Void = {}

  var isMuted: Bool {
    snapshot().content(contentID)?.terminal?.isNotificationsMuted ?? false
  }

  func toggleMute() {
    setLabel(contentID, InboxLabels.muted, !isMuted)
  }

  func close() {
    closeTab()
  }
}

/// Right-click menu on a Tab's content. Hosts the "Mute notifications"
/// toggle, "Close Tab" and "Close Pane"; future menu items can be added
/// here without churning `LazyPaneHost`.
///
/// The menu reads `HierarchyClient.snapshot()` lazily inside
/// `PaneContextMenuModel.isMuted` on every render so the checkmark
/// reflects the latest label state when the user re-opens the menu —
/// the per-Content mute label flips elsewhere are picked up without an
/// explicit observer.
struct PaneContextMenu: View {
  let contentID: ContentID
  let tabID: TabID
  let paneID: PaneID
  @Dependency(HierarchyClient.self) private var hierarchy

  private var model: PaneContextMenuModel {
    PaneContextMenuModel(
      contentID: contentID,
      snapshot: hierarchy.snapshot,
      setLabel: hierarchy.setContentLabel,
      closeTab: { try? hierarchy.closeTab(tabID) },
      closePane: { try? hierarchy.closePane(paneID) }
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
      Label("Close Tab", systemImage: "xmark")
    }
    Button {
      model.closePane()
    } label: {
      Label("Close Pane", systemImage: "rectangle.slash")
    }
  }
}
