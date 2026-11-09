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
  /// Open the Settings window AND select the given section, rather than
  /// wherever the sidebar was last left.
  var openAt: @MainActor @Sendable (SettingsSection) -> Void
  /// Open the Settings window on the Project's page scrolled to its Commands
  /// section ("Manage Project Commands…").
  var openProjectCommands: @MainActor @Sendable (ProjectID) -> Void = { _ in }
  /// Open the Settings window on the Remote Hosts page with the Host's edit form
  /// (the sidebar Host row's "Edit Host…").
  var editHost: @MainActor @Sendable (HostID) -> Void = { _ in }
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
    },
    openProjectCommands: { _ in
      fatalError(
        "SettingsWindowPresenter.liveValue not configured; wire via `.withDependencies` with { $0.settingsWindowPresenter = ... } in CodansApp"
      )
    },
    editHost: { _ in
      fatalError(
        "SettingsWindowPresenter.liveValue not configured; wire via `.withDependencies` with { $0.settingsWindowPresenter = ... } in CodansApp"
      )
    }
  )

  static let testValue: SettingsWindowPresenter = SettingsWindowPresenter(
    open: unimplemented("SettingsWindowPresenter.open"),
    openAt: unimplemented("SettingsWindowPresenter.openAt"),
    openProjectCommands: unimplemented("SettingsWindowPresenter.openProjectCommands"),
    editHost: unimplemented("SettingsWindowPresenter.editHost")
  )
}

extension DependencyValues {
  var settingsWindowPresenter: SettingsWindowPresenter {
    get { self[SettingsWindowPresenter.self] }
    set { self[SettingsWindowPresenter.self] = newValue }
  }
}
