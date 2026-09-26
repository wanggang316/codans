import CodansIPC
import ComposableArchitecture
import SwiftUI

/// What the home screen's title menu and toolbar can open, owned by the
/// root view that presents the sheets.
struct HomeActions {
  var openAgents: () -> Void
  var openSettings: () -> Void
  var openPairing: () -> Void
  var openConnectionDetails: () -> Void
}

/// The workspace: Project → Worktree on the home list, the worktree's
/// terminal in the detail column. In compact width the columns collapse
/// into a stack and a worktree opens straight into its terminal (the pane
/// last viewed there, else the Mac's own choice); in regular width the list
/// is a sidebar beside the terminal. Only size class decides.
struct WorkspaceView: View {
  let store: StoreOf<AppFeature>
  let actions: HomeActions
  @Binding var selectedWorktreeID: String?
  @Binding var selectedPaneID: String?
  @Binding var paneMemory: PaneMemory

  /// A pane the composer just started that the hierarchy has not reported
  /// yet; selected as soon as it appears.
  @State private var pendingPaneID: String?
  @State private var isComposerOpen = false
  /// Counts recoveries from a dropped connection, for the haptic.
  @State private var reconnects = 0
  @State private var wasLive = false
  @State private var wasDropped = false

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var health: ConnectionHealth { store.connection.health }
  private var canCompose: Bool { store.connection.terminalPermission == .interactive }

