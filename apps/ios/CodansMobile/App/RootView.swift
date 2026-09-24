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
  }

  private func openSettings() {
    tab = .settings
  }
}
