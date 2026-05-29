import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Horizontal tab bar for the active Worktree. Reads `Worktree.tabs` from
/// the environment `HierarchyManager`; dispatches create / select / close
/// / rename / reorder / bulk-close actions through `TabBarFeature`.
///
/// Post M2-T2.7 the chip row lives inside `TabBarOverflowScroll`, which
/// owns horizontal scrolling, edge-gradient shadows, and auto-scroll-to-
/// selected; the trailing accessory cluster is pinned outside the scroll
/// region so `+` is always visible regardless of chip count.
struct TabBarView: View {
  let store: StoreOf<TabBarFeature>
  /// Resolved address of the active worktree whose tabs we render. If any
  /// of the IDs is nil, the view shows a thin empty bar.
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let activeTabID: TabID?
  /// AgentState registry (optional — previews / tests omit it). OR'd into the
  /// per-tab busy spinner so a chip lights while a bound agent in that tab is
  /// `.working`, complementing the terminal signal from `tabIsDirty`.
  var agentStateStore: AgentStateStore?
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    HStack(spacing: 4, content: barContent)
      .frame(height: TabBarMetrics.barHeight, alignment: .bottom)
      .sheet(
        item: Binding(
          get: { store.renameTarget },
          set: { newValue in
            // `.sheet(item:)` only ever sets `nil` (sheet dismissed by the
            // system / drag-down). Commit path drives clear from inside the
            // reducer via `.renameSubmitted`, so we forward nil → reducer
            // and ignore non-nil writes.
            if newValue == nil { store.send(.renameDismissed) }
          }
        )
      ) { target in
        TabRenameSheetView(
          initialName: target.currentName,
          onCommit: { newName in
            store.send(
              .renameSubmitted(
                target.id, name: newName,
                inWorktree: worktreeID, inProject: projectID
              ))
          },
          onCancel: { store.send(.renameDismissed) }
        )
      }
      .sheet(
        item: Binding(
          get: { store.colorTarget },
          set: { newValue in
            if newValue == nil { store.send(.colorDismissed) }
          }
        )
      ) { target in
        TabColorSheetView(
          initialColor: target.currentColor,
          onCommit: { color in
            store.send(
              .colorSubmitted(
                target.id, color: color,
                inWorktree: worktreeID, inProject: projectID
              ))
          },
          onCancel: { store.send(.colorDismissed) }
        )
      }
      .sheet(
        item: Binding(
          get: { store.iconTarget },
          set: { newValue in
            if newValue == nil { store.send(.iconDismissed) }
          }
        )
      ) { target in
        TabIconPickerSheet(
          initialIcon: target.currentIcon,
          onCommit: { icon in
            store.send(
              .iconSubmitted(
                target.id, icon: icon,
                inWorktree: worktreeID, inProject: projectID
              ))
          },
          onCancel: { store.send(.iconDismissed) }
        )
      }
  }

  @ViewBuilder
  private func barContent() -> some View {
    Group {
      if let worktree = currentWorktree() {
        TabBarOverflowScroll(activeTabID: activeTabID) {
          rowView(for: worktree)
        }
      }
      TabBarTrailingAccessories(
        activeTabSplitTree: activeSplitTree(),
        onNewTab: {
          store.send(
            .newTabButtonTapped(
              inWorktree: worktreeID, inProject: projectID
            ))
        },
        onSplitRight: {
          store.send(
            .trailingSplitRequested(
              direction: .right,
              inWorktree: worktreeID, inProject: projectID
            ))
        },
        onSplitDown: {
          store.send(
            .trailingSplitRequested(
              direction: .down,
              inWorktree: worktreeID, inProject: projectID
            ))
        }
      )
    }
  }

  /// Splits the active tab's tree for the trailing hover-preview popover.
  /// Returns `nil` when there is no active tab or the tab has no panes.
  private func activeSplitTree() -> SplitTree<PaneID>? {
    guard
      let worktree = currentWorktree(),
      let activeTabID,
      let tab = worktree.tabs.first(where: { $0.id == activeTabID })
    else { return nil }
    return tab.splitTree.isEmpty ? nil : tab.splitTree
  }

  /// True iff tab `tabID` has a pane hosting a bound agent currently `.working`.
  /// Static so the `isDirty` closure stays a light value-capture; only `.working`
  /// counts (`.blocked` is "waiting on the user", not busy).
  private static func tabHasWorkingAgent(
    _ tabID: TabID, in worktree: Worktree, store: AgentStateStore?
  ) -> Bool {
    guard let entries = store?.entries, !entries.isEmpty,
      let tab = worktree.tabs.first(where: { $0.id == tabID })
    else { return false }
    return tab.panes.contains { entries[$0.id]?.state == .working }
  }

  @ViewBuilder
  private func rowView(for worktree: Worktree) -> some View {
    TabBarRowView(
      tabs: worktree.tabs,
      activeTabID: activeTabID,
      // Read through the @Observable HierarchyManager so any flip of the
      // terminal signal (OSC 9;4 progress ∪ running foreground command)
      // triggers a chip re-render. OR in the render-derived agent `.working`
      // state for this tab; reading `agentStateStore.entries` here registers
      // the @Observable dependency that re-renders the chip on a state flip.
      isDirty: { tabID in
        hierarchyManager.tabIsDirty(tabID)
          || Self.tabHasWorkingAgent(tabID, in: worktree, store: agentStateStore)
      },
      onSelect: { tabID in
        store.send(
          .tabButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onClose: { tabID in
        store.send(
          .closeButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onMiddleClick: { tabID in
        store.send(
          .middleClicked(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCloseOthers: { tabID in
        store.send(
          .contextMenuCloseOthers(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCloseToRight: { tabID in
        store.send(
          .contextMenuCloseToRight(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCloseAll: {
        store.send(
          .contextMenuCloseAll(
            inWorktree: worktreeID, inProject: projectID
          ))
      },
      onRenameRequested: { tabID in
        guard let tab = worktree.tabs.first(where: { $0.id == tabID }) else { return }
        store.send(.renameRequested(tabID, currentName: tab.name ?? ""))
      },
      onChangeColorRequested: { tabID in
        guard let tab = worktree.tabs.first(where: { $0.id == tabID }) else { return }
        store.send(.colorRequested(tabID, currentColor: tab.color))
      },
      onChangeIconRequested: { tabID in
        guard let tab = worktree.tabs.first(where: { $0.id == tabID }) else { return }
        store.send(.iconRequested(tabID, currentIcon: tab.icon))
      },
      onCopyID: { tabID in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tabID.description, forType: .string)
      },
      onReorder: { orderedIDs in
        store.send(
          .dragReorderEnded(
            orderedIDs: orderedIDs,
            inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCacheLiveTitle: { tabID, title in
        // Direct manager call rather than a TCA action: the cache is a
        // persistence side-effect of rendering, not a user intent, so
        // routing through reducer + effect would add noise without
        // benefit. `setCachedTabTitle` debounces internally and no-ops
        // on identical values, so a hot OSC stream is cheap.
        hierarchyManager.setCachedTabTitle(
          title,
          for: tabID,
          in: worktreeID,
          in: projectID
        )
      }
    )
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