  var body: some View {
    NavigationSplitView {
      HomeList(
        store: store,
        selectedWorktreeID: $selectedWorktreeID,
        showsSelection: sizeClass == .regular,
        actions: actions,
        newAgent: { projectID in
          store.send(.composer(.targetSelected(.newWorktree(projectID: projectID))))
          isComposerOpen = true
        }
      )
      .navigationTitle(store.connection.activeGateway?.displayName ?? "Codans")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          HomeTitleMenu(store: store, actions: actions)
        }
        ToolbarItem(placement: .primaryAction) {
          AgentsToolbarButton(needsInput: store.agents.needsInputCount, action: actions.openAgents)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        // The last session's permission: the pill stays through a
        // reconnect (its Send waits for live) instead of flickering away.
        if canCompose, store.browser.hierarchy != nil {
          ComposerPill(profile: store.composer.profile) { isComposerOpen = true }
        }
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
    } detail: {
      detail
        .safeAreaInset(edge: .top, spacing: 0) {
          if health.isPaired, !health.isLive {
            ConnectionBanner(
              health: health,
              retry: { store.send(.connection(.connectTapped)) },
              pairAgain: actions.openPairing
            )
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
            .background(Color.surface)
            .transition(.opacity)
          }
        }
        .themeAnimation(health.isLive)
    }
    .composerPresentation(isPresented: $isComposerOpen, compact: sizeClass != .regular) {
      ComposerSheet(
        store: store.scope(state: \.composer, action: \.composer),
        projects: store.browser.projects,
        macName: store.connection.activeGateway?.displayName ?? "Mac",
        onLaunched: { launch in
          isComposerOpen = false
          if let paneID = launch.paneID {
            paneMemory.remember(pane: paneID, inWorktree: launch.worktreeID)
          }
          pendingPaneID = launch.paneID
          selectedWorktreeID = launch.worktreeID
          selectPendingPane()
        }
      )
    }
    .onChange(of: selectedWorktreeID) { _, _ in
      followSelection()
      resolvePane()
    }
    .onChange(of: selectedPaneID) { _, paneID in
      guard let paneID, let location = store.browser.location(ofPane: paneID) else { return }
      paneMemory.remember(pane: paneID, inWorktree: location.worktree.id)
    }
    .onChange(of: store.browser.hierarchy) { _, _ in
      selectPendingPane()
      resolvePane()
    }
    .task(id: store.browser.hierarchy?.projects.count) {
      followSelection()
      resolvePane()
    }
    .onChange(of: health.isLive) { _, isLive in
      if isLive, wasDropped { reconnects += 1 }
      wasDropped = !isLive && (wasLive || wasDropped)
      wasLive = isLive
    }
    .sensoryFeedback(.impact(weight: .light), trigger: reconnects)
    .task {
      #if DEBUG
        if DemoMode.initialSheet == "composer" {
          try? await Task.sleep(for: .seconds(1.5))
          isComposerOpen = true
        }
      #endif
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let paneID = selectedPaneID, let location = store.browser.location(ofPane: paneID),
      location.worktree.id == selectedWorktreeID
    {
      if store.connection.supportsLiveTerminal {
        TerminalDetailView(store: store, selectedPaneID: $selectedPaneID)
      } else {
        PaneDetailContainer(store: store, paneID: paneID)
          .safeAreaInset(edge: .top, spacing: 0) {
            if health.needsMacUpdate { LiveTerminalUnavailableNotice() }
          }
      }
    } else if let found = store.browser.worktree(id: selectedWorktreeID) {
      StateView(
        symbol: "terminal",
        title: "No terminals",
        message: "\(found.worktree.name) has no open terminals on your Mac.")
        .navigationTitle(found.worktree.name)
    } else if selectedWorktreeID != nil {
      // Restored before the hierarchy arrived: the terminal's own dark
      // page, not a flash of "choose a worktree".
      MirrorTerminalView.background.swiftUIColor
        .ignoresSafeArea(edges: .bottom)
    } else {
      StateView(
        symbol: "sidebar.leading",
        title: "Choose a worktree",
        message: "Its terminal opens here, on the pane you last looked at.")
    }
  }

  // MARK: - Selection

  /// Lands on the selected worktree's pane: the one last viewed here, else
  /// the Mac's selected tab's focused pane, else the first.
  private func resolvePane() {
    guard let worktreeID = selectedWorktreeID, let found = store.browser.worktree(id: worktreeID) else { return }
    if let paneID = selectedPaneID, store.browser.location(ofPane: paneID)?.worktree.id == worktreeID { return }
    selectedPaneID = TerminalLayout.landingPane(
      in: found.worktree, remembered: paneMemory.pane(inWorktree: worktreeID))
  }

  private func selectPendingPane() {
    guard let paneID = pendingPaneID,
      store.browser.location(ofPane: paneID)?.worktree.id == selectedWorktreeID
    else { return }
    pendingPaneID = nil
    selectedPaneID = paneID
  }

  /// The composer sends into the selected worktree, else the Mac's own
  /// selection; an explicit pick in the composer stays until the selection
  /// changes.
  private func followSelection() {
    let browser = store.browser
    if let found = browser.worktree(id: selectedWorktreeID) {
      store.send(.composer(.targetSelected(.worktree(projectID: found.project.id, worktreeID: found.worktree.id))))
      return
    }
    // Keep a target that still exists on the Mac (including a pending new
    // worktree in a project that still exists).
    if let target = store.composer.target, Self.exists(target, in: browser) { return }
    let project = browser.project(id: browser.hierarchy?.selectedProjectID) ?? browser.projects.first
    guard let project else { return }
    let worktree = project.worktrees.first { $0.id == project.selectedWorktreeID } ?? project.worktrees.first
    store.send(
      .composer(
        .targetSelected(
          worktree.map { .worktree(projectID: project.id, worktreeID: $0.id) } ?? .newWorktree(projectID: project.id))))
  }

  private static func exists(_ target: ComposerFeature.Target, in browser: BrowserFeature.State) -> Bool {
    switch target {
    case .worktree(_, let worktreeID): return browser.worktree(id: worktreeID) != nil
    case .newWorktree(let projectID): return browser.project(id: projectID) != nil
    }
  }
}

// MARK: - Home list

/// Projects as folders, each with its worktrees; skeleton rows until the
/// first data arrives, the reconnecting strip on top while not live.
private struct HomeList: View {
  let store: StoreOf<AppFeature>
  @Binding var selectedWorktreeID: String?
  /// Whether the list sits beside its detail. Decided by the split view's
  /// size class: the sidebar column itself always reports compact.
  let showsSelection: Bool
  let actions: HomeActions
  let newAgent: (String) -> Void

