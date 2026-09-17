import ComposableArchitecture
import SwiftUI

/// SwiftUI owns the toolbar so NavigationSplitView can install native sidebar controls.
struct DiffWindowToolbar: ToolbarContent {
  @Bindable var store: StoreOf<DiffFeature>

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Picker(
        "Diff Layout",
        selection: Binding(get: { store.layout }, set: { store.send(.layoutChanged($0)) })
      ) {
        Image(systemName: "rectangle").accessibilityLabel("Unified Diff").tag("unified")
        Image(systemName: "rectangle.split.2x1").accessibilityLabel("Split Diff").tag("split")
      }
      .pickerStyle(.segmented).labelsHidden().help("Diff layout")
      .accessibilityIdentifier("diff-layout")
      Button {
        store.send(.refresh)
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh changes").accessibilityIdentifier("diff-refresh")
    }
  }
}
