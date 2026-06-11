import ComposableArchitecture
import Foundation
import CodansCore

/// Lightweight TCA dependency wrapping `EnvironmentValues.openWindow` for the Settings
/// scene. Reducers that need to bring the Settings window up (e.g. the Worktree Header's
/// "+ Custom editors…" delegate) inject this instead of plumbing an `OpenWindowAction`
/// through the ViewStore. `CodansApp` overrides `liveValue` inside the main scene body
/// so the closure captures the live `@Environment(\.openWindow)` value.
nonisolated struct SettingsWindowPresenter: Sendable {
  var open: @MainActor @Sendable () -> Void
  /// Open the Settings window AND select the given section. Used by
  /// "Manage Scripts…" in the worktree-header split button to land
  /// the user directly on the Project Scripts pane for the active
  /// Project rather than wherever the sidebar was last left.
  var openAt: @MainActor @Sendable (SettingsSection) -> Void
}

extension SettingsWindowPresenter: DependencyKey {
  /// `liveValue` is intentionally unusable — missing wiring is a programmer error, not a
  /// silent no-op. `CodansApp.body` overrides via `.withDependencies` at scene attach.
  static let liveValue: SettingsWindowPresenter = SettingsWindowPresenter(
    open: {
      fatalError(
        "SettingsWindowPresenter.liveValue not configured; wire via `.withDependencies` with { $0.settingsWindowPresenter = ... } in CodansApp"
      )
    },
    openAt: { _ in
      fatalError(
        "SettingsWindowPresenter.liveValue not configured; wire via `.withDependencies` with { $0.settingsWindowPresenter = ... } in CodansApp"
      )
    }
  )

  static let testValue: SettingsWindowPresenter = SettingsWindowPresenter(
    open: unimplemented("SettingsWindowPresenter.open"),
    openAt: unimplemented("SettingsWindowPresenter.openAt")
  )
}

extension DependencyValues {
  var settingsWindowPresenter: SettingsWindowPresenter {
    get { self[SettingsWindowPresenter.self] }
    set { self[SettingsWindowPresenter.self] = newValue }
  }
}