  private var health: ConnectionHealth { store.connection.health }

  var body: some View {
    List(selection: $selectedWorktreeID) {
      // A row, not a top inset: an inset sits under the bar's scroll-edge
      // effect and is hard to read there.
      if health.isPaired, !health.isLive, store.browser.hierarchy != nil {
        ConnectionBanner(
          health: health,
          retry: { store.send(.connection(.connectTapped)) },
          pairAgain: actions.openPairing
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
      }
      if store.browser.hierarchy == nil {
        skeleton
      } else {
        ForEach(store.browser.projects, id: \.id) { project in
          Section {
            ProjectHeaderRow(project: project, canCompose: canCompose) { newAgent(project.id) }
              .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 12))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
              .selectionDisabled()
            ForEach(project.worktrees, id: \.id) { worktree in
              WorktreeRow(
                worktree: worktree,
                agents: store.agents.summary(forWorktree: worktree.id),
                isStale: !health.isLive
              )
              .tag(worktree.id)
              .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
              .listRowSeparator(.hidden)
              .listRowBackground(rowBackground(worktree.id))
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.surface)
    .overlay {
      if let hierarchy = store.browser.hierarchy, hierarchy.projects.isEmpty {
        StateView(
          symbol: "folder",
          title: "No projects yet",
          message: "Projects you add in Codans on your Mac show up here.")
      }
    }
    .themeAnimation(health.isLive)
    .themeAnimation(store.browser.hierarchy == nil)
  }

  private var canCompose: Bool { store.connection.terminalPermission == .interactive }

  /// A soft rounded fill for the sidebar's selection instead of the
  /// system's solid accent bar; compact width has no persistent selection.
  @ViewBuilder
  private func rowBackground(_ id: String) -> some View {
    if showsSelection, selectedWorktreeID == id {
      RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        .fill(Color.surfaceMuted)
        .padding(.horizontal, Theme.Space.xs)
    } else {
      Color.clear
    }
  }

  @ViewBuilder
  private var skeleton: some View {
    Section {
      HStack(spacing: Theme.Space.sm) {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.surfaceMuted)
          .frame(width: 22, height: 18)
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.surfaceMuted)
          .frame(width: 96, height: 14)
      }
      .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 16))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()
      ForEach(0..<4, id: \.self) { index in
        SkeletonRow(variant: [0.1, 0.8, 0.4, 0.65][index])
          .padding(.leading, HomeMetrics.rowIndent)
          .padding(.vertical, 6)
          .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .selectionDisabled()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(health.title)
    .accessibilityIdentifier("home-skeleton")
  }
}

enum HomeMetrics {
  /// Worktree rows start under the project's name, past its folder glyph.
  static let rowIndent: CGFloat = 34
}

private struct ProjectHeaderRow: View {
  let project: IPC.ProjectSummary
  let canCompose: Bool
  let newAgent: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.sm) {
      Image(systemName: "folder")
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(Color.ink)
        .frame(width: 22)
        .accessibilityHidden(true)
      Text(project.name)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color.ink)
        .lineLimit(1)
      Spacer(minLength: Theme.Space.xs)
      if canCompose {
        Button(action: newAgent) {
          Image(systemName: "square.and.pencil")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Color.inkSecondary)
            .frame(width: 36, height: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Agent in \(project.name)")
        .accessibilityIdentifier("project-new-agent")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isHeader)
  }
}

private struct WorktreeRow: View {
  let worktree: IPC.WorktreeSummary
  let agents: AgentSummary?
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(worktree.name)
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(Color.ink)
        .lineLimit(1)
      HStack(spacing: Theme.Space.xs) {
        Text(detail)
          .font(.rowDetail)
          .foregroundStyle(Color.inkSecondary)
          .lineLimit(1)
        if let agents, agents.kind != .idle {
          AgentChip(kind: agents.kind, count: agents.count)
        }
      }
    }
    .padding(.leading, HomeMetrics.rowIndent)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    // Old data stays readable but reads as old.
    .opacity(isStale ? 0.5 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("worktree-row")
  }

