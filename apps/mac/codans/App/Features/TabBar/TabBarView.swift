import CodansCore
import ComposableArchitecture
import SwiftUI

/// Horizontal tab bar for the active Worktree. Reads `Worktree.tabs` from
/// the environment `HierarchyManager`; dispatches create / select / close
/// / rename / reorder / bulk-close actions through `TabBarFeature`.
///
/// The chip row lives inside `TabBarOverflowScroll`, which owns horizontal
/// scrolling and overflow stacking; the track fills the bar's width. The
/// bar carries no buttons of its own: new tabs come from ⌘T and the empty
/// page, splits and session history from each pane's header.
struct TabBarView: View {
  let store: StoreOf<TabBarFeature>
  /// Resolved address of the active worktree whose tabs we render.
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let activeTabID: TabID?
  /// AgentState registry (optional — previews / tests omit it). OR'd into the
  /// per-tab busy spinner so a chip lights while a bound agent in that tab is
  /// `.working`, complementing the terminal signal from `tabIsDirty`.
  var agentStateStore: AgentStateStore?
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    Group {
      if showsBar {
        barContent()
          .padding(.leading, TabBarMetrics.trackLeadingInset)
          .frame(height: TabBarMetrics.trackHeight)
      } else {
        // Keeps the sheets below mounted (a chip's context menu presents
        // them) while the bar itself takes no space.
        Color.clear.frame(height: 0)
      }
    }
    .sheet(
      item: Binding(
        get: { store.renameTarget },
        set: { newValue in
          // `.sheet(item:)` only ever sets `nil` (sheet dismissed by the
          // system / drag-down). Commit path drives clear from inside the
          // reducer via `.renameSubmitted`, so we forward nil → reducer
          // and ignore non-nil writes.
          if newValue == nil { store.send(.renameDismissed) }
        },
      )
    ) { target in
      TabRenameSheetView(
        initialName: target.currentName,
        onCommit: { newName in
          store.send(
            .renameSubmitted(
              target.id, name: newName,
              inWorktree: worktreeID, inProject: projectID,
            ))
        },
        onCancel: { store.send(.renameDismissed) },
      )
    }
    .sheet(
      item: Binding(
        get: { store.colorTarget },
        set: { newValue in
          if newValue == nil { store.send(.colorDismissed) }
        },
      )
    ) { target in
      TabColorSheetView(
        initialColor: target.currentColor,
        onCommit: { color in
          store.send(
            .colorSubmitted(
              target.id, color: color,
              inWorktree: worktreeID, inProject: projectID,
            ))
        },
        onCancel: { store.send(.colorDismissed) },
      )
    }
    .sheet(
      item: Binding(
        get: { store.iconTarget },
        set: { newValue in
          if newValue == nil { store.send(.iconDismissed) }
        },
      )
    ) { target in
      TabIconPickerSheet(
        initialIcon: target.currentIcon,
        onCommit: { icon in
          store.send(
            .iconSubmitted(
              target.id, icon: icon,
              inWorktree: worktreeID, inProject: projectID,
            ))
        },
        onCancel: { store.send(.iconDismissed) },
      )
    }
  }

  @ViewBuilder
  private func barContent() -> some View {
    if let worktree = currentWorktree(), !worktree.tabs.isEmpty {
      TabBarOverflowScroll(itemCount: worktree.tabs.count) { viewport in
        rowView(for: worktree, viewport: viewport)
      }
      .frame(height: TabBarMetrics.trackHeight)
    }
  }

  /// True iff tab `tabID` has a pane hosting a bound agent currently `.working`.
  /// Static so the `isDirty` closure stays a light value-capture; only `.working`
  /// counts (`.blocked` is "waiting on the user", not busy).
  private static func tabHasWorkingAgent(
    _ tabID: TabID, in worktree: Worktree, store: AgentStateStore?,
  ) -> Bool {
    guard let entries = store?.entries, !entries.isEmpty,
      let tab = worktree.tabs.first(where: { $0.id == tabID })
    else { return false }
    return tab.panes.contains { entries[$0.id]?.state == .working }
  }

  @ViewBuilder
  private func rowView(for worktree: Worktree, viewport: TabBarViewport) -> some View {
    TabBarRowView(
      tabs: worktree.tabs,
      activeTabID: activeTabID,
      viewport: viewport,
      // Two busy signals, kept apart so the chip can treat them differently.
      // Terminal (OSC 9;4 progress ∪ running foreground command): reading the
      // @Observable HierarchyManager re-renders the chip on a flip. Agent (the
      // render-derived `.working` state): reading `agentStateStore.entries`
      // registers the @Observable dependency that re-renders on a flip. A
      // working agent animates its own spinner into the tab title, so the chip
      // suppresses its spinner there (see `ResolvingTabChipView`) while the
      // terminal signal always shows it.
      isTerminalBusy: { tabID in hierarchyManager.tabIsDirty(tabID) },
      isAgentWorking: { tabID in
        Self.tabHasWorkingAgent(tabID, in: worktree, store: agentStateStore)
      },
      onSelect: { tabID in
        store.send(
          .tabButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID,
          ))
      },
      onClose: { tabID in
        store.send(
          .closeButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID,
          ))
      },
      onMiddleClick: { tabID in
        store.send(
          .middleClicked(
            tabID, inWorktree: worktreeID, inProject: projectID,
          ))
      },
      onCloseOthers: { tabID in
        store.send(
          .contextMenuCloseOthers(
            tabID, inWorktree: worktreeID, inProject: projectID,
          ))
      },
      onCloseToRight: { tabID in
        store.send(
          .contextMenuCloseToRight(
            tabID, inWorktree: worktreeID, inProject: projectID,
          ))
      },
      onCloseAll: {
        store.send(
          .contextMenuCloseAll(
            inWorktree: worktreeID, inProject: projectID,
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
            inWorktree: worktreeID, inProject: projectID,
          ))
      },
      emptyTabTitle: (worktree.path as NSString).lastPathComponent,
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
          in: projectID,
        )
      },
    )
    // A worktree switch swaps in a whole other tab list; a fresh row per
    // worktree keeps its chips from playing the add-tab insertion.
    .id(worktreeID)
  }

  /// The bar shows only with two or more tabs: a single tab has nothing to
  /// switch to, and with no tab the empty page offers New Tab and Resume
  /// Session itself.
  private var showsBar: Bool {
    (currentWorktree()?.tabs.count ?? 0) > 1
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
