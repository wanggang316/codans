import CodansIPC
import ComposableArchitecture
import SwiftUI

/// The detail column for a Mac that streams terminals (protocol minor 2):
/// the selected pane's live terminal under a tab-name menu. The menu lists
/// the worktree's tabs, the current tab's split panes in split order —
/// how splits reach a phone — and the tab and pane actions. In regular
/// width the tab's real split layout is shown instead, one stream per
/// visible pane.
///
/// Picking a pane here is local to the phone: it never moves the Mac's
/// focus.
struct TerminalDetailView: View {
  let store: StoreOf<AppFeature>
  @Binding var selectedPaneID: String?

  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var cache = TerminalStoreCache()
  @State private var keyboard = TerminalKeyboardState()
  /// A tab or pane just created on the Mac that the hierarchy has not
  /// listed yet.
  @State private var pending: TerminalStreamFeature.Navigation?
  @State private var isRenaming = false
  @State private var renameText = ""
  @State private var closeConfirmation: CloseTarget?

  private enum CloseTarget: Identifiable {
    case pane
    case tab

    var id: Self { self }
  }

  private var location: PaneLocation? {
    selectedPaneID.flatMap(store.browser.location(ofPane:))
  }

  /// Streams attach only once the session is live (the snapshot arrived),
  /// and drop to their reconnecting state as soon as it is not.
  private var isConnected: Bool { store.connection.isLive }
  private var permission: IPC.RemotePermission { store.connection.terminalPermission }
  private var isSplitLayout: Bool { sizeClass == .regular }

  var body: some View {
    Group {
      if let location {
        content(location)
      } else {
        ContentUnavailableView("Select a Pane", systemImage: "terminal")
      }
    }
    .onChange(of: store.browser.hierarchy) { _, _ in resolvePending() }
    .onChange(of: isConnected) { _, connected in
      for pane in cache.all { pane.send(.connectionChanged(connected)) }
    }
    .onChange(of: permission) { _, permission in
      for pane in cache.all { pane.send(.permissionChanged(permission)) }
    }
  }

