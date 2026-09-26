import ComposableArchitecture
import SwiftUI

/// A sheet presented over the workspace.
enum RootSheet: String, Identifiable {
  case agents
  case settings
  /// Settings, opened on pairing a new Mac.
  case pairing
  case connectionDetails

  var id: String { rawValue }
}

/// Root of every scene: the workspace, or a full-page connection state
/// when there is nothing to show or nothing shown could refresh. Agents,
/// Settings and connection details are sheets. Layout adapts to size
/// class only, with no size or orientation checks here.
struct RootView: View {
  let store: StoreOf<AppFeature>

  /// Per scene, so folding, unfolding and multiple windows each keep their
  /// own place.
  @SceneStorage("workspace.selectedWorktree") private var selectedWorktreeID: String?
  @SceneStorage("workspace.selectedPane") private var selectedPaneID: String?
  @SceneStorage("workspace.paneMemory") private var paneMemoryStorage = ""
  @State private var sheet: RootSheet?

  private var actions: HomeActions {
    HomeActions(
      openAgents: { sheet = .agents },
      openSettings: { sheet = .settings },
      openPairing: { sheet = .pairing },
      openConnectionDetails: { sheet = .connectionDetails }
    )
  }

  private var paneMemory: Binding<PaneMemory> {
    Binding(
      get: { PaneMemory(encoded: paneMemoryStorage) },
      set: { paneMemoryStorage = $0.encoded }
    )
  }

  var body: some View {
    content
      .tint(Color.ink)
      .sheet(item: $sheet) { sheet in
        Group {
          switch sheet {
          case .agents:
            AgentsView(store: store) { entry in
              self.sheet = nil
              paneMemory.wrappedValue.remember(pane: entry.paneID, inWorktree: entry.worktreeID)
              selectedPaneID = entry.paneID
              selectedWorktreeID = entry.worktreeID
            }
          case .settings, .pairing:
            SettingsView(
              store: store.scope(state: \.connection, action: \.connection), startsPairing: sheet == .pairing)
          case .connectionDetails:
            ConnectionDetailsView(store: store.scope(state: \.connection, action: \.connection))
          }
        }
        .tint(Color.ink)
      }
      .task {
        #if DEBUG
          applyDemoSelection()
        #endif
        store.send(.connection(.task))
      }
    .onOpenURL { store.send(.connection(.pairingLinkOpened($0))) }
    .alert(linkPairingTitle, isPresented: isLinkPairingPresented) {
      if case .confirm = store.connection.linkPairing {
        Button("Pair") { store.send(.connection(.linkPairingConfirmed)) }
        Button("Cancel", role: .cancel) { store.send(.connection(.linkPairingDismissed)) }
      } else {
        Button("OK", role: .cancel) { store.send(.connection(.linkPairingDismissed)) }
      }
    } message: {
      switch store.connection.linkPairing {
      case .confirm:
        Text(
          "Only pair with a Mac you own. Codans will connect to it over your local network "
            + "and show its terminals here.")
      case .invalid(let message):
        Text(message)
      case nil:
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    let health = store.connection.health
    if !store.connection.hasStarted {
      Color.surface.ignoresSafeArea()
    } else if let blocker = health.blocker(hasContent: store.browser.hierarchy != nil) {
      NavigationStack {
        ConnectionStateView(
          blocker: blocker,
          health: health,
          retry: { store.send(.connection(.connectTapped)) },
          pair: actions.openPairing
        )
        .background(Color.surface)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .principal) {
            HomeTitleMenu(store: store, actions: actions)
          }
        }
      }
    } else {
      WorkspaceView(
        store: store,
        actions: actions,
        selectedWorktreeID: $selectedWorktreeID,
        selectedPaneID: $selectedPaneID,
        paneMemory: paneMemory
      )
    }
  }

  #if DEBUG
    /// Demo screenshots start on a pane or a sheet named in the
    /// environment.
    private func applyDemoSelection() {
      if let demo = DemoMode.initialSelection {
        paneMemory.wrappedValue.remember(pane: demo.paneID, inWorktree: demo.worktreeID)
        selectedPaneID = demo.paneID
        selectedWorktreeID = demo.worktreeID
      } else if DemoMode.isEnabled {
        selectedWorktreeID = nil
        selectedPaneID = nil
      }
      if let name = DemoMode.initialSheet, let demoSheet = RootSheet(rawValue: name) {
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          sheet = demoSheet
        }
      }
    }
  #endif

  private var linkPairingTitle: String {
    switch store.connection.linkPairing {
    case .confirm(let payload): "Pair with \u{201C}\(payload.serviceName)\u{201D}?"
    case .invalid: "Can't Pair"
    case nil: ""
    }
  }

  private var isLinkPairingPresented: Binding<Bool> {
    Binding(
      get: { store.connection.linkPairing != nil },
      set: { if !$0 { store.send(.connection(.linkPairingDismissed)) } }
    )
  }
}
