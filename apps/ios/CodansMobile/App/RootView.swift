import ComposableArchitecture
import SwiftUI

/// A sheet presented over the workspace.
enum RootSheet: String, Identifiable {
  case agents
  case settings

  var id: String { rawValue }
}

/// Root of every scene: the Project → Worktree workspace, with Agents and
/// Settings as sheets from its toolbar. The workspace's split view adapts
/// to size class (sidebar in regular width on iPad and the iPhone Duo inner
/// display, a stack in compact width), with no size or orientation checks
/// here.
struct RootView: View {
  let store: StoreOf<AppFeature>

  /// Per scene, so folding, unfolding and multiple windows each keep their
  /// own place.
  @SceneStorage("workspace.selectedWorktree") private var selectedWorktreeID: String?
  @SceneStorage("workspace.selectedPane") private var selectedPaneID: String?
  @State private var sheet: RootSheet?

  var body: some View {
    WorkspaceView(
      store: store,
      openAgents: { sheet = .agents },
      openSettings: { sheet = .settings },
      selectedWorktreeID: $selectedWorktreeID,
      selectedPaneID: $selectedPaneID
    )
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .agents:
        AgentsView(store: store) { entry in
          self.sheet = nil
          selectedWorktreeID = entry.worktreeID
          selectedPaneID = entry.paneID
        }
      case .settings:
        SettingsView(store: store.scope(state: \.connection, action: \.connection))
      }
    }
    .task { store.send(.connection(.task)) }
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