  @ViewBuilder
  private func content(_ location: PaneLocation) -> some View {
    let focused = paneStore(location.pane.id, location: location)
    Group {
      if isSplitLayout, let layout = location.tab.layout, location.tab.panes.count > 1 {
        VStack(spacing: 0) {
          splitLayout(layout, location: location)
          if focused.isInteractive {
            // One key bar under the whole layout: a narrow split pane has
            // no room for it, and only the focused pane takes keys.
            TerminalInputChrome(
              store: focused,
              agent: location.pane.agent,
              keyboard: keyboard,
              onShortcut: { handle($0, location: location, focused: focused) }
            )
            .id(location.pane.id)
          }
        }
      } else {
        VStack(spacing: 0) {
          PaneStrip(
            location: location,
            agent: store.agents.kind(ofPane: location.pane.id),
            onSwipe: { offset in select(TerminalLayout.pane(offset, from: location.pane.id, in: location.tab)) }
          )
          TerminalPaneView(
            store: focused,
            agent: location.pane.agent,
            keyboard: keyboard,
            onShortcut: { handle($0, location: location, focused: focused) },
            onCloseRequested: { closeConfirmation = .pane },
            connectionStatus: store.connection.health.title
          )
          .id(location.pane.id)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        TabTitleMenu(
          location: location,
          agents: store.agents,
          canManage: permission == .interactive && isConnected,
          select: { selectedPaneID = $0 },
          newTab: { focused.send(.newTabTapped) },
          split: { focused.send(.splitTapped($0)) },
          rename: {
            renameText = location.tab.title ?? ""
            isRenaming = true
          },
          openOnMac: { focused.send(.openOnMacTapped) },
          close: { closeConfirmation = $0 == .tab ? .tab : .pane }
        )
      }
    }
    .alert("Rename Tab", isPresented: $isRenaming) {
      TextField("Tab name", text: $renameText)
      Button("Rename") { focused.send(.renameTabSubmitted(renameText)) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Leave it empty to show the terminal's own title.")
    }
    .confirmationDialog(
      closeConfirmation == .tab ? "Close this tab?" : "Close this pane?",
      isPresented: Binding(get: { closeConfirmation != nil }, set: { if !$0 { closeConfirmation = nil } }),
      titleVisibility: .visible,
      presenting: closeConfirmation
    ) { target in
      switch target {
      case .pane:
        Button("Close Pane", role: .destructive) { focused.send(.closePaneConfirmed) }
      case .tab:
        Button("Close Tab", role: .destructive) { focused.send(.closeTabConfirmed) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { target in
      switch target {
      case .pane:
        Text("This ends the process running in the pane on your Mac.")
      case .tab:
        Text("This ends the processes in all \(location.tab.panes.count) panes of the tab on your Mac.")
      }
    }
    .onChange(of: focused.navigation) { _, navigation in
      guard let navigation else { return }
      focused.send(.navigationHandled)
      navigate(navigation, from: location)
    }
    .onChange(of: streamedPaneIDs(location)) { _, ids in cache.retain(only: ids) }
    .onAppear { cache.retain(only: streamedPaneIDs(location)) }
  }

  // MARK: - iPad split layout

  private func splitLayout(_ layout: IPC.SplitLayoutNode, location: PaneLocation) -> some View {
    let streamed = streamedPaneIDs(location)
    return SplitLayoutView(node: layout) { paneID in
      let pane = location.tab.panes.first { $0.id == paneID }
      let isFocused = paneID == location.pane.id
      // A tap focuses the pane on the phone; to VoiceOver it stays a
      // terminal, with "Focus Pane" as its action.
      // swiftlint:disable:next accessibility_trait_for_button
      Group {
        if streamed.contains(paneID), let pane {
          let paneLocation = PaneLocation(
            project: location.project, worktree: location.worktree, tab: location.tab, pane: pane)
          let paneStore = self.paneStore(paneID, location: paneLocation)
          TerminalPaneView(
            store: paneStore,
            agent: pane.agent,
            keyboard: isFocused ? keyboard : nil,
            showsInputChrome: false,
            onCloseRequested: {
              selectedPaneID = paneID
              closeConfirmation = .pane
            },
            connectionStatus: store.connection.health.title
          )
        } else {
          PanePlaceholder(title: pane.map(Self.title) ?? "Pane")
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 2)
          .strokeBorder(
            isFocused ? Color.white.opacity(0.85) : Color.white.opacity(0.08), lineWidth: isFocused ? 2 : 1
          )
          .allowsHitTesting(false)
      }
      .simultaneousGesture(TapGesture().onEnded { if !isFocused { selectedPaneID = paneID } })
      .accessibilityAction(named: "Focus Pane") { selectedPaneID = paneID }
    }
    // Not into the safe area: the navigation bar above keeps the app's
    // appearance.
    .background(Color.black, ignoresSafeAreaEdges: [])
  }

  // MARK: - Stores

  private func paneStore(_ paneID: String, location: PaneLocation) -> StoreOf<TerminalStreamFeature> {
    let paneStore = cache.store(for: paneID, permission: permission, isConnected: isConnected)
    let locator = PaneLocator(
      projectID: location.project.id, worktreeID: location.worktree.id, tabID: location.tab.id, paneID: paneID)
    if paneStore.location != locator {
      // Deferred: sending during a view update would mutate observed state
      // mid-render.
      Task { @MainActor in paneStore.send(.locationChanged(locator)) }
    }
    return paneStore
  }

  private func streamedPaneIDs(_ location: PaneLocation) -> Set<String> {
    guard isSplitLayout, location.tab.layout != nil, location.tab.panes.count > 1 else {
      return [location.pane.id]
    }
    return TerminalLayout.streamedPaneIDs(in: location.tab, focused: location.pane.id)
  }

  // MARK: - Navigation

  private func select(_ paneID: String?) {
    guard let paneID else { return }
    selectedPaneID = paneID
  }

  private func handle(
    _ shortcut: TerminalHardwareShortcut, location: PaneLocation, focused: StoreOf<TerminalStreamFeature>
  ) {
    switch shortcut {
    case .previousPane: select(TerminalLayout.pane(-1, from: location.pane.id, in: location.tab))
    case .nextPane: select(TerminalLayout.pane(1, from: location.pane.id, in: location.tab))
    case .tab(let number):
      let tabs = location.worktree.tabs
      guard tabs.indices.contains(number - 1) else { return }
      select(TerminalLayout.landingPane(in: tabs[number - 1]))
    case .newTab: focused.send(.newTabTapped)
    case .splitRight: focused.send(.splitTapped(.right))
    case .splitDown: focused.send(.splitTapped(.down))
    case .zoomIn, .zoomOut, .clear: break
    }
  }

  private func navigate(_ navigation: TerminalStreamFeature.Navigation, from location: PaneLocation) {
    switch navigation {
    case .paneClosed:
      selectedPaneID = TerminalLayout.paneAfterClosing(location.pane.id, in: location.worktree)
    case .showTab, .showPane:
      pending = navigation
      resolvePending()
    }
  }

  private func resolvePending() {
    guard let pending, let worktree = location?.worktree else { return }
    switch pending {
    case .showTab(let tabID):
      guard let tab = worktree.tabs.first(where: { $0.id == tabID }),
        let paneID = TerminalLayout.landingPane(in: tab)
      else { return }
      selectedPaneID = paneID
    case .showPane(let paneID):
      guard worktree.tabs.contains(where: { $0.panes.contains { $0.id == paneID } }) else { return }
      selectedPaneID = paneID
    case .paneClosed:
      break
    }
    self.pending = nil
  }

  static func title(_ pane: IPC.PaneSummary) -> String {
    pane.title ?? pane.handle ?? "Pane"
  }
}

// MARK: - Title menu

/// The tab name with a chevron, and page dots when the tab is split.
private struct TabTitleMenu: View {
  enum CloseKind { case pane, tab }

  let location: PaneLocation
  let agents: AgentsFeature.State
  let canManage: Bool
  let select: (String) -> Void
  let newTab: () -> Void
  let split: (SplitDirection) -> Void
  let rename: () -> Void
  let openOnMac: () -> Void
  let close: (CloseKind) -> Void

  var body: some View {
    let ordered = TerminalLayout.orderedPaneIDs(in: location.tab)
    Menu {
      Section("Tabs") {
        ForEach(location.worktree.tabs, id: \.id) { tab in
          Button {
            if let paneID = TerminalLayout.landingPane(in: tab) { select(paneID) }
          } label: {
            Label(tabTitle(tab), systemImage: tab.id == location.tab.id ? "checkmark" : symbol(forTab: tab))
            if let status = status(forTab: tab) { Text(status) }
          }
        }
      }
      if ordered.count > 1 {
        Section("Panes in This Tab") {
          ForEach(Array(ordered.enumerated()), id: \.element) { index, paneID in
            if let pane = location.tab.panes.first(where: { $0.id == paneID }) {
              Button {
                select(paneID)
              } label: {
                Label(
                  "\(index + 1). \(TerminalDetailView.title(pane))",
                  systemImage: paneID == location.pane.id ? "checkmark" : symbol(forPane: pane))
                Text(paneSubtitle(pane))
              }
            }
          }
        }
      }
      if canManage {
        Section {
          Button("New Tab", systemImage: "plus.square.on.square", action: newTab)
          Button("Split Right", systemImage: "rectangle.split.2x1") { split(.right) }
          Button("Split Down", systemImage: "rectangle.split.1x2") { split(.down) }
          Button("Rename Tab…", systemImage: "pencil", action: rename)
          Button("Open on Mac", systemImage: "macwindow", action: openOnMac)
        }
        Section {
          Button("Close Pane…", systemImage: "xmark.square", role: .destructive) { close(.pane) }
          Button("Close Tab…", systemImage: "xmark.rectangle", role: .destructive) { close(.tab) }
        }
      }
    } label: {
      VStack(spacing: 3) {
        HStack(spacing: 4) {
          Text(tabTitle(location.tab))
            .font(.headline)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .accessibilityHidden(true)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
        }
        if ordered.count > 1 {
          PageDots(count: ordered.count, current: ordered.firstIndex(of: location.pane.id) ?? 0)
        }
      }
      .foregroundStyle(.primary)
      .contentShape(.rect)
    }
    .accessibilityIdentifier("tab-menu")
  }

  private func tabTitle(_ tab: IPC.TabSummary) -> String {
    tab.title ?? tab.handle ?? "Tab"
  }

  private func mostUrgent(_ panes: [IPC.PaneSummary]) -> AgentGroup.Kind? {
    let kinds = panes.compactMap { agents.kind(ofPane: $0.id) }
    return AgentGroup.Kind.allCases.first { kinds.contains($0) }
  }

  private func status(forTab tab: IPC.TabSummary) -> String? {
    let panes = tab.panes.count == 1 ? "1 pane" : "\(tab.panes.count) panes"
    guard let kind = mostUrgent(tab.panes), kind != .idle else { return panes }
    return "\(panes) · \(kind.title)"
  }

  private func symbol(forTab tab: IPC.TabSummary) -> String {
    mostUrgent(tab.panes).map(\.dotSymbol) ?? "terminal"
  }

  private func symbol(forPane pane: IPC.PaneSummary) -> String {
    agents.kind(ofPane: pane.id).map(\.dotSymbol) ?? "terminal"
  }

  private func paneSubtitle(_ pane: IPC.PaneSummary) -> String {
    var parts: [String] = []
    if let kind = agents.kind(ofPane: pane.id) { parts.append(kind.title) }
    if let cwd = TerminalLayout.displayPath(pane.cwd) { parts.append(cwd) }
    return parts.joined(separator: " · ")
  }
}

extension AgentGroup.Kind {
  /// A filled dot for needs input and working, hollow for idle.
  var dotSymbol: String {
    switch self {
    case .needsInput: return "exclamationmark.circle.fill"
    case .working: return "circle.fill"
    case .idle: return "circle"
    }
  }
}

private struct PageDots: View {
  let count: Int
  let current: Int

  var body: some View {
    HStack(spacing: 5) {
      ForEach(0..<count, id: \.self) { index in
        Circle()
          .fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
          .frame(width: 5, height: 5)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Pane \(current + 1) of \(count)")
  }
}

/// Name and working directory of the pane on screen; swiping it moves to
/// the neighbouring split pane.
private struct PaneStrip: View {
  let location: PaneLocation
  let agent: AgentGroup.Kind?
  let onSwipe: (Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: agent?.dotSymbol ?? "terminal")
        .accessibilityHidden(true)
        .font(.caption)
        .foregroundStyle(agent?.tint ?? .secondary)
      Text(TerminalDetailView.title(location.pane))
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
      if let cwd = TerminalLayout.displayPath(location.pane.cwd) {
        Text(cwd)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 0)
      if location.tab.panes.count > 1 {
        Image(systemName: "chevron.left.chevron.right")
          .accessibilityHidden(true)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    // A minimum, not a fixed height, so larger text sizes are not clipped.
    .frame(minHeight: 30)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .contentShape(.rect)
    .gesture(
      DragGesture(minimumDistance: 20).onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        onSwipe(value.translation.width < 0 ? 1 : -1)
      }
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pane-strip")
    .accessibilityAction(named: "Next Pane") { onSwipe(1) }
    .accessibilityAction(named: "Previous Pane") { onSwipe(-1) }
  }
}

/// A split pane beyond the iPad's live-stream limit.
private struct PanePlaceholder: View {
  let title: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "terminal")
        .accessibilityHidden(true)
        .font(.title3)
      Text(title)
        .font(.footnote.weight(.semibold))
      Text("Tap to show")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.5))
    }
    .foregroundStyle(.white.opacity(0.75))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MirrorTerminalView.background.swiftUIColor)
  }
}

/// A tab's split tree drawn with the Mac's proportions.
private struct SplitLayoutView<Leaf: View>: View {
  let node: IPC.SplitLayoutNode
  @ViewBuilder let leaf: (String) -> Leaf

  var body: some View {
    switch node {
    case .leaf(let paneID):
      leaf(paneID)
    case .split(let direction, let ratio, let left, let right):
      GeometryReader { geometry in
        let share = min(max(ratio, 0.1), 0.9)
        if direction == .horizontal {
          HStack(spacing: 2) {
            SplitLayoutView(node: left, leaf: leaf).frame(width: (geometry.size.width - 2) * share)
            SplitLayoutView(node: right, leaf: leaf)
          }
        } else {
          VStack(spacing: 2) {
            SplitLayoutView(node: left, leaf: leaf).frame(height: (geometry.size.height - 2) * share)
            SplitLayoutView(node: right, leaf: leaf)
          }
        }
      }
    }
  }
}
