import CodansCore
import ComposableArchitecture
import SwiftUI

/// Horizontal tab bar of one Pane. Reads the Pane's Tabs from the
/// environment `HierarchyManager`; dispatches new / select / close / rename
/// / reorder / bulk-close actions through `TabBarFeature`. Every Pane of
/// the Worktree renders its own strip on the same store.
///
/// The chip row lives inside `TabBarOverflowScroll`, which owns horizontal
/// scrolling, edge-gradient shadows, and auto-scroll-to-selected; the
/// trailing accessory cluster is pinned outside the scroll region so `+`
/// is always visible regardless of chip count.
struct TabBarView: View {
  let store: StoreOf<TabBarFeature>
  /// Resolved address of the Pane whose strip we render. When the Pane is
  /// unresolved or has no Tabs, only the trailing accessories show.
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let paneID: PaneID
  /// Whether this Pane is the Worktree's focused one. The focused strip of
  /// the key window renders active; every other strip renders the inactive
  /// window style.
  var isFocused: Bool = true
  /// AgentState registry (optional — previews / tests omit it). OR'd into the
  /// per-tab busy spinner so a chip lights while a bound agent in that tab is
  /// `.working`, complementing the terminal signal from `tabIsDirty`.
  var agentStateStore: AgentStateStore?
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(ContentRuntime.self) private var contentRuntime: ContentRuntime?
  @Environment(\.controlActiveState) private var controlActiveState
  /// Strip width, for the accessory fold. Starts wide so the first frame
  /// shows the full cluster rather than flashing the folded one.
  @State private var stripWidth: CGFloat = .infinity

  /// Active style: focused Pane in the key window, like the system bar,
  /// which renders inactive whenever its window is not key.
  private var isActiveStyle: Bool {
    isFocused && controlActiveState != .inactive
  }

