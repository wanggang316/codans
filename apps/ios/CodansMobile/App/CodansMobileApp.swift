import ComposableArchitecture
import SwiftUI

@main
struct CodansMobileApp: App {
  /// Aggregate phase across every scene: `.background` only when all of
  /// them are, so a second window going away does not drop the connection.
  @Environment(\.scenePhase) private var scenePhase

  /// One store for the process. Each `WindowGroup` scene (iPad windows,
  /// iPhone Duo Split View) renders from it and shares its connection.
  @State private var store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  var body: some Scene {
    WindowGroup {
      if Self.isHostingTests {
        // Unit tests are hosted by this app; keep the live network stack
        // and its dependencies out of the test process.
        EmptyView()
      } else {
        RootView(store: store)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard !Self.isHostingTests else { return }
      store.send(.connection(.scenePhaseChanged(phase)))
    }
  }

  private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
