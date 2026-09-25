import ComposableArchitecture
import SwiftUI

/// The three top-level destinations. Raw values persist in scene storage.
enum RootTab: String, Hashable {
  case agents
  case browse
  case settings
}

/// Root of every scene. `.sidebarAdaptable` makes the tab bar a sidebar in
/// regular width (iPad, iPhone Duo inner display) and a bottom bar in
/// compact width, with no size or orientation checks here.
struct RootView: View {
  let store: StoreOf<AppFeature>

  /// Per scene, so folding, unfolding and multiple windows each keep their
  /// own place.
  @SceneStorage("root.tab") private var tab: RootTab = .agents

  var body: some View {
    TabView(selection: $tab) {
      Tab("Agents", systemImage: "sparkles", value: RootTab.agents) {
        AgentsView(store: store, openSettings: openSettings)
      }
      .badge(store.agents.needsInputCount)

      Tab("Browse", systemImage: "folder", value: RootTab.browse) {
        BrowserView(store: store, openSettings: openSettings)
      }

      Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
        SettingsView(store: store.scope(state: \.connection, action: \.connection))
      }
    }
    .tabViewStyle(.sidebarAdaptable)
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

  private func openSettings() {
    tab = .settings
  }
}