  /// The branch when it says something the name does not, and the tabs.
  private var detail: String {
    let tabs = worktree.tabs.count == 1 ? "1 tab" : "\(worktree.tabs.count) tabs"
    guard let branch = worktree.branch, branch != worktree.name else { return tabs }
    return "\(branch) · \(tabs)"
  }
}

// MARK: - Title and toolbar

/// The Mac's name with a chevron over the connection status line; a menu
/// to switch Mac, see the connection, reconnect, and reach Settings.
struct HomeTitleMenu: View {
  let store: StoreOf<AppFeature>
  let actions: HomeActions

  var body: some View {
    let connection = store.connection
    Menu {
      if connection.gateways.count > 1 {
        Section("Macs") {
          ForEach(connection.gateways) { gateway in
            Button {
              store.send(.connection(.gatewaySelected(gateway.deviceID)))
            } label: {
              if gateway.deviceID == connection.activeID {
                Label(gateway.displayName, systemImage: "checkmark")
              } else {
                Text(gateway.displayName)
              }
            }
          }
        }
      }
      if connection.health.isPaired {
        Section {
          Button("Connection Details", systemImage: "info.circle", action: actions.openConnectionDetails)
          Button("Reconnect Now", systemImage: "arrow.clockwise") { store.send(.connection(.connectTapped)) }
        }
      }
      Section {
        Button("Settings", systemImage: "gearshape", action: actions.openSettings)
          .accessibilityIdentifier("open-settings")
        Button("Pair New Mac…", systemImage: "plus", action: actions.openPairing)
      }
    } label: {
      VStack(spacing: 1) {
        HStack(spacing: 4) {
          Text(connection.activeGateway?.displayName ?? "Codans")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.inkSecondary)
            .accessibilityHidden(true)
        }
        if connection.health.isPaired {
          ConnectionStatusLine(health: connection.health)
            .font(.system(size: 12))
        }
      }
      .padding(.horizontal, Theme.Space.xs)
      .contentShape(.rect)
    }
    .accessibilityIdentifier("home-title-menu")
  }
}

/// Agents as a toolbar icon; an amber count sits on it while agents wait
/// for input.
struct AgentsToolbarButton: View {
  let needsInput: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "sparkles")
        .overlay(alignment: .topTrailing) {
          if needsInput > 0 {
            Text("\(needsInput)")
              .font(.system(size: 10, weight: .bold).monospacedDigit())
              .foregroundStyle(.white)
              .padding(.horizontal, 4)
              .frame(minWidth: 15, minHeight: 15)
              .background(Color.needsInput, in: .capsule)
              .offset(x: 9, y: -7)
          }
        }
    }
    .accessibilityLabel("Agents")
    .accessibilityValue(needsInput > 0 ? "\(needsInput) need input" : "")
    .accessibilityIdentifier("open-agents")
  }
}

/// Shown over the text snapshot for a Mac too old to stream terminals.
private struct LiveTerminalUnavailableNotice: View {
  var body: some View {
    InlineBanner(
      color: .offline,
      title: "Update Codans on your Mac",
      detail: { Text("For a live terminal. Showing text snapshots until then.") }
    )
    .padding(.horizontal, Theme.Space.sm)
    .padding(.vertical, Theme.Space.xs)
    .background(Color.surface)
    .accessibilityIdentifier("live-terminal-unavailable")
  }
}

extension View {
  /// Full screen on a phone, like a page of its own; a sheet in regular
  /// width, where a full-screen card would be a wall of white.
  func composerPresentation<Content: View>(
    isPresented: Binding<Bool>, compact: Bool, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(ComposerPresentation(isPresented: isPresented, compact: compact, sheet: content))
  }
}

private struct ComposerPresentation<Sheet: View>: ViewModifier {
  @Binding var isPresented: Bool
  let compact: Bool
  @ViewBuilder let sheet: () -> Sheet

  func body(content: Content) -> some View {
    if compact {
      content.fullScreenCover(isPresented: $isPresented, content: sheet)
    } else {
      content.sheet(isPresented: $isPresented) {
        sheet().presentationSizing(.form)
      }
    }
  }
}
