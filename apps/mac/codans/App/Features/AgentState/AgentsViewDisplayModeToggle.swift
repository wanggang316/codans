import CodansCore

/// Presentation of the Agents View title-row button that flips
/// `GeneralSettings.agentsViewDisplayMode`. The icon and label name the
/// mode a click switches to, not the current one.
struct AgentsViewDisplayModeToggle: Equatable {
  let target: AgentsViewDisplayMode

  init(current: AgentsViewDisplayMode) {
    switch current {
    case .normal: target = .compact
    case .compact: target = .normal
    }
  }

  var systemImage: String {
    switch target {
    case .compact: "rectangle.compress.vertical"
    case .normal: "rectangle.expand.vertical"
    }
  }

  var label: String {
    switch target {
    case .compact: "Switch to Compact"
    case .normal: "Switch to Normal"
    }
  }

  /// Writes the flipped mode through the global setting so it persists and
  /// the Settings picker stays in sync; the panel keeps no state of its own.
  @MainActor
  static func apply(to store: SettingsStore) {
    let toggle = AgentsViewDisplayModeToggle(current: store.settings.general.agentsViewDisplayMode)
    store.setAgentsViewDisplayMode(toggle.target)
  }
}