  var body: some View {
    HStack(spacing: TabBarMetrics.trackAccessoryGap, content: barContent)
      .padding(.leading, TabBarMetrics.trackLeadingInset)
      .frame(height: TabBarMetrics.trackHeight)
      .padding(.top, TabBarMetrics.trackTopInset)
      .padding(.bottom, TabBarMetrics.trackBottomInset)
      .onGeometryChange(for: CGFloat.self, of: \.size.width) { stripWidth = $0 }
      // A click on the strip outside a chip or a control focuses the Pane,
      // like a click on its content.
      .background {
        // Not an accessibility element: AX focuses a Pane through its
        // chips and content, this only catches stray pointer clicks.
        Color.clear
          .contentShape(.rect)
          .gesture(TapGesture().onEnded { store.send(.stripTapped(paneID)) })
          .accessibilityHidden(true)
      }
      .environment(\.tabStripIsActive, isActiveStyle)
      .accessibilityIdentifier("tab_strip.\(paneID.raw.uuidString)")
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
            store.send(.renameSubmitted(target.id, name: newName))
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
            store.send(.colorSubmitted(target.id, color: color))
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
            store.send(.iconSubmitted(target.id, icon: icon))
          },
          onCancel: { store.send(.iconDismissed) }
        )
      }
  }

  @ViewBuilder
  private func barContent() -> some View {
    Group {
      // No tabs → no track: an empty capsule reads as a blank tab. The
      // spacer keeps the accessories pinned trailing in its place.
      if let worktree = currentWorktree(), let pane = worktree.pane(paneID), !pane.tabs.isEmpty {
        TabBarOverflowScroll(itemCount: pane.tabs.count) { viewport in
          rowView(for: pane, in: worktree, viewport: viewport)
        }
        .frame(height: TabBarMetrics.trackHeight)
      } else {
        Spacer(minLength: 0)
      }
      TabBarTrailingAccessories(
        worktreePath: currentWorktree()?.path,
        remoteHost: hierarchyManager.catalog.projects
          .first(where: { $0.id == projectID })?.remoteHost,
        isFolded: TabBarMetrics.foldsAccessories(stripWidth: stripWidth),
        onNewTab: {
          store.send(.newTabButtonTapped(inPane: paneID, inWorktree: worktreeID, inProject: projectID))
        },
        onLaunchAgent: { profileID in
          store.send(
            .launchAgentInNewTabTapped(
              profileID: profileID, inPane: paneID, inWorktree: worktreeID, inProject: projectID))
        },
        onManageAgents: { store.send(.manageAgentsTapped) },
        onResumeSession: { session in
          store.send(
            .resumeAgentSessionTapped(
              agent: session.agent, sessionID: session.sessionID,
              inPane: paneID, inWorktree: worktreeID, inProject: projectID
            ))
        }
      )
    }
  }

  /// True iff the Tab's Content hosts a bound agent currently `.working`.
  /// Static so the `isDirty` closure stays a light value-capture; only
  /// `.working` counts (`.blocked` is "waiting on the user", not busy).
  private static func tabHasWorkingAgent(
    _ tabID: TabID, in pane: Pane, store: AgentStateStore?
  ) -> Bool {
    guard let entries = store?.entries, !entries.isEmpty,
      let tab = pane.tab(tabID)
    else { return false }
    return entries[tab.contentID]?.state == .working
  }

  @ViewBuilder
  private func rowView(for pane: Pane, in worktree: Worktree, viewport: TabBarViewport) -> some View {
    TabBarRowView(
      tabs: pane.tabs,
      activeTabID: pane.selectedTabID,
      paneID: paneID,
      viewport: viewport,
      // Two busy signals, kept apart so the chip can treat them differently.
      // Terminal (OSC 9;4 progress ∪ running foreground command): reading the
      // @Observable ContentRuntime re-renders the chip on a flip. Agent (the
      // render-derived `.working` state): reading `agentStateStore.entries`
      // registers the @Observable dependency that re-renders on a flip. A
      // working agent animates its own spinner into the tab title, so the chip
      // suppresses its spinner there (see `ResolvingTabChipView`) while the
      // terminal signal always shows it.
      isTerminalBusy: { tabID in contentRuntime?.tabIsDirty(tabID) ?? false },
      isAgentWorking: { tabID in
        Self.tabHasWorkingAgent(tabID, in: pane, store: agentStateStore)
      },
      onSelect: { tabID in store.send(.tabButtonTapped(tabID)) },
      onClose: { tabID in store.send(.closeButtonTapped(tabID)) },
      onMiddleClick: { tabID in store.send(.middleClicked(tabID)) },
      onCloseOthers: { tabID in store.send(.contextMenuCloseOthers(tabID)) },
      onCloseToRight: { tabID in store.send(.contextMenuCloseToRight(tabID)) },
      onCloseAll: { store.send(.contextMenuCloseAll(inPane: paneID)) },
      onRenameRequested: { tabID in
        guard let tab = pane.tab(tabID) else { return }
        store.send(.renameRequested(tabID, currentName: tab.name ?? ""))
      },
      onChangeColorRequested: { tabID in
        guard let tab = pane.tab(tabID) else { return }
        store.send(.colorRequested(tabID, currentColor: tab.color))
      },
      onChangeIconRequested: { tabID in
        guard let tab = pane.tab(tabID) else { return }
        store.send(.iconRequested(tabID, currentIcon: tab.icon))
      },
      onCopyID: { tabID in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tabID.description, forType: .string)
      },
      onReorder: { orderedIDs in
        store.send(.dragReorderEnded(orderedIDs: orderedIDs, inPane: paneID))
      },
      emptyTabTitle: (worktree.path as NSString).lastPathComponent,
      onCacheLiveTitle: { tabID, title in
        // Direct manager call rather than a TCA action: the cache is a
        // persistence side-effect of rendering, not a user intent, so
        // routing through reducer + effect would add noise without
        // benefit. `setCachedTabTitle` debounces internally and no-ops
        // on identical values, so a hot OSC stream is cheap.
        hierarchyManager.setCachedTabTitle(title, for: tabID)
      }
    )
    // A Pane swap brings a whole other tab list; a fresh row per Pane
    // keeps its chips from playing the add-tab insertion.
    .id(paneID)
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
